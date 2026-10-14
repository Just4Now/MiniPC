import { util } from '@kit.ArkTS';

/**
 * 图片随请求传输的裸 base64 上限（无 data: 前缀）。
 * 约束链：分片层 MAX_FRAME 64 KiB；裸 base64 24000 + prompt 上限 32768 + 字段开销 ≈ 57 KB < 64 KiB，
 * 因此带图时无需裁剪 prompt。必须与 packages/inference-protocol 的 LIMITS.maxImageBase64
 * 以及算力端 ChatProtocol.MAX_IMAGE_BASE64 三处一致。
 */
export const MAX_IMAGE_BASE64: number = 24000;

export interface ChatMessage { role: string; content: string; }
export interface DeviceInfoEntry {
  id?: string;
  /** Stable per-install identity. `id` remains for compatibility with older builds. */
  deviceUid?: string;
  name?: string;
  role?: string;
  memTotal?: number;
  memAvail?: number;
  memUsage?: number;
  /** System thermal gear 0–7, or -1 when unknown. */
  thermalLevel?: number;
  /** Battery temperature in Celsius, or -1 when unknown. */
  batteryTemp?: number;
  /** Whole-device CPU occupancy 0–100, or -1 when unknown. */
  cpuUsage?: number;
  model?: string;
  modelRequests?: number;
  ready?: boolean;
  slot?: number;
}
export interface WireMessage {
  protocol?: string;
  type: string;
  requestId?: string;
  messages?: ChatMessage[];
  /** infer.request 的可选附图：裸 base64（无 data: 前缀），受 MAX_IMAGE_BASE64 约束。 */
  image?: string;
  text?: string;
  finishReason?: string;
  error?: string;
  peerRole?: string;
  sched?: boolean;
  /** Public origin label preserved when a coordinator forwards a request. */
  origin?: string;
  source?: string;
  name?: string;
  memTotal?: number;
  memAvail?: number;
  memUsage?: number;
  thermalLevel?: number;
  batteryTemp?: number;
  cpuUsage?: number;
  model?: string;
  modelRequests?: number;
  devices?: DeviceInfoEntry[];
  slot?: number;
  /** Stable per-install identity exchanged during hello/roster sync. */
  deviceUid?: string;
  inferenceVersions?: number[];
  version?: number;
  clientInstanceId?: string;
  agentRunId?: string;
  modelId?: string;
  modelRevision?: string;
  promptFormat?: string;
  prompt?: string;
  maxOutputTokens?: number;
  deadlineBudgetMs?: number;
  seq?: number;
  lastSeq?: number;
  outputUtf8Bytes?: number;
  outputSha256?: string;
  code?: string;
  message?: string;
  retryable?: boolean;
  state?: string;
  profiles?: InferProfile[];
  /** Cluster idle/total on infer.status; the compute hub also reports it in capabilities. */
  cluster?: ClusterInfo;
  /** Label of the device that actually runs an accepted request. */
  device?: string;
  /** Short caption of the request's purpose, e.g. a parallel sub-task. Display only. */
  label?: string;
}

export interface ClusterInfo {
  idle: number;
  total: number;
}

export interface InferProfile {
  modelId: string;
  modelRevision: string;
  promptFormat: string;
  maxContextTokens: number;
  maxOutputTokens: number;
  maxPromptBytes: number;
  maxWireBytes: number;
  tokenBudgetMode: string;
  streaming: boolean;
  cancellation: boolean;
  ready: boolean;
  readinessReason: string;
  maxCtx: number;
  gateBPassed: boolean;
  /** Host accepts `messages` (developer + user) instead of one flattened prompt. */
  splitMessages?: boolean;
  /** Present on the compute hub: how many modelled devices exist and how many are idle. */
  cluster?: ClusterInfo;
}

const PROTOCOL = 'nearby-chat-v1';
const MAX_FRAME = 65536;

function validOptionalString(value: string | undefined, max: number): boolean {
  return value === undefined || (typeof value === 'string' && value.length <= max);
}

