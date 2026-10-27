import { util } from '@kit.ArkTS';

/** 单个请求头的字节上限；超过直接 431 断开，防止畸形连接耗尽内存。 */
export const HTTP_MAX_HEADER_BYTES: number = 16384;
/**
 * 单个请求体上限（2MB）。agent harness 的原始 JSON 往往超过 256KB——完整 tools
 * 定义、工具循环历史等在拍平时大多被丢弃，真正进集群的只是 ≤32KB 的拍平文本，
 * 因此这里只拦明显异常的请求（误传音视频 base64 等），业务级拒绝由翻译层给出
 * 精确错误（32768 字节提示词上限 / 24000 字符图片上限）。
 */
export const HTTP_MAX_BODY_BYTES: number = 2097152;

/** 解析失败时抛出；status 为应答状态码，message 为面向调用方的错误说明。 */
export class HttpProtocolError extends Error {
  readonly status: number;
  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

export interface HttpRequest {
  method: string;
  path: string;
  headers: Map<string, string>;
  body: string;
}

function decodeUtf8(bytes: Uint8Array): string {
  return util.TextDecoder.create('utf-8').decodeToString(bytes);
}

/** 头部结束符 \r\n\r\n 的字节偏移；未出现返回 -1。 */
function headerTerminator(bytes: Uint8Array): number {
  for (let index = 0; index + 3 < bytes.length; index++) {
    if (bytes[index] === 13 && bytes[index + 1] === 10 && bytes[index + 2] === 13 && bytes[index + 3] === 10) {
      return index;
    }
  }
  return -1;
}

/**
 * 每连接一个的增量 HTTP/1.1 请求解析器：持续 push TCP 分片，凑齐
 * 「请求头 + Content-Length 请求体」后整体解码返回（UTF-8 跨分片安全），
 * 未凑齐一律返回 null。本服务固定 Connection: close，一连接一请求，不做管线化。
 */
export class HttpRequestParser {
  private bytes: Uint8Array = new Uint8Array(0);

