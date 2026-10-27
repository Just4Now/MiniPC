// node OpenAiTranslator.test.cjs [path/to/typescript/lib/typescript.js]
// OpenAI ↔ infer.wire 翻译层：请求拍平/图片/限额、生成的 infer.request 过真实
// ChatProtocol 校验，SSE 流喂给 agent-client 真实解析器验证可提取全文。
const assert = require('node:assert/strict');
const vm = require('node:vm');
const path = require('node:path');
const { transpile } = require('../../../../../../../tests/ets-harness.cjs');
function load(file, requires = {}) {
  const mod = { exports: {} };
  const context = { module: mod, exports: mod.exports, Error, Map, Math, Number, String, Promise, JSON, Array,
    RegExp, Uint8Array, require: (name) => requires[name] || {} };
  vm.runInNewContext(transpile(file), context);
  return mod.exports;
}
const utilMock = {
  TextEncoder: class { encodeInto(text) { return new Uint8Array(Buffer.from(text, 'utf8')); } },
  TextDecoder: { create: () => ({ decodeToString: (bytes) => Buffer.from(bytes.buffer, bytes.byteOffset, bytes.byteLength).toString('utf8') }) }
};
const dir = __dirname;
const chat = load(path.join(dir, '../protocol/ChatProtocol.ets'), { '@kit.ArkTS': { util: utilMock } });
const http = load(path.join(dir, './HttpProtocol.ets'), { '@kit.ArkTS': { util: utilMock } });
const translator = load(path.join(dir, './OpenAiTranslator.ets'), {
  '@kit.ArkTS': { util: utilMock }, '../protocol/ChatProtocol': chat, './HttpProtocol': http
});
const clientParser = load(path.resolve(dir, '../../../../../../agent-client/agent-core/src/main/ets/model/TextCompletionResponse.ets'));

const {
  parseChatRequest, buildInferRequest, modelNeeds, OpenAiError,
  streamFirstChunk, streamDeltaChunk, streamFinishChunk, STREAM_DONE, streamErrorFrame,
  completionResponse, errorResponse, httpStatusForWireCode, modelsResponse, OPENAI_MAX_OUTPUT_TOKENS
} = translator;

const tests = [];
const test = (name, fn) => tests.push([name, fn]);
const json = (value) => JSON.parse(JSON.stringify(value));
const parse = (body) => parseChatRequest(JSON.stringify(body));
const rejects = (body, status) => {
  try { parse(body); } catch (error) {
    assert.ok(error instanceof OpenAiError, 'throws OpenAiError');
    assert.equal(error.status, status, 'status ' + status + ', got ' + error.status + ': ' + error.message);
    return error;
  }
  throw new Error('expected rejection');
};
// encodeMessage 在出口统一盖 protocol 章（'nearby-chat-v1' 非导出常量），
// 校验前同样补上，等价于真实链路 channel.send → encodeMessage。
const stamp = (wire) => { wire.protocol = 'nearby-chat-v1'; return wire; };
const validWire = (parsed) => chat.validMessage(stamp(buildInferRequest(parsed, 'openai-test-1', 170000)));

test('single-turn system+user passes through unmodified and survives the real wire validator', () => {
  const parsed = parse({ model: 'qwen', messages: [
    { role: 'system', content: '你是一个简洁的助手' },
    { role: 'user', content: '用一句话介绍自己' }] });
  assert.deepEqual(json(parsed.messages), [
    { role: 'developer', content: '你是一个简洁的助手' },
    { role: 'user', content: '用一句话介绍自己' }]);
  assert.equal(parsed.image, '');
  assert.equal(parsed.streaming, false);
  assert.equal(parsed.maxOutputTokens, OPENAI_MAX_OUTPUT_TOKENS);
  assert.equal(parsed.messageCount, 2);
  assert.equal(parsed.trimmedTurns, 0);
  assert.equal(parsed.promptBytes, Buffer.byteLength('你是一个简洁的助手用一句话介绍自己', 'utf8'));
  assert.equal(validWire(parsed), true, JSON.stringify(buildInferRequest(parsed, 't', 170000)));
});

test('multi-turn history flattens into developer + transcript-style user turn', () => {
  const parsed = parse({ messages: [
    { role: 'system', content: '规则一' },
    { role: 'user', content: '第一问' },
    { role: 'assistant', content: '第一答' },
    { role: 'user', content: '第二问' }] });
  assert.deepEqual(json(parsed.messages), [
    { role: 'developer', content: '规则一' },
    { role: 'user', content: '[用户]\n第一问\n\n[助手]\n第一答\n\n[当前问题]\n第二问' }]);
  assert.equal(validWire(parsed), true);
});

