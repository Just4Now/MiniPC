'use strict';

const {
  LIMITS,
  ComputeError,
  validateInferMessage,
  wireMessage,
  StreamAssembler,
  redactPrompt,
  userText
} = require('../protocol/inference-v2');
const { utf8ByteLength, sha256Text } = require('../protocol/text');

function createId(prefix, seq) {
  return prefix + '-' + String(seq);
}

class ComputeClient {
  constructor(transport, options) {
    const settings = options || {};
    this.transport = transport;
    this.now = settings.now || (() => Date.now());
    this.schedule = settings.schedule || ((fn, ms) => setTimeout(fn, ms));
    this.clear = settings.clear || ((id) => clearTimeout(id));
    this.clientInstanceId = settings.clientInstanceId || 'boot-1';
    this.state = 'STOPPED';
    this.connectionEpoch = 0;
    this.profile = null;
    this.seq = 1;
    this.pending = new Map();
    this.listeners = [];
    this.negotiateTimer = 0;
    this.transport.setHandler((message) => this.onMessage(message));
    this.transport.setLinkHandler((event) => this.onLink(event));
  }

  onState(listener) {
    this.listeners.push(listener);
  }

  setState(state) {
    this.state = state;
    for (const listener of this.listeners) listener(state);
  }

  isReady() {
    return this.state === 'READY' && this.profile !== null && this.profile.ready === true;
  }

  modelLabel() {
    if (!this.profile) return 'MINIPC remote';
    return this.profile.modelId + ' @ ' + (this.profile.readinessReason || 'remote');
  }

  start() {
    if (this.state !== 'STOPPED' && this.state !== 'DISCONNECTED' && this.state !== 'INCOMPATIBLE') return;
    this.setState('DISCOVERING');
    this.transport.start();
  }

  stop() {
    this.failAll('CONNECTION_LOST');
    this.setState('STOPPED');
    this.profile = null;
    this.transport.stop();
  }

  onLink(event) {
    if (event.type === 'discovering') this.setState('DISCOVERING');
    else if (event.type === 'connecting') this.setState('CONNECTING');
    else if (event.type === 'negotiated') this.beginNegotiate(event.epoch);
    else if (event.type === 'incompatible') {
      this.connectionEpoch = event.epoch || this.connectionEpoch;
      this.failAll('PROTOCOL_UNSUPPORTED');
      this.setState('INCOMPATIBLE');
    } else if (event.type === 'down') {
      if (event.epoch !== undefined && event.epoch !== this.connectionEpoch) return;
      this.failAll('CONNECTION_LOST');
      this.profile = null;
      this.setState('DISCONNECTED');
    }
  }

  beginNegotiate(epoch) {
    this.connectionEpoch = epoch;
    this.profile = null;
    this.setState('NEGOTIATING');
    const requestId = createId('cap', this.seq);
    this.seq += 1;
    this.clear(this.negotiateTimer);
    this.negotiateTimer = this.schedule(() => {
      if (this.state === 'NEGOTIATING') {
        this.failAll('PROTOCOL_UNSUPPORTED');
        this.setState('INCOMPATIBLE');
      }
    }, LIMITS.negotiateMs);
    this.transport.send(wireMessage('infer.capabilities.get', { requestId: requestId }));
  }

  async infer(prompt, control, image) {
    if (!this.isReady()) throw new ComputeError(this.state === 'INCOMPATIBLE' ? 'PROTOCOL_UNSUPPORTED' : 'NO_COMPUTE');
    if (control && !control.checkpoint('before-model')) throw new ComputeError(control.reason || 'CANCELLED');
    const redacted = redactPrompt(prompt);
    if (utf8ByteLength(redacted) > this.profile.maxPromptBytes) throw new ComputeError('PAYLOAD_TOO_LARGE');
    const maxOutputTokens = Math.min(LIMITS.defaultOutputTokens, this.profile.maxOutputTokens);
    const requestId = createId('req', this.seq);
    this.seq += 1;
    const agentRunId = control ? control.agentRunId : createId('run', this.seq);
    const epoch = this.connectionEpoch;
    const generation = control ? control.runGeneration : 0;
    const message = wireMessage('infer.request', {
      clientInstanceId: this.clientInstanceId,
      agentRunId: agentRunId,
      requestId: requestId,
      modelId: this.profile.modelId,
      modelRevision: this.profile.modelRevision,
      promptFormat: this.profile.promptFormat,
      prompt: redacted,
      maxOutputTokens: maxOutputTokens,
      deadlineBudgetMs: LIMITS.hardInferenceMs
    });
    // 可选附图：裸 base64（无 data: 前缀）。只在确有图片时挂字段 ——
    // 值为 undefined 也会成为键，会被对端 hasOnly 判为未知字段而拒收。
    if (typeof image === 'string' && image.length > 0) message.image = image;
    const checked = validateInferMessage(message);
    if (!checked.ok) throw new ComputeError(checked.code);
    const pending = this.openPending(requestId, epoch, generation, control);
    const sent = await this.transport.send(message);
    if (!sent) {
      this.settle(requestId, new ComputeError('CONNECTION_LOST'));
    }
    return pending.promise;
  }