  push(chunk: Uint8Array): HttpRequest | null {
    const merged = new Uint8Array(this.bytes.length + chunk.length);
    merged.set(this.bytes, 0);
    merged.set(chunk, this.bytes.length);
    this.bytes = merged;
    const headerEnd = headerTerminator(this.bytes);
    if (headerEnd < 0) {
      if (this.bytes.length > HTTP_MAX_HEADER_BYTES) {
        throw new HttpProtocolError(431, '请求头过大');
      }
      return null;
    }
    if (headerEnd > HTTP_MAX_HEADER_BYTES) {
      throw new HttpProtocolError(431, '请求头过大');
    }
    const lines = decodeUtf8(this.bytes.subarray(0, headerEnd)).split('\r\n');
    const parts = lines[0].split(' ');
    if (parts.length !== 3 || parts[2].indexOf('HTTP/') !== 0) {
      throw new HttpProtocolError(400, '请求行不合法');
    }
    const method = parts[0].toUpperCase();
    let target = parts[1];
    // 代理形式的绝对 URI 只取路径部分；直接按 origin-form 访问的客户端不受影响。
    if (target.indexOf('http://') === 0 || target.indexOf('https://') === 0) {
      const rest = target.substring(target.indexOf('://') + 3);
      const slash = rest.indexOf('/');
      target = slash >= 0 ? rest.substring(slash) : '/';
    }
    const query = target.indexOf('?');
    const path = query >= 0 ? target.substring(0, query) : target;
    const headers = new Map<string, string>();
    for (let index = 1; index < lines.length; index++) {
      const line = lines[index];
      if (line.length === 0) continue;
      const colon = line.indexOf(':');
      if (colon <= 0) {
        throw new HttpProtocolError(400, '请求头不合法');
      }
      headers.set(line.substring(0, colon).trim().toLowerCase(), line.substring(colon + 1).trim());
    }
    let contentLength = 0;
    const lengthHeader = headers.get('content-length');
    if (lengthHeader !== undefined) {
      if (!/^\d+$/.test(lengthHeader)) {
        throw new HttpProtocolError(400, 'Content-Length 不合法');
      }
      contentLength = Number.parseInt(lengthHeader);
      if (contentLength > HTTP_MAX_BODY_BYTES) {
        throw new HttpProtocolError(413, '请求体超过 2MB 上限');
      }
    } else if ((headers.get('transfer-encoding') || '').toLowerCase().indexOf('chunked') >= 0) {
      // 本端只服务 curl/SDK 的定长上传；分块编码明确拒绝而不是静默截断。
      throw new HttpProtocolError(411, '请使用 Content-Length 上传请求体');
    }
    const total = headerEnd + 4 + contentLength;
    if (this.bytes.length < total) return null;
    const body = decodeUtf8(this.bytes.subarray(headerEnd + 4, total));
    // 只消费本请求的字节；残留（客户端误管线化的下一请求）留在缓冲，
    // 由上层按 Connection: close 语义忽略。
    this.bytes = this.bytes.slice(total);
    const request: HttpRequest = { method: method, path: path, headers: headers, body: body };
    return request;
  }
}

export function statusReason(status: number): string {
  if (status === 200) return 'OK';
  if (status === 204) return 'No Content';
  if (status === 400) return 'Bad Request';
  if (status === 404) return 'Not Found';
  if (status === 405) return 'Method Not Allowed';
  if (status === 409) return 'Conflict';
  if (status === 411) return 'Length Required';
  if (status === 413) return 'Payload Too Large';
  if (status === 429) return 'Too Many Requests';
  if (status === 431) return 'Request Header Fields Too Large';
  if (status === 500) return 'Internal Server Error';
  if (status === 502) return 'Bad Gateway';
  if (status === 503) return 'Service Unavailable';
  if (status === 504) return 'Gateway Timeout';
  return 'Response';
}

/** 浏览器直连（Web 前端 agent）所需的宽松 CORS；本服务无鉴权，无凭据可泄。 */
export const CORS_HEADERS: string[] = [
  'Access-Control-Allow-Origin: *',
  'Access-Control-Allow-Methods: GET, POST, OPTIONS',
  'Access-Control-Allow-Headers: Content-Type, Authorization',
  'Access-Control-Max-Age: 86400'
];

/**
 * 字符串的 UTF-8 字节数。SDK 文档规定 util.TextEncoder.encodeInto('')
 * 返回 undefined，空串必须特判，否则取 .length 直接崩溃（线上 OPTIONS→204
 * 预检曾因此 JsError 杀进程）。
 */
export function utf8Length(text: string): number {
  if (text.length === 0) return 0;
  return new util.TextEncoder().encodeInto(text).length;
}

/** 组装完整响应（含 CORS、Content-Length、Connection: close）。 */
export function formatResponse(status: number, contentType: string, body: string): string {
  const bytes = utf8Length(body);
  const lines: string[] = ['HTTP/1.1 ' + String(status) + ' ' + statusReason(status)];
  for (const header of CORS_HEADERS) lines.push(header);
  if (status !== 204) {
    // RFC 7230：204 响应不得携带 Content-Length。
    lines.push('Content-Type: ' + contentType);
    lines.push('Content-Length: ' + String(bytes));
  }
  lines.push('Connection: close');
  lines.push('');
  lines.push('');
  return lines.join('\r\n') + body;
}

/** SSE 流式响应头：无 Content-Length，靠连接关闭表示结束。 */
export function sseResponseHead(): string {
  const lines: string[] = ['HTTP/1.1 200 OK'];
  for (const header of CORS_HEADERS) lines.push(header);
  lines.push('Content-Type: text/event-stream; charset=utf-8');
  lines.push('Cache-Control: no-cache');
  lines.push('Connection: close');
  lines.push('');
  lines.push('');
  return lines.join('\r\n');
}

export function sseFrame(payload: string): string {
  return 'data: ' + payload + '\n\n';
}
