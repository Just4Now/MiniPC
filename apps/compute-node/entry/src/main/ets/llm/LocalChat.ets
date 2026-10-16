import { hilog } from '@kit.PerformanceAnalysisKit';
import probe from 'libgewu_probe.so';
import { fileIo } from '@kit.CoreFileKit';
import { SessionPlan, SessionReuse } from './SessionReuse';
import { manifestTier, modelRequestType, readyModelDirs, selectModelDir } from './ModelRegistry';
import { classifyFromMessages, taskTextOf } from '../cluster/TaskRules';
import { sanitizeModelOutput } from './Utf8Repair';

/**
 * 本地文本推理（GEWU probe）。档位感知选模：与 hub 侧同规则重算任务档位（消息
 * 逐字转发，两侧结果一致），用它在就绪目录里按贴近选强/弱模型；
 * 选出的目录档位低于任务档位时记 local tier fallback 日志（降档可观测）。
 * VL 通道（VlLlmTransport/QwenVlManager）v1 不感知档位——带图路径由 vision 需求
 * 独占，不在本类的选型范围内。
 *
 * GEWU 引擎内部的跨块字符替换无法避免（见 Utf8Repair.sanitizeModelOutput），
 * 本类是它的执行点：响应内容在进入 answer/回调之前一律清洗——本机 UI、
 * 任务卡与 wire 下游拿到的都是同一份净化文本，幂等保证下游二次清洗安全。
 */

export interface ChatMessage { role: string; content: string; }
export interface ChatUpdate { kind: 'delta' | 'done'; text: string; error?: string; finishReason?: string; }
/** 多模态消息分片：图片（image_url 为 data URL）或文本。 */
interface MessagePart { type: string; text?: string; image_url?: string }
/** 推理请求的消息：纯文本 content 为字符串；带图时最后一条 user 消息为分片数组。 */
interface RequestMessage { role: string; content: string | MessagePart[] }
interface ChatRequest { type: string; messages: RequestMessage[]; stream: boolean; max_tokens: number; }
export interface ChatStartOptions { maxTokens?: number; waitSeconds?: number; image?: string; }
const MAX_TOKENS = 2048;
interface NativeEvent { event: string; id?: string; payload: string; }
interface NativeResponse { message?: ChatMessage; finish_reason?: string | null; }

interface Job {
  requestId: string;
  nativeId: number;
  cancelled: boolean;
  answer: string;
  failure: string;
  finishReason: string;
  delivered: boolean;
  /** 请求原文（taskTextOf 拼接）：sanitizeModelOutput 的修复锚点来源。 */
  promptSource: string;
  callback: ((update: ChatUpdate) => void) | undefined;
  plan: SessionPlan | undefined;
}

export class LocalChat {
  private filesDir: string;
  private timer: number = -1;
  private closed: boolean = false;
  private jobs: Job[] = [];
  private reuse: SessionReuse = new SessionReuse((key: string): void => {
    try { probe.closeSession(key); } catch (_) { /* older native library: nothing cached */ }
  });

  constructor(filesDir: string) { this.filesDir = filesDir; }
  isBusy(): boolean { return this.activeCount() > 0; }

  /**
   * Session reuse is off unless <filesDir>/session-reuse.on exists, so the default path is
   * the original one-session-per-request behaviour.
   */
  private reuseEnabled(): boolean {
    try { return fileIo.accessSync(this.filesDir + '/session-reuse.on'); } catch (_) { return false; }
  }
  activeCount(): number { return this.jobs.filter((job: Job): boolean => !job.delivered).length; }

  /** Native cleanup still owns model memory after the answer has been delivered. */
  hasPendingNativeJobs(): boolean { return this.jobs.length > 0; }

  // Basic readiness only: leave GEWU initialization to the actual request.
  // 任意一个就绪模型即视为可用；具体目录在请求时按需求选择。
  readinessError(): string {
    if (this.closed) return '模型服务已关闭。';
    return readyModelDirs(this.filesDir).length > 0 ? '' : '模型文件缺失或无法读取。';
  }

