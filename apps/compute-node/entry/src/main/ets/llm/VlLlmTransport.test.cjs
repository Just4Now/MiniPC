// node VlLlmTransport.test.cjs [path/to/typescript/lib/typescript.js]
const assert = require('node:assert/strict');
const vm = require('node:vm');
const { transpile } = require('../../../../../../tests/harness.cjs');

// ---- 文件系统桩：记录写过什么，模拟可读可写沙箱 cache ----
const writes = [];
const fsStub = {
  OpenMode: { READ_ONLY: 0, READ_WRITE: 1, CREATE: 2, TRUNC: 4 },
  openSync(path, mode) { writes.push({ path, mode }); return { fd: path }; },
  closeSync() {}, readSync() { return 0; }, writeSync(fd, buf) { },
  mkdirSync(dir, recursive) { }
};

// ---- VL 引擎桩：捕获 start 参数，可编程回调 ----
let called = null;
let engineStarts = 0;
let engineReady = '';
let engineOk = true;
const engineStub = {
  getInstance: () => ({
    readinessError: () => engineReady,
    start(imagePath, prompt, cb) {
      engineStarts++; called = { imagePath, prompt, cb }; return engineOk;
    },
    cancel() {}, isBusy() { return false; }
  })
};

const context = { exports: {}, ArrayBuffer, Uint8Array, Date: { now: () => 123 } ,
  require(name) {
    if (name === '@kit.CoreFileKit') return { fileIo: fsStub };
    if (name === '@kit.ArkTS') return {
      util: {
        Base64Helper: class { decodeSync(text) { return new Uint8Array(Buffer.from(text, 'base64')); } },
        TextEncoder: { create: () => ({ encodeInto(text) { return new Uint8Array(Buffer.from(text, 'utf8')); } }) },
        TextDecoder: { create: () => ({ decodeToString: bytes => Buffer.from(bytes).toString('utf8') }) }
      }
    };
    if (name === '@kit.PerformanceAnalysisKit') return { hilog: { info() {}, error() {}, warn() {} } };
    if (name === './LocalChat') return {};
    if (name === './LlmTransport') return {};
    if (name === './QwenVlManager') return { QwenVlManager: engineStub };
    return {};
  } };
vm.runInNewContext(transpile(__dirname + '/VlLlmTransport.ets'), context);
const { VlLlmTransport } = context.exports;

// 裸 base64（新版管线格式）→ 解码落盘
{
  const t = new VlLlmTransport('/cache', '/files');
  engineStarts = 0; called = null;
  assert.equal(t.start([{ role: 'user', content: '这是什么' }], () => {}, 'a', 'QUJD'), '');
  assert.equal(engineStarts, 1, 'VL engine is started');
  assert.equal(called.imagePath.indexOf('/data/storage/el2/base/cache/qwenvl_'), 0,
    'bare base64 decodes to a cache jpg');
  assert.ok(called.imagePath.endsWith('.jpg'), 'image lands as a jpg file');
  assert.equal(called.prompt, '这是什么', 'the last user message is the prompt');
  assert.ok(writes.some(w => w.path.indexOf('/data/storage/el2/base/cache/qwenvl_') === 0),
    'image file is created');
}

// 回归：JPEG 裸 base64 以 "/9j/..." 开头（含 '/'），绝不能被误判为绝对路径透传。
// 这正是线上 "stbi_load failed: /9j/4AAQ..." 的根因。
{
  const t = new VlLlmTransport('/cache', '/files');
  engineStarts = 0; called = null;
  const jpegB64 = '/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAkJCQoKCg0NDQ0NDQ0'+'NDQ0NDQ0NDQ0NDQ0NDQ0='.replace('=', '');
  const err = t.start([{ role: 'user', content: '图里有几只猫' }], () => {}, 'a1', jpegB64);
  assert.equal(err, '', 'jpeg-like bare base64 starts the engine: ' + err);
  assert.equal(engineStarts, 1, 'engine called for jpeg-prefixed base64');
  assert.equal(called.imagePath.indexOf('/data/storage/el2/base/cache/qwenvl_'), 0,
    'starts with /9j/ yet still decodes to a cache file, not passed through: ' + called.imagePath);
  assert.ok(called.imagePath.endsWith('.jpg'), 'lands as jpg');
  assert.equal(called.prompt, '图里有几只猫');
}

