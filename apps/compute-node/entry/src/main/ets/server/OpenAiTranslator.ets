import { ChatMessage, MAX_IMAGE_BASE64, WireMessage } from '../protocol/ChatProtocol';
import { sseFrame, utf8Length } from './HttpProtocol';

/** 与 InferenceHost.MAX_OUTPUT / InferProfile.maxOutputTokens 一致。 */
export const OPENAI_MAX_OUTPUT_TOKENS: number = 2048;
/** 与聊天端 InferenceClient 的默认预算一致；OpenAI 网关看门狗在其上加余量。 */
export const OPENAI_DEFAULT_DEADLINE_MS: number = 170000;
/** 与 InferenceHost.MAX_PROMPT_BYTES 一致：拍平后的 developer+user 总字节上限。 */
const MAX_PROMPT_BYTES: number = 32768;
/** 单请求消息条数上限（防呆护栏）：超长历史由拍平后的 32KB 上限约束，超出部分自动裁剪。 */
const MAX_MESSAGES: number = 1024;
/** 历史被裁剪时插入的标记段，让模型知道转写从中间开始。 */
const TRIM_HISTORY_MARKER: string = '[较早的历史已省略]';
/** 协议只随请求携带一张图（见 ChatProtocol.MAX_IMAGE_BASE64 注释）。 */
const DATA_URL_PATTERN: RegExp = /^data:image\/[a-zA-Z0-9.+-]+;base64,([A-Za-z0-9+/=]+)$/;

