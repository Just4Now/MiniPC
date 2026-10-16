'use strict';

const { utf8ByteLength, cutUtf8 } = require('../protocol/text');
const { ComputeError } = require('../protocol/inference-v2');
const { buildNativeRequest } = require('../protocol/prompt-split');
const { ctxAllowed } = require('./model-profiles');
const { NativeEventDispatcher } = require('./native-event-dispatcher');

const SAFE_LOG_KEYS = ['requestId', 'stage', 'code', 'bytes', 'elapsedMs', 'nativeId'];

function safeLog(logger, fields) {
  const safe = { stage: fields.stage };
  for (const key of SAFE_LOG_KEYS) {
    if (fields[key] !== undefined) safe[key] = fields[key];
  }
  logger(safe);
}

class NativeInferenceService {
  constructor(probe, options) {
    const settings = options || {};
    this.probe = probe;
    this.profile = settings.profile;
    this.modelPath = settings.modelPath || 'files/models/Qwen2.5-7B-Instruct-Q4_N_0';
    this.logPath = settings.logPath || 'files/gewu-inference.jsonl';
    this.logger = settings.logger || (() => {});
    this.dispatcher = new NativeEventDispatcher(() => probe.takeEvents());
    this.jobs = new Map();
  }

  submit(spec, callbacks) {
    const request = buildNativeRequest(spec.prompt, spec.maxOutputTokens);
    const json = JSON.stringify(request);
    if (json.indexOf('\0') >= 0) throw new ComputeError('REJECTED');
    if (utf8ByteLength(json) > 65536) throw new ComputeError('PAYLOAD_TOO_LARGE');
    if (!ctxAllowed(spec.maxCtx, this.profile)) throw new ComputeError('MODEL_UNAVAILABLE');
    if (spec.maxOutputTokens > this.profile.maxOutputTokens) throw new ComputeError('REJECTED');
    const nativeId = this.probe.startInference(this.modelPath, json, this.logPath, spec.maxCtx);
    if (!nativeId) throw new ComputeError('BUSY');
    const job = {
      forwardId: spec.forwardId,
      nativeId: nativeId,
      pending: '',
      failed: '',
      cancelled: false,
      cleaned: false,
      finishReason: '',
      callbacks: callbacks
    };
    this.jobs.set(spec.forwardId, job);
    safeLog(this.logger, {
      stage: 'start',
      requestId: spec.forwardId,
      nativeId: nativeId,
      bytes: utf8ByteLength(spec.prompt),
      // 参考 host 的 probe 是脚本化测试替身，不做视觉推理；这里只记录图片体积，
      // 绝不记录图片内容。真实视觉执行在 ArkTS 侧 InferenceHost + VL 引擎。
      imageBytes: utf8ByteLength(spec.image || '')
    });
    this.dispatcher.subscribe(nativeId, (event) => this.onEvent(job, event));
    this.dispatcher.poll();
    return nativeId;
  }

  cancel(forwardId) {
    const job = this.jobs.get(forwardId);
    if (!job || job.cleaned) return;
    job.cancelled = true;
    this.probe.cancel(job.nativeId);
    safeLog(this.logger, { stage: 'cancel', requestId: forwardId, nativeId: job.nativeId });
  }

  onEvent(job, event) {
    if (job.cleaned) return;
    if (event.event === 'response') this.onResponse(job, event.payload);
    if (event.event === 'file_error') job.failed = job.failed || 'MODEL_EXECUTION_FAILED';
    if ((event.event === 'create' || event.event === 'submit' || event.event === 'destroy') && event.payload !== '0') {
      job.failed = job.failed || 'MODEL_EXECUTION_FAILED';
    }
    if (event.event === 'end') this.finish(job);
  }

  onResponse(job, payloadText) {
    let payload;
    try {
      payload = JSON.parse(payloadText);
    } catch (_error) {
      job.failed = 'MODEL_EXECUTION_FAILED';
      return;
    }
    const nested = payload.message && typeof payload.message.content === 'string' ? payload.message.content : null;
    const top = typeof payload.content === 'string' ? payload.content : null;
    if (nested === null && top === null && typeof payload.finish_reason !== 'string') {
      job.failed = 'MODEL_EXECUTION_FAILED';
      return;
    }
    const text = nested === null ? top : nested;
    if (text) this.pushText(job, text);
    if (typeof payload.finish_reason === 'string') job.finishReason = payload.finish_reason;
  }

  pushText(job, text) {
    if (job.failed) return;
    job.pending += text;
    while (utf8ByteLength(job.pending) >= 1024) {
      const cut = cutUtf8(job.pending, 1024);
      if (!cut.text) break;
      job.pending = job.pending.slice(cut.text.length);
      this.emit(job, cut.text);
      if (job.failed) return;
    }
  }

  emit(job, text) {
    const accepted = job.callbacks.onDelta(text);
    if (accepted === false) {
      job.failed = 'BACKPRESSURE_OVERFLOW';
      this.probe.cancel(job.nativeId);
    }
  }

  flush(job) {
    if (!job.pending || job.failed) return;
    const text = job.pending;
    job.pending = '';
    this.emit(job, text);
  }

  finish(job) {
    if (job.cleaned) return;
    this.flush(job);
    if (job.finishReason === 'length') job.failed = job.failed || 'MODEL_OUTPUT_TRUNCATED';
    job.cleaned = true;
    this.dispatcher.unsubscribe(job.nativeId);
    this.jobs.delete(job.forwardId);
    safeLog(this.logger, {
      stage: 'end',
      requestId: job.forwardId,
      nativeId: job.nativeId,
      code: job.cancelled ? 'CANCELLED' : (job.failed || 'stop')
    });
    if (job.cancelled) job.callbacks.onCleaned('cancelled');
    else if (job.failed) job.callbacks.onCleaned('error', job.failed);
    else job.callbacks.onCleaned('done');
  }
}

module.exports = { NativeInferenceService, safeLog };
