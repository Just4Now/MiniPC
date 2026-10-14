'use strict';

const { utf8ByteLength, sha256Text } = require('../protocol/text');
const {
  LIMITS,
  validateInferMessage,
  wireMessage,
  errorMessage,
  contextAdmission,
  estimateTokens
} = require('../protocol/inference-v2');
const { ComputeAdmission } = require('./compute-admission');
const { StreamWindow } = require('./stream-window');
const { safeLog } = require('./native-inference-service');
const { pickInferenceNode } = require('./pick-inference-node');

class InferenceGateway {
  constructor(options) {
    this.profile = options.profile;
    this.executor = options.executor;
    this.sendTo = options.send;
    this.now = options.now || (() => Date.now());
    this.schedule = options.schedule || ((fn, ms) => setTimeout(fn, ms));
    this.clear = options.clear || ((id) => clearTimeout(id));
    this.logger = options.logger || (() => {});
    this.admission = options.admission || new ComputeAdmission();
    this.peers = options.peers || [];
    this.jobs = new Map();
    this.forwards = new Map();
    this.tombs = [];
    this.isolated = false;
    this.forwardSeq = 1;
    this.maxUnackedSeq = options.maxUnackedSeq || 16;
  }

  handle(message, ingress) {
    const checked = validateInferMessage(message);
    if (!checked.ok) {
      if (message && message.requestId) this.reply(ingress.epoch, errorMessage(message.requestId, checked.code));
      return;
    }
    if (!ingress.inferenceV2) {
      this.reply(ingress.epoch, errorMessage(message.requestId, 'PROTOCOL_UNSUPPORTED'));
      return;
    }
    if (message.type === 'infer.capabilities.get') {
      this.reply(ingress.epoch, wireMessage('infer.capabilities', {
        requestId: message.requestId,
        profiles: [this.publicProfile()]
      }));
      return;
    }
    if (message.type === 'infer.request') this.onRequest(message, ingress);
    else if (message.type === 'infer.cancel') this.onCancel(message, ingress);
    else if (message.type === 'infer.ack') this.onAck(message, ingress);
    else if (message.type === 'infer.delta' || message.type === 'infer.done' ||
      message.type === 'infer.error' || message.type === 'infer.cancelled') this.onWorker(message, ingress);
  }

  publicProfile() {
    const profile = Object.assign({}, this.profile);
    if (this.isolated) {
      profile.ready = false;
      profile.readinessReason = '节点已隔离，等待重启模型服务';
    }
    return profile;
  }

  requestKey(ingress, message) {
    return String(ingress.epoch) + ':' + message.clientInstanceId + ':' + message.requestId;
  }

  onRequest(message, ingress) {
    if (message.sched === true && ingress.role !== 'compute') {
      this.reply(ingress.epoch, errorMessage(message.requestId, 'REJECTED'));
      return;
    }
    const key = this.requestKey(ingress, message);
    const tomb = this.findTomb(key) || this.findTomb(String(ingress.epoch) + ':' + message.requestId);
    if (tomb) {
      const code = tomb.kind === 'cancel' ? 'CANCELLED' : 'REJECTED';
      this.reply(ingress.epoch, errorMessage(message.requestId, code, false));
      return;
    }
    if (this.jobs.has(key)) return;
    const profile = this.publicProfile();
    if (!profile.ready || message.modelId !== profile.modelId || message.modelRevision !== profile.modelRevision ||
      message.promptFormat !== profile.promptFormat) {
      this.reply(ingress.epoch, errorMessage(message.requestId, 'MODEL_UNAVAILABLE'));
      return;
    }
    if (message.maxOutputTokens > profile.maxOutputTokens) {
      this.reply(ingress.epoch, errorMessage(message.requestId, 'REJECTED'));
      return;
    }
    const context = contextAdmission(profile, message.prompt, message.maxOutputTokens);
    if (!context.ok) {
      this.reply(ingress.epoch, errorMessage(message.requestId, context.code));
      return;
    }
    if (message.sched !== true) {
      const peer = pickInferenceNode(this.peers, {
        promptFormat: message.promptFormat,
        modelId: message.modelId,
        modelRevision: message.modelRevision,
        contextTokens: estimateTokens(message.prompt) + message.maxOutputTokens + 64,
        maxOutputTokens: message.maxOutputTokens
      });
      if (peer && !peer.isSelf) {
        this.forward(message, ingress, key, peer);
        return;
      }
    }
    this.acquire(message, ingress, key);
  }

