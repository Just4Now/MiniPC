// node HttpProtocol.test.cjs [path/to/typescript/lib/typescript.js]
// 纯 HTTP/1.1 解析/格式化层的分片、超限、UTF-8 安全与响应组装测试。
const assert = require('node:assert/strict');
const vm = require('node:vm');
const path = require('node:path');
const { transpile } = require('../../../../../../../tests/ets-harness.cjs');
function load(relative, requires = {}) {
  const mod = { exports: {} };
  const context = { module: mod, exports: mod.exports, Error, Map, Math, Number, String, Promise, JSON, Array,
    Uint8Array, require: (name) => requires[name] || {} };
  vm.runInNewContext(transpile(path.join(__dirname, relative)), context);
  return mod.exports;
}
const utilMock = {
  // 注意：设备端 util.TextEncoder.encodeInto('') 按官方文档返回 undefined（会杀进程），
  // 这里刻意镜像该行为，让 utf8Length 的空串特判在测试里真实生效。
  TextEncoder: class { encodeInto(text) { if (text === '') return undefined; return new Uint8Array(Buffer.from(text, 'utf8')); } },
  TextDecoder: { create: () => ({ decodeToString: (bytes) => Buffer.from(bytes.buffer, bytes.byteOffset, bytes.byteLength).toString('utf8') }) }
};
const { HttpRequestParser, formatResponse, sseResponseHead, sseFrame, utf8Length, HttpProtocolError } =
  load('./HttpProtocol.ets', { '@kit.ArkTS': { util: utilMock } });

const bytesOf = (text) => new Uint8Array(Buffer.from(text, 'utf8'));
const GET = 'GET /v1/models HTTP/1.1\r\nHost: hub:8080\r\nAccept: application/json\r\n\r\n';
const post = (body, extra = '') => 'POST /v1/chat/completions HTTP/1.1\r\nHost: hub:8080' + extra +
  '\r\nContent-Type: application/json\r\nContent-Length: ' + String(Buffer.byteLength(body, 'utf8')) + '\r\n\r\n' + body;
/** 把整段字节按给定切片边界逐块喂给解析器，模拟 TCP 分片。 */
const feed = (parser, whole, cuts) => {
  let start = 0;
  for (const cut of cuts.concat([whole.length])) {
    if (cut > start) {
      const step = parser.push(whole.subarray(start, cut));
      if (step !== null) return { request: step, rest: whole.subarray(cut) };
    }
    start = cut;
  }
  return { request: null, rest: new Uint8Array(0) };
};

const tests = [];
const test = (name, fn) => tests.push([name, fn]);

test('single-block GET parses method, lowercase headers, empty body', () => {
  const parser = new HttpRequestParser();
  const { request } = feed(parser, bytesOf(GET), []);
  assert.ok(request);
  assert.equal(request.method, 'GET');
  assert.equal(request.path, '/v1/models');
  assert.equal(request.headers.get('host'), 'hub:8080');
  assert.equal(request.body, '');
});

test('header and body split across chunks reassembles once Content-Length is satisfied', () => {
  const parser = new HttpRequestParser();
  const body = '{"model":"qwen","messages":[{"role":"user","content":"你好"}]}';
  const whole = bytesOf(post(body));
  // 请求行中间、头结束符中间、body 中间各切一刀。
  const { request } = feed(parser, whole, [7, 120, 160]);
  assert.ok(request);
  assert.equal(request.method, 'POST');
  assert.equal(request.headers.get('content-length'), String(Buffer.byteLength(body, 'utf8')));
  assert.equal(request.body, body);
});

test('UTF-8 multibyte body split mid-character decodes safely', () => {
  const parser = new HttpRequestParser();
  const body = '你好，世界';
  const whole = bytesOf(post(body));
  const bodyStart = whole.length - Buffer.byteLength(body, 'utf8');
  const { request } = feed(parser, whole, [bodyStart + 3]);
  assert.ok(request);
  assert.equal(request.body, body);
});

test('partial body keeps returning null until the last byte arrives', () => {
  const parser = new HttpRequestParser();
  const whole = bytesOf(post('hello world'));
  const bodyStart = whole.length - 11;
  assert.equal(parser.push(whole.subarray(0, whole.length - 1)), null);
  assert.equal(parser.push(whole.subarray(whole.length - 1, whole.length - 1)), null);
  const request = parser.push(whole.subarray(whole.length - 1));
  assert.ok(request);
  assert.equal(request.body, 'hello world');
  assert.ok(bodyStart > 0);
});

