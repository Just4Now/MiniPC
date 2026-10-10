'use strict';

const { utf8ByteLength, sha256Text } = require('./text');

const PROTOCOL = 'nearby-chat-v1';
const INFERENCE_VERSION = 2;
const LIMITS = {
  maxIdLength: 128,
  maxPromptBytes: 32768,
  maxWireBytes: 65536,
  maxDeltaBytes: 1024,
  maxOutputBytes: 32768,
  maxErrorBytes: 1024,
  maxProfiles: 16,
  maxVersions: 4,
  maxLabelLength: 128,
  defaultOutputTokens: 512,
  hardInferenceMs: 180000,
  acceptedWaitMs: 10000,
  queueWaitMs: 30000,
  progressIdleMs: 15000,
  negotiateMs: 10000,
  agentDeadlineMs: 600000,
  maxAgentSteps: 10,
  cancelCleanupMs: 10000,
  tombstones: 256,
  tombstoneMs: 300000,
  queueLimit: 4,
  perClientQueue: 1,
  executionSlots: 1
};

const ID_PATTERN = /^[A-Za-z0-9_-]{1,128}$/;
const HASH_PATTERN = /^[a-f0-9]{64}$/;
const INFER_TYPES = [
  'infer.capabilities.get',
  'infer.capabilities',
  'infer.request',
  'infer.accepted',
  'infer.status',
  'infer.delta',
  'infer.ack',
  'infer.done',
  'infer.error',
  'infer.cancel',
  'infer.cancelled'
];
const NORMAL_FINISH = new Set(['stop']);
const DONE_FINISH = new Set(['stop', 'length']);
const ACCEPTED_STATES = new Set(['queued', 'preparing']);
const STATUS_STATES = new Set(['queued', 'loading', 'prefill', 'generating']);

const USER_TEXT = {
  NO_COMPUTE: '尚未发现可用算力设备',
  PROTOCOL_UNSUPPORTED: '请升级算力端到支持该协议的版本',
  MODEL_UNAVAILABLE: '模型未部署、未通过自检或没有兼容节点',
  PAYLOAD_TOO_LARGE: '本轮输入超过传输限制',
  CONTEXT_TOO_LARGE: '当前模型上下文不足',
  BUSY: '算力繁忙，请稍后重试',
  QUEUE_TIMEOUT: '算力繁忙，请稍后重试',
  REQUEST_TIMEOUT: '本轮推理中断，部分工具操作可能已完成',
  CONNECTION_LOST: '本轮推理中断，部分工具操作可能已完成',
  MODEL_OUTPUT_TRUNCATED: '回复未完整生成，未执行本轮新工具操作',
  MODEL_EXECUTION_FAILED: '模型加载、提交或清理失败',
  BACKPRESSURE_OVERFLOW: '链路无法完整交付结果',
  STREAM_CORRUPTED: '链路无法完整交付结果',
  CANCELLED: '已停止；已开始的外部操作未必可撤销',
  REJECTED: '请求被拒绝'
};

const RETRYABLE = new Set([
  'NO_COMPUTE',
  'BUSY',
  'QUEUE_TIMEOUT',
  'REQUEST_TIMEOUT',
  'CONNECTION_LOST',
  'MODEL_UNAVAILABLE'
]);

class ComputeError extends Error {
  constructor(code, message, retryable) {
    super(message || USER_TEXT[code] || code);
    this.name = 'ComputeError';
    this.code = code;
    this.retryable = retryable === undefined ? RETRYABLE.has(code) : retryable;
    this.fallbackForbidden = true;
  }
}

function userText(code) {
  return USER_TEXT[code] || '请求失败';
}

function reject(code) {
  return { ok: false, code: code, userMessage: userText(code), retryable: RETRYABLE.has(code) };
}

function accept() {
  return { ok: true };
}

function isId(value) {
  return typeof value === 'string' && ID_PATTERN.test(value);
}

function isBoundedInt(value, min, max) {
  return typeof value === 'number' && Number.isInteger(value) && value >= min && value <= max;
}

function hasOnly(message, allowed) {
  for (const key of Object.keys(message)) {
    if (!allowed.includes(key)) return false;
  }
  return true;
}

function requireFields(message, fields) {
  for (const field of fields) {
    if (message[field] === undefined) return false;
  }
  return true;
}

