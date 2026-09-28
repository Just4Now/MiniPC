import { hilog } from '@kit.PerformanceAnalysisKit';
import { InferProfile, WireMessage } from '../protocol/ChatProtocol';
import { ChatUpdate, LocalChat } from './LocalChat';
import { sha256Hex, splitUtf8, utf8Bytes } from './InferenceWire';
import { repairUtf8FromSource } from './Utf8Repair';

const MAX_CONTEXT = 131072;
const MAX_OUTPUT = 256;
const MAX_PROMPT_BYTES = 32768;

/** Mirrors one accepted infer request onto the compute task rail. */
export class InferCardHooks {
  begin: (requestId: string, epoch: number, prompt: string) => void = (_requestId: string, _epoch: number, _prompt: string): void => {};
  delta: (requestId: string, epoch: number, answer: string) => void = (_requestId: string, _epoch: number, _answer: string): void => {};
  end: (requestId: string, epoch: number, answer: string, failed: boolean) => void =
    (_requestId: string, _epoch: number, _answer: string, _failed: boolean): void => {};
}

export class InferenceHost {
  private model: LocalChat;
  private sender: (message: WireMessage, epoch: number) => Promise<boolean>;
  private card: InferCardHooks;
  private activeId: string = '';
  private activeEpoch: number = 0;
  private seq: number = 0;
  private answer: string = '';
  private promptText: string = '';

  constructor(model: LocalChat, sender: (message: WireMessage, epoch: number) => Promise<boolean>,
    card: InferCardHooks) {
    this.model = model;
    this.sender = sender;
    this.card = card;
  }

  handle(message: WireMessage, epoch: number): void {
    if (message.type === 'infer.capabilities.get') {
      this.replyCapabilities(message.requestId || '', epoch);
      return;
    }
    if (message.type === 'infer.request') {
      this.acceptRequest(message, epoch);
      return;
    }
    if (message.type === 'infer.cancel' && message.requestId === this.activeId) {
      this.model.cancel(this.activeId);
    }
  }

  private replyCapabilities(requestId: string, epoch: number): void {
    const missing = this.model.readinessError();
    const profile: InferProfile = {
      modelId: 'qwen25-7b-instruct-q4',
      modelRevision: 'admission-open',
      promptFormat: 'loop-react-split-v1',
      maxContextTokens: MAX_CONTEXT,
      maxOutputTokens: MAX_OUTPUT,
      maxPromptBytes: MAX_PROMPT_BYTES,
      maxWireBytes: 65536,
      tokenBudgetMode: 'certified-conservative',
      streaming: true,
      cancellation: true,
      ready: missing.length === 0,
      readinessReason: missing.length === 0 ? '不按上下文长度拒绝请求，Gate B 尚未认证' : missing,
      maxCtx: MAX_CONTEXT,
      gateBPassed: false
    };
    this.sender({
      type: 'infer.capabilities', version: 2, requestId: requestId, profiles: [profile]
    }, epoch);
  }

  private acceptRequest(message: WireMessage, epoch: number): void {
    const requestId = message.requestId || '';
    const prompt = message.prompt || '';
    if (this.model.isBusy() || this.activeId.length > 0) {
      this.fail(requestId, epoch, 'BUSY', '算力繁忙，请稍后重试', true);
      return;
    }
    if (utf8Bytes(prompt).length > MAX_PROMPT_BYTES) {
      this.fail(requestId, epoch, 'PAYLOAD_TOO_LARGE', '本轮输入超过传输限制', false);
      return;
    }
    const missing = this.model.readinessError();
    if (missing.length > 0) {
      this.fail(requestId, epoch, 'MODEL_UNAVAILABLE', missing, true);
      return;
    }
    this.activeId = requestId;
    this.activeEpoch = epoch;
    this.seq = 0;
    this.answer = '';
    this.promptText = prompt;
    this.card.begin(requestId, epoch, prompt);
    this.sender({ type: 'infer.accepted', version: 2, requestId: requestId, state: 'preparing' }, epoch);
    const error = this.model.start([{ role: 'user', content: prompt }], (update: ChatUpdate) => {
      this.onUpdate(requestId, update);
    }, requestId);
    if (error.length > 0) {
      this.activeId = '';
      this.fail(requestId, epoch, 'MODEL_EXECUTION_FAILED', error, true);
    }
  }

  private onUpdate(requestId: string, update: ChatUpdate): void {
    if (requestId !== this.activeId) {
      return;
    }
    if (update.kind === 'delta') {
      const pieces = splitUtf8(update.text, 1024);
      for (const piece of pieces) {
        this.seq += 1;
        this.answer += piece;
        this.sender({
          type: 'infer.delta', version: 2, requestId: requestId, seq: this.seq, text: piece
        }, this.activeEpoch);
      }
      this.card.delta(requestId, this.activeEpoch, repairUtf8FromSource(this.answer, this.promptText));
      return;
    }
    const epoch = this.activeEpoch;
    this.activeId = '';
    if (update.error || update.finishReason === 'cancelled' || this.answer.trim().length === 0 || this.seq < 1) {
      const cancelled = update.finishReason === 'cancelled';
      this.fail(requestId, epoch, cancelled ? 'CANCELLED' : 'MODEL_EXECUTION_FAILED',
        cancelled ? '已停止；已开始的外部操作未必可撤销' : (update.error || '模型加载、提交或清理失败'), !cancelled);
      return;
    }
    const reason = update.finishReason === 'length' ? 'length' : 'stop';
    const bytes = utf8Bytes(this.answer);
    hilog.info(0, 'NearbyChat', 'infer done request=%{public}s bytes=%{public}d reason=%{public}s',
      requestId, bytes.length, reason);
    this.card.end(requestId, epoch, repairUtf8FromSource(this.answer, this.promptText), false);
    this.sender({
      type: 'infer.done', version: 2, requestId: requestId, lastSeq: this.seq,
      outputUtf8Bytes: bytes.length, outputSha256: sha256Hex(bytes), finishReason: reason, source: 'mate70-local'
    }, epoch);
  }

  private fail(requestId: string, epoch: number, code: string, text: string, retryable: boolean): void {
    hilog.warn(0, 'NearbyChat', 'infer error code=%{public}s request=%{public}s', code, requestId);
    this.card.end(requestId, epoch, repairUtf8FromSource(this.answer, this.promptText), true);
    this.sender({
      type: 'infer.error', version: 2, requestId: requestId, code: code, message: text, retryable: retryable
    }, epoch);
  }
}