/** 翻译层拒绝请求时抛出；status 为 HTTP 状态码。 */
export class OpenAiError extends Error {
  readonly status: number;
  readonly code: string;
  constructor(status: number, code: string, message: string) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

export interface OpenAiImageUrl {
  url?: string;
}

export interface OpenAiContentPart {
  type?: string;
  text?: string;
  image_url?: string | OpenAiImageUrl;
}

export interface OpenAiChatMessage {
  role?: string;
  content?: string | OpenAiContentPart[];
}

interface OpenAiRequestBody {
  model?: string;
  messages?: OpenAiChatMessage[];
  stream?: boolean;
  max_tokens?: number;
  max_completion_tokens?: number;
}

export interface ParsedChatRequest {
  model: string;
  streaming: boolean;
  maxOutputTokens: number;
  messages: ChatMessage[];
  image: string;
  promptText: string;
  /** 原始 OpenAI 请求的消息条数（观测用）。 */
  messageCount: number;
  /** 拍平后（含裁剪）进入集群的总字节数（观测用）。 */
  promptBytes: number;
  /** 为满足 32KB 上限被裁掉的最旧历史轮数（观测用）。 */
  trimmedTurns: number;
}

export interface OpenAiModelEntry {
  id: string;
  vision: boolean;
}

interface ChunkDelta { role?: string; content?: string; }
interface StreamChoice { index: number; delta: ChunkDelta; finish_reason: string | null; }
interface StreamChunk { id: string; object: string; created: number; model: string; choices: StreamChoice[]; }
interface CompletionMessage { role: string; content: string; }
interface CompletionChoice { index: number; message: CompletionMessage; finish_reason: string; }
interface UsageInfo { prompt_tokens: number; completion_tokens: number; total_tokens: number; }
interface CompletionBody {
  id: string; object: string; created: number; model: string;
  choices: CompletionChoice[]; usage: UsageInfo;
}
interface ErrorBody { message: string; type: string; code: string; }
interface ErrorEnvelope { error: ErrorBody; }
interface ModelEntry { id: string; object: string; owned_by: string; created: number; }
interface ModelsBody { object: string; data: ModelEntry[]; }

function badRequest(message: string): OpenAiError {
  return new OpenAiError(400, 'invalid_request_error', message);
}

function partImageUrl(part: OpenAiContentPart): string {
  const value = part.image_url;
  if (typeof value === 'string') return value;
  if (value !== null && typeof value === 'object') return value.url || '';
  return '';
}

interface ContentView { text: string; image: string; }

/**
 * 展开一条消息的 content。字符串原样返回；多模态数组拼接 text 部分，
 * 仅末条（当前轮）消息收集 image_url（协议每请求只带一张图），历史轮图片按协议丢弃。
 */
function viewContent(content: string | OpenAiContentPart[] | undefined, isFinal: boolean): ContentView {
  if (typeof content === 'string') return { text: content, image: '' };
  if (content === null || content === undefined) return { text: '', image: '' };
  if (!Array.isArray(content)) throw badRequest('content 只支持字符串或多模态数组。');
  const parts: string[] = [];
  let image = '';
  for (const part of content) {
    if (part === null || typeof part !== 'object') throw badRequest('多模态数组元素不合法。');
    const type = part.type || '';
    if (type === 'text') {
      if (typeof part.text !== 'string') throw badRequest('text 部分必须是字符串。');
      parts.push(part.text);
      continue;
    }
    if (type === 'image_url') {
      if (isFinal && image.length === 0) image = partImageUrl(part);
      continue;
    }
    if (isFinal) throw badRequest('暂不支持的多模态类型：' + type);
  }
  return { text: parts.join('\n'), image: image };
}

/**
 * 解析 OpenAI chat/completions 请求体。多轮历史拍平为协议允许的两轮
 * （developer + user 转写），保证生成结果能通过 ChatProtocol.validInference。
 */
export function parseChatRequest(body: string): ParsedChatRequest {
  let value: Object;
  try {
    value = JSON.parse(body);
  } catch (_error) {
    throw badRequest('请求体不是合法 JSON。');
  }
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw badRequest('请求体必须是 JSON 对象。');
  }
  const request = value as OpenAiRequestBody;
  if (!Array.isArray(request.messages) || request.messages.length === 0) {
    throw badRequest('messages 必须是非空数组。');
  }
  if (request.messages.length > MAX_MESSAGES) {
    throw badRequest('messages 数量过多（上限 ' + String(MAX_MESSAGES) + ' 条）。');
  }
  const systemParts: string[] = [];
  const historyParts: string[] = [];
  let promptText = '';
  let image = '';
  for (let index = 0; index < request.messages.length; index++) {
    const message = request.messages[index];
    if (message === null || typeof message !== 'object') throw badRequest('messages 元素不合法。');
    const role = message.role || '';
    const isFinal = index === request.messages.length - 1;
    if (isFinal && role !== 'user') throw badRequest('最后一条消息必须是 user。');
    const view = viewContent(message.content, isFinal);
    if (isFinal) {
      promptText = view.text;
      image = view.image;
      continue;
    }
    if (role === 'system' || role === 'developer') {
      if (view.text.trim().length > 0) systemParts.push(view.text);
      continue;
    }
    if (view.text.trim().length === 0) continue;
    if (role === 'user') historyParts.push('[用户]\n' + view.text);
    else if (role === 'assistant') historyParts.push('[助手]\n' + view.text);
    else if (role === 'tool') historyParts.push('[工具结果]\n' + view.text);
    else throw badRequest('不支持的消息角色：' + role);
  }
  if (image.length > 0) {
    const match = DATA_URL_PATTERN.exec(image);
    if (match === null) {
      if (/^https?:\/\//.test(image)) {
        throw badRequest('暂不支持 http(s) 图片链接，请使用 data URL 内联 base64。');
      }
      throw badRequest('image_url 需为 data:image/...;base64,... 形式。');
    }
    const payload = match[1] || '';
    if (payload.length > MAX_IMAGE_BASE64) {
      throw new OpenAiError(413, 'payload_too_large',
        '图片 base64 超过 ' + String(MAX_IMAGE_BASE64) + ' 字符上限（约 18KB）。');
    }
    if (!/^[A-Za-z0-9+/]+={0,2}$/.test(payload)) {
      throw badRequest('图片 base64 内容不合法。');
    }
    image = payload;
  }
  if (promptText.trim().length === 0 && image.length > 0) {
    promptText = '[图片输入]';
  }
  if (promptText.trim().length === 0 && image.length === 0) {
    throw badRequest('最后一条 user 消息内容为空。');
  }
  const systemText = systemParts.join('\n\n');
  const messages: ChatMessage[] = [];
  if (systemText.length > 0) messages.push({ role: 'developer', content: systemText });
  let trimmedTurns = 0;
  if (historyParts.length === 0) {
    // 常见形态（system + 单轮 user）不加重排标记，保住 TaskRules 定档与会话复用的既有行为。
    messages.push({ role: 'user', content: promptText });
  } else {
    // 长会话按「轮」分组：一轮 = [用户] 起、到下一个 [用户] 前，工具调用与其结果
    // 同进同退。超过 32KB 时从最旧一轮开始丢弃，system 与当前问题永不裁。
    const turns: string[] = [];
    let currentTurn: string[] = [];
    for (const part of historyParts) {
      if (part.indexOf('[用户]\n') === 0) {
        if (currentTurn.length > 0) turns.push(currentTurn.join('\n\n'));
        currentTurn = [part];
      } else {
        currentTurn.push(part);
      }
    }
    if (currentTurn.length > 0) turns.push(currentTurn.join('\n\n'));
    const count = turns.length;
    // suffixBytes[i] = turns[i..] 连接后的字节数（含轮间 '\n\n'）。
    const suffixBytes: number[] = new Array<number>(count + 1);
    suffixBytes[count] = 0;
    for (let i = count - 1; i >= 0; i--) {
      suffixBytes[i] = utf8Length(turns[i]) + (i + 1 < count ? 2 : 0) + suffixBytes[i + 1];
    }
    const systemBytes = utf8Length(systemText);
    const questionSection = '[当前问题]\n' + promptText;
    const questionBytes = utf8Length(questionSection);
    const sizeWith = (kept: number): number => {
      // 保留 turns[kept..]；kept>0 说明丢弃过历史，需加省略标记段。
      let bytes = systemBytes + questionBytes;
      if (kept > 0) bytes += utf8Length(TRIM_HISTORY_MARKER) + 2;
      if (kept < count) bytes += suffixBytes[kept] + 2;
      return bytes;
    };
    let kept = 0;
    while (kept < count && sizeWith(kept) > MAX_PROMPT_BYTES) kept++;
    if (sizeWith(kept) > MAX_PROMPT_BYTES) {
      throw new OpenAiError(413, 'payload_too_large',
        'system 与当前问题合计已超过 ' + String(MAX_PROMPT_BYTES) + ' 字节上限，请缩短后重试。');
    }
    const sections: string[] = [];
    if (kept > 0) sections.push(TRIM_HISTORY_MARKER);
    for (let i = kept; i < count; i++) sections.push(turns[i]);
    sections.push(questionSection);
    messages.push({ role: 'user', content: sections.join('\n\n') });
    trimmedTurns = kept;
  }
  let totalBytes = 0;
  for (const message of messages) {
    totalBytes += utf8Length(message.content);
  }
  if (totalBytes > MAX_PROMPT_BYTES) {
    throw new OpenAiError(413, 'payload_too_large',
      '拍平后的输入超过 ' + String(MAX_PROMPT_BYTES) + ' 字节上限。');
  }
  let maxOutputTokens = OPENAI_MAX_OUTPUT_TOKENS;
  const rawTokens = request.max_completion_tokens !== undefined ? request.max_completion_tokens : request.max_tokens;
  if (typeof rawTokens === 'number' && Number.isFinite(rawTokens) && rawTokens > 0) {
    maxOutputTokens = Math.min(OPENAI_MAX_OUTPUT_TOKENS, Math.max(1, Math.round(rawTokens)));
  }
  const model = typeof request.model === 'string' && request.model.trim().length > 0 ?
    request.model.trim().substring(0, 64) : 'default';
  return {
    model: model,
    streaming: request.stream === true,
    maxOutputTokens: maxOutputTokens,
    messages: messages,
    image: image,
    promptText: promptText,
    messageCount: request.messages.length,
    promptBytes: totalBytes,
    trimmedTurns: trimmedTurns
  };
}

