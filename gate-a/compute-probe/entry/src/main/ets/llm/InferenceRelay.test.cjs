// node InferenceRelay.test.cjs [path/to/typescript/lib/typescript.js]
// Executes the real DevicePool, ComputeRouter and InferenceRelay sources with controlled senders.
const assert = require('node:assert/strict');
const vm = require('node:vm');
const path = require('node:path');
const { transpile } = require('../../../../../../tests/harness.cjs');
function load(relative, requires = {}) {
  const mod = { exports: {} };
  const context = { module: mod, exports: mod.exports, Error, Map, Math, Number, String, Promise, JSON, Array,
    require: (name) => requires[name] || {} };
  vm.runInNewContext(transpile(path.join(__dirname, relative)), context);
  return mod.exports;
}
const pool = load('../cluster/DevicePool.ets');
const routerModule = load('../cluster/ComputeRouter.ets');
const reuseModule = load('./SessionReuse.ets');
const { InferenceRelay, RelayEvents } = load('./InferenceRelay.ets', {
  './SessionReuse': reuseModule,
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
  if(options.forward)handlers.forward=options.forward;
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
test('forwarded child keeps display identity and original chat source', () => {
  const h=harness([self({inflight:1}),worker()]);
  h.relay.handleFromChat({...request('child'),taskId:'parent',subtaskId:'s2',origin:'聊天设备3'},5);
  const forwarded=h.to(7,'infer.request')[0];
  assert.equal(forwarded.taskId,'parent');assert.equal(forwarded.subtaskId,'s2');assert.equal(forwarded.origin,'聊天设备3');
});

test('legacy display context is attached after the card observer and before forwarding',()=>{
  let observed=false;
  const h=harness([self({inflight:1}),worker()],{forward:(id,chat,worker,copy)=>{
    observed=h.events.some(event=>event[0]==='begin'&&event[1]===id);
    copy.taskId='display_session_parent';copy.subtaskId='s2';
  }});
  const original={...request('legacy'),label:'子任务 2/2'};
  h.relay.handleFromChat(original,5);
  const copy=h.to(7,'infer.request')[0];
  assert(observed);assert.equal(copy.taskId,'display_session_parent');assert.equal(copy.subtaskId,'s2');
  assert.deepEqual(copy.messages,original.messages);assert.equal(original.taskId,undefined);
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
test('one busy worker accepts multiple sessions and keeps separate dispatch identities', () => {
  const h = harness([self({ ready: false }), worker()]);
  h.relay.handleFromChat(request('a'), 5);
  h.relay.handleFromChat(request('b'), 5);
  const sent = h.to(7, 'infer.request');
  assert.equal(sent.length, 2);assert.notEqual(sent[0].requestId,sent[1].requestId);
  assert.equal(h.router.workerLoad(7,0),2);assert.equal(h.to(5,'infer.error').length,0);
  h.relay.handleFromWorker({type:'infer.done',requestId:sent[1].requestId,lastSeq:1},7);
  assert.equal(h.to(5,'infer.done')[0].requestId,'b');assert.equal(h.router.workerLoad(7,0),1);
  h.relay.handleFromChat({type:'infer.cancel',requestId:'a'},5);
  assert.equal(h.to(7,'infer.cancel')[0].requestId,sent[0].requestId);
});

test('parallel routing keeps idle preference, then balances busy nodes by in-flight count',()=>{
  assert.equal(pool.pickAvailable([self({inflight:4}),worker({sampled:0,inflight:2})]).epoch,7);
  assert.equal(pool.pickAvailable([self({inflight:1}),worker({inflight:2})],7).epoch,0);
  assert.equal(pool.pickAvailable([self({inflight:2}),worker({inflight:2})],7).epoch,7);
  assert.equal(pool.pickAvailable([self({inflight:4}),worker()]).epoch,7);
  assert.equal(pool.pickAvailable([self({ready:false}),worker({ready:false})]),null);
});

test('unavailable devices still return retryable refusal',()=>{
  const h=harness([self({ready:false}),worker({ready:false})]);h.relay.handleFromChat(request('a'),5);
  assert.equal(h.to(5,'infer.error')[0].code,'BUSY');assert.equal(h.to(5,'infer.error')[0].retryable,true);
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
    const h = harness([self({ ready: false }), worker()]);
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
const roundOf = (id, tail) => ({ type: 'infer.request', version: 2, requestId: id, promptFormat: 'loop-react-split-v1',
  messages: [{ role: 'developer', content: 'sys\nCurrent device local datetime: ' + id + '\nTools' },
    { role: 'user', content: 'User task:\nweather\n' + tail }] });
function finishOn(h, epoch) {
  const forwarded = h.to(epoch, 'infer.request');
  const last = forwarded[forwarded.length - 1];
  h.relay.handleFromWorker({ type: 'infer.done', requestId: last.requestId, lastSeq: 1, finishReason: 'stop' }, epoch);
}
test('affinity keeps the next round of a run on the device that holds its session, only when idle', () => {
  const h = harness([self({ memAvail: 100 }), worker({ memAvail: 200 })]);
  h.relay.setAffinity(() => true);
  h.relay.handleFromChat(roundOf('r1', 'Control: go'), 5);
  assert.equal(h.to(7, 'infer.request').length, 1, 'first round goes to the larger-memory worker');
  finishOn(h, 7);
  h.nodes[0].memAvail = 900; // default choice would now be the hub
  h.relay.handleFromChat(roundOf('r2', 'Action: a\nObservation: b\nControl: go'), 5);
  assert.equal(h.to(7, 'infer.request').length, 2, 'same run stays on the worker that has its session');
  finishOn(h, 7);
  h.relay.handleFromChat(roundOf('r3', 'Action: a\nObservation: b\nControl: go'), 5);
  h.nodes[1].sampled = 1; // the preferred worker is busy now
  h.relay.handleFromChat({ ...roundOf('r4', 'Action: c\nObservation: d\nControl: go') }, 5);
  assert.equal(h.localHandled.filter((entry) => entry[1] === 'r4').length, 1, 'a busy preferred device is not waited for');
  const other = harness([self({ memAvail: 100 }), worker({ memAvail: 200 })]);
  other.relay.setAffinity(() => true);
  other.relay.handleFromChat(roundOf('x1', 'Control: go'), 5);
  finishOn(other, 7);
  other.nodes[0].memAvail = 900;
  other.relay.handleFromChat({ ...roundOf('x2', 'Control: go'), messages: [{ role: 'developer', content: 'sys\nTools' },
    { role: 'user', content: 'User task:\nsomething else\nControl: go' }] }, 5);
  assert.equal(other.localHandled.filter((entry) => entry[1] === 'x2').length, 1, 'a different run is placed normally');
});
test('affinity is off by default and then placement is unchanged', () => {
  const h = harness([self({ memAvail: 100 }), worker({ memAvail: 200 })]);
  h.relay.handleFromChat(roundOf('r1', 'Control: go'), 5);
  finishOn(h, 7);
  h.nodes[0].memAvail = 900;
  h.relay.handleFromChat(roundOf('r2', 'Action: a\nObservation: b\nControl: go'), 5);
  assert.equal(h.localHandled.filter((entry) => entry[1] === 'r2').length, 1);
});
test('pickIdle prefers the given epoch only while it is idle', () => {
  assert.equal(pool.pickIdle([self({ memAvail: 900 }), worker({ memAvail: 1 })], 7).epoch, 7);
  assert.equal(pool.pickIdle([self({ memAvail: 900 }), worker({ memAvail: 1, inflight: 1 })], 7).epoch, 0);
  assert.equal(pool.pickIdle([self({ memAvail: 900 }), worker({ memAvail: 1 })], 99).epoch, 0);
  assert.equal(pool.pickIdle([self({ memAvail: 900 }), worker({ memAvail: 1 })]).epoch, 0);
});
const trio = (selfBusy = true) => harness([self({ memAvail: 1, inflight: selfBusy ? 1 : 0 }), worker({ memAvail: 200 }), worker({ epoch: 8, label: '算力设备3', memAvail: 100 })]);
const errorsToChat = (h) => h.sent.filter((entry) => entry[1] === 5 && entry[0].type === 'infer.error').map((entry) => entry[0]);
test('a worker lost mid-request: the request is re-issued to another idle device, the requester sees no error', () => {
  const h = trio();
  h.relay.handleFromChat(request('r1'), 5);
  const first = h.to(7, 'infer.request')[0];
  h.relay.handleFromWorker({ type: 'infer.accepted', requestId: first.requestId, state: 'running' }, 7);
  h.relay.workerDropped(7);
  assert.equal(errorsToChat(h).length, 0);
  const second = h.to(8, 'infer.request');
  assert.equal(second.length, 1);
  assert.notEqual(second[0].requestId, first.requestId, 'a new hand-off id');
  assert.deepEqual(json(h.events.filter((e) => e[0] === 'end')), [['end', 'r1', 5, '', true]], 'the lost attempt closes its card');
  h.relay.handleFromWorker({ type: 'infer.done', requestId: second[0].requestId, lastSeq: 1, finishReason: 'stop' }, 8);
  assert.equal(h.sent.filter((entry) => entry[0].type === 'infer.done' && entry[0].requestId === 'r1').length, 1, 'the requester gets the answer under its own id');
});
test('a worker that cancels by itself is retried elsewhere; a requested cancel is not', () => {
  const h = trio();
  h.relay.handleFromChat(request('r1'), 5);
  const first = h.to(7, 'infer.request')[0];
  h.relay.handleFromWorker({ type: 'infer.error', requestId: first.requestId, code: 'CANCELLED', message: 'x', retryable: false }, 7);
  assert.equal(errorsToChat(h).length, 0);
  assert.equal(h.to(8, 'infer.request').length, 1);
  const b = trio();
  b.relay.handleFromChat(request('r2'), 5);
  const sent = b.to(7, 'infer.request')[0];
  b.relay.handleFromChat({ type: 'infer.cancel', version: 2, requestId: 'r2' }, 5);
  b.relay.handleFromWorker({ type: 'infer.error', requestId: sent.requestId, code: 'CANCELLED', message: 'x', retryable: false }, 7);
  assert.equal(errorsToChat(b).length, 1, 'cancel asked by the requester is reported, not retried');
  assert.equal(b.to(8, 'infer.request').length, 0);
});
test('no re-issue after output was delivered, without a ready untried device, or beyond the attempt limit', () => {
  const partial = trio();
  partial.relay.handleFromChat(request('p1'), 5);
  const sent = partial.to(7, 'infer.request')[0];
  partial.relay.handleFromWorker({ type: 'infer.delta', requestId: sent.requestId, seq: 1, text: 'abc' }, 7);
  partial.relay.workerDropped(7);
  assert.equal(errorsToChat(partial).length, 1);
  assert.equal(partial.to(8, 'infer.request').length, 0);
  const none = harness([self({ ready: false }), worker()]);
  none.relay.handleFromChat(request('n1'), 5);
  none.relay.workerDropped(7);
  assert.equal(errorsToChat(none).length, 1, 'only device is gone: the failure is reported as before');
  const many = harness([self({ memAvail: 1, inflight: 1 }), worker({ memAvail: 300 }), worker({ epoch: 8, label: 'b', memAvail: 200 }),
    worker({ epoch: 9, label: 'c', memAvail: 100 }), worker({ epoch: 10, label: 'd', memAvail: 50 })]);
  many.relay.handleFromChat(request('m1'), 5);
  many.relay.workerDropped(7);
  many.relay.workerDropped(8);
  many.relay.workerDropped(9);
  assert.equal(many.to(9, 'infer.request').length, 1);
  assert.equal(many.to(10, 'infer.request').length, 0, 'at most two re-issues');
  assert.equal(errorsToChat(many).length, 1);
});
test('a lost worker with the hub idle is re-issued on the hub itself', () => {
  const h = harness([self({ memAvail: 1 }), worker({ memAvail: 200 })]);
  h.relay.handleFromChat(request('h1'), 5);
  assert.equal(h.to(7, 'infer.request').length, 1);
  h.relay.workerDropped(7);
  assert.equal(errorsToChat(h).length, 0);
  assert.deepEqual(h.localHandled.map((e) => e[1]), ['h1']);
});
const speedModule = load('../cluster/DeviceSpeed.ets');
test('DeviceSpeed: smoothed ms per 1k chars; failed and tiny samples ignored', () => {
  const s = new speedModule.DeviceSpeed();
  assert.equal(s.cost(7), -1);
  s.record(7, 30000, 10000, false);
  assert.equal(s.cost(7), 3000);
  s.record(7, 100, 10, false);
  s.record(7, 90000, 10000, true);
  assert.equal(s.cost(7), 3000);
  s.record(7, 20000, 10000, false);
  assert.ok(s.cost(7) < 3000 && s.cost(7) > 2000, 'moves toward the new sample, not all the way');
});
test('pickIdle prefers the measured faster idle device, whichever it is', () => {
  const cost = (table) => (epoch) => table[epoch] === undefined ? -1 : table[epoch];
  assert.equal(pool.pickIdle([self({ memAvail: 900 }), worker({ memAvail: 1 })], -1, cost({ 0: 3000, 7: 1500 })).epoch, 7);
  assert.equal(pool.pickIdle([self({ memAvail: 1 }), worker({ memAvail: 900 })], -1, cost({ 0: 1500, 7: 3000 })).epoch, 0);
  assert.equal(pool.pickIdle([self(), worker({ inflight: 1 })], -1, cost({ 0: 3000, 7: 1500 })).epoch, 0, 'a slower device still works while the faster one is busy');
  assert.equal(pool.pickIdle([self(), worker()], -1, cost({ 0: 1500 })).epoch, 7, 'unmeasured devices are tried so they get measured');
  assert.equal(pool.pickIdle([self({ memAvail: 10 }), worker({ memAvail: 20 })], -1, cost({ 0: 1000, 7: 1100 })).epoch, 7, 'near-equal speed falls back to memory');
  assert.equal(pool.pickIdle([self(), worker()], -1, cost({ 0: 1000, 7: 1100 })).isSelf, true, 'then to the hub');
});
test('relay uses the supplied speed table for placement and for re-issue', () => {
  const h = harness([self({ memAvail: 900 }), worker({ memAvail: 1 })]);
  h.relay.setSpeed((epoch) => epoch === 7 ? 1000 : 2500);
  h.relay.handleFromChat(request('s1'), 5);
  assert.equal(h.to(7, 'infer.request').length, 1);
  assert.equal(h.localHandled.length, 0);
  const r = trio(false);
  r.relay.setSpeed((epoch) => ({ 0: 3000, 7: 1000, 8: 1500 })[epoch]);
  r.relay.handleFromChat(request('s2'), 5);
  r.relay.workerDropped(7);
  assert.equal(r.to(8, 'infer.request').length, 1, 're-issue goes to the faster remaining device, not the slower hub');
});
(async () => {
  let pass = 0;
  for (const [name, fn] of tests) {
    try { await fn(); pass++; console.log('PASS ' + name); } catch (error) { console.error('FAIL ' + name, error); process.exitCode = 1; }
  }
  console.log(pass + '/' + tests.length + ' relay/pool tests passed');
})();