function validOptionalNumber(value: number | undefined): boolean {
  return value === undefined || (typeof value === 'number' && Number.isFinite(value));
}

function validDeviceEntry(entry: DeviceInfoEntry): boolean {
  if (entry === null || typeof entry !== 'object') return false;
  return validOptionalString(entry.id, 128) && validOptionalString(entry.deviceUid, 64) &&
    validOptionalString(entry.name, 128) &&
    (entry.role === undefined || entry.role === 'chat' || entry.role === 'compute' || entry.role === 'self') &&
    validOptionalNumber(entry.memTotal) && validOptionalNumber(entry.memAvail) &&
    validOptionalNumber(entry.memUsage) && validOptionalNumber(entry.thermalLevel) &&
    validOptionalNumber(entry.batteryTemp) && validOptionalNumber(entry.cpuUsage) &&
    validOptionalString(entry.model, 128) &&
    validOptionalNumber(entry.modelRequests) &&
    (entry.ready === undefined || typeof entry.ready === 'boolean') &&
    (entry.slot === undefined || (Number.isInteger(entry.slot) && entry.slot >= 1 && entry.slot <= 64));
}

function validDeviceInfo(m: WireMessage): boolean {
  return validOptionalString(m.name, 128) && validOptionalString(m.model, 128) &&
    validOptionalNumber(m.memTotal) && validOptionalNumber(m.memAvail) &&
    validOptionalNumber(m.memUsage) && validOptionalNumber(m.thermalLevel) &&
    validOptionalNumber(m.batteryTemp) && validOptionalNumber(m.cpuUsage) &&
    validOptionalNumber(m.modelRequests) &&
    (m.peerRole === undefined || m.peerRole === 'compute' || m.peerRole === 'chat');
}

function validDeviceInfoSync(m: WireMessage): boolean {
  if (!Array.isArray(m.devices) || m.devices.length > 16) return false;
  for (const entry of m.devices) {
    if (!validDeviceEntry(entry)) return false;
  }
  return true;
}

// Validate before forwarding anything to the model or UI.
export function validMessage(m: WireMessage): boolean {
  if (m === null || typeof m !== 'object' || m.protocol !== PROTOCOL || typeof m.type !== 'string') return false;
  if (['hello', 'hello_ack'].includes(m.type)) {
    if (m.peerRole !== undefined && m.peerRole !== 'compute' && m.peerRole !== 'chat') return false;
    if (!validOptionalString(m.name, 128)) return false;
    if (!validOptionalString(m.deviceUid, 64)) return false;
    if (m.slot !== undefined && (!Number.isInteger(m.slot) || m.slot < 1 || m.slot > 64)) return false;
    return true;
  }
  if (typeof m.requestId !== 'string' || m.requestId.length === 0 || m.requestId.length > 128) return false;
  if (m.type === 'cancel' || m.type === 'prepare') return true;
  if (m.type === 'prepared') return m.error === undefined ||
    (typeof m.error === 'string' && m.error.length <= 2048);
  if (m.type === 'delta') return typeof m.text === 'string' && m.text.length <= 16000;
  if (m.type === 'done') {
    return (m.finishReason === undefined || (typeof m.finishReason === 'string' && m.finishReason.length <= 128)) &&
      (m.source === undefined || (typeof m.source === 'string' && m.source.length <= 256));
  }
  if (m.type === 'error') return typeof m.error === 'string' && m.error.length <= 2048;
  if (m.type === 'deviceInfo') return validDeviceInfo(m);
  if (m.type === 'deviceInfoSync') return validDeviceInfoSync(m);
  if (m.type.indexOf('infer.') === 0) return validInference(m);
  if (m.type !== 'request' || !Array.isArray(m.messages) || m.messages.length === 0 || m.messages.length > 7) return false;
  if (m.sched !== undefined && m.sched !== true && m.sched !== false) return false;
  if (!validOptionalString(m.origin, 128)) return false;
  let length = 0;
  for (const message of m.messages) {
    if (message === null || typeof message !== 'object' ||
      (message.role !== 'user' && message.role !== 'assistant') || typeof message.content !== 'string') return false;
    length += message.content.length;
  }
  return length <= 1800 && m.messages[m.messages.length - 1].role === 'user' &&
    m.messages[m.messages.length - 1].content.trim().length > 0;
}