export function buildInferRequest(parsed: ParsedChatRequest, requestId: string, deadlineBudgetMs: number): WireMessage {
  const request: WireMessage = {
    type: 'infer.request', version: 2, requestId: requestId,
    messages: parsed.messages, maxOutputTokens: parsed.maxOutputTokens,
    deadlineBudgetMs: deadlineBudgetMs, label: 'OpenAI 请求', origin: '外部代理'
  };
  if (parsed.image.length > 0) request.image = parsed.image;
  return request;
}

/** model 字段仅作元数据参考（能力路由由「是否带图」决定，见 InferenceRelay.route）。 */
export function modelNeeds(model: string): string[] {
  const lower = model.toLowerCase();
  return lower.indexOf('vl') >= 0 || lower.indexOf('vision') >= 0 ? ['vision'] : ['text'];
}

export function streamFirstChunk(id: string, model: string, created: number): string {
  const delta: ChunkDelta = { role: 'assistant', content: '' };
  const choice: StreamChoice = { index: 0, delta: delta, finish_reason: null };
  const chunk: StreamChunk = { id: id, object: 'chat.completion.chunk', created: created, model: model,
    choices: [choice] };
  return sseFrame(JSON.stringify(chunk));
}

export function streamDeltaChunk(id: string, model: string, created: number, text: string): string {
  const delta: ChunkDelta = { content: text };
  const choice: StreamChoice = { index: 0, delta: delta, finish_reason: null };
  const chunk: StreamChunk = { id: id, object: 'chat.completion.chunk', created: created, model: model,
    choices: [choice] };
  return sseFrame(JSON.stringify(chunk));
}