function validProfile(profile) {
  if (profile === null || typeof profile !== 'object' || Array.isArray(profile)) return false;
  if (!hasOnly(profile, [
    'modelId', 'modelRevision', 'promptFormat', 'maxContextTokens', 'maxOutputTokens',
    'maxPromptBytes', 'maxWireBytes', 'tokenBudgetMode', 'streaming', 'cancellation',
    'ready', 'readinessReason', 'maxCtx', 'gateBPassed'
  ])) return false;
  if (!isId(profile.modelId) || !isId(profile.modelRevision) || !isId(profile.promptFormat)) return false;
  if (!isBoundedInt(profile.maxContextTokens, 1, 131072)) return false;
  if (!isBoundedInt(profile.maxOutputTokens, 1, 131072)) return false;
  if (!isBoundedInt(profile.maxPromptBytes, 1, LIMITS.maxPromptBytes)) return false;
  if (!isBoundedInt(profile.maxWireBytes, 1, LIMITS.maxWireBytes)) return false;
  if (profile.tokenBudgetMode !== 'exact' && profile.tokenBudgetMode !== 'certified-conservative') return false;
  if (typeof profile.streaming !== 'boolean' || typeof profile.cancellation !== 'boolean') return false;
  if (typeof profile.ready !== 'boolean') return false;
  if (typeof profile.readinessReason !== 'string' || utf8ByteLength(profile.readinessReason) > LIMITS.maxErrorBytes) return false;
  if (profile.maxCtx !== undefined && !isBoundedInt(profile.maxCtx, 1, 131072)) return false;
  if (profile.gateBPassed !== undefined && typeof profile.gateBPassed !== 'boolean') return false;
  return true;
}

function validMetrics(metrics) {
  if (metrics === undefined) return true;
  if (metrics === null || typeof metrics !== 'object' || Array.isArray(metrics)) return false;
  const keys = Object.keys(metrics);
  if (keys.length > 16) return false;
  for (const key of keys) {
    if (!isId(key)) return false;
    const value = metrics[key];
    if (typeof value !== 'number' || !Number.isFinite(value)) return false;
  }
  return true;
}

function validateHelloExtensions(message) {
  if (message === null || typeof message !== 'object') return reject('PROTOCOL_UNSUPPORTED');
  if (message.inferenceVersions === undefined) return accept();
  if (!Array.isArray(message.inferenceVersions) || message.inferenceVersions.length === 0 ||
    message.inferenceVersions.length > LIMITS.maxVersions) return reject('PROTOCOL_UNSUPPORTED');
  for (const version of message.inferenceVersions) {
    if (!isBoundedInt(version, 1, 16)) return reject('PROTOCOL_UNSUPPORTED');
  }
  return accept();
}

function supportsInferenceV2(message) {
  const checked = validateHelloExtensions(message || {});
  if (!checked.ok || !message || !Array.isArray(message.inferenceVersions)) return false;
  return message.inferenceVersions.includes(INFERENCE_VERSION);
}