// 绝对路径仍直通（路径含 '.'，不匹配裸 base64 判定）
{
  const t = new VlLlmTransport('/cache', '/files');
  engineStarts = 0; called = null;
  const err = t.start([{ role: 'user', content: '看' }], () => {}, 'a2',
    '/data/storage/el2/base/cache/qwenvl_1.jpg');
  assert.equal(err, '', 'abs path accepted');
  assert.equal(called.imagePath, '/data/storage/el2/base/cache/qwenvl_1.jpg', 'abs path passes through');
}

// dataUrl（旧版/远端转发兼容）→ 同样解码落盘
{
  const t = new VlLlmTransport('/cache', '/files');
  engineStarts = 0;
  assert.equal(t.start([{ role: 'user', content: '图示' }], () => {}, 'b',
    'data:image/jpeg;base64,QUJD'), '');
  assert.equal(engineStarts, 1);
  assert.equal(called.imagePath.indexOf('/data/storage/el2/base/cache/qwenvl_'), 0,
    'dataUrl also lands in cache');
  assert.equal(called.prompt, '图示');
}

// 绝对路径直接透传（测试/内部调用），prompt 剥离"（附图）"伪前缀
{
  const t = new VlLlmTransport('/cache', '/files');
  engineStarts = 0;
  assert.equal(t.start([{ role: 'user', content: '（附图）请看' }], () => {}, 'c',
    '/data/storage/el2/base/cache/qwenvl_1.jpg'), '');
  assert.equal(engineStarts, 1);
  assert.equal(called.imagePath, '/data/storage/el2/base/cache/qwenvl_1.jpg', 'abs path passes through');
  assert.equal(called.prompt, '请看', '（附图） prefix is peeled');
}

// 引擎未部署 → 门控失败，不触碰引擎
{
  const t = new VlLlmTransport('/cache', '/files');
  engineStarts = 0; engineReady = 'VL 模型未部署';
  const err = t.start([{ role: 'user', content: 'x' }], () => {}, 'd', 'QUJD');
  assert.ok(err.length > 0, 'readiness gate rejects: ' + err);
  assert.equal(engineStarts, 0);
  engineReady = '';
}

// 事件映射：delta 透传；done 追加溯源标签并带 finishReason
{
  const t = new VlLlmTransport('/cache', '/files');
  const updates = [];
  t.start([{ role: 'user', content: '图里有什么' }], u => { updates.push(u); }, 'e', 'QUJD');
  called.cb({ delta: '一只' });
  called.cb({ delta: '猫' });
  called.cb({ done: '一只猫', finishReason: 'stop' });
  assert.equal(updates[0].kind, 'delta'); assert.equal(updates[0].text, '一只');
  assert.equal(updates[1].kind, 'delta'); assert.equal(updates[1].text, '猫');
  assert.equal(updates[2].kind, 'done');
  assert.ok(updates[2].text.indexOf('一只猫') === 0, 'done carries the full answer');
  assert.ok(updates[2].text.indexOf('Qwen2.5-VL-3B-NPU') > 0, 'source tag appended');
  assert.equal(updates[2].finishReason, 'stop');
}

// loading 事件被忽略（web UI busy 态覆盖）
{
  const t = new VlLlmTransport('/cache', '/files');
  const updates = [];
  t.start([{ role: 'user', content: 'x' }], u => { updates.push(u); }, 'f', 'QUJD');
  called.cb({ loading: true });
  assert.equal(updates.length, 0, 'loading is swallowed');
  called.cb({ done: '答' });
  assert.equal(updates.length, 1, 'only the final done surfaces');
}

console.log('PASS: VlLlmTransport image forms, prompt peeling, readiness gate, event mapping');