export function streamFinishChunk(id: string, model: string, created: number, finishReason: string): string {
  const delta: ChunkDelta = {};
  const reason = finishReason === 'length' ? 'length' : 'stop';
  const choice: StreamChoice = { index: 0, delta: delta, finish_reason: reason };
  const chunk: StreamChunk = { id: id, object: 'chat.completion.chunk', created: created, model: model,
    choices: [choice] };
  return sseFrame(JSON.stringify(chunk));
}

export const STREAM_DONE: string = 'data: [DONE]\n\n';

/** SSE 已开始后出错：HTTP 状态码发不出去，按 OpenAI 惯例以错误帧收尾。 */
export function streamErrorFrame(status: number, code: string, message: string): string {
  return sseFrame(errorResponse(status, code, message));
}

export function completionResponse(id: string, model: string, created: number, text: string,
  finishReason: string, promptTokens?: number, completionTokens?: number): string {
  const prompt = promptTokens === undefined ? 0 : Math.max(0, Math.round(promptTokens));
  const completion = completionTokens === undefined ? 0 : Math.max(0, Math.round(completionTokens));
  const message: CompletionMessage = { role: 'assistant', content: text };
  const choice: CompletionChoice = { index: 0, message: message,
    finish_reason: finishReason === 'length' ? 'length' : 'stop' };
  const usage: UsageInfo = { prompt_tokens: prompt, completion_tokens: completion,
    total_tokens: prompt + completion };
  const body: CompletionBody = { id: id, object: 'chat.completion', created: created, model: model,
    choices: [choice], usage: usage };
  return JSON.stringify(body);
}

export function errorTypeForStatus(status: number): string {
  if (status === 429) return 'rate_limit_error';
  if (status >= 500) return 'api_error';
  return 'invalid_request_error';
}

export function errorResponse(status: number, code: string, message: string): string {
  const body: ErrorBody = { message: message, type: errorTypeForStatus(status), code: code };
  const envelope: ErrorEnvelope = { error: body };
  return JSON.stringify(envelope);
}

/** infer.error 错误码 → HTTP 状态码。BUSY 意为「有能力的节点都忙」，按限流语义回 429。 */
export function httpStatusForWireCode(code: string): number {
  if (code === 'BUSY') return 429;
  if (code === 'MODEL_UNAVAILABLE') return 503;
  if (code === 'PAYLOAD_TOO_LARGE') return 413;
  if (code === 'DUPLICATE_REQUEST') return 409;
  if (code === 'MODEL_EXECUTION_FAILED') return 500;
  if (code === 'WORKER_LOST') return 502;
  if (code === 'CANCELLED') return 499;
  return 500;
}

export function modelsResponse(entries: OpenAiModelEntry[], created: number): string {
  const data: ModelEntry[] = [];
  for (const entry of entries) {
    const item: ModelEntry = { id: entry.id, object: 'model', owned_by: 'minipc-hub', created: created };
    data.push(item);
  }
  const body: ModelsBody = { object: 'list', data: data };
  return JSON.stringify(body);
}
