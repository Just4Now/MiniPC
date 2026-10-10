// node InferenceRelay.test.cjs [path/to/typescript/lib/typescript.js]
// Executes the real DevicePool, ComputeRouter and InferenceRelay sources with controlled senders.
const assert = require('node:assert/strict');
const vm = require('node:vm');
const path = require('node:path');
const { transpile } = require('../../../../../../../tests/ets-harness.cjs');
function load(relative, requires = {}) {
  const mod = { exports: {} };
  const context = { module: mod, exports: mod.exports, Error, Map, Math, Number, String, Promise, JSON, Array,
    require: (name) => requires[name] || {} };
  vm.runInNewContext(transpile(path.join(__dirname, relative)), context);
  return mod.exports;
}
const pool = load('../cluster/DevicePool.ets');
const routerModule = load('../cluster/ComputeRouter.ets');
const { InferenceRelay, RelayEvents } = load('./InferenceRelay.ets', {
  '@kit.PerformanceAnalysisKit': { hilog: { info() {}, warn() {} } },
  '../cluster/ComputeRouter': routerModule,
  '../cluster/DevicePool': pool
});
const json = (value) => JSON.parse(JSON.stringify(value));

function node(partial) { return Object.assign(new pool.PoolNode(), partial); }
function harness(initial, options = {}) {
  const nodes = initial;
  const sent = [], localHandled = [], events = [];
  const router = new routerModule.ComputeRouter();
  const handlers = new RelayEvents();
  handlers.begin = (id, chat, worker) => events.push(['begin', id, chat, worker]);
  handlers.delta = (id, chat, text) => events.push(['delta', id, chat, text]);
  handlers.end = (id, chat, text, failed) => events.push(['end', id, chat, text, failed]);
  // Like Index.poolNodes(): a worker's in-flight count comes from the hub's own hand-off ledger.
  const snapshot = () => nodes.map((item) => item.isSelf ? item : Object.assign(item, { inflight: Math.max(item.sampled || 0, router.workerLoad(item.epoch, 0)) }));
  const relay = new InferenceRelay(router, snapshot, () => [5], { handle: (m, e) => localHandled.push([m.type, m.requestId, e]) },
    (message, epoch) => { sent.push([json(message), epoch]); return Promise.resolve(options.sendResult !== false); }, handlers);
  const to = (epoch, type) => sent.filter((entry) => entry[1] === epoch && (type === undefined || entry[0].type === type)).map((entry) => entry[0]);
  return { relay, router, nodes, sent, localHandled, events, to };
}
const request = (id) => ({ type: 'infer.request', version: 2, requestId: id, messages: [{ role: 'developer', content: 'sys' }, { role: 'user', content: 'q' }],
  maxOutputTokens: 512, deadlineBudgetMs: 170000, promptFormat: 'loop-react-split-v1' });
const self = (extra) => node({ epoch: 0, label: '算力设备1', isSelf: true, ready: true, inflight: 0, memAvail: 100, ...extra });
const worker = (extra) => node({ epoch: 7, label: '算力设备2', ready: true, inflight: 0, memAvail: 100, ...extra });
const tests = [];
const test = (name, fn) => tests.push([name, fn]);
const tick = () => new Promise((resolve) => setImmediate(resolve));