test('tool results become transcript blocks; multiple system turns merge', () => {
  const parsed = parse({ messages: [
    { role: 'system', content: 'A' }, { role: 'system', content: 'B' },
    { role: 'user', content: '问题' },
    { role: 'assistant', content: '调用工具' },
    { role: 'tool', content: '工具输出' },
    { role: 'user', content: '继续' }] });
  assert.equal(parsed.messages[0].content, 'A\n\nB');
  assert.ok(parsed.messages[1].content.includes('[工具结果]\n工具输出'));
  assert.ok(parsed.messages[1].content.endsWith('[当前问题]\n继续'));
  assert.equal(parsed.messages.length, 2);
  assert.equal(validWire(parsed), true);
});

test('multimodal array: text parts join, final image_url strips the data URL prefix', () => {
  const base64 = 'AAECAwQFBgcICQ==';
  const parsed = parse({ messages: [
    { role: 'user', content: [
      { type: 'text', text: '图中是什么' },
      { type: 'image_url', image_url: { url: 'data:image/jpeg;base64,' + base64 } }] }] });
  assert.equal(parsed.image, base64);
  assert.equal(parsed.promptText, '图中是什么');
  const wire = buildInferRequest(parsed, 'openai-img-1', 170000);
  assert.equal(wire.image, base64);
  assert.equal(chat.validMessage(stamp(wire)), true);
});

test('image-only prompt gets a placeholder so the user turn stays non-empty', () => {
  const parsed = parse({ messages: [
    { role: 'user', content: [{ type: 'image_url', image_url: { url: 'data:image/png;base64,AAAB' } }] }] });
  assert.equal(parsed.promptText, '[图片输入]');
  assert.equal(validWire(parsed), true);
});

test('image in a history turn is dropped; only the final message carries one', () => {
  const parsed = parse({ messages: [
    { role: 'user', content: [{ type: 'image_url', image_url: { url: 'data:image/png;base64,AAAA' } }] },
    { role: 'assistant', content: '旧图说明' },
    { role: 'user', content: '再见' }] });
  assert.equal(parsed.image, '');
  assert.equal(parsed.messages.length, 1, 'history-only image must not force a vision request');
});

test('oversized image base64 rejects with 413', () => {
  rejects({ messages: [{ role: 'user', content: [
    { type: 'image_url', image_url: { url: 'data:image/jpeg;base64,' + 'A'.repeat(24001) } }] }] }, 413);
});

test('invalid base64 payload rejects with 400', () => {
  rejects({ messages: [{ role: 'user', content: [
    { type: 'image_url', image_url: { url: 'data:image/jpeg;base64,AA!A' } }] }] }, 400);
});

test('remote http image URL rejects with a clear hint', () => {
  const error = rejects({ messages: [{ role: 'user', content: [
    { type: 'image_url', image_url: { url: 'https://example.com/cat.png' } }] }] }, 400);
  assert.ok(error.message.includes('data URL'));
});

test('max_tokens and max_completion_tokens clamp to 1..2048', () => {
  assert.equal(parse({ messages: [{ role: 'user', content: 'q' }], max_tokens: 999999 }).maxOutputTokens, 2048);
  assert.equal(parse({ messages: [{ role: 'user', content: 'q' }], max_tokens: 100 }).maxOutputTokens, 100);
  assert.equal(parse({ messages: [{ role: 'user', content: 'q' }], max_completion_tokens: 1 }).maxOutputTokens, 1);
  assert.equal(parse({ messages: [{ role: 'user', content: 'q' }], max_tokens: 0 }).maxOutputTokens, 2048);
  assert.equal(parse({ messages: [{ role: 'user', content: 'q' }], max_tokens: '32' }).maxOutputTokens, 2048);
});

test('model name is echoed, never rejected; vl/vision hint feeds /v1/models metadata only', () => {
  assert.equal(parse({ model: '完全随意的名字', messages: [{ role: 'user', content: 'q' }] }).model, '完全随意的名字');
  assert.equal(parse({ messages: [{ role: 'user', content: 'q' }] }).model, 'default');
  assert.deepEqual(modelNeeds('qwen2.5-vl-7b').join(','), 'vision');
  assert.deepEqual(modelNeeds('Qwen-Vision').join(','), 'vision');
  assert.deepEqual(modelNeeds('text-model').join(','), 'text');
});

