import { hilog } from '@kit.PerformanceAnalysisKit';
import { ChatMessage, InferenceMetrics, WireMessage } from '../protocol/ChatProtocol';
import { HttpRequest, utf8Length } from './HttpProtocol';
import { HttpResponder, HttpTransport } from './TcpHttpServer';
import {
  OPENAI_DEFAULT_DEADLINE_MS,
  OpenAiError,
  OpenAiModelEntry,
  ParsedChatRequest,
  STREAM_DONE,
  buildInferRequest,
  completionResponse,
  errorResponse,
  httpStatusForWireCode,
  modelsResponse,
  parseChatRequest,
  streamDeltaChunk,
  streamErrorFrame,
  streamFirstChunk,
  streamFinishChunk
} from './OpenAiTranslator';

const DOMAIN = 0x0301;
const TAG = 'OpenAiServer';
export const OPENAI_HTTP_PORT: number = 8080;
/**
 * HTTP 请求的合成 epoch 基数。真实 linkEnhance epoch 是 ++counter 的小整数，
 * 900000 起的自增值永不与其重叠；ChatProtocol 校验不限制 epoch 取值。
 */
export const HTTP_EPOCH_BASE: number = 900000;
/** 看门狗在推理预算之外的余量，覆盖尾部 token/收尾耗时。 */
const WATCHDOG_MARGIN_MS: number = 3000;

export interface OpenAiServerOptions {
  port: number;
  /** 每次启动创建新传输实例（真实 TCP 或测试假实现）。 */
  transport: () => HttpTransport;
  /** 集群当前可用模型清单（/v1/models 元数据）。 */
  models: () => OpenAiModelEntry[];
  /** 本机 LAN IPv4；取不到时端点显示降级为空。 */
  resolveAddress: () => Promise<string>;
  /** 把 infer.request 送入推理路由（relay.handleFromChat / host.handle）。 */
  submit: (message: WireMessage, epoch: number) => void;
  /** HTTP 侧不再需要该 epoch 的结果：取消集群侧执行。 */
  drop: (epoch: number) => void;
  /**
   * 集群当前可并行承载的推理数（ready 算力节点数）。网关在途请求达到该值
   * 即回 429——实测并发文本会话会把 GEWU 服务整个打挂（"gewu service
   * died"），relay 的忙节点准入按设计允许重叠，保护只能在网关层做。
   * 缺省 1（单 hub 串行）。
   */
  capacity?: () => number;
  /** 面板任务卡注册钩子（taskLinks）。 */
  onRequest?: (epoch: number, requestId: string, prompt: string) => void;
  /**
   * 调试用流量落盘：每个请求的完整 body 与完整回复以 JSONL 行回调给外部
   * 写入器（Index 接 filesDir/openai-traffic.jsonl，见 TrafficLog）。缺省不落盘。
   */
  trafficSink?: (line: string) => void;
  deadlineBudgetMs?: number;
}

interface PendingHttp {
  epoch: number;
  requestId: string;
  responder: HttpResponder;
  streaming: boolean;
  model: string;
  created: number;
  text: string;
  sseStarted: boolean;
  timer: number;
}

/** trafficSink 的 JSONL 行结构；字段按事件类型取子集，JSON.stringify 会丢弃 undefined 字段。 */
interface TrafficEntry {
  ts: string;
  /** request | prompt | reply */
  kind: string;
  id?: string;
  epoch?: number;
  method?: string;
  path?: string;
  bytes?: number;
  body?: string;
  /** 拍平后送入集群的实际输入（kind=prompt）：与原始 body 的差异就是裁剪/拍平的效果。 */
  model?: string;
  stream?: boolean;
  maxOutputTokens?: number;
  messageCount?: number;
  promptBytes?: number;
  trimmedTurns?: number;
  image?: boolean;
  messages?: ChatMessage[];
  /** done | error | timeout | aborted | rejected */
  outcome?: string;
  status?: number;
  code?: string;
  message?: string;
  finish?: string;
  promptTokens?: number;
  completionTokens?: number;
  text?: string;
}