  acquire(message, ingress, key) {
    const clientId = String(ingress.epoch) + ':' + message.clientInstanceId;
    const slot = this.admission.tryAcquire(clientId, message.requestId);
    if (slot === 'busy') {
      this.reply(ingress.epoch, errorMessage(message.requestId, 'BUSY'));
      return;
    }
    const job = {
      key: key,
      localId: key,
      message: message,
      ingress: ingress,
      clientId: clientId,
      state: slot,
      queuedAt: this.now(),
      parts: [],
      window: new StreamWindow(this.maxUnackedSeq, 16384),
      nativeId: 0,
      cleaned: false,
      cleanupTimer: 0,
      statusTimer: 0
    };
    this.jobs.set(key, job);
    this.reply(ingress.epoch, wireMessage('infer.accepted', {
      requestId: message.requestId,
      state: slot === 'queued' ? 'queued' : 'preparing',
      source: this.profile.modelId
    }));
    safeLog(this.logger, { stage: slot, requestId: message.requestId, bytes: utf8ByteLength(message.prompt), epoch: ingress.epoch });
    this.armStatus(job);
    if (slot === 'acquired') this.execute(job);
    else this.armQueueTimer(job);
  }

  armStatus(job) {
    const tick = () => {
      if (!this.jobs.has(job.key) || job.cleaned) return;
      const state = job.state === 'queued' ? 'queued' : 'generating';
      this.reply(job.ingress.epoch, wireMessage('infer.status', {
        requestId: job.message.requestId,
        state: state,
        elapsedMs: Math.max(0, this.now() - job.queuedAt)
      }));
      job.statusTimer = this.schedule(tick, 2000);
    };
    job.statusTimer = this.schedule(tick, 2000);
  }

  armQueueTimer(job) {
    job.cleanupTimer = this.schedule(() => {
      if (!this.jobs.has(job.key) || job.state !== 'queued') return;
      this.admission.release(job.clientId, job.message.requestId);
      this.jobs.delete(job.key);
      this.reply(job.ingress.epoch, errorMessage(job.message.requestId, 'QUEUE_TIMEOUT'));
    }, LIMITS.queueWaitMs);
  }

  execute(job) {
    this.clear(job.cleanupTimer);
    job.state = 'running';
    const elapsed = this.now() - job.queuedAt;
    const budget = Math.max(1, job.message.deadlineBudgetMs - elapsed);
    try {
      job.nativeId = this.executor.submit({
        forwardId: job.localId,
        prompt: job.message.prompt,
        image: job.message.image,
        maxOutputTokens: job.message.maxOutputTokens,
        maxCtx: this.profile.maxCtx,
        deadlineBudgetMs: budget
      }, {
        onDelta: (text) => this.onDelta(job, text),
        onCleaned: (kind, code) => this.onCleaned(job, kind, code)
      });
    } catch (error) {
      this.finishLocal(job, 'error', error.code || 'MODEL_EXECUTION_FAILED');
    }
  }

  onDelta(job, text) {
    if (job.cleaned) return false;
    const seq = job.window.push(utf8ByteLength(text));
    if (!seq) return false;
    job.parts.push(text);
    this.reply(job.ingress.epoch, wireMessage('infer.delta', {
      requestId: job.message.requestId,
      seq: seq,
      text: text
    }));
    return true;
  }

  onCleaned(job, kind, code) {
    if (job.cleaned) return;
    if (kind === 'done') {
      const text = job.parts.join('');
      if (text.trim().length === 0) {
        this.reply(job.ingress.epoch, errorMessage(job.message.requestId, 'MODEL_EXECUTION_FAILED'));
        this.remember(job.key, 'error');
        this.release(job);
        return;
      }
      this.reply(job.ingress.epoch, wireMessage('infer.done', {
        requestId: job.message.requestId,
        lastSeq: job.parts.length,
        outputUtf8Bytes: utf8ByteLength(text),
        outputSha256: sha256Text(text),
        finishReason: 'stop',
        source: this.profile.modelId
      }));
      this.remember(job.key, 'done');
      this.release(job);
      return;
    }
    const errorCode = kind === 'cancelled' ? 'CANCELLED' : (code || 'MODEL_EXECUTION_FAILED');
    this.reply(job.ingress.epoch, errorMessage(job.message.requestId, errorCode));
    this.remember(job.key, kind === 'cancelled' ? 'cancel' : 'error');
    this.release(job);
  }

  finishLocal(job, kind, code) {
    this.onCleaned(job, kind, code);
  }

  findJob(epoch, requestId) {
    for (const job of this.jobs.values()) {
      if (job.ingress.epoch === epoch && job.message.requestId === requestId) return job;
    }
    return undefined;
  }