test('malformed bodies reject with 400', () => {
  try { parseChatRequest('not json'); assert.fail('no throw'); } catch (e) { assert.equal(e.status, 400); }
  rejects({}, 400);
  rejects({ messages: [] }, 400);
  rejects({ messages: [{ role: 'user', content: 'q' }, { role: 'assistant', content: 'a' }] }, 400);
  rejects({ messages: [{ role: 'user', content: 'q' }, { role: 'user', content: '' }] }, 400);
  rejects({ messages: [{ role: 'wizard', content: 'q' }, { role: 'user', content: 'q' }] }, 400);
  rejects({ messages: [{ role: 'user', content: [{ type: 'audio', audio: 'x' }] }] }, 400);
});

test('oversized history trims oldest turns; untrimmable system+question still 413s', () => {
  // 40 轮历史（约 58KB）超过 32KB 线协议上限：自动裁最旧轮而不是拒绝。
  const messages = [{ role: 'system', content: '你是编程助手' }];
  for (let i = 0; i < 40; i++) {
    const tag = String(i).padStart(2, '0');
    messages.push({ role: 'user', content: `turn${tag}q ` + 'x'.repeat(700) });
    messages.push({ role: 'assistant', content: `turn${tag}a ` + 'y'.repeat(700) });
  }
  messages.push({ role: 'user', content: '最终的问题' });
  const parsed = parse({ model: 'qwen', messages });
  assert.equal(parsed.messages[0].role, 'developer', 'system is never trimmed');
  const user = parsed.messages[parsed.messages.length - 1];
  assert.ok(user.content.includes('[较早的历史已省略]'), 'trim marker present');
  assert.ok(!user.content.includes('turn00q'), 'oldest turn dropped');
  assert.ok(user.content.includes('turn39a'), 'newest turn survives');
  assert.ok(user.content.includes('[当前问题]\n最终的问题'));
  const totalBytes = Buffer.byteLength(parsed.messages[0].content, 'utf8') +
    Buffer.byteLength(user.content, 'utf8');
  assert.ok(totalBytes <= 32768, 'trimmed prompt fits the wire cap, got ' + totalBytes);
  assert.equal(validWire(parsed), true, 'trimmed request passes the real wire validator');
  // 观测字段：原始条数 / 拍平字节（与实测一致）/ 裁掉的轮数（供网关日志打印）。
  assert.equal(parsed.messageCount, 82);
  assert.equal(parsed.promptBytes, totalBytes);
  assert.ok(parsed.trimmedTurns > 0, 'oldest turns reported as trimmed');
  assert.ok(parsed.trimmedTurns < 40, 'newest turns kept');
  // 裁无可裁：单轮 system+问题本身超限（historyParts 为空，走兜底检查）。
  rejects({ messages: [
    { role: 'system', content: '很长的系统提示'.repeat(1500) },
    { role: 'user', content: '很长的当前问题'.repeat(1500) }] }, 413);
  // 裁无可裁：有历史但全裁掉后 system+问题仍超限。
  rejects({ messages: [
    { role: 'user', content: '短历史' },
    { role: 'assistant', content: '短回答' },
    { role: 'system', content: '很长的系统提示'.repeat(1500) },
    { role: 'user', content: '很长的当前问题'.repeat(1500) }] }, 413);
});

test('message count guard allows long tool loops', () => {
  const messages = [];
  for (let i = 0; i < 300; i++) {
    messages.push({ role: i % 2 === 0 ? 'user' : 'assistant', content: 'ok' + i });
  }
  messages.push({ role: 'user', content: '最终问题' });
  const parsed = parse({ model: 'qwen', messages });
  assert.ok(parsed.messages[parsed.messages.length - 1].content.includes('最终问题'));
});

test('buildInferRequest labels the external agent and enforces the wire budget', () => {
  const parsed = parse({ messages: [{ role: 'user', content: 'q' }] });
  const wire = buildInferRequest(parsed, 'openai-x1', 170000);
  assert.equal(wire.type, 'infer.request');
  assert.equal(wire.label, 'OpenAI 请求');
  assert.equal(wire.origin, '外部代理');
  assert.equal(wire.deadlineBudgetMs, 170000);
  assert.equal(wire.image, undefined);
  assert.equal(chat.validMessage(stamp(wire)), true);
});

