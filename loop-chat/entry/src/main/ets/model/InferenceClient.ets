import { hilog } from '@kit.PerformanceAnalysisKit';
import { nearbyChannel } from '../nearby/LinkEnhanceChannel';
import { InferProfile, WireMessage } from '../protocol/ChatProtocol';
import { sha256Hex, utf8Bytes } from './InferenceWire';
import { repairUtf8FromSource } from './Utf8Repair';

const NEGOTIATE_MS = 10000;
const ACCEPTED_MS = 10000;
const HARD_MS = 180000;
export const INFERENCE_STOPPED = '已停止生成';

class StreamState {
  requestId: string = '';
  prompt: string = '';
  next: number = 1;
  text: string = '';
  accepted: boolean = false;
  started: number = 0;
  resolve: ((value: string) => void) | null = null;
  reject: ((error: Error) => void) | null = null;
  timer: number = -1;
}

class InferenceClient {
  private profile: InferProfile | null = null;
  private negotiateId: string = '';
  private negotiateTimer: number = -1;
  private negotiateWait: ((value: string) => void) | null = null;
  private negotiatePromise: Promise<string> | null = null;
  private serial: number = 1;
  private pending: StreamState | null = null;
  private preview: ((text: string) => void) | null = null;
  private onStart: (() => void) | null = null;
  private status: string = '正在检查模型能力';
  private broken: boolean = false;

  setPreview(preview: ((text: string) => void) | null): void {
    this.preview = preview;
  }

  setStart(start: (() => void) | null): void {
    this.onStart = start;
  }

  cancelActive(): void {
    const pending = this.pending;
    if (pending === null) {
      return;
    }
    nearbyChannel.send({ type: 'infer.cancel', version: 2, requestId: pending.requestId });
    this.failPending(INFERENCE_STOPPED);
  }

  bind(): void {
    nearbyChannel.setInferenceHandler((message: WireMessage, _epoch: number): void => {
      this.onMessage(message);
    });
  }

  reset(): void {
    this.profile = null;
    this.negotiateId = '';
    this.broken = false;
    this.status = '正在检查模型能力';
    this.negotiatePromise = null;
    this.clearNegotiate();
    this.failPending('连接已中断，请连接后重新发送。');
  }

  isReady(): boolean {
    return this.profile !== null && this.profile.ready;
  }

  failed(): boolean {
    return this.broken;
  }

  statusText(): string {
    return this.status;
  }

  ensureReady(): Promise<string> {
    if (!nearbyChannel.inferenceReady()) {
      this.broken = true;
      this.status = '算力端版本不支持';
      return Promise.resolve(this.status);
    }
    if (this.isReady()) {
      this.status = '已就绪';
      return Promise.resolve('');
    }
    if (this.negotiatePromise !== null) {
      return this.negotiatePromise;
    }
    const requestId = this.nextId('cap');
    this.negotiateId = requestId;
    this.status = '正在检查模型能力';
    this.broken = false;
    const result = new Promise<string>((resolve: (value: string) => void) => {
      this.negotiateWait = resolve;
    });
    this.negotiatePromise = result;
    this.negotiateTimer = setTimeout(() => {
      this.finishNegotiate('算力端版本不支持');
    }, NEGOTIATE_MS);
    nearbyChannel.send({ type: 'infer.capabilities.get', version: 2, requestId: requestId });
    return result;
  }

  complete(prompt: string): Promise<string> {
    if (!this.isReady() || this.profile === null) {
      return Promise.reject(new Error('算力端版本不支持'));
    }
    const profile = this.profile;
    const outputTokens = Math.min(256, profile.maxOutputTokens);
    hilog.info(0, 'NearbyChat', 'infer prompt chars=%{public}d ctx=%{public}d',
      prompt.length, profile.maxContextTokens);
    if (utf8Bytes(prompt).length > profile.maxPromptBytes) {
      return Promise.reject(new Error('本轮输入超过传输限制'));
    }
    if (this.pending !== null) {
      return Promise.reject(new Error('算力繁忙，请稍后重试'));
    }
    const requestId = this.nextId('req');
    const state = new StreamState();
    state.requestId = requestId;
    state.prompt = prompt;
    state.started = Date.now();
    this.pending = state;
    const result = new Promise<string>((resolve: (value: string) => void, reject: (error: Error) => void) => {
      state.resolve = resolve;
      state.reject = reject;
    });
    state.timer = setTimeout(() => {
      this.expire(requestId);
    }, ACCEPTED_MS);
    nearbyChannel.send({
      type: 'infer.request', version: 2, requestId: requestId,
      clientInstanceId: 'loopchat', agentRunId: this.nextId('run'),
      modelId: profile.modelId, modelRevision: profile.modelRevision, promptFormat: profile.promptFormat,
      prompt: prompt, maxOutputTokens: outputTokens, deadlineBudgetMs: HARD_MS
    });
    const start = this.onStart;
    if (start !== null) {
      start();
    }
    return result;
  }