/**
 * OpenAI 兼容网关：HTTP 请求 → infer.request（合成 epoch）→ 推理路由，
 * 回包经 Index.sendWire 分流到 deliver()，转成 SSE / completion JSON。
 * 生命周期由 hub 角色驱动（Index.syncOpenAiServer → sync(true/false)）。
 */
export class OpenAiServer {
  private readonly options: OpenAiServerOptions;
  private readonly deadlineMs: number;
  private readonly pendingByEpoch: Map<number, PendingHttp> = new Map();
  private transport: HttpTransport | null = null;
  private running: boolean = false;
  private address: string = '';
  private epochSerial: number = 0;

  constructor(options: OpenAiServerOptions) {
    this.options = options;
    this.deadlineMs = options.deadlineBudgetMs !== undefined && options.deadlineBudgetMs > 0 ?
      options.deadlineBudgetMs : OPENAI_DEFAULT_DEADLINE_MS;
  }

  /** 幂等启停；启动失败仅记日志（端口被占等），下次 sync(true) 重试。 */
  async sync(active: boolean): Promise<void> {
    if (active) {
      if (this.running) return;
      const transport = this.options.transport();
      try {
        await transport.start(this.options.port, (request: HttpRequest, responder: HttpResponder): void => {
          this.dispatch(request, responder);
        });
        this.transport = transport;
        this.running = true;
        try {
          this.address = await this.options.resolveAddress();
        } catch (_error) {
          this.address = '';
        }
        hilog.info(DOMAIN, TAG, 'serving %{public}s', this.endpoint());
      } catch (error) {
        this.running = false;
        hilog.error(DOMAIN, TAG, 'listen tcp/%{public}d failed: %{public}s', this.options.port,
          error instanceof Error ? error.message : String(error));
      }
      return;
    }
    if (!this.running) return;
    this.running = false;
    const transport = this.transport;
    this.transport = null;
    this.detachAll();
    if (transport !== null) {
      try {
        await transport.stop();
      } catch (_error) {
        // 关闭失败不影响状态复位。
      }
    }
  }

  isActive(): boolean {
    return this.running;
  }

  /** 面板展示用；未运行或拿不到本机 IP 时为空串。 */
  endpoint(): string {
    if (!this.running || this.address.length === 0) return '';
    return 'http://' + this.address + ':' + String(this.options.port) + '/v1';
  }

  /**
   * Index.sendWire 的分流出口：合成 epoch（≥ HTTP_EPOCH_BASE）归本服务处理。
   * 返回 true 表示已消费；pending 已结束的迟到回包静默吞掉。
   */
  async deliver(message: WireMessage, epoch: number): Promise<boolean> {
    if (epoch < HTTP_EPOCH_BASE) return false;
    const pending = this.pendingByEpoch.get(epoch);
    if (pending === undefined) return true;
    if (message.type === 'infer.delta') {
      const text = message.text || '';
      pending.text += text;
      if (pending.streaming) {
        if (!pending.sseStarted) {
          pending.sseStarted = true;
          if (!pending.responder.openSse()) {
            this.detach(epoch);
            return true;
          }
          this.writeFrame(pending, streamFirstChunk(pending.requestId, pending.model, pending.created));
        }
        this.writeFrame(pending, streamDeltaChunk(pending.requestId, pending.model, pending.created, text));
      }
      return true;
    }
    if (message.type === 'infer.done') {
      this.complete(pending, message.finishReason || 'stop', message.metrics);
      return true;
    }
    if (message.type === 'infer.error') {
      this.fail(pending, message.code || 'MODEL_EXECUTION_FAILED', message.message || '推理失败');
      return true;
    }
    // infer.accepted / infer.status：执行阶段推进对 HTTP 客户端不可见。
    return true;
  }

  async stop(): Promise<void> {
    await this.sync(false);
  }

