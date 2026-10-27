import socket from '@ohos.net.socket';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { HttpRequest, HttpRequestParser, HttpProtocolError, formatResponse, sseResponseHead } from './HttpProtocol';
import { errorResponse } from './OpenAiTranslator';

const DOMAIN = 0x0300;
const TAG = 'OpenAiHttp';
/** 并发连接上限；超限时新连接直接回 503 并关闭，防连接耗尽。 */
const MAX_CONNECTIONS: number = 8;
/** 单连接挂起未完成的写请求数上限；超过说明对端不再收数据，断开止损。 */
const MAX_PENDING_WRITES: number = 64;
/** 建连后允许等待完整请求的空闲时长；超时关闭（防慢速连接占坑）。 */
const IDLE_TIMEOUT_MS: number = 30000;

/** 供上层（OpenAiServer）回包的句柄；全部方法幂等且连接关闭后安全。 */
export interface HttpResponder {
  /** 发送完整 JSON 响应并关闭连接。 */
  sendJson(status: number, body: string): void;
  /** 发送 SSE 响应头；返回 false 表示连接已不可用。 */
  openSse(): boolean;
  /** 追加一帧 SSE 数据；返回 false 表示连接已不可用（调用方应放弃该请求）。 */
  sendFrame(frame: string): Promise<boolean>;
  /** 注册连接关闭（无论对端断开还是本地主动关闭）回调；已关闭则立即回调。 */
  onClose(callback: () => void): void;
  /** 主动关闭连接（幂等）。 */
  close(): void;
}

export type HttpHandler = (request: HttpRequest, responder: HttpResponder) => void;

/** 可注入的传输层；测试用假实现替换真实 TCP。 */
export interface HttpTransport {
  start(port: number, handler: HttpHandler): Promise<void>;
  stop(): Promise<void>;
}

interface CloseCallbackEntry { callback: () => void; }

/** 单个 TCP 连接：解析请求 + 串行写 + 关闭回调分发。 */
class ServerConnection implements HttpResponder {
  readonly parser: HttpRequestParser = new HttpRequestParser();
  private readonly connection: socket.TCPSocketConnection;
  private readonly onCloseCallbacks: CloseCallbackEntry[] = [];
  private writeChain: Promise<void> = Promise.resolve();
  private pendingWrites: number = 0;
  private idleTimer: number = -1;
  private closed: boolean = false;
  private requestDispatched: boolean = false;
  private sseOpen: boolean = false;

  constructor(connection: socket.TCPSocketConnection, handler: HttpHandler) {
    this.connection = connection;
    this.idleTimer = setTimeout((): void => this.close(), IDLE_TIMEOUT_MS);
    connection.on('message', (info: socket.SocketMessageInfo): void => {
      // socket 事件回调里的未捕获异常会被运行时以 JsError 杀掉整个应用
      // （实测），任何处理缺陷都必须就地消化，降级为 500 或断连。
      try {
        this.receive(new Uint8Array(info.message), handler);
      } catch (error) {
        hilog.error(DOMAIN, TAG, 'receive failed client=%{public}d: %{public}s', connection.clientId,
          error instanceof Error ? error.message : String(error));
        try {
          this.sendJson(500, errorResponse(500, 'internal_error', '服务内部错误。'));
        } catch (_ignored) {
          this.close();
        }
      }
    });
    connection.on('close', (): void => this.close());
    connection.on('error', (_error: Error): void => this.close());
  }

  get clientId(): number {
    return this.connection.clientId;
  }

  /** 连接关闭（含本地主动）后为 true；上层据此停止写。 */
  get isClosed(): boolean {
    return this.closed;
  }

  private receive(chunk: Uint8Array, handler: HttpHandler): void {
    if (this.closed || this.requestDispatched) return;
    let request: HttpRequest | null = null;
    try {
      request = this.parser.push(chunk);
    } catch (error) {
      if (error instanceof HttpProtocolError) {
        this.sendJson(error.status, errorResponse(error.status, 'protocol_error', error.message));
      } else {
        this.sendJson(400, errorResponse(400, 'protocol_error', '请求解析失败。'));
      }
      return;
    }
    if (request === null) return;
    // 一连接一请求（Connection: close）；后续到达的字节直接忽略。
    this.requestDispatched = true;
    clearTimeout(this.idleTimer);
    this.idleTimer = -1;
    if (request.method === 'OPTIONS') {
      this.sendJson(204, '');
      return;
    }
    try {
      handler(request, this);
    } catch (error) {
      hilog.error(DOMAIN, TAG, 'handler failed: %{public}s', error instanceof Error ? error.message : String(error));
      this.sendJson(500, errorResponse(500, 'internal_error', '服务内部错误。'));
    }
  }