  /**
   * 带图请求把最后一条 user 消息编码为多模态分片（图片在前、文本在后，对齐
   * Qwen-VL 惯例）；请求类型跟随所选模型 api_config 的声明。
   *
   * stream 固定为 false：流式回调会把跨块的字符切成 U+FFFD。真机实测单次完整
   * 响应也不能幸免（引擎内部边界仍会吃掉多字节字符），最终的兜底是出口清洗
   * sanitizeModelOutput（consumeEvents 处执行），stream:false 只是少制造一份。
   */
  private buildRequest(messages: ChatMessage[], image: string, type: string, maxTokens: number): ChatRequest {
    const out: RequestMessage[] = [];
    for (let index = 0; index < messages.length; index++) {
      const message = messages[index];
      if (image.length > 0 && index === messages.length - 1 && message.role === 'user') {
        const parts: MessagePart[] = [
          { type: 'image_url', image_url: 'data:image/jpeg;base64,' + image },
          { type: 'text', text: message.content }
        ];
        out.push({ role: message.role, content: parts });
      } else {
        out.push({ role: message.role, content: message.content });
      }
    }
    return { type: type, messages: out, stream: false, max_tokens: maxTokens };
  }

  start(messages: ChatMessage[], callback: (update: ChatUpdate) => void, requestId: string = '',
    options: ChatStartOptions = {}): string {
    if (this.closed) return '模型服务已关闭。';
    if (messages.length === 0) return '请输入问题。';
    const image: string = options.image === undefined ? '' : options.image;
    const maxTokens = Number.isInteger(options.maxTokens) && (options.maxTokens as number) > 0 ?
      Math.min(MAX_TOKENS, options.maxTokens as number) : MAX_TOKENS;
    const waitSeconds = Number.isInteger(options.waitSeconds) && (options.waitSeconds as number) > 0 ?
      options.waitSeconds as number : 0;
    // 图片即 vision 需求：选不出覆盖该需求的模型目录时 fail closed，绝不送给纯文本模型。
    const needs: string[] = image.length > 0 ? ['vision'] : [];
    // 档位感知选模：与 hub 侧同规则重算（消息逐字转发，两侧结果一致）。
    const profile = classifyFromMessages(messages, image.length > 0);
    const modelDir = selectModelDir(this.filesDir, needs, profile.tier);
    if (modelDir.length === 0) {
      return image.length > 0 ? '本地模型不支持图片理解。' : '模型文件缺失或无法读取。';
    }
    const dirTier = manifestTier(this.filesDir, modelDir);
    if (dirTier < profile.tier) {
      hilog.info(0, 'NearbyChat', 'local tier fallback task=%{public}d dir=%{public}d model=%{public}s',
        profile.tier, dirTier, modelDir);
    }
    // A cached native session belongs to a specific model directory.
    const plan: SessionPlan | undefined = this.reuseEnabled() && image.length === 0 ?
      this.reuse.plan(messages, modelDir) : undefined;
    const sent = plan !== undefined ? plan.messages : messages;
    const request = this.buildRequest(sent, image, modelRequestType(this.filesDir, modelDir), maxTokens);
    let nativeId = 0;
    try {
      if (plan !== undefined && plan.key.length > 0) {
        nativeId = probe.start(this.filesDir + '/models/' + modelDir, JSON.stringify(request),
          this.filesDir + '/gewu-chat.jsonl', waitSeconds, plan.key);
      } else {
        nativeId = probe.start(this.filesDir + '/models/' + modelDir, JSON.stringify(request),
          this.filesDir + '/gewu-chat.jsonl', waitSeconds);
      }
    } catch (_) {
      if (plan !== undefined) this.reuse.finish(plan, false);
      return '无法启动模型，请确认模型文件已部署。';
    }
    if (nativeId <= 0) {
      if (plan !== undefined) this.reuse.finish(plan, false);
      return '模型繁忙，请稍后再发。';
    }
    this.jobs.push({
      requestId: requestId, nativeId: nativeId, cancelled: false, answer: '', failure: '',
      finishReason: '', delivered: false, plan: plan, promptSource: taskTextOf(messages), callback: callback
    });
    if (this.timer === -1) this.timer = setInterval(() => this.consumeEvents(), 80);
    return '';
  }