  private onMessage(message: WireMessage): void {
    if (message.type === 'infer.capabilities' && message.requestId === this.negotiateId) {
      const profiles = message.profiles;
      const profile = profiles !== undefined && profiles.length > 0 ? profiles[0] : undefined;
      if (profile === undefined || profile.promptFormat !== 'loop-react-split-v1') {
        this.finishNegotiate('算力端版本不支持');
        return;
      }
      this.profile = profile;
      this.broken = !profile.ready;
      this.status = profile.ready ? '已就绪' : profile.readinessReason;
      this.finishNegotiate(profile.ready ? '' : profile.readinessReason);
      return;
    }
    const pending = this.pending;
    if (pending === null || message.requestId !== pending.requestId) {
      return;
    }
    if (message.type === 'infer.accepted') {
      pending.accepted = true;
      this.arm(pending);
      return;
    }
    if (message.type === 'infer.delta' && typeof message.seq === 'number' && typeof message.text === 'string') {
      if (message.seq !== pending.next) {
        this.failPending('链路无法完整交付结果');
        return;
      }
      pending.text += message.text;
      pending.next += 1;
      this.arm(pending);
      const preview = this.preview;
      const shown = repairUtf8FromSource(pending.text, pending.prompt);
      if (preview !== null && shown.length > 0) {
        preview(shown);
      }
      return;
    }
    if (message.type === 'infer.done') {
      const bytes = utf8Bytes(pending.text);
      const hash = sha256Hex(bytes);
      if (message.lastSeq !== pending.next - 1 || message.outputUtf8Bytes !== bytes.length ||
        message.outputSha256 !== hash || pending.text.trim().length === 0) {
        this.failPending('链路无法完整交付结果');
        return;
      }
      if (message.finishReason !== 'stop') {
        this.failPending('回复未完整生成，未执行本轮新工具操作');
        return;
      }
      this.succeed(repairUtf8FromSource(pending.text, pending.prompt));
      return;
    }
    if (message.type === 'infer.error') {
      this.failPending(message.message || '模型加载、提交或清理失败');
    }
  }

  private succeed(text: string): void {
    const pending = this.pending;
    this.pending = null;
    if (pending === null) {
      return;
    }
    clearTimeout(pending.timer);
    hilog.info(0, 'NearbyChat', 'infer complete bytes=%{public}d', utf8Bytes(text).length);
    pending.resolve?.(text);
  }

  private failPending(text: string): void {
    const pending = this.pending;
    this.pending = null;
    if (pending === null) {
      return;
    }
    clearTimeout(pending.timer);
    pending.reject?.(new Error(text));
  }

  private expire(requestId: string): void {
    const pending = this.pending;
    if (pending === null || pending.requestId !== requestId) {
      return;
    }
    nearbyChannel.send({ type: 'infer.cancel', version: 2, requestId: requestId });
    this.failPending('本轮推理中断，部分工具操作可能已完成');
  }

  private arm(pending: StreamState): void {
    clearTimeout(pending.timer);
    const remaining = Math.max(1000, HARD_MS - (Date.now() - pending.started));
    pending.timer = setTimeout(() => {
      this.expire(pending.requestId);
    }, remaining);
  }

  private finishNegotiate(text: string): void {
    this.clearNegotiate();
    const wait = this.negotiateWait;
    this.negotiateWait = null;
    this.negotiatePromise = null;
    this.negotiateId = '';
    if (text.length > 0) {
      this.broken = true;
      this.status = text;
    }
    if (wait !== null) {
      wait(text);
    }
  }

  private clearNegotiate(): void {
    if (this.negotiateTimer !== -1) {
      clearTimeout(this.negotiateTimer);
      this.negotiateTimer = -1;
    }
  }

  private nextId(prefix: string): string {
    const id = prefix + String(this.serial);
    this.serial += 1;
    return id;
  }
}

export const inferenceClient: InferenceClient = new InferenceClient();