test('wire error codes map to OpenAI-idiomatic HTTP statuses', () => {
  assert.equal(httpStatusForWireCode('BUSY'), 429);
  assert.equal(httpStatusForWireCode('MODEL_UNAVAILABLE'), 503);
  assert.equal(httpStatusForWireCode('PAYLOAD_TOO_LARGE'), 413);
  assert.equal(httpStatusForWireCode('DUPLICATE_REQUEST'), 409);
  assert.equal(httpStatusForWireCode('MODEL_EXECUTION_FAILED'), 500);
  assert.equal(httpStatusForWireCode('WORKER_LOST'), 502);
  assert.equal(httpStatusForWireCode('CANCELLED'), 499);
  assert.equal(httpStatusForWireCode('SOMETHING_NEW'), 500);
  assert.equal(JSON.parse(errorResponse(429, 'BUSY', 'busy')).error.type, 'rate_limit_error');
  assert.equal(JSON.parse(errorResponse(503, 'MODEL_UNAVAILABLE', 'x')).error.type, 'api_error');
});

test('non-streaming completion JSON parses with the real client parser', () => {
  const body = completionResponse('chatcmpl-1', 'qwen', 1700000000, '你好，我是集群助手。', 'stop', 12, 34);
  assert.equal(clientParser.parseTextCompletion(body), '你好，我是集群助手。');
  const parsed = JSON.parse(body);
  assert.equal(parsed.object, 'chat.completion');
  assert.equal(parsed.usage.total_tokens, 46);
  assert.equal(parsed.choices[0].finish_reason, 'stop');
});

test('empty completion content still parses to a non-empty transcript answer', () => {
  const body = completionResponse('chatcmpl-2', 'qwen', 1700000000, ' ', 'stop', 1, 1);
  try { clientParser.parseTextCompletion(body); assert.fail('client rejects blank content'); } catch (e) {
    assert.ok(String(e.message).includes('no message content'));
  }
});

test('SSE chunks concatenated feed the real client parser end to end', () => {
  let stream = '';
  stream += streamFirstChunk('chatcmpl-s', 'qwen', 1700000000);
  for (const piece of ['你好', '，', '集群']) stream += streamDeltaChunk('chatcmpl-s', 'qwen', 1700000000, piece);
  stream += streamFinishChunk('chatcmpl-s', 'qwen', 1700000000, 'stop');
  stream += STREAM_DONE;
  assert.equal(stream.startsWith('data: '), true);
  assert.ok(stream.endsWith('\n\n'));
  assert.equal(clientParser.parseTextCompletion(stream), '你好，集群');
});

test('finish_reason length is preserved for OpenAI semantics', () => {
  const stream = streamFirstChunk('c1', 'm', 1) + streamFinishChunk('c1', 'm', 1, 'length') + STREAM_DONE;
  try { clientParser.parseTextCompletion(stream); assert.fail('agent-client rejects length'); } catch (e) {
    assert.ok(String(e.message).includes('finish_reason=length'));
  }
  const body = completionResponse('c2', 'm', 1, '部分输出', 'length', 1, 2);
  assert.equal(JSON.parse(body).choices[0].finish_reason, 'length');
});

test('mid-stream error frame surfaces as a provider error to the client parser', () => {
  const stream = streamFirstChunk('c3', 'm', 1) +
    streamDeltaChunk('c3', 'm', 1, '部分') +
    streamErrorFrame(500, 'MODEL_EXECUTION_FAILED', '推理失败') +
    STREAM_DONE;
  try { clientParser.parseTextCompletion(stream); assert.fail('expected provider error'); } catch (e) {
    assert.ok(String(e.message).includes('provider error'));
    assert.ok(String(e.message).includes('MODEL_EXECUTION_FAILED'));
  }
});

test('modelsResponse lists cluster models', () => {
  const body = JSON.parse(modelsResponse([
    { id: 'qwen-2.5-gepu', vision: false }, { id: 'qwen2.5-vl', vision: true }], 1700000000));
  assert.equal(body.object, 'list');
  assert.deepEqual(body.data.map((m) => m.id), ['qwen-2.5-gepu', 'qwen2.5-vl']);
  assert.equal(body.data[0].object, 'model');
});

(async () => {
  let pass = 0;
  for (const [name, fn] of tests) {
    try { await fn(); pass++; console.log('PASS ' + name); } catch (error) { console.error('FAIL ' + name, error); process.exitCode = 1; }
  }
  console.log(pass + '/' + tests.length + ' openai translator tests passed');
})();