const CHUNK_BYTES = 480;
const MAX_PARTS = Math.ceil(MAX_FRAME / CHUNK_BYTES);
const MAX_PENDING = 8;
const FRAGMENT_TIMEOUT = 15000;
interface Fragment { version: number; id: string; index: number; count: number; data: string; }
class PendingMessage {
  created: number = Date.now();
  count: number;
  bytes: number = 0;
  parts: Map<number, Uint8Array> = new Map();
  constructor(count: number) { this.count = count; }
}

function validInference(m: WireMessage): boolean {
  if (m.version !== undefined && m.version !== 2) return false;
  if (typeof m.requestId !== 'string' || !/^[A-Za-z0-9_-]{1,128}$/.test(m.requestId)) return false;
  if (m.prompt !== undefined && (typeof m.prompt !== 'string' ||
    new util.TextEncoder().encodeInto(m.prompt).length > 32768)) return false;
  if (m.text !== undefined && (typeof m.text !== 'string' ||
    new util.TextEncoder().encodeInto(m.text).length > 1024)) return false;
  if (m.message !== undefined && (typeof m.message !== 'string' || m.message.length > 1024)) return false;
  if (m.device !== undefined && (typeof m.device !== 'string' || m.device.length > 128)) return false;
  if (m.label !== undefined && (typeof m.label !== 'string' || m.label.length > 64)) return false;
  if (m.cluster !== undefined && !validCluster(m.cluster)) return false;
  // 可选附图：与 nearby-chat request 同一条约束（裸 base64、无 data: 前缀、受上限约束）。
  // 出站消息也要过这道校验（encodeMessage 会调 validMessage），保证发出去的一定是规范 base64。
  if (m.image !== undefined) {
    if (typeof m.image !== 'string' || m.image.length === 0 || m.image.length > MAX_IMAGE_BASE64 ||
      !/^[A-Za-z0-9+/]+={0,2}$/.test(m.image)) return false;
  }
  return m.messages === undefined || validInferenceMessages(m.messages);
}

export function validCluster(value: ClusterInfo): boolean {
  return value !== null && typeof value === 'object' && Number.isInteger(value.idle) && Number.isInteger(value.total) &&
    value.idle >= 0 && value.total >= 0 && value.total <= 64 && value.idle <= value.total;
}

/** loop-react-split-v1: optional developer turn, then exactly one non-empty user turn. */
export function validInferenceMessages(messages: ChatMessage[]): boolean {
  if (!Array.isArray(messages) || messages.length < 1 || messages.length > 2) return false;
  let bytes = 0;
  for (let index = 0; index < messages.length; index++) {
    const message = messages[index];
    if (message === null || typeof message !== 'object' || typeof message.content !== 'string') return false;
    const last = index === messages.length - 1;
    if (last ? message.role !== 'user' : message.role !== 'developer') return false;
    bytes += new util.TextEncoder().encodeInto(message.content).length;
  }
  return bytes <= 32768 && messages[messages.length - 1].content.trim().length > 0;
}

function validId(id: string): boolean {
  return typeof id === 'string' && /^[A-Za-z0-9_-]{1,64}$/.test(id);
}