  onCancel(message, ingress) {
    const job = this.findJob(ingress.epoch, message.requestId);
    const key = job ? job.key : String(ingress.epoch) + ':' + message.requestId;
    if (!job) {
      this.remember(key, 'cancel');
      this.reply(ingress.epoch, wireMessage('infer.cancelled', { requestId: message.requestId }));
      return;
    }
    if (job.state === 'queued') {
      this.clear(job.cleanupTimer);
      this.clear(job.statusTimer);
      this.admission.release(job.clientId, job.message.requestId);
      this.jobs.delete(job.key);
      this.remember(job.key, 'cancel');
      this.reply(ingress.epoch, wireMessage('infer.cancelled', { requestId: message.requestId }));
      this.promote();
      return;
    }
    job.cleanupTimer = this.schedule(() => {
      if (job.cleaned) return;
      this.isolated = true;
      safeLog(this.logger, { stage: 'isolate', requestId: message.requestId, code: 'CANCELLED' });
    }, LIMITS.cancelCleanupMs);
    this.executor.cancel(job.localId);
  }

  onAck(message, ingress) {
    for (const job of this.jobs.values()) {
      if (job.message.requestId === message.requestId && job.ingress.epoch === ingress.epoch) job.window.ack(message.ackSeq);
    }
  }

  forward(message, ingress, key, peer) {
    const forwardId = 'f' + String(this.forwardSeq);
    this.forwardSeq += 1;
    const clientId = String(ingress.epoch) + ':' + message.clientInstanceId;
    const slot = this.admission.tryAcquire(clientId, message.requestId);
    if (slot === 'busy') {
      this.reply(ingress.epoch, errorMessage(message.requestId, 'BUSY'));
      return;
    }
    this.forwards.set(forwardId, { key: key, requestId: message.requestId, originEpoch: ingress.epoch, workerEpoch: peer.epoch, clientId: clientId });
    this.jobs.set(key, { key: key, message: message, ingress: ingress, clientId: clientId, state: 'forwarded', forwardId: forwardId, cleaned: false });
    this.reply(ingress.epoch, wireMessage('infer.accepted', { requestId: message.requestId, state: 'preparing', source: peer.name || peer.modelId }));
    const forwarded = wireMessage('infer.request', {
      clientInstanceId: message.clientInstanceId,
      agentRunId: message.agentRunId,
      requestId: forwardId,
      modelId: message.modelId,
      modelRevision: message.modelRevision,
      promptFormat: message.promptFormat,
      prompt: message.prompt,
      maxOutputTokens: message.maxOutputTokens,
      deadlineBudgetMs: message.deadlineBudgetMs,
      sched: true,
      origin: 'loop'
    });
    // 附图必须随转发一起走，否则 worker 只拿到纯文本请求。
    if (message.image !== undefined) forwarded.image = message.image;
    this.sendTo(peer.epoch, forwarded);
  }

  onWorker(message, ingress) {
    if (ingress.role !== 'compute') return;
    const mapped = this.forwards.get(message.requestId);
    if (!mapped || mapped.workerEpoch !== ingress.epoch) return;
    const outbound = Object.assign({}, message, { requestId: mapped.requestId });
    this.reply(mapped.originEpoch, outbound);
    if (message.type === 'infer.done' || message.type === 'infer.error' || message.type === 'infer.cancelled') {
      this.forwards.delete(message.requestId);
      const job = this.jobs.get(mapped.key);
      if (job) this.release(job);
      this.remember(mapped.key, message.type === 'infer.cancelled' ? 'cancel' : 'done');
    }
  }

  release(job) {
    if (job.cleaned) return;
    job.cleaned = true;
    this.clear(job.cleanupTimer);
    this.clear(job.statusTimer);
    this.jobs.delete(job.key);
    const next = this.admission.release(job.clientId, job.message.requestId);
    if (next) this.promote(next);
  }

  promote(nextKey) {
    const key = nextKey || '';
    if (!key) return;
    for (const job of this.jobs.values()) {
      const jobKey = this.admission.key(job.clientId, job.message.requestId);
      if (jobKey === key && job.state === 'queued') {
        this.clear(job.cleanupTimer);
        this.execute(job);
      }
    }
  }

  dropEpoch(epoch) {
    for (const job of Array.from(this.jobs.values())) {
      if (job.ingress.epoch !== epoch) continue;
      const mapped = job.forwardId ? this.forwards.get(job.forwardId) : undefined;
      if (mapped) this.sendTo(mapped.workerEpoch, wireMessage('infer.cancel', { requestId: job.forwardId }));
      else if (job.localId && job.state === 'running') this.executor.cancel(job.localId);
      this.reply(epoch, errorMessage(job.message.requestId, 'CONNECTION_LOST'));
      this.release(job);
    }
  }

  remember(key, kind) {
    this.tombs.push({ key: key, kind: kind, at: this.now() });
    if (this.tombs.length > LIMITS.tombstones) this.tombs.shift();
  }

  findTomb(key) {
    const time = this.now();
    this.tombs = this.tombs.filter((item) => time - item.at < LIMITS.tombstoneMs);
    return this.tombs.find((item) => item.key === key);
  }

  reply(epoch, message) {
    this.sendTo(epoch, message);
  }
}

module.exports = { InferenceGateway };