  private rawSend(text: string): void {
    if (this.closed) return;
    if (this.pendingWrites >= MAX_PENDING_WRITES) {
      hilog.warn(DOMAIN, TAG, 'client=%{public}d pending writes overflow, closing', this.connection.clientId);
      this.close();
      return;
    }
    this.pendingWrites++;
    const done = (): void => {
      this.pendingWrites--;
    };
    // 按到达顺序串行写：避免帧交错；写失败视为连接已死。
    // 注意：这里不能以 this.closed 短路——sendJson 先入队再 close()，
    // closed 在微任务执行前就已置 true，短路会把已排队的响应整个吞掉
    // （客户端表现为空回复）。socket 真死时 send 会 reject，走失败分支。
    this.writeChain = this.writeChain.then((): Promise<void> => {
      return this.connection.send({ data: text, encoding: 'UTF-8' }).then(done, (_error: Error): void => {
        this.pendingWrites--;
        hilog.warn(DOMAIN, TAG, 'send failed client=%{public}d msg=%{public}s', this.connection.clientId,
          _error instanceof Error ? _error.message : String(_error));
        this.close();
      });
    });
  }

  sendJson(status: number, body: string): void {
    if (this.closed) return;
    this.rawSend(formatResponse(status, 'application/json; charset=utf-8', body));
    this.close();
  }

  openSse(): boolean {
    if (this.closed) return false;
    if (this.sseOpen) return true;
    this.sseOpen = true;
    this.rawSend(sseResponseHead());
    return true;
  }

  sendFrame(frame: string): Promise<boolean> {
    if (this.closed || !this.sseOpen) return Promise.resolve(false);
    this.rawSend(frame);
    return this.writeChain.then((): boolean => !this.closed);
  }

  onClose(callback: () => void): void {
    if (this.closed) {
      callback();
      return;
    }
    this.onCloseCallbacks.push({ callback: callback });
  }

  close(): void {
    if (this.closed) return;
    this.closed = true;
    if (this.idleTimer >= 0) {
      clearTimeout(this.idleTimer);
      this.idleTimer = -1;
    }
    const callbacks = this.onCloseCallbacks.slice();
    this.onCloseCallbacks.length = 0;
    // 先冲刷已挂起的写（响应/SSE 帧已入队但未发出），再关闭底层 socket。
    this.writeChain.then((): void => {
      try {
        this.connection.close();
      } catch (_error) {
        // 对端已断开时 close 可能报错，忽略。
      }
    });
    // 关闭回调同样不允许抛出：它运行在 socket 事件回调栈上，未捕获会杀进程。
    for (const entry of callbacks) {
      try {
        entry.callback();
      } catch (error) {
        hilog.error(DOMAIN, TAG, 'close callback failed: %{public}s',
          error instanceof Error ? error.message : String(error));
      }
    }
  }
}

/** 真实 TCP 传输：0.0.0.0 监听 + 连接管理。 */
export class TcpHttpServer implements HttpTransport {
  private server: socket.TCPSocketServer | null = null;
  private connections: ServerConnection[] = [];
  private stopped: boolean = true;

  async start(port: number, handler: HttpHandler): Promise<void> {
    if (this.server !== null) return;
    this.stopped = false;
    const server = socket.constructTCPSocketServerInstance();
    server.on('connect', (connection: socket.TCPSocketConnection): void => {
      if (this.stopped || this.connections.length >= MAX_CONNECTIONS) {
        hilog.warn(DOMAIN, TAG, 'rejecting connection (limit %{public}d)', MAX_CONNECTIONS);
        try {
          connection.send({ data: formatResponse(503, 'application/json; charset=utf-8',
            errorResponse(503, 'overloaded', '服务繁忙，请稍后重试。')), encoding: 'UTF-8' })
            .then((): void => { connection.close(); }, (): void => { connection.close(); });
        } catch (_error) {
          // 发送失败则直接丢弃连接。
        }
        return;
      }
      const entry = new ServerConnection(connection, handler);
      this.connections.push(entry);
      entry.onClose((): void => this.remove(entry));
      hilog.info(DOMAIN, TAG, 'client=%{public}d accepted (%{public}d open)', entry.clientId, this.connections.length);
    });
    server.on('error', (error: Error): void => {
      hilog.error(DOMAIN, TAG, 'server error: %{public}s', error.message);
    });
    try {
      await server.listen({ address: '0.0.0.0', port: port });
      this.server = server;
      hilog.info(DOMAIN, TAG, 'openai api listening tcp/%{public}d', port);
    } catch (error) {
      server.off('connect');
      server.off('error');
      throw new Error(error instanceof Error ? error.message : String(error));
    }
  }

  private remove(entry: ServerConnection): void {
    const index = this.connections.indexOf(entry);
    if (index >= 0) this.connections.splice(index, 1);
  }

  async stop(): Promise<void> {
    this.stopped = true;
    const server = this.server;
    this.server = null;
    const connections = this.connections.slice();
    this.connections.length = 0;
    for (const entry of connections) entry.close();
    if (server !== null) {
      try {
        await server.close();
      } catch (_error) {
        // 进程退出时监听可能已失效。
      }
      server.off('connect');
      server.off('error');
    }
  }
}