  openPending(requestId, epoch, generation, control) {
    let resolve;
    let reject;
    const promise = new Promise((done, failed) => {
      resolve = done;
      reject = failed;
    });
    const started = this.now();
    const pending = {
      requestId: requestId,
      epoch: epoch,
      generation: generation,
      control: control,
      assembler: new StreamAssembler(),
      resolve: resolve,
      reject: reject,
      promise: promise,
      terminal: '',
      started: started,
      progress: started,
      accepted: false,
      timers: []
    };
    pending.timers.push(this.schedule(() => {
      if (!pending.accepted && pending.terminal === '') this.expire(requestId, 'REQUEST_TIMEOUT');
    }, LIMITS.acceptedWaitMs));
    pending.timers.push(this.schedule(() => this.watch(requestId), LIMITS.progressIdleMs));
    this.pending.set(requestId, pending);
    return pending;
  }

  watch(requestId) {
    const pending = this.pending.get(requestId);
    if (!pending || pending.terminal) return;
    const elapsed = this.now() - pending.started;
    if (elapsed >= LIMITS.hardInferenceMs) {
      this.expire(requestId, 'REQUEST_TIMEOUT');
      return;
    }
    if (this.now() - pending.progress >= LIMITS.progressIdleMs) {
      this.expire(requestId, 'REQUEST_TIMEOUT');
      return;
    }
    pending.timers.push(this.schedule(() => this.watch(requestId), LIMITS.progressIdleMs));
  }

  expire(requestId, code) {
    const pending = this.pending.get(requestId);
    if (!pending || pending.terminal) return;
    this.transport.send(wireMessage('infer.cancel', { requestId: requestId }));
    this.settle(requestId, new ComputeError(code));
  }

  cancel(requestId) {
    const pending = this.pending.get(requestId);
    if (!pending) return;
    if (pending.control) pending.control.cancel('CANCELLED');
    this.transport.send(wireMessage('infer.cancel', { requestId: requestId }));
    this.settle(requestId, new ComputeError('CANCELLED'));
  }

  cancelAll(code) {
    for (const requestId of Array.from(this.pending.keys())) {
      const pending = this.pending.get(requestId);
      if (pending && pending.control) pending.control.cancel(code || 'CANCELLED');
      this.transport.send(wireMessage('infer.cancel', { requestId: requestId }));
      this.settle(requestId, new ComputeError(code || 'CANCELLED'));
    }
  }

  failAll(code) {
    for (const requestId of Array.from(this.pending.keys())) this.settle(requestId, new ComputeError(code));
  }

  onMessage(message) {
    if (message.type === 'infer.capabilities') {
      this.onCapabilities(message);
      return;
    }
    const requestId = message.requestId;
    const pending = this.pending.get(requestId);
    if (!pending || pending.epoch !== this.connectionEpoch) return;
    if (pending.control && pending.control.runGeneration !== pending.generation) return;
    pending.progress = this.now();
    if (message.type === 'infer.accepted') {
      pending.accepted = true;
      return;
    }
    if (message.type === 'infer.status') return;
    if (message.type === 'infer.delta') {
      const pushed = pending.assembler.push(message.seq, message.text);
      if (!pushed.ok) this.settle(requestId, new ComputeError(pushed.code));
      else if (message.seq % 4 === 0) {
        this.transport.send(wireMessage('infer.ack', { requestId: requestId, ackSeq: message.seq }));
      }
      return;
    }
    if (message.type === 'infer.done') {
      if (pending.control && pending.control.isCancelled()) {
        this.settle(requestId, new ComputeError('CANCELLED'));
        return;
      }
      const finished = pending.assembler.finish(
        message.lastSeq,
        message.outputUtf8Bytes,
        message.outputSha256,
        message.finishReason
      );
      if (!finished.ok) this.settle(requestId, new ComputeError(finished.code));
      else {
        this.transport.send(wireMessage('infer.ack', { requestId: requestId, ackSeq: message.lastSeq }));
        this.settle(requestId, null, {
          text: finished.text,
          source: message.source,
          hash: sha256Text(finished.text)
        });
      }
      return;
    }
    if (message.type === 'infer.error') {
      this.settle(requestId, new ComputeError(message.code, message.message, message.retryable));
      return;
    }
    if (message.type === 'infer.cancelled') this.settle(requestId, new ComputeError('CANCELLED'));
  }

  onCapabilities(message) {
    if (this.state !== 'NEGOTIATING') return;
    const checked = validateInferMessage(message);
    if (!checked.ok) {
      this.setState('INCOMPATIBLE');
      return;
    }
    const profile = message.profiles.find((item) => item.ready && item.promptFormat === 'loop-react-split-v1');
    if (!profile) {
      this.clear(this.negotiateTimer);
      this.setState('INCOMPATIBLE');
      return;
    }
    this.profile = profile;
    this.clear(this.negotiateTimer);
    this.setState('READY');
  }

  settle(requestId, error, value) {
    const pending = this.pending.get(requestId);
    if (!pending || pending.terminal) return;
    pending.terminal = error ? 'error' : 'done';
    for (const timer of pending.timers) this.clear(timer);
    this.pending.delete(requestId);
    if (error) pending.reject(error);
    else pending.resolve(value);
  }
}

module.exports = { ComputeClient };