test('query string is stripped and proxy absolute URI collapses to path', () => {
  const parser = new HttpRequestParser();
  const request = parser.push(bytesOf('GET http://192.168.1.5:8080/v1/models?verbose=1 HTTP/1.1\r\nHost: x\r\n\r\n'));
  assert.ok(request);
  assert.equal(request.path, '/v1/models');
});

test('oversized header rejects with 431', () => {
  const parser = new HttpRequestParser();
  assert.throws(() => parser.push(bytesOf('GET / HTTP/1.1\r\nX-Big: ' + 'a'.repeat(20000) + '\r\n\r\n')),
    (error) => error instanceof HttpProtocolError && error.status === 431);
});

test('declared Content-Length above the body cap rejects with 413', () => {
  const parser = new HttpRequestParser();
  assert.throws(() => parser.push(bytesOf('POST /v1/chat/completions HTTP/1.1\r\nContent-Length: 3000000\r\n\r\n')),
    (error) => error instanceof HttpProtocolError && error.status === 413);
});

test('chunked transfer-encoding rejects with 411', () => {
  const parser = new HttpRequestParser();
  assert.throws(() => parser.push(bytesOf('POST /v1/chat/completions HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n')),
    (error) => error instanceof HttpProtocolError && error.status === 411);
});

test('malformed request line rejects with 400', () => {
  const parser = new HttpRequestParser();
  assert.throws(() => parser.push(bytesOf('GET\r\n\r\n')),
    (error) => error instanceof HttpProtocolError && error.status === 400);
});

test('non-numeric Content-Length rejects with 400', () => {
  const parser = new HttpRequestParser();
  assert.throws(() => parser.push(bytesOf('POST /v1/chat/completions HTTP/1.1\r\nContent-Length: 4x\r\n\r\n')),
    (error) => error instanceof HttpProtocolError && error.status === 400);
});

test('bytes after the first request stay buffered (no silent loss)', () => {
  const parser = new HttpRequestParser();
  const trailing = 'GET /next HTTP/1.1\r\n\r\n';
  const whole = bytesOf(GET + trailing);
  const request = parser.push(whole);
  assert.ok(request);
  // 残留留在解析器缓冲里，由上层按 Connection: close 语义丢弃。
  assert.equal(parser.bytes.length, trailing.length);
});

test('formatResponse carries CORS, byte-accurate Content-Length and close', () => {
  const body = JSON.stringify({ ok: true, text: '中文内容' });
  const response = formatResponse(200, 'application/json; charset=utf-8', body);
  const head = response.substring(0, response.indexOf('\r\n\r\n'));
  assert.ok(head.includes('HTTP/1.1 200 OK'));
  assert.ok(head.includes('Access-Control-Allow-Origin: *'));
  assert.ok(head.includes('Content-Type: application/json; charset=utf-8'));
  assert.ok(head.includes('Content-Length: ' + String(Buffer.byteLength(body, 'utf8'))));
  assert.ok(head.includes('Connection: close'));
  assert.ok(response.endsWith(body));
});

test('204 response omits Content-Length per RFC 7230', () => {
  const response = formatResponse(204, 'text/plain', '');
  const head = response.substring(0, response.indexOf('\r\n\r\n'));
  assert.ok(head.includes('HTTP/1.1 204 No Content'));
  assert.ok(!head.includes('Content-Length'));
});

test('utf8Length tolerates empty string (device encodeInto returns undefined)', () => {
  // 回归：设备端 encodeInto('') 返回 undefined，取 .length 曾直接 JsError 杀进程。
  assert.equal(utf8Length(''), 0);
  assert.equal(utf8Length('abc'), 3);
  assert.equal(utf8Length('中文'), 6);
  // 空 body 的 formatResponse 必须能完整走通（OPTIONS→204 预检路径）。
  assert.ok(formatResponse(204, 'text/plain', '').endsWith('\r\n\r\n'));
});

test('SSE head and frame formats match the client parser expectations', () => {
  const head = sseResponseHead();
  assert.ok(head.startsWith('HTTP/1.1 200 OK\r\n'));
  assert.ok(head.includes('Content-Type: text/event-stream; charset=utf-8'));
  assert.ok(head.endsWith('\r\n\r\n'));
  const frame = sseFrame('{"a":1}');
  assert.equal(frame, 'data: {"a":1}\n\n');
});

(async () => {
  let pass = 0;
  for (const [name, fn] of tests) {
    try { await fn(); pass++; console.log('PASS ' + name); } catch (error) { console.error('FAIL ' + name, error); process.exitCode = 1; }
  }
  console.log(pass + '/' + tests.length + ' http protocol tests passed');
})();