  private dispatch(request: HttpRequest, responder: HttpResponder): void {
    // 访问日志：所有到达 OpenAI 层的请求（OPTIONS 预检在传输层直接 204，不在此列）。
    hilog.info(DOMAIN, TAG, 'request %{public}s %{public}s body=%{public}d bytes',
      request.method, request.path, utf8Length(request.body));
    if (request.path === '/v1/models') {
      this.logTraffic({ ts: this.nowIso(), kind: 'request',
        method: request.method, path: request.path, bytes: utf8Length(request.body), body: request.body });
      if (request.method !== 'GET') {
        responder.sendJson(405, errorResponse(405, 'method_not_allowed', '仅支持 GET。'));
        return;
      }
      responder.sendJson(200, modelsResponse(this.options.models(), Math.floor(Date.now() / 1000)));
      return;
    }
    if (request.path === '/v1/chat/completions') {
      // 先给身份再校验：被拒请求（405/400/429）也要能在落盘日志里配对。
      this.epochSerial++;
      const epoch = HTTP_EPOCH_BASE + this.epochSerial;
      const requestId = 'openai-' + this.epochSerial.toString(36) + '-' + Date.now().toString(36);
      this.logTraffic({ ts: this.nowIso(), kind: 'request', id: requestId, epoch: epoch,
        method: request.method, path: request.path, bytes: utf8Length(request.body), body: request.body });
      if (request.method !== 'POST') {
        this.logTraffic({ ts: this.nowIso(), kind: 'reply', id: requestId, epoch: epoch,
          outcome: 'rejected', status: 405, code: 'method_not_allowed', message: '仅支持 POST。' });
        responder.sendJson(405, errorResponse(405, 'method_not_allowed', '仅支持 POST。'));
        return;
      }
      this.handleChat(request, responder, epoch, requestId);
      return;
    }
    this.logTraffic({ ts: this.nowIso(), kind: 'request',
      method: request.method, path: request.path, bytes: utf8Length(request.body), body: request.body });
    responder.sendJson(404, errorResponse(404, 'not_found', '未知路径：' + request.path));
  }

  private nowIso(): string {
    return new Date().toISOString();
  }