function validateInferMessage(message) {
  if (message === null || typeof message !== 'object' || Array.isArray(message)) return reject('PROTOCOL_UNSUPPORTED');
  if (message.protocol !== PROTOCOL || typeof message.type !== 'string') return reject('PROTOCOL_UNSUPPORTED');
  if (!INFER_TYPES.includes(message.type)) return reject('PROTOCOL_UNSUPPORTED');
  if (message.version !== undefined && message.version !== INFERENCE_VERSION) return reject('PROTOCOL_UNSUPPORTED');
  if (!isId(message.requestId)) return reject('REJECTED');
  if (message.type === 'infer.capabilities.get') {
    if (!hasOnly(message, ['protocol', 'type', 'version', 'requestId'])) return reject('REJECTED');
    if (message.version !== INFERENCE_VERSION) return reject('PROTOCOL_UNSUPPORTED');
    return accept();
  }
  if (message.type === 'infer.capabilities') {
    if (!hasOnly(message, ['protocol', 'type', 'version', 'requestId', 'profiles'])) return reject('REJECTED');
    if (message.version !== INFERENCE_VERSION) return reject('PROTOCOL_UNSUPPORTED');
    if (!Array.isArray(message.profiles) || message.profiles.length === 0 ||
      message.profiles.length > LIMITS.maxProfiles) return reject('REJECTED');
    for (const profile of message.profiles) {
      if (!validProfile(profile)) return reject('REJECTED');
    }
    return accept();
  }
  if (message.type === 'infer.request') {
    if (!hasOnly(message, [
      'protocol', 'type', 'version', 'clientInstanceId', 'agentRunId', 'requestId',
      'modelId', 'modelRevision', 'promptFormat', 'prompt', 'maxOutputTokens',
      'deadlineBudgetMs', 'sched', 'origin'
    ])) return reject('REJECTED');
    if (message.version !== INFERENCE_VERSION) return reject('PROTOCOL_UNSUPPORTED');
    if (!requireFields(message, [
      'clientInstanceId', 'agentRunId', 'modelId', 'modelRevision', 'promptFormat',
      'prompt', 'maxOutputTokens', 'deadlineBudgetMs'
    ])) return reject('REJECTED');
    if (!isId(message.clientInstanceId) || !isId(message.agentRunId) || !isId(message.modelId) ||
      !isId(message.modelRevision) || !isId(message.promptFormat)) return reject('REJECTED');
    if (typeof message.prompt !== 'string') return reject('REJECTED');
    if (utf8ByteLength(message.prompt) > LIMITS.maxPromptBytes) return reject('PAYLOAD_TOO_LARGE');
    if (!isBoundedInt(message.maxOutputTokens, 1, 131072)) return reject('REJECTED');
    if (!isBoundedInt(message.deadlineBudgetMs, 1, LIMITS.hardInferenceMs)) return reject('REJECTED');
    if (message.sched !== undefined && message.sched !== true && message.sched !== false) return reject('REJECTED');
    if (message.origin !== undefined && (typeof message.origin !== 'string' ||
      utf8ByteLength(message.origin) > LIMITS.maxLabelLength)) return reject('REJECTED');
    if (utf8ByteLength(JSON.stringify(message)) > LIMITS.maxWireBytes) return reject('PAYLOAD_TOO_LARGE');
    return accept();
  }
  if (message.type === 'infer.accepted') {
    if (!hasOnly(message, ['protocol', 'type', 'version', 'requestId', 'state', 'source'])) return reject('REJECTED');
    if (!ACCEPTED_STATES.has(message.state)) return reject('REJECTED');
    if (message.source !== undefined && (typeof message.source !== 'string' ||
      utf8ByteLength(message.source) > LIMITS.maxLabelLength)) return reject('REJECTED');
    return accept();
  }
  if (message.type === 'infer.status') {
    if (!hasOnly(message, ['protocol', 'type', 'version', 'requestId', 'state', 'elapsedMs'])) return reject('REJECTED');
    if (!STATUS_STATES.has(message.state)) return reject('REJECTED');
    if (message.elapsedMs !== undefined && !isBoundedInt(message.elapsedMs, 0, 3600000)) return reject('REJECTED');
    return accept();
  }
  if (message.type === 'infer.delta') {
    if (!hasOnly(message, ['protocol', 'type', 'version', 'requestId', 'seq', 'text'])) return reject('REJECTED');
    if (!isBoundedInt(message.seq, 1, 1000000)) return reject('STREAM_CORRUPTED');
    if (typeof message.text !== 'string' || utf8ByteLength(message.text) > LIMITS.maxDeltaBytes) {
      return reject('STREAM_CORRUPTED');
    }
    return accept();
  }
  if (message.type === 'infer.ack') {
    if (!hasOnly(message, ['protocol', 'type', 'version', 'requestId', 'ackSeq'])) return reject('REJECTED');
    if (!isBoundedInt(message.ackSeq, 0, 1000000)) return reject('REJECTED');
    return accept();
  }
  if (message.type === 'infer.done') {
    if (!hasOnly(message, [
      'protocol', 'type', 'version', 'requestId', 'lastSeq', 'outputUtf8Bytes',
      'outputSha256', 'finishReason', 'source', 'metrics'
    ])) return reject('REJECTED');
    if (!isBoundedInt(message.lastSeq, 1, 1000000)) return reject('STREAM_CORRUPTED');
    if (!isBoundedInt(message.outputUtf8Bytes, 0, LIMITS.maxOutputBytes)) return reject('STREAM_CORRUPTED');
    if (typeof message.outputSha256 !== 'string' || !HASH_PATTERN.test(message.outputSha256)) return reject('STREAM_CORRUPTED');
    if (!DONE_FINISH.has(message.finishReason)) return reject('STREAM_CORRUPTED');
    if (typeof message.source !== 'string' || utf8ByteLength(message.source) > LIMITS.maxLabelLength) return reject('REJECTED');
    if (!validMetrics(message.metrics)) return reject('REJECTED');
    return accept();
  }
  if (message.type === 'infer.error') {
    if (!hasOnly(message, ['protocol', 'type', 'version', 'requestId', 'code', 'message', 'retryable'])) {
      return reject('REJECTED');
    }
    if (typeof message.code !== 'string' || !Object.prototype.hasOwnProperty.call(USER_TEXT, message.code)) {
      return reject('REJECTED');
    }
    if (typeof message.message !== 'string' || utf8ByteLength(message.message) > LIMITS.maxErrorBytes) {
      return reject('REJECTED');
    }
    if (typeof message.retryable !== 'boolean') return reject('REJECTED');
    return accept();
  }
  if (message.type === 'infer.cancel' || message.type === 'infer.cancelled') {
    if (!hasOnly(message, ['protocol', 'type', 'version', 'requestId'])) return reject('REJECTED');
    return accept();
  }
  return reject('PROTOCOL_UNSUPPORTED');
}

