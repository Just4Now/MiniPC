// node OpenAiServer.test.cjs [path/to/typescript/lib/typescript.js]
// OpenAI 网关生命周期：假传输 + 假应答器 + 虚拟时钟验证请求往返、SSE 收尾、
// BUSY→429、断连取消、看门狗 504、epoch 分配与幂等启停。
const assert = require('node:assert/strict');
const vm = require('node:vm');
const path = require('node:path');
const { transpile } = require('../../../../../../../tests/ets-harness.cjs');
function load(file, requires = {}, extraGlobals = {}) {
  const mod = { exports: {} };
  const context = Object.assign({ module: mod, exports: mod.exports, Error, Map, Math, Number, String, Promise,
    JSON, Array, RegExp, Uint8Array, require: (name) => requires[name] || {} }, extraGlobals);
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

// 虚拟时钟：注入 sandbox 的 setTimeout/clearTimeout。
function clock() {
  let now = 0;
  let timers = [];
  let nextId = 1;
  return {
    setTimeout: (fn, delay) => { const id = nextId++; timers.push({ id, fn, at: now + delay }); return id; },
    clearTimeout: (id) => { timers = timers.filter((t) => t.id !== id); },
    advance: (ms) => {
      now += ms;
      const due = timers.filter((t) => t.at <= now).sort((a, b) => a.at - b.at);
      timers = timers.filter((t) => t.at > now);
      for (const t of due) t.fn();
    },
    pending: () => timers.length
  };
}

// 假传输：记录 start/stop，handler 由测试直接驱动。
function fakeTransport() {
  const state = { started: [], stopped: 0, handler: null };
  return {
    state,
    async start(port, handler) { state.started.push(port); state.handler = handler; },
    async stop() { state.stopped++; state.handler = null; }
  };
}

// 假应答器：镜像 ServerConnection 语义（close 后写返回 false、onClose 立即回调）。
function fakeResponder() {
  const state = { json: [], sseOpened: 0, frames: [], closed: 0, closeCallbacks: [] };
  return {
    state,
    get closed() { return state.closed > 0; },
    sendJson(status, body) { state.json.push([status, body]); this.close(); },
    openSse() { if (this.closed) return false; state.sseOpened++; return true; },
    sendFrame(frame) { if (this.closed) return Promise.resolve(false); state.frames.push(frame); return Promise.resolve(true); },
    onClose(cb) { if (this.closed) { cb(); return; } state.closeCallbacks.push(cb); },
    close() { if (this.closed) return; state.closed++; for (const cb of state.closeCallbacks.splice(0)) cb(); }
  };
}

// vm 模块只加载一次；sandbox 的 setTimeout 代理到当前 harness 的虚拟时钟。
let activeClock = null;
const { OpenAiServer, HTTP_EPOCH_BASE } = load(path.join(dir, './OpenAiServer.ets'), {
  '@kit.PerformanceAnalysisKit': { hilog: { info() {}, warn() {}, error() {} } },
  './HttpProtocol': http,
  './OpenAiTranslator': translator
}, {
  setTimeout: (fn, delay) => activeClock.setTimeout(fn, delay),
  clearTimeout: (id) => activeClock.clearTimeout(id)
});

const tests = [];
const test = (name, fn) => tests.push([name, fn]);
const tick = () => new Promise((resolve) => setImmediate(resolve));

/** 组装一套运行中的网关：submit/drop 记录到数组，models 固定，地址固定。 */
function harness(options = {}) {
  const clk = clock();
  activeClock = clk;
  // Date.now 由 vm 内的真实 Date 提供；看门狗只依赖注入的 setTimeout。
  const transport = fakeTransport();
  const submitted = [];
  const dropped = [];
  const requested = [];
  const traffic = [];
  const server = new OpenAiServer({
    port: 8080,
    transport: () => transport,
    models: () => [{ id: 'qwen-2.5-gepu', vision: false }],
    resolveAddress: async () => '192.168.1.5',
    submit: (message, epoch) => submitted.push([message, epoch]),
    drop: (epoch) => dropped.push(epoch),
    onRequest: (epoch, id, prompt) => requested.push([epoch, id, prompt]),
    trafficSink: (line) => traffic.push(line),
    // 默认放开并发，让限流只在专属测试里生效（生产 Index 传 ready 节点数）。
    capacity: () => (options.capacity !== undefined ? options.capacity : 8),
    deadlineBudgetMs: options.deadlineMs !== undefined ? options.deadlineMs : 170000
  });
  return { server, transport, submitted, dropped, requested, traffic, clk };
}
const httpGet = (path) => ({ method: 'GET', path, headers: new Map(), body: '' });
const httpPost = (path, body) => ({ method: 'POST', path, headers: new Map(), body: JSON.stringify(body) });
const chatBody = (extra = {}) => Object.assign({ model: 'qwen', messages: [{ role: 'user', content: '你好' }] }, extra);

test('sync(true) starts the transport once and exposes the LAN endpoint', async () => {
  const h = harness();
  await h.server.sync(true);
  await h.server.sync(true);
  assert.deepEqual(h.transport.state.started, [8080]);
  assert.equal(h.server.isActive(), true);
  assert.equal(h.server.endpoint(), 'http://192.168.1.5:8080/v1');
});

test('sync(false) is idempotent and stops the transport', async () => {
  const h = harness();
  await h.server.sync(true);
  await h.server.sync(false);
  await h.server.sync(false);
  assert.equal(h.transport.state.stopped, 1);
  assert.equal(h.server.isActive(), false);
  assert.equal(h.server.endpoint(), '');
});

test('GET /v1/models lists cluster models', async () => {
  const h = harness();
  await h.server.sync(true);
  const responder = fakeResponder();
  h.transport.state.handler(httpGet('/v1/models'), responder);
  assert.equal(responder.state.json.length, 1);
  const [status, body] = responder.state.json[0];
  assert.equal(status, 200);
  assert.deepEqual(JSON.parse(body).data.map((m) => m.id), ['qwen-2.5-gepu']);
});

test('unknown paths 404 and wrong methods 405', async () => {
  const h = harness();
  await h.server.sync(true);
  for (const [request, status] of [
    [httpGet('/v1/other'), 404],
    [httpGet('/'), 404],
    [httpGet('/v1/chat/completions'), 405],
    [httpPost('/v1/models', {}), 405]]) {
    const responder = fakeResponder();
    h.transport.state.handler(request, responder);
    assert.equal(responder.state.json[0][0], status, request.method + ' ' + request.path);
  }
});

test('non-streaming round trip aggregates deltas into one completion JSON', async () => {
  const h = harness();
  await h.server.sync(true);
  const responder = fakeResponder();
  h.transport.state.handler(httpPost('/v1/chat/completions', chatBody()), responder);
  assert.equal(h.submitted.length, 1, 'request entered the routing layer');
  const [message, epoch] = h.submitted[0];
  assert.equal(message.type, 'infer.request');
  assert.equal(message.messages[0].content, '你好');
  assert.equal(message.label, 'OpenAI 请求');
  assert.equal(message.origin, '外部代理');
  assert.ok(epoch >= HTTP_EPOCH_BASE, 'synthetic epoch');
  assert.equal(h.requested.length, 1, 'taskLinks hook fired');
  await h.server.deliver({ type: 'infer.delta', version: 2, requestId: message.requestId, seq: 1, text: '你好' }, epoch);
  await h.server.deliver({ type: 'infer.delta', version: 2, requestId: message.requestId, seq: 2, text: '，集群' }, epoch);
  assert.equal(responder.state.json.length, 0, 'nothing sent before done');
  assert.equal(responder.state.sseOpened, 0, 'no SSE for non-streaming');
  await h.server.deliver({ type: 'infer.done', version: 2, requestId: message.requestId, lastSeq: 2,
    finishReason: 'stop', metrics: { promptTokens: 8, completionTokens: 6 } }, epoch);
  assert.equal(responder.state.json.length, 1);
  const [status, body] = responder.state.json[0];
  assert.equal(status, 200);
  const parsed = JSON.parse(body);
  assert.equal(parsed.choices[0].message.content, '你好，集群');
  assert.equal(parsed.choices[0].finish_reason, 'stop');
  assert.deepEqual([parsed.usage.prompt_tokens, parsed.usage.completion_tokens], [8, 6]);
  assert.equal(responder.state.closed, 1, 'connection closed after reply');
  assert.equal(h.dropped.length, 0, 'no cancel on clean finish');
  assert.equal(h.clk.pending(), 0, 'watchdog cleared');
});

test('streaming round trip emits role chunk, deltas, finish and [DONE]', async () => {
  const h = harness();
  await h.server.sync(true);
  const responder = fakeResponder();
  h.transport.state.handler(httpPost('/v1/chat/completions', chatBody({ stream: true })), responder);
  const [message, epoch] = h.submitted[0];
  await h.server.deliver({ type: 'infer.accepted', version: 2, requestId: message.requestId, state: 'queued' }, epoch);
  await h.server.deliver({ type: 'infer.status', version: 2, requestId: message.requestId, state: 'generating' }, epoch);
  assert.equal(responder.state.sseOpened, 0, 'SSE stays closed before the first delta so errors can use status codes');
  await h.server.deliver({ type: 'infer.delta', version: 2, requestId: message.requestId, seq: 1, text: '第一' }, epoch);
  assert.equal(responder.state.sseOpened, 1);
  await h.server.deliver({ type: 'infer.delta', version: 2, requestId: message.requestId, seq: 2, text: '段' }, epoch);
  await h.server.deliver({ type: 'infer.done', version: 2, requestId: message.requestId, lastSeq: 2,
    finishReason: 'stop' }, epoch);
  assert.ok(responder.state.frames.length >= 4, 'first + deltas + finish + DONE');
  const stream = responder.state.frames.join('');
  assert.ok(stream.endsWith('data: [DONE]\n\n'), 'stream ends with [DONE]');
  const first = JSON.parse(responder.state.frames[0].replace(/^data: /, ''));
  assert.equal(first.choices[0].delta.role, 'assistant');
  const finish = JSON.parse(responder.state.frames[responder.state.frames.length - 2].replace(/^data: /, ''));
  assert.equal(finish.choices[0].finish_reason, 'stop');
  assert.equal(responder.state.closed, 1);
  assert.equal(h.dropped.length, 0);
});

test('traffic sink records full request body, flattened prompt and completion reply as JSONL', async () => {
  const h = harness();
  await h.server.sync(true);
  const responder = fakeResponder();
  const body = chatBody({ messages: [{ role: 'system', content: '规则' }, { role: 'user', content: '写诗' }] });
  h.transport.state.handler(httpPost('/v1/chat/completions', body), responder);
  const [message, epoch] = h.submitted[0];
  await h.server.deliver({ type: 'infer.delta', version: 2, requestId: message.requestId, seq: 1, text: '全文' }, epoch);
  await h.server.deliver({ type: 'infer.done', version: 2, requestId: message.requestId, lastSeq: 1,
    finishReason: 'stop', metrics: { promptTokens: 3, completionTokens: 2 } }, epoch);
  assert.equal(h.traffic.length, 3, 'request + prompt + reply lines');
  const [reqLine, promptLine, replyLine] = h.traffic.map((line) => JSON.parse(line));
  assert.equal(reqLine.kind, 'request');
  assert.equal(reqLine.method, 'POST');
  assert.equal(reqLine.path, '/v1/chat/completions');
  assert.equal(reqLine.bytes, Buffer.byteLength(JSON.stringify(body), 'utf8'));
  assert.equal(reqLine.body, JSON.stringify(body), 'raw request body preserved verbatim');
  assert.ok(reqLine.id.indexOf('openai-') === 0);
  assert.ok(reqLine.epoch >= HTTP_EPOCH_BASE);
  assert.ok(reqLine.ts.length > 0);
  // prompt 行 = 模型实际收到的拍平输入（含观测指标），与 request 行同 id/epoch。
  assert.equal(promptLine.kind, 'prompt');
  assert.equal(promptLine.id, reqLine.id);
  assert.equal(promptLine.model, 'qwen');
  assert.equal(promptLine.stream, false);
  assert.equal(promptLine.maxOutputTokens, 2048);
  assert.equal(promptLine.messageCount, 2);
  assert.equal(promptLine.promptBytes, Buffer.byteLength('规则写诗', 'utf8'));
  assert.equal(promptLine.trimmedTurns, 0);
  assert.equal(promptLine.image, false);
  assert.deepEqual(promptLine.messages, [
    { role: 'developer', content: '规则' }, { role: 'user', content: '写诗' }]);
  assert.equal(replyLine.kind, 'reply');
  assert.equal(replyLine.id, reqLine.id, 'request and reply pair by id');
  assert.equal(replyLine.epoch, reqLine.epoch);
  assert.equal(replyLine.outcome, 'done');
  assert.equal(replyLine.status, 200);
  assert.equal(replyLine.finish, 'stop');
  assert.equal(replyLine.text, '全文', 'full reply text preserved');
  assert.deepEqual([replyLine.promptTokens, replyLine.completionTokens], [3, 2]);
});

test('traffic sink pairs rejected (400/429) and aborted requests with their request line', async () => {
  const h = harness({ capacity: 1 });
  await h.server.sync(true);
  // 400：空 messages，被拒请求也要有 request + reply 配对。
  h.transport.state.handler(httpPost('/v1/chat/completions', { messages: [] }), fakeResponder());
  const [req400, reply400] = h.traffic.map((line) => JSON.parse(line));
  assert.equal(reply400.id, req400.id, 'rejected request still pairs by id');
  assert.equal(reply400.outcome, 'rejected');
  assert.equal(reply400.status, 400);
  assert.ok(reply400.message.length > 0);
  // 占满唯一名额，第二个请求 → 429。
  const busy = fakeResponder();
  h.transport.state.handler(httpPost('/v1/chat/completions', chatBody()), busy);
  assert.equal(h.submitted.length, 1);
  h.transport.state.handler(httpPost('/v1/chat/completions', chatBody({ messages: [{ role: 'user', content: '二' }] })),
    fakeResponder());
  const lines = h.traffic.map((line) => JSON.parse(line));
  const reply429 = lines[lines.length - 1];
  assert.equal(reply429.outcome, 'rejected');
  assert.equal(reply429.status, 429);
  assert.equal(reply429.id, lines[lines.length - 2].id, '429 pairs with its request line');
  // 客户端断开在途请求 → aborted，带已收到的部分输出。
  await h.server.deliver({ type: 'infer.delta', version: 2, requestId: h.submitted[0][0].requestId, seq: 1, text: '部分' },
    h.submitted[0][1]);
  busy.close();
  const afterAbort = h.traffic.map((line) => JSON.parse(line));
  const aborted = afterAbort.filter((l) => l.outcome === 'aborted');
  assert.equal(aborted.length, 1);
  assert.equal(aborted[0].text, '部分');
  const paired = afterAbort.filter((l) => l.kind === 'request' && l.id === aborted[0].id);
  assert.equal(paired.length, 1);
  assert.ok(paired[0].body.includes('你好'), 'aborted entry pairs with the in-flight request');
});

test('zero-delta stream completion still opens SSE and closes cleanly', async () => {
  const h = harness();
  await h.server.sync(true);
  const responder = fakeResponder();
  h.transport.state.handler(httpPost('/v1/chat/completions', chatBody({ stream: true })), responder);
  const [message, epoch] = h.submitted[0];
  await h.server.deliver({ type: 'infer.done', version: 2, requestId: message.requestId, lastSeq: 0,
    finishReason: 'stop' }, epoch);
  assert.equal(responder.state.sseOpened, 1);
  assert.ok(responder.state.frames.length >= 2);
  assert.ok(responder.state.frames.join('').endsWith('data: [DONE]\n\n'));
});

test('BUSY refuses with 429 before any SSE byte', async () => {
  const h = harness();
  await h.server.sync(true);
  const responder = fakeResponder();
  h.transport.state.handler(httpPost('/v1/chat/completions', chatBody()), responder);
  const [, epoch] = h.submitted[0];
  await h.server.deliver({ type: 'infer.error', version: 2, requestId: 'x', code: 'BUSY',
    message: '有能力的设备都在忙' }, epoch);
  const [status, body] = responder.state.json[0];
  assert.equal(status, 429);
  assert.equal(JSON.parse(body).error.code, 'BUSY');
  assert.equal(responder.state.sseOpened, 0);
});

test('error after SSE started finishes the stream with an error frame', async () => {
  const h = harness();
  await h.server.sync(true);
  const responder = fakeResponder();
  h.transport.state.handler(httpPost('/v1/chat/completions', chatBody({ stream: true })), responder);
  const [message, epoch] = h.submitted[0];
  await h.server.deliver({ type: 'infer.delta', version: 2, requestId: message.requestId, seq: 1, text: '部分' }, epoch);
  await h.server.deliver({ type: 'infer.error', version: 2, requestId: message.requestId,
    code: 'MODEL_EXECUTION_FAILED', message: '引擎异常' }, epoch);
  const tail = responder.state.frames.slice(-2).join('');
  assert.ok(tail.includes('MODEL_EXECUTION_FAILED'));
  assert.ok(tail.includes('[DONE]'));
  assert.equal(responder.state.closed, 1);
});

test('client disconnect mid-stream cancels via drop with the synthetic epoch', async () => {
  const h = harness();
  await h.server.sync(true);
  const responder = fakeResponder();
  h.transport.state.handler(httpPost('/v1/chat/completions', chatBody({ stream: true })), responder);
  const [message, epoch] = h.submitted[0];
  await h.server.deliver({ type: 'infer.delta', version: 2, requestId: message.requestId, seq: 1, text: 'x' }, epoch);
  responder.close(); // 远端断开 → onClose → detach
  assert.deepEqual(h.dropped, [epoch]);
  // 迟到的回包被吞掉且不再触发任何响应。
  const before = responder.state.frames.length;
  await h.server.deliver({ type: 'infer.done', version: 2, requestId: message.requestId, lastSeq: 1 }, epoch);
  assert.equal(responder.state.frames.length, before);
});

test('watchdog fires 504 and cancels at deadline + margin', async () => {
  const h = harness({ deadlineMs: 1000 });
  await h.server.sync(true);
  const responder = fakeResponder();
  h.transport.state.handler(httpPost('/v1/chat/completions', chatBody()), responder);
  const [, epoch] = h.submitted[0];
  h.clk.advance(5000); // deadline(1000) + WATCHDOG_MARGIN(3000) 之外
  assert.equal(responder.state.json[0][0], 504);
  assert.deepEqual(h.dropped, [epoch]);
  assert.equal(h.clk.pending(), 0);
  // 看门狗后的迟到回包被吞。
  await h.server.deliver({ type: 'infer.done', version: 2, requestId: 'x', lastSeq: 1 }, epoch);
  assert.equal(responder.state.json.length, 1);
});

test('watchdog does not fire after a clean completion', async () => {
  const h = harness({ deadlineMs: 1000 });
  await h.server.sync(true);
  const responder = fakeResponder();
  h.transport.state.handler(httpPost('/v1/chat/completions', chatBody()), responder);
  const [message, epoch] = h.submitted[0];
  await h.server.deliver({ type: 'infer.done', version: 2, requestId: message.requestId, lastSeq: 0,
    finishReason: 'stop' }, epoch);
  h.clk.advance(60000);
  assert.deepEqual(h.dropped, []);
  assert.equal(responder.state.json.length, 1);
});

test('capacity throttle 429s beyond the cluster width and frees the slot on completion', async () => {
  // 单节点集群（capacity=1）：第二个在途请求立刻 429，不进 relay；
  // 第一个完成后槽位释放，后续请求恢复放行。
  const h = harness({ capacity: 1 });
  await h.server.sync(true);
  const busy = fakeResponder();
  const rejected = fakeResponder();
  h.transport.state.handler(httpPost('/v1/chat/completions', chatBody()), busy);
  h.transport.state.handler(httpPost('/v1/chat/completions', chatBody()), rejected);
  assert.equal(h.submitted.length, 1, 'only the first request reaches the cluster');
  assert.equal(rejected.state.json.length, 1);
  assert.equal(rejected.state.json[0][0], 429);
  assert.ok(rejected.state.json[0][1].includes('rate_limit_error'));
  // 完成第一个请求后，新请求重新可用。
  const message = h.submitted[0][0];
  await h.server.deliver({ type: 'infer.done', version: 2, requestId: message.requestId, lastSeq: 0 }, h.submitted[0][1]);
  const next = fakeResponder();
  h.transport.state.handler(httpPost('/v1/chat/completions', chatBody()), next);
  assert.equal(h.submitted.length, 2, 'slot is released after completion');
  assert.equal(next.state.json.length, 0);
});

test('missing capacity option defaults to serial admission', async () => {
  const clk = clock();
  activeClock = clk;
  const transport = fakeTransport();
  const submitted = [];
  const server = new OpenAiServer({
    port: 8080,
    transport: () => transport,
    models: () => [{ id: 'm', vision: false }],
    resolveAddress: async () => '1.2.3.4',
    submit: (message, epoch) => submitted.push([message, epoch]),
    drop: (_epoch) => {}
  });
  await server.sync(true);
  transport.state.handler(httpPost('/v1/chat/completions', chatBody()), fakeResponder());
  const second = fakeResponder();
  transport.state.handler(httpPost('/v1/chat/completions', chatBody()), second);
  assert.equal(submitted.length, 1);
  assert.equal(second.state.json[0][0], 429);
});

test('concurrent requests get distinct epochs >= base; late replies are swallowed', async () => {
  const h = harness();
  await h.server.sync(true);
  const responders = [fakeResponder(), fakeResponder()];
  h.transport.state.handler(httpPost('/v1/chat/completions', chatBody()), responders[0]);
  h.transport.state.handler(httpPost('/v1/chat/completions', chatBody()), responders[1]);
  const epochA = h.submitted[0][1];
  const epochB = h.submitted[1][1];
  assert.notEqual(epochA, epochB);
  assert.ok(epochA >= HTTP_EPOCH_BASE && epochB >= HTTP_EPOCH_BASE);
  // A 正常完成；B 收到 A 的迟到回包（错投）应被忽略。
  const messageA = h.submitted[0][0];
  await h.server.deliver({ type: 'infer.done', version: 2, requestId: messageA.requestId, lastSeq: 0 }, epochA);
  assert.equal(responders[0].state.json.length, 1);
  assert.equal(responders[1].state.json.length, 0);
  assert.equal(h.dropped.length, 0);
});

test('deliver returns false for real chat epochs and sync(false) drops pending work', async () => {
  const h = harness();
  await h.server.sync(true);
  assert.equal(await h.server.deliver({ type: 'infer.delta', version: 2, requestId: 'x', text: 'y' }, 5), false);
  assert.equal(await h.server.deliver({ type: 'infer.delta', version: 2, requestId: 'x', text: 'y' }, HTTP_EPOCH_BASE - 1), false);
  const responder = fakeResponder();
  h.transport.state.handler(httpPost('/v1/chat/completions', chatBody()), responder);
  const epoch = h.submitted[0][1];
  await h.server.sync(false);
  assert.deepEqual(h.dropped, [epoch], 'stop cancels in-flight requests');
  assert.equal(responder.state.closed, 1, 'connection closed on shutdown');
});

(async () => {
  let pass = 0;
  for (const [name, fn] of tests) {
    try { await fn(); pass++; console.log('PASS ' + name); } catch (error) { console.error('FAIL ' + name, error); process.exitCode = 1; }
  }
  console.log(pass + '/' + tests.length + ' openai server tests passed');
})();