test('DevicePool: idle only, more memory first, hub wins ties, load counts ready nodes', () => {
  assert.equal(pool.pickIdle([]), null);
  assert.equal(pool.pickIdle([self({ inflight: 1 }), worker({ ready: false })]), null);
  assert.equal(pool.pickIdle([self({ memAvail: 10 }), worker({ memAvail: 20 })]).epoch, 7);
  assert.equal(pool.pickIdle([worker(), self()]).isSelf, true);
  const load = pool.clusterLoad([self({ inflight: 2 }), worker(), worker({ epoch: 8, ready: false })]);
  assert.deepEqual(json(load), { idle: 1, total: 2 });
});
test('idle hub runs the request itself', () => {
  const h = harness([self(), worker({ memAvail: 50 })]);
  h.relay.handleFromChat(request('r1'), 5);
  assert.deepEqual(h.localHandled, [['infer.request', 'r1', 5]]);
  assert.equal(h.to(7).length, 0);
});
test('busy hub forwards to the idle worker with a hub forwardId and reduced budget', () => {
  const h = harness([self({ inflight: 1 }), worker()]);
  h.relay.handleFromChat(request('r1'), 5);
  assert.equal(h.localHandled.length, 0);
  const forwarded = h.to(7, 'infer.request')[0];
  assert.notEqual(forwarded.requestId, 'r1');
  assert.equal(forwarded.deadlineBudgetMs, 165000);
  assert.equal(forwarded.messages[1].content, 'q');
  assert.equal(forwarded.maxOutputTokens, 512);
  assert.equal(h.events[0][0], 'begin');
});
test('two simultaneous requests never share one idle device; third is retryable BUSY', () => {
  const h = harness([self({ inflight: 1 }), worker()]);
  h.relay.handleFromChat(request('a'), 5);
  h.relay.handleFromChat(request('b'), 5);
  assert.equal(h.to(7, 'infer.request').length, 1);
  const refusal = h.to(5, 'infer.error')[0];
  assert.equal(refusal.requestId, 'b'); assert.equal(refusal.code, 'BUSY'); assert.equal(refusal.retryable, true);
});
test('worker replies are rewritten to the origin id with payload, seq and hash untouched', () => {
  const h = harness([self({ inflight: 1 }), worker()]);
  h.relay.handleFromChat(request('r1'), 5);
  const fid = h.to(7, 'infer.request')[0].requestId;
  h.relay.handleFromWorker({ type: 'infer.accepted', requestId: fid, state: 'preparing' }, 7);
  h.relay.handleFromWorker({ type: 'infer.delta', requestId: fid, seq: 1, text: '你好' }, 7);
  h.relay.handleFromWorker({ type: 'infer.done', requestId: fid, lastSeq: 1, outputUtf8Bytes: 6, outputSha256: 'abc', finishReason: 'stop', source: 'w' }, 7);
  const out = h.to(5).filter((m) => m.type !== 'infer.status');
  assert.deepEqual(out.map((m) => m.type), ['infer.accepted', 'infer.delta', 'infer.done']);
  assert.ok(out.every((m) => m.requestId === 'r1'));
  assert.equal(out[0].device, '算力设备2');
  assert.deepEqual([out[1].seq, out[1].text], [1, '你好']);
  assert.deepEqual([out[2].lastSeq, out[2].outputUtf8Bytes, out[2].outputSha256, out[2].finishReason], [1, 6, 'abc', 'stop']);
  assert.deepEqual(h.events.slice(-1)[0], ['end', 'r1', 5, '你好', false]);
  assert.equal(h.router.getByForwardId(fid), undefined, 'hand-off released');
});
test('replies for unknown ids or from another device are dropped', () => {
  const h = harness([self({ inflight: 1 }), worker()]);
  h.relay.handleFromChat(request('r1'), 5);
  const fid = h.to(7, 'infer.request')[0].requestId;
  const before = h.sent.length;
  h.relay.handleFromWorker({ type: 'infer.delta', requestId: 'zzz', seq: 1, text: 'x' }, 7);
  h.relay.handleFromWorker({ type: 'infer.delta', requestId: fid, seq: 1, text: 'x' }, 9);
  assert.equal(h.sent.length, before);
});
test('cancel is forwarded under the forwardId and the CANCELLED reply returns to the chat', () => {
  const h = harness([self({ inflight: 1 }), worker()]);
  h.relay.handleFromChat(request('r1'), 5);
  const fid = h.to(7, 'infer.request')[0].requestId;
  h.relay.handleFromChat({ type: 'infer.cancel', requestId: 'r1' }, 5);
  assert.equal(h.to(7, 'infer.cancel')[0].requestId, fid);
  h.relay.handleFromWorker({ type: 'infer.error', requestId: fid, code: 'CANCELLED', message: 'stopped', retryable: false }, 7);
  const error = h.to(5, 'infer.error')[0];
  assert.deepEqual([error.requestId, error.code, error.retryable], ['r1', 'CANCELLED', false]);
});
test('cancel for a locally run request goes to the local host', () => {
  const h = harness([self(), worker()]);
  h.relay.handleFromChat({ type: 'infer.cancel', requestId: 'mine' }, 5);
  assert.deepEqual(h.localHandled, [['infer.cancel', 'mine', 5]]);
});
test('worker lost before accepted is retryable; after accepted it is not', () => {
  for (const accepted of [false, true]) {
    const h = harness([self({ inflight: 1 }), worker()]);
    h.relay.handleFromChat(request('r1'), 5);
    const fid = h.to(7, 'infer.request')[0].requestId;
    if (accepted) h.relay.handleFromWorker({ type: 'infer.accepted', requestId: fid }, 7);
    h.relay.workerDropped(7);
    const error = h.to(5, 'infer.error')[0];
    assert.deepEqual([error.requestId, error.code, error.retryable], ['r1', 'WORKER_LOST', !accepted]);
    assert.equal(h.router.getByForwardId(fid), undefined);
  }
});
test('chat drop cancels the remote work and releases the hand-off', () => {
  const h = harness([self({ inflight: 1 }), worker()]);
  h.relay.handleFromChat(request('r1'), 5);
  const fid = h.to(7, 'infer.request')[0].requestId;
  h.relay.chatDropped(5);
  assert.equal(h.to(7, 'infer.cancel')[0].requestId, fid);
  assert.equal(h.router.getByForwardId(fid), undefined);
});
test('failed forward send reports a retryable error and frees the device', async () => {
  const h = harness([self({ inflight: 1 }), worker()], { sendResult: false });
  h.relay.handleFromChat(request('r1'), 5);
  await tick();
  const error = h.to(5, 'infer.error')[0];
  assert.deepEqual([error.requestId, error.code, error.retryable], ['r1', 'WORKER_LOST', true]);
  assert.equal(h.router.workerLoad(7, 0), 0);
});
test('duplicate live request id is refused without a second hand-off', () => {
  const h = harness([self({ inflight: 1 }), worker(), worker({ epoch: 8, label: '算力设备3' })]);
  h.relay.handleFromChat(request('r1'), 5);
  h.relay.handleFromChat(request('r1'), 5);
  assert.equal(h.to(5, 'infer.error')[0].code, 'DUPLICATE_REQUEST');
  assert.equal(h.sent.filter((entry) => entry[0].type === 'infer.request').length, 1);
});
test('infer.status is pushed to chats only when the idle count changes', () => {
  const h = harness([self(), worker()]);
  h.relay.publishLoad();
  h.relay.publishLoad();
  assert.equal(h.to(5, 'infer.status').length, 1);
  assert.deepEqual(h.to(5, 'infer.status')[0].cluster, { idle: 2, total: 2 });
  h.nodes[1].sampled = 1;
  h.relay.publishLoad();
  assert.deepEqual(h.to(5, 'infer.status')[1].cluster, { idle: 1, total: 2 });
});
test('capabilities.get is answered by the local host', () => {
  const h = harness([self(), worker()]);
  h.relay.handleFromChat({ type: 'infer.capabilities.get', requestId: 'cap-1' }, 5);
  assert.deepEqual(h.localHandled, [['infer.capabilities.get', 'cap-1', 5]]);
});
(async () => {
  let pass = 0;
  for (const [name, fn] of tests) {
    try { await fn(); pass++; console.log('PASS ' + name); } catch (error) { console.error('FAIL ' + name, error); process.exitCode = 1; }
  }
  console.log(pass + '/' + tests.length + ' relay/pool tests passed');
})();