export function encodeMessage(message: WireMessage, id: string): string[] {
  if (!validId(id)) throw new Error('Invalid fragment ID');
  // Outgoing callers retain the original optional protocol convention.
  message.protocol = PROTOCOL;
  if (!validMessage(message)) throw new Error('Invalid chat message');
  const bytes = new util.TextEncoder().encodeInto(JSON.stringify(message));
  if (bytes.length > MAX_FRAME) throw new Error('Chat message exceeds 64 KiB');
  const count = Math.ceil(bytes.length / CHUNK_BYTES);
  const output: string[] = [];
  for (let index = 0; index < count; index++) {
    const fragment: Fragment = { version: 1, id: id, index: index, count: count,
      data: new util.Base64Helper().encodeToStringSync(bytes.subarray(index * CHUNK_BYTES, (index + 1) * CHUNK_BYTES)) };
    output.push(JSON.stringify(fragment));
  }
  return output;
}

export class MessageAssembler {
  private pending: Map<string, PendingMessage> = new Map();
  // Session-local replay window; clear on disconnect. No timers apply to inference.
  private completed: string[] = [];

  clear(): void { this.pending.clear(); this.completed = []; }

  checkExpiry(): void {
    for (const entry of this.pending) {
      if (Date.now() - entry[1].created >= FRAGMENT_TIMEOUT) {
        this.clear();
        throw new Error('Incomplete chat fragments timed out');
      }
    }
  }

  receive(text: string): WireMessage | null {
    this.checkExpiry();
    if (typeof text !== 'string' || text.length >= 1024 ||
      new util.TextEncoder().encodeInto(text).length >= 1024) throw new Error('Fragment exceeds limit');
    const fragment = JSON.parse(text) as Fragment;
    if (fragment === null || typeof fragment !== 'object' || fragment.version !== 1 || !validId(fragment.id) ||
      !Number.isInteger(fragment.count) || fragment.count < 1 || fragment.count > MAX_PARTS ||
      !Number.isInteger(fragment.index) || fragment.index < 0 || fragment.index >= fragment.count ||
      typeof fragment.data !== 'string' || fragment.data.length === 0 || fragment.data.length > 640 ||
      !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(fragment.data)) {
      throw new Error('Malformed chat fragment');
    }
    const bytes = new util.Base64Helper().decodeSync(fragment.data);
    if (new util.Base64Helper().encodeToStringSync(bytes) !== fragment.data ||
      bytes.length === 0 || bytes.length > CHUNK_BYTES ||
      (fragment.index < fragment.count - 1 && bytes.length !== CHUNK_BYTES) ||
      (fragment.count - 1) * CHUNK_BYTES + (fragment.index === fragment.count - 1 ? bytes.length : 1) > MAX_FRAME) {
      throw new Error('Invalid fragment payload');
    }
    if (this.completed.includes(fragment.id)) return null;
    let pending = this.pending.get(fragment.id);
    if (pending === undefined) {
      if (this.pending.size >= MAX_PENDING) throw new Error('Too many incomplete chat messages');
      pending = new PendingMessage(fragment.count);
      this.pending.set(fragment.id, pending);
    }
    if (pending.count !== fragment.count) throw new Error('Conflicting fragment count');
    const previous = pending.parts.get(fragment.index);
    if (previous !== undefined) {
      if (new util.Base64Helper().encodeToStringSync(previous) !== fragment.data) throw new Error('Conflicting duplicate fragment');
      return null;
    }
    pending.parts.set(fragment.index, bytes);
    pending.bytes += bytes.length;
    if (pending.bytes > MAX_FRAME) throw new Error('Chat message exceeds 64 KiB');
    if (pending.parts.size !== pending.count) return null;
    const joined = new Uint8Array(pending.bytes);
    for (let index = 0; index < pending.count; index++) {
      const part = pending.parts.get(index);
      if (part === undefined) throw new Error('Missing chat fragment');
      joined.set(part, index * CHUNK_BYTES);
    }
    const decoded = util.TextDecoder.create('utf-8', { fatal: true }).decodeToString(joined);
    const message = JSON.parse(decoded) as WireMessage;
    if (!validMessage(message)) throw new Error('Invalid chat message');
    this.pending.delete(fragment.id);
    this.completed.push(fragment.id);
    if (this.completed.length > 128) this.completed.shift();
    return message;
  }
}