  cancel(requestId?: string): void {
    if (this.jobs.length === 0) return;
    if (requestId === undefined || requestId.length === 0) {
      for (const job of this.jobs) job.cancelled = true;
      probe.cancel();
      return;
    }
    const job = this.jobs.find((item: Job) => item.requestId === requestId && !item.delivered);
    if (job === undefined) return;
    job.cancelled = true;
    probe.cancel(job.nativeId);
  }

  close(): void {
    this.closed = true;
    for (const job of this.jobs) job.callback = undefined;
    this.cancel();
    this.reuse.closeAll();
    if (this.timer !== -1) clearInterval(this.timer);
    this.timer = -1;
  }

  private jobByNative(nativeId: number): Job | undefined {
    return this.jobs.find((item: Job) => item.nativeId === nativeId);
  }

  private consumeEvents(): void {
    for (const line of probe.takeEvents()) {
      if (this.closed) continue;
      let event: NativeEvent;
      try { event = JSON.parse(line) as NativeEvent; }
      catch (_) { continue; }
      if (!event || typeof event.event !== 'string') continue;
      const nativeId = event.id ? Number(event.id) : 0;
      if (nativeId <= 0) continue;
      const job = this.jobByNative(nativeId);
      if (job === undefined) continue;
      if (event.event === 'file_error') job.failure = '模型文件缺失或无法读取。';
      if ((event.event === 'create' || event.event === 'submit' || event.event === 'destroy') &&
        event.payload !== '0') job.failure = '模型请求失败（' + event.event + ': ' + event.payload + '），请重试。';
      if (event.event === 'abort') job.cancelled = true;
      if (event.event === 'response' && !job.delivered && !job.cancelled && !job.failure) {
        let response: NativeResponse;
        try { response = JSON.parse(event.payload) as NativeResponse; }
        catch (_) { this.parseFailure(job); continue; }
        if (!response) { this.parseFailure(job); continue; }
        if (typeof response.message?.content === 'string' && response.message.content.length > 0) {
          // GEWU 引擎可能在回调前就把跨块多字节字符替换成 U+FFFD：先修复后剔除，
          // answer、delta 回调与最终 done 用的都是这一份净化文本。
          const content = sanitizeModelOutput(response.message.content, job.promptSource);
          job.answer += content;
          if (job.callback) job.callback({ kind: 'delta', text: content });
        }
        if (typeof response.finish_reason === 'string' && response.finish_reason.length > 0) {
          job.finishReason = response.finish_reason;
          probe.complete(job.nativeId);
        } else if (job.answer.length > 0) {
          // stream:false has exactly one response; native already treats it as terminal.
          job.finishReason = 'stop';
          probe.complete(job.nativeId);
        }
        // stream:false is a complete answer. Return it before native session
        // teardown; keep the job only for cleanup and session-cache ownership.
        if (job.finishReason.length > 0) { this.deliver(job); }
      }
      if (event.event === 'end') {
        if (event.payload === 'stalled' && job.answer.length === 0 && job.failure.length === 0) {
          job.failure = '算力端没有在时限内返回，请再试一次。';
        }
        this.finish(job);
      }
    }
  }

  private parseFailure(job: Job): void {
    job.failure = '模型回复解析失败，请重试。';
    probe.cancel(job.nativeId);
  }

  private finish(job: Job): void {
    if (this.jobs.indexOf(job) < 0) return;
    this.deliver(job);
    if (job.plan !== undefined) {
      this.reuse.finish(job.plan, !job.failure && !job.cancelled && job.answer.length > 0);
    }
    this.jobs.splice(this.jobs.indexOf(job), 1);
    if (this.jobs.length === 0 && this.timer !== -1) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  private deliver(job: Job): void {
    if (job.delivered) return;
    if (!job.failure && !job.cancelled && (!job.answer || !job.finishReason)) {
      job.failure = job.answer ? '模型回复意外中断，请重试。' : '模型没有返回内容，请重试。';
    }
    const update: ChatUpdate = {
      kind: 'done', text: job.failure || (job.cancelled ?
        (job.answer ? job.answer + '\n\n已停止生成' : '已停止生成') : job.answer),
      finishReason: job.cancelled ? 'cancelled' : job.finishReason
    };
    if (job.failure) update.error = job.failure;
    const callback = job.callback;
    job.callback = undefined;
    job.delivered = true;
    if (callback) callback(update);
  }
}