function wireMessage(type, fields) {
  return Object.assign({ protocol: PROTOCOL, type: type, version: INFERENCE_VERSION }, fields);
}

function errorMessage(requestId, code, retryable) {
  return wireMessage('infer.error', {
    requestId: requestId,
    code: code,
    message: userText(code),
    retryable: retryable === undefined ? RETRYABLE.has(code) : retryable
  });
}

class StreamAssembler {
  constructor() {
    this.parts = new Map();
    this.text = '';
    this.next = 1;
    this.failed = null;
    this.terminal = '';
  }

  push(seq, text) {
    if (this.failed || this.terminal) return this.failed || reject('STREAM_CORRUPTED');
    const previous = this.parts.get(seq);
    if (previous !== undefined) {
      if (previous !== text) {
        this.failed = reject('STREAM_CORRUPTED');
        return this.failed;
      }
      return accept();
    }
    this.parts.set(seq, text);
    while (this.parts.has(this.next)) {
      this.text += this.parts.get(this.next);
      this.next += 1;
    }
    if (utf8ByteLength(this.text) > LIMITS.maxOutputBytes) {
      this.failed = reject('STREAM_CORRUPTED');
      return this.failed;
    }
    return accept();
  }

  finish(lastSeq, outputUtf8Bytes, outputSha256, finishReason) {
    if (this.failed) return this.failed;
    if (this.terminal) return reject('STREAM_CORRUPTED');
    this.terminal = 'done';
    for (const seq of this.parts.keys()) {
      if (seq < 1 || seq > lastSeq) return reject('STREAM_CORRUPTED');
    }
    if (this.next !== lastSeq + 1) return reject('STREAM_CORRUPTED');
    const bytes = utf8ByteLength(this.text);
    if (bytes !== outputUtf8Bytes || sha256Text(this.text) !== outputSha256) return reject('STREAM_CORRUPTED');
    if (!NORMAL_FINISH.has(finishReason)) return reject('MODEL_OUTPUT_TRUNCATED');
    if (this.text.trim().length === 0) return reject('MODEL_EXECUTION_FAILED');
    return { ok: true, text: this.text };
  }

  fail(kind) {
    if (this.terminal || this.failed) return false;
    this.terminal = kind;
    return true;
  }
}

function redactPrompt(prompt) {
  return prompt
    .replace(/"(apiKey|access_token|refresh_token|authorization)"\s*:\s*"[^"]*"/gi, '"$1":"***"')
    .replace(/Authorization:\s*\S+/gi, 'Authorization: ***')
    .replace(/\bsk-[A-Za-z0-9]{8,}\b/g, 'sk-***');
}

function estimateTokens(text) {
  return Array.from(text).length;
}

function contextAdmission(profile, prompt, maxOutputTokens) {
  const margin = 64;
  const input = estimateTokens(prompt);
  if (profile.tokenBudgetMode !== 'exact' && profile.tokenBudgetMode !== 'certified-conservative') {
    return reject('MODEL_UNAVAILABLE');
  }
  if (input + maxOutputTokens + margin > profile.maxContextTokens) return reject('CONTEXT_TOO_LARGE');
  return accept();
}

module.exports = {
  PROTOCOL,
  INFERENCE_VERSION,
  LIMITS,
  INFER_TYPES,
  USER_TEXT,
  ComputeError,
  userText,
  validateHelloExtensions,
  supportsInferenceV2,
  validateInferMessage,
  wireMessage,
  errorMessage,
  StreamAssembler,
  redactPrompt,
  estimateTokens,
  contextAdmission,
  isId
};