  /** 流量落盘（旁路）：格式化/写入失败只记日志，绝不影响请求主流程。 */
  private logTraffic(entry: TrafficEntry): void {
    if (this.options.trafficSink === undefined) return;
    try {
      this.options.trafficSink(JSON.stringify(entry));
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'traffic log failed: %{public}s',
        error instanceof Error ? error.message : String(error));
    }
  }

  private handleChat(request: HttpRequest, responder: HttpResponder, epoch: number, requestId: string): void {
    let parsed: ParsedChatRequest;
    try {
      parsed = parseChatRequest(request.body);
    } catch (error) {
      if (error instanceof OpenAiError) {
        hilog.warn(DOMAIN, TAG, 'chat rejected %{public}d %{public}s: %{public}s',
          error.status, error.code, error.message);
        this.logTraffic({ ts: this.nowIso(), kind: 'reply', id: requestId, epoch: epoch,
          outcome: 'rejected', status: error.status, code: error.code, message: error.message });
        responder.sendJson(error.status, errorResponse(error.status, error.code, error.message));
        return;
      }
      // 非翻译层错误（如 JSON.parse 意外类型）交给传输层统一 500。
      throw new Error(error instanceof Error ? error.message : String(error));
    }
    const capacity = this.options.capacity !== undefined ? Math.max(1, this.options.capacity()) : 1;
    if (this.pendingByEpoch.size >= capacity) {
      hilog.warn(DOMAIN, TAG, 'chat rejected 429: %{public}d in-flight >= capacity %{public}d',
        this.pendingByEpoch.size, capacity);
      this.logTraffic({ ts: this.nowIso(), kind: 'reply', id: requestId, epoch: epoch,
        outcome: 'rejected', status: 429, code: 'rate_limit_error', message: '算力繁忙，请稍后重试。' });
      responder.sendJson(429, errorResponse(429, 'rate_limit_error', '算力繁忙，请稍后重试。'));
      return;
    }
    // 请求详情：模型/流式/消息数/拍平字节/裁剪轮数/图片，附当前问题开头便于对日志。
    const head = parsed.promptText.substring(0, 80).replace(/\s+/g, ' ');
    hilog.info(DOMAIN, TAG,
      'chat accepted epoch=%{public}d id=%{public}s model=%{public}s stream=%{public}s ' +
      'messages=%{public}d prompt=%{public}dB trimmed=%{public}d image=%{public}s maxTokens=%{public}d head=%{public}s',
      epoch, requestId, parsed.model, String(parsed.streaming), parsed.messageCount,
      parsed.promptBytes, parsed.trimmedTurns, parsed.image.length > 0 ? 'yes' : 'no',
      parsed.maxOutputTokens, head);
    // 落盘拍平后的完整 prompt：调试「模型为什么这么答」要看模型实际收到了什么
    // （含裁剪标记），而不是客户端发了什么。
    this.logTraffic({ ts: this.nowIso(), kind: 'prompt', id: requestId, epoch: epoch,
      model: parsed.model, stream: parsed.streaming, maxOutputTokens: parsed.maxOutputTokens,
      messageCount: parsed.messageCount, promptBytes: parsed.promptBytes,
      trimmedTurns: parsed.trimmedTurns, image: parsed.image.length > 0, messages: parsed.messages });
    const pending: PendingHttp = {
      epoch: epoch,
      requestId: requestId,
      responder: responder,
      streaming: parsed.streaming,
      model: parsed.model,
      created: Math.floor(Date.now() / 1000),
      text: '',
      sseStarted: false,
      timer: -1
    };
    this.pendingByEpoch.set(epoch, pending);
    responder.onClose((): void => this.detach(epoch));
    if (this.options.onRequest !== undefined) {
      try {
        this.options.onRequest(epoch, requestId, parsed.promptText);
      } catch (_error) {
        // 面板注册失败不影响推理本身。
      }
    }
    pending.timer = setTimeout((): void => this.expire(epoch), this.deadlineMs + WATCHDOG_MARGIN_MS);
    try {
      this.options.submit(buildInferRequest(parsed, requestId, this.deadlineMs), epoch);
    } catch (error) {
      hilog.error(DOMAIN, TAG, 'submit failed: %{public}s', error instanceof Error ? error.message : String(error));
      this.logTraffic({ ts: this.nowIso(), kind: 'reply', id: requestId, epoch: epoch,
        outcome: 'error', status: 500, code: 'internal_error', message: '请求未能进入推理队列。' });
      this.finish(pending, (): void => {
        responder.sendJson(500, errorResponse(500, 'internal_error', '请求未能进入推理队列。'));
      });
    }
  }

  /** 写帧失败（客户端已断开）即取消集群侧执行。 */
  private writeFrame(pending: PendingHttp, frame: string): void {
    pending.responder.sendFrame(frame).then((sent: boolean): void => {
      if (!sent && this.pendingByEpoch.get(pending.epoch) === pending) {
        this.detach(pending.epoch);
      }
    }).catch((_error: Error): void => {
      if (this.pendingByEpoch.get(pending.epoch) === pending) {
        this.detach(pending.epoch);
      }
    });
  }

  private complete(pending: PendingHttp, finishReason: string, metrics?: InferenceMetrics): void {
    this.finish(pending, (): void => {
      this.logTraffic({ ts: this.nowIso(), kind: 'reply', id: pending.requestId, epoch: pending.epoch,
        outcome: 'done', status: 200, finish: finishReason, text: pending.text,
        promptTokens: metrics?.promptTokens, completionTokens: metrics?.completionTokens });
      if (pending.streaming) {
        if (!pending.sseStarted) {
          // 零增量完成：仍按 OpenAI 形状发角色帧，客户端才能解析出全文。
          pending.sseStarted = true;
          if (!pending.responder.openSse()) return;
          this.writeFrame(pending, streamFirstChunk(pending.requestId, pending.model, pending.created));
        }
        this.writeFrame(pending, streamFinishChunk(pending.requestId, pending.model, pending.created, finishReason));
        this.writeFrame(pending, STREAM_DONE);
        pending.responder.close();
        return;
      }
      pending.responder.sendJson(200, completionResponse(pending.requestId, pending.model, pending.created,
        pending.text, finishReason, metrics?.promptTokens, metrics?.completionTokens));
    });
  }

  private fail(pending: PendingHttp, code: string, text: string): void {
    const status = httpStatusForWireCode(code);
    this.finish(pending, (): void => {
      this.logTraffic({ ts: this.nowIso(), kind: 'reply', id: pending.requestId, epoch: pending.epoch,
        outcome: 'error', status: status, code: code, message: text, text: pending.text });
      if (pending.streaming && pending.sseStarted) {
        // SSE 已开始，HTTP 状态码发不出去：按 OpenAI 惯例以错误帧收尾。
        this.writeFrame(pending, streamErrorFrame(status, code, text));
        this.writeFrame(pending, STREAM_DONE);
        pending.responder.close();
        return;
      }
      pending.responder.sendJson(status, errorResponse(status, code, text));
    });
  }

  /** 看门狗：预算 + 余量内没有任何终态 → 504 并取消集群侧执行。 */
  private expire(epoch: number): void {
    const pending = this.pendingByEpoch.get(epoch);
    if (pending === undefined) return;
    this.finish(pending, (): void => {
      this.logTraffic({ ts: this.nowIso(), kind: 'reply', id: pending.requestId, epoch: pending.epoch,
        outcome: 'timeout', status: 504, code: 'timeout', message: '推理超时。', text: pending.text });
      if (pending.streaming && pending.sseStarted) {
        this.writeFrame(pending, streamErrorFrame(504, 'timeout', '推理超时。'));
        this.writeFrame(pending, STREAM_DONE);
        pending.responder.close();
        return;
      }
      pending.responder.sendJson(504, errorResponse(504, 'timeout', '推理超时。'));
    });
    this.options.drop(epoch);
  }

  /**
   * 连接关闭 / 写失败的统一清理：摘除 pending 并取消集群侧执行。
   * complete/fail/expire 先摘除再回包，因此自身关流不会走到这里的 drop。
   */
  private detach(epoch: number): void {
    const pending = this.pendingByEpoch.get(epoch);
    if (pending === undefined) return;
    this.pendingByEpoch.delete(epoch);
    if (pending.timer >= 0) clearTimeout(pending.timer);
    this.options.drop(epoch);
    this.logTraffic({ ts: this.nowIso(), kind: 'reply', id: pending.requestId, epoch: pending.epoch,
      outcome: 'aborted', text: pending.text });
    // 幂等：客户端断开路径连接已死为 no-op；停服路径借它把挂起连接收掉。
    try {
      pending.responder.close();
    } catch (_error) {
      // 连接已死则忽略。
    }
  }

  private detachAll(): void {
    const epochs: number[] = [];
    for (const epoch of this.pendingByEpoch.keys()) epochs.push(epoch);
    for (const epoch of epochs) this.detach(epoch);
  }

  /** 终态收口：先摘除（幂等），再执行回包动作；回包抛错兜底关流。 */
  private finish(pending: PendingHttp, body: () => void): void {
    if (this.pendingByEpoch.get(pending.epoch) !== pending) return;
    this.pendingByEpoch.delete(pending.epoch);
    if (pending.timer >= 0) clearTimeout(pending.timer);
    try {
      body();
    } catch (error) {
      hilog.error(DOMAIN, TAG, 'respond failed: %{public}s', error instanceof Error ? error.message : String(error));
      try {
        pending.responder.close();
      } catch (_ignored) {
        // 连接已死则忽略。
      }
    }
  }
}
