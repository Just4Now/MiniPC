// node IndexFocus.test.cjs [path/to/typescript/lib/typescript.js]
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const { transpile, transpileSource } = require('../../../../../../tests/harness.cjs');
const flush = async () => { for (let i = 0; i < 12; i++) await Promise.resolve(); };
function loadEts(file, requires = {}) {
  const box = { exports: {}, Error, Map, Math, Number, Date, Promise, JSON, require: name => requires[name] || {} };
  vm.runInNewContext(transpile(file), box);
  return box.exports;
}
function deferred() { let resolve; const promise = new Promise(done => { resolve = done; }); return { promise, resolve }; }
function setup(isServer) {
  let connected = false, operation = 0, connections = 0, disconnects = 0, checks = 0;
  const events = [], sent = [];
  const behavior = { devices: [{ deviceId: 'stable', networkId: 'current', deviceName: '模型手机' }],
    check: async () => '', connect: async () => { connected = true; }, wait: async () => connected };
  const channel = {
    isConnected: () => connected, isConnecting: () => false, operation: () => operation,
    devices: async () => behavior.devices,
    computeDevices: async () => behavior.devices,
    hasComputeHits: () => !!behavior.hits,
    connectToAdvertisers: async () => { connections++; await behavior.connect(); },
    connect: async (id, expected) => { assert.equal(id, 'current'); assert.equal(expected, operation); connections++; await behavior.connect(); },
    waitUntilConnected: () => behavior.wait(), checkService: () => { checks++; return behavior.check(); },
    connectedCount: () => connected ? 1 : 0, hasEpoch: () => connected, peerInfos: () => [],
    peerRole: () => '', connectOtherComputes: async () => { behavior.meshCalls = (behavior.meshCalls || 0) + 1; },
    setActiveJobs: count => { behavior.activeJobs = count; },
    localName: () => '算力设备',
    localUid: () => 'self-uid',
    isListening: () => !!behavior.listening, prepare: async () => { behavior.listening = true; },
    selfLabel: () => '算力设备1',
    selfComputeNumber: () => 1,
    applyRemoteRoster() { return true; },
    setSelfMem() {}, setPeerMem() {}, setRemoteChats(names) { behavior.remoteChats = names.slice(); },
    disconnect: () => { disconnects++; operation++; connected = false; behavior.listening = false; },
    getStatus: () => connected ? '近场已连接' : '未连接',
    send: async message => { sent.push(message); return true; }
  };
  const context = { exports: {}, Error, Map, Math, Number, Date, Promise, JSON, setInterval() { return 1; }, clearInterval() {},
    require(name) {
    if (name === '@kit.ArkWeb') return { webview: { WebviewController: class {
      async runJavaScript(script) { events.push(JSON.parse(script.slice('window.onNativeEvent('.length, -1))); }
    } } };
    if (name === '@kit.ArkTS') return { util: { generateRandomUUID: () => 'request-1' } };
    if (name === '@kit.PerformanceAnalysisKit') return { hilog: { info() {}, warn() {} } };
    if (name === '../nearby/LinkEnhanceChannel') {
      return { nearbyChannel: channel };
    }
    if (name === '../nearby/NearbyConfig') return { IS_SERVER: !!isServer };
    if (name === '../llm/LocalChat') return { LocalChat: class {} };
    if (name === '../llm/LlmTransport') return { LocalLlmTransport: class {
      constructor(chat) { this.chat = chat; }
      start(messages, cb, id) { return this.chat.start(messages, cb, id); }
      cancel(id) { this.chat.cancel(id); }
      readinessError() { return this.chat.readinessError(); }
    } };
    if (name === '../cluster/DeviceSpeed') {
      return loadEts(__dirname + '/../cluster/DeviceSpeed.ets');
    }
    if (name === '../cluster/ComputeRouter') {
      return loadEts(__dirname + '/../cluster/ComputeRouter.ets');
    }
    if (name === '../cluster/DeviceLabels') {
      return loadEts(__dirname + '/../cluster/DeviceLabels.ets');
    }
    if (name === '../ui/ChatBridge') return loadEts(__dirname + '/../ui/ChatBridge.ets');
    if (name === '../ui/InferencePresentation') return loadEts(__dirname + '/../ui/InferencePresentation.ets');
    if (name === '../ui/TaskDisplayRelay') return loadEts(__dirname + '/../ui/TaskDisplayRelay.ets');
    if (name === '../ui/InferenceTaskObserver') return loadEts(__dirname + '/../ui/InferenceTaskObserver.ets', {
      './InferencePresentation': loadEts(__dirname + '/../ui/InferencePresentation.ets')
    });
    if (name === '../ui/TaskBoard') return loadEts(__dirname + '/../ui/TaskBoard.ets', {
      '../protocol/ChatProtocol': loadEts(__dirname + '/../protocol/ChatProtocol.ets')
    });
    if (name === '../ui/CollaborationScreen') return loadEts(__dirname + '/../ui/CollaborationScreen.ets');
    if (name === '../cluster/DeviceInfo') return {
      DEVICE_INFO_POLL_MS: 2000,
      applyDeviceInfo(target, message) {
        if (typeof message.name === 'string' && message.name.length > 0) target.name = message.name;
        if (typeof message.memTotal === 'number') target.memTotal = message.memTotal;
        if (typeof message.memAvail === 'number') target.memAvail = message.memAvail;
        if (typeof message.memUsage === 'number') target.memUsage = message.memUsage;
        if (typeof message.thermalLevel === 'number') target.thermalLevel = message.thermalLevel;
        if (typeof message.batteryTemp === 'number') target.batteryTemp = message.batteryTemp;
        if (typeof message.cpuUsage === 'number') target.cpuUsage = message.cpuUsage;
        if (typeof message.model === 'string') target.model = message.model;
        if (typeof message.modelRequests === 'number') target.modelRequests = message.modelRequests;
      },
      buildSelfEntry(_dir, running) {
        return { name: '本机', id: 'self', role: 'self', model: 'Qwen2.5-7B-Instruct-Q4_N_0',
          modelRequests: running, memUsage: 10, memAvail: 1000, memTotal: 2000,
          thermalLevel: 2, batteryTemp: 42, cpuUsage: 18 };
      },
      deployedModelName: () => 'Qwen2.5-7B-Instruct-Q4_N_0',
      formatComputeStatus: () => 'Qwen',
      toDeviceInfoReply: (id, entry) => ({
        type: 'deviceInfo', requestId: id, name: entry.name, model: entry.model,
        memUsage: entry.memUsage, thermalLevel: entry.thermalLevel, batteryTemp: entry.batteryTemp,
        cpuUsage: entry.cpuUsage, modelRequests: entry.modelRequests, peerRole: 'compute'
      })
    };
    if (name === '../media/ImageAttach') return { pickJpegDataUrl: async () => '' };
    return {};
  } };
  let source = fs.readFileSync(__dirname + '/Index.ets', 'utf8');
  source = source.replace(/@Entry\s+@Component\s+struct Index/, 'export class Index');
  source = source.slice(0, source.indexOf('  build() {')) + '\n}';
  vm.runInNewContext(transpileSource(source), context);
  const page = new context.exports.Index(); page.pageReady = true;
  return { page, channel, behavior, events, sent, counts: () => ({ connections, disconnects, checks }), setConnected: value => { connected = value; } };
}
(async () => {
  const c = setup(), check = deferred(); c.behavior.check = () => check.promise;
  const preparing = c.page.ensureCollaborationReady();
  assert.equal(c.page.ensureCollaborationReady(), preparing);
  await flush(); assert.equal(c.counts().connections, 1); assert.equal(c.counts().checks, 1);
  assert(c.events.every(event => !event.available), 'link alone never enables send');
  assert(c.page.send('保留草稿').includes('尚未准备')); assert.equal(c.sent.length, 0);
  assert.equal(c.page.history.length, 0); assert.equal(c.page.activeId, '');
  check.resolve(''); await preparing;
  assert.equal(c.page.serviceReady, true); assert(c.events.at(-1).available);
  await c.page.ensureCollaborationReady();
  assert.deepEqual(c.counts(), { connections: 1, disconnects: 0, checks: 1 }, 'prepared focus reuses session');
  assert.equal(c.page.send('真实问题'), ''); await flush();
  assert.equal(c.sent.length, 1); assert.equal(c.sent[0].type, 'request');
  assert.equal(c.sent[0].messages[0].content, '真实问题');
  for (const error of ['模型忙', '模型文件缺失']) {
    const f = setup(); f.behavior.check = async () => error;
    await f.page.ensureCollaborationReady(); assert.equal(f.page.serviceReady, false);
    assert.equal(f.page.connectionError, error); assert.equal(f.page.activeId, ''); assert.equal(f.sent.length, 0);
    f.behavior.check = async () => ''; await f.page.ensureCollaborationReady();
    assert.equal(f.page.serviceReady, true); assert.equal(f.counts().connections, 1);
    assert.equal(f.counts().disconnects, 0); assert.equal(f.counts().checks, 2);
  }
  const offline = setup(); offline.behavior.devices = [];
  await offline.page.ensureCollaborationReady(); assert(offline.page.connectionError.includes('未发现'));
  assert.equal(offline.sent.length, 0); assert.equal(offline.page.serviceReady, false);
  offline.behavior.devices = [{ deviceId: 'stable', networkId: 'current', deviceName: '模型手机' }];
  await offline.page.ensureCollaborationReady(); assert(offline.page.serviceReady);
  const unnamed = setup(); unnamed.behavior.devices = []; unnamed.behavior.hits = true;
  await unnamed.page.ensureCollaborationReady(); assert(unnamed.page.serviceReady);
  assert.equal(unnamed.counts().connections, 1);
  const stale = setup(), pending = deferred(); stale.behavior.check = () => pending.promise;
  const old = stale.page.ensureCollaborationReady(); await flush();
  stale.channel.disconnect(); pending.resolve(''); await old;
  assert.equal(stale.page.serviceReady, false); assert(stale.events.every(event => !event.available));
  stale.behavior.check = async () => ''; await stale.page.ensureCollaborationReady(); assert(stale.page.serviceReady);
  const hidden = setup(), delayed = deferred(); hidden.behavior.check = () => delayed.promise;
  const hiddenWork = hidden.page.ensureCollaborationReady(); await flush(); hidden.page.pageReady = false;
  delayed.resolve(''); await hiddenWork; assert.equal(hidden.page.serviceReady, false);
  console.log('PASS: focus preparation coalescing, prepared reuse, business-ready send gate, busy/missing/offline retry, stale/hidden result rejection, actual send only after readiness');
})().catch(error => { console.error(error); process.exitCode = 1; });
// Execute the actual HTML event handlers with a small DOM stub.
{
  const makeElement = () => {
    const el = { handlers: {}, value: '', textContent: '', innerHTML: '', style: {}, attrs: {}, classList: { add() {}, remove() {}, toggle() {} },
      addEventListener(type, fn) { this.handlers[type] = fn; },
      setAttribute(k, v) { this.attrs[k] = v; },
      getAttribute(k) { return this.attrs[k]; },
      appendChild() {}, blur() {} };
    return el;
  };
  const elements = Object.fromEntries(['history', 'prompt', 'send', 'connect', 'composer', 'connection',
    'stats', 'devices', 'pick', 'preview', 'previewImg', 'previewClear', 'clearTasks', 'title'].map(id => [id, makeElement()]));
  const document = { handlers: {}, getElementById: id => elements[id], createElement: makeElement,
    addEventListener(type, fn) { this.handlers[type] = fn; } };
  let preparations = 0;
  const window = { chatBridge: { prepare() { preparations++; }, connect() {}, send() { return '协同尚未准备完成'; } } };
  const html = fs.readFileSync(__dirname + '/../../resources/rawfile/peer-chat.html', 'utf8');
  vm.runInNewContext(html.match(/<script>([\s\S]*?)<\/script>/)[1], { document, window, Date });
  elements.prompt.handlers.pointerdown(); elements.prompt.handlers.focus();
  assert.equal(preparations, 1, 'pointer and resulting focus only prepare once');
  elements.prompt.handlers.focus(); assert.equal(preparations, 1, 'automatic restored focus never retries');
  elements.prompt.handlers.pointerdown(); assert.equal(preparations, 2, 'explicit repeated click retries');
  document.handlers.keydown({ key: 'Tab' }); elements.prompt.handlers.focus();
  assert.equal(preparations, 3, 'explicit keyboard focus prepares');
  elements.prompt.value = '保留草稿';
  window.onNativeEvent({ kind: 'connection', available: false }); assert.equal(elements.send.disabled, true);
  elements.composer.handlers.submit({ preventDefault() {} });
  assert.equal(elements.prompt.value, '保留草稿', 'native readiness rejection preserves draft');
  window.onNativeEvent({ kind: 'connection', available: true }); assert.equal(elements.send.disabled, false);
  window.onNativeEvent({ kind: 'remote-start', text: '远端问题', requestId: 'r1' });
  assert.equal(elements.send.disabled, false, 'remote stream must not lock composer');
  assert.equal(elements.send.getAttribute('aria-label'), '发送');
  let picked = 0, sent = '';
  window.chatBridge.pickImage = () => { picked++; };
  window.chatBridge.send = (text) => { sent = text; return ''; };
  elements.pick.handlers.click();
  assert.equal(picked, 1);
  window.onNativeEvent({ kind: 'image', text: 'data:image/jpeg;base64,xx' });
  elements.prompt.value = '';
  assert.equal(elements.send.disabled, false, 'image alone enables send');
  elements.composer.handlers.submit({ preventDefault() {} });
  assert.equal(sent, '请描述这张图片。');
  window.onNativeEvent({
    kind: 'dashboard', running: 2, jobs: [], selfLabel: '算力设备2',
    devices: [
      { role: 'self', name: '算力设备2', ready: true, jobs: 2, memUsage: 41,
        thermalLevel: 2, batteryTemp: 42, cpuUsage: 18, model: 'Qwen2.5-7B-Instruct' },
      { role: 'chat', name: '聊天设备1', ready: true, jobs: 1 }
    ]
  });
  assert.equal(elements.title.textContent, '算力设备2');
  assert(elements.devices.innerHTML.includes('算力设备2'));
  const localAt = elements.devices.innerHTML.indexOf('class="tag local">本机');
  const statusAt = elements.devices.innerHTML.indexOf('>推理中<');
  assert(localAt > elements.devices.innerHTML.indexOf('算力设备2') && statusAt > localAt,
    '本机 is a chip between the device name and the status');
  assert.equal(elements.devices.innerHTML.split('tag local').length - 1, 1, 'only this device is marked 本机');
  assert(elements.devices.innerHTML.includes('推理 2'), 'compute card shows running job count');
  window.onNativeEvent({
    kind: 'dashboard', running: 1, jobs: [], selfLabel: '算力设备1',
    devices: [
      { role: 'self', name: '算力设备1', ready: true, jobs: 1, memUsage: 41,
        thermalLevel: 2, batteryTemp: 42, cpuUsage: 18, modelRequests: 2, model: 'Qwen2.5-7B-Instruct' }
    ]
  });
  assert(elements.devices.innerHTML.includes('推理 1'), 'card uses jobs, not sampled+inflight');
  assert(!elements.devices.innerHTML.includes('推理 2'), 'inflated modelRequests must not double the badge');
  assert(elements.devices.innerHTML.includes('内存'), 'compute card still shows memory');
  assert(elements.devices.innerHTML.includes('42℃ · 温热'), 'compute card shows battery temp and thermal gear');
  assert(elements.devices.innerHTML.includes('class="heat"'), 'heat sits on the model row');
  assert(elements.devices.innerHTML.includes('class="bar cpu"'), 'CPU uses the same meter as memory');
  assert(elements.devices.innerHTML.includes('width:18%'), 'CPU meter fills to occupancy');
  window.onNativeEvent({ kind: 'dashboard', running: 1, selfLabel: '算力设备1', devices: [], jobs: [{
    id: 'time-1', key: '0:time-1', source: '算力设备1', origin: '聊天设备1', question: '时间测试', answer: '',
    chars: 0, startedAt: new Date(2026, 8, 21, 10, 30, 45).getTime(), firstAt: 0, endedAt: 0,
    running: true, error: false, elapsedMs: 1200
  }] });
  assert(elements.history.innerHTML.includes('创建 09-21 10:30:45'), 'task card shows its creation time');
  // A streaming reply patches its own card immediately, instead of waiting up to five
  // seconds for the next dashboard poll.
  window.onNativeEvent({ kind: 'text', requestId: 'time-1', text: '流式第一段' });
  assert(!elements.history.innerHTML.includes('流式第一段'), 'model output stays in details rather than the task list');
  window.onNativeEvent({ kind: 'done', requestId: 'time-1', text: '流式完成', error: false });
  assert(!elements.history.innerHTML.includes('流式完成'), 'final output stays in details');
  assert(!elements.history.innerHTML.includes('进行中'), 'the card leaves the running state');
  window.onNativeEvent({ kind: 'text', requestId: 'not-on-the-board', text: '无关文本' });
  assert(!elements.history.innerHTML.includes('无关文本'), 'an event for an unknown job patches nothing');
  window.onNativeEvent({
    kind: 'dashboard', running: 0, jobs: [], selfLabel: '算力设备',
    devices: [{ role: 'self', name: '算力设备', ready: true, jobs: 0 }]
  });
  assert.equal(elements.title.textContent, '算力设备1', 'numbered title must not fall back to bare 算力设备');
  assert(!elements.devices.innerHTML.includes('聊天设备2'), 'chat slots must not fall back to list index');
  console.log('PASS: HTML pointer/focus dedup, automatic focus no retry, explicit click/Tab retries, send availability and draft preservation');
}

{
  const s = setup(true);
  const callbacks = new Map();
  s.page.model = {
    start(messages, cb, id) {
      callbacks.set(id, cb);
      return '';
    },
    isBusy() { return callbacks.size > 0; },
    activeCount() { return callbacks.size; },
    readinessError() { return ''; },
    cancel(id) {
      const cb = callbacks.get(id);
      if (!cb) return;
      callbacks.delete(id);
      cb({ kind: 'done', text: '已停止生成', finishReason: 'cancelled' });
    }
  };
  s.page.pageReady = true;
  s.page.receive({ type: 'prepare', requestId: 'p1' }, 1);
  assert.equal(s.sent.find(item => item.type === 'prepared').error, undefined);
  assert.equal(s.sent.filter(item => item.type === 'deviceInfo').length, 1);
  s.page.receive({ type: 'request', requestId: 'r1', messages: [{ role: 'user', content: 'A' }] }, 1);
  s.page.receive({ type: 'request', requestId: 'r2', messages: [{ role: 'user', content: 'B' }] }, 2);
  assert.equal(s.page.jobs.length, 2);
  assert.equal(s.page.jobs[0].source, '算力设备1');
  assert.equal(s.page.jobs[0].origin.indexOf('聊天设备') >= 0 || s.page.jobs[0].origin.length > 0, true);
  s.page.receive({ type: 'prepare', requestId: 'p2' }, 2);
  const prepared = s.sent.filter(item => item.type === 'prepared');
  assert.equal(prepared.at(-1).error, undefined, 'prepare stays ready while two jobs run');
  s.page.receive({ type: 'request', requestId: 'r3', messages: [{ role: 'user', content: 'C' }] }, 1);
  assert.equal(s.page.jobs.length, 3, 'third peer job is accepted without a fixed cap');
  assert.notEqual(s.sent.at(-1).type, 'error');
  s.channel.hasEpoch = epoch => epoch === 2;
  s.page.connectionChanged(true, 1);
  assert.equal(s.page.jobs.length, 1);
  assert.equal(s.page.jobs[0].id, 'r2');
  console.log('PASS: three peer jobs in parallel, prepare not gated, disconnect cancels only that epoch');
}

{
  const s = setup(true);
  s.page.model = {
    start() { return ''; },
    readinessError() { return ''; },
    cancel() {},
    activeCount() { return 0; }
  };
  s.page.pageReady = true;
  s.channel.peerInfos = () => [{ epoch: 7, peerId: 'aa:bb', ready: true, role: 'compute', name: '算力设备2' }];
  s.page.peerStats.set(7, { model: 'Qwen2.5-7B-Instruct-Q4_N_0', modelRequests: 0, memAvail: 8000 });
  s.page.receive({ type: 'request', requestId: 'r1', messages: [{ role: 'user', content: 'A' }] }, 1);
  assert.equal(s.sent.at(-1).type, 'request');
  assert.equal(s.sent.at(-1).sched, true);
  assert.equal(s.sent.at(-1).origin, '聊天设备', 'forwarded work carries the public chat origin');
  // The worker only ever sees the forwarded id, and echoes it back verbatim.
  const forwardId = s.sent.at(-1).requestId;
  assert.equal(forwardId === 'r1', false, 'the wire carries a hand-off id, not the client id');
  assert.equal(s.page.jobs[0].workerEpoch, 7);
  assert.equal(s.page.jobs[0].source, '算力设备2');
  s.page.receive({ type: 'request', requestId: 'r2', messages: [{ role: 'user', content: 'B' }],
    sched: true, origin: '聊天设备3' }, 7);
  assert.equal(s.page.jobs.find(job => job.id === 'r2').workerEpoch, 0, 'sched request stays local');
  assert.equal(s.page.jobs.find(job => job.id === 'r2').origin, '聊天设备3');
  s.page.emitDashboard();
  const board = s.events.filter(event => event.kind === 'dashboard').at(-1);
  assert.equal(board.devices.find(device => device.role === 'self').jobs, 1);
  assert.equal(board.devices.find(device => device.role === 'self').batteryTemp, 42);
  assert.equal(board.devices.find(device => device.role === 'self').cpuUsage, 18);
  assert.equal(board.devices.find(device => device.role === 'compute').jobs, 1,
    'the coordinator counts only work actually dispatched to that compute');
  assert.equal(board.running, 1, 'the task rail count includes only work executed by this compute');
  assert.equal(board.jobs.length, 1, 'a coordinator-only hand-off is hidden from this compute task rail');
  assert.equal(board.jobs[0].id, 'r2', 'the locally executed forwarded request remains visible');
  s.page.receive({ type: 'delta', requestId: forwardId, text: 'hi' }, 7);
  assert.equal(s.sent.at(-1).type, 'delta');
  assert.equal(s.sent.at(-1).text, 'hi');
  assert.equal(s.sent.at(-1).requestId, 'r1', 'the origin gets its own id back, not the forwarded one');
  s.page.receive({ type: 'done', requestId: forwardId, finishReason: 'stop' }, 7);
  assert.equal(s.sent.at(-1).type, 'done');
  assert.equal(s.sent.at(-1).source, '由算力设备2推理');
  s.page.receive({ type: 'deviceInfo', requestId: 'info-7', model: 'Qwen', memUsage: 41,
    thermalLevel: 3, batteryTemp: 45.5, cpuUsage: 67, modelRequests: 1, memAvail: 7000 }, 7);
  assert.equal(s.page.peerStats.get(7).memUsage, 41);
  assert.equal(s.page.peerStats.get(7).thermalLevel, 3);
  assert.equal(s.page.peerStats.get(7).batteryTemp, 45.5);
  assert.equal(s.page.peerStats.get(7).cpuUsage, 67);
  s.page.emitDashboard();
  const loadBoard = s.events.filter(event => event.kind === 'dashboard').at(-1);
  assert.equal(loadBoard.devices.find(device => device.role === 'compute').thermalLevel, 3);
  assert.equal(loadBoard.devices.find(device => device.role === 'compute').cpuUsage, 67);
  s.page.receive({ type: 'deviceInfo', requestId: 'q1' }, 1);
  assert.equal(s.sent.at(-1).type, 'deviceInfo');
  assert.equal(s.sent.at(-1).model, 'Qwen2.5-7B-Instruct-Q4_N_0');
  console.log('PASS: schedule to idle compute, sched stays local, worker reply remapped, deviceInfo poll/reply');
}

{
  const follower = setup(true);
  follower.channel.selfComputeNumber = () => 2;
  follower.page.model = { start() { throw new Error('a follower must not coordinate'); }, activeCount() { return 0; } };
  follower.page.receive({ type: 'request', requestId: 'not-hub',
    messages: [{ role: 'user', content: 'A' }] }, 1);
  assert.equal(follower.sent.at(-1).type, 'error');
  assert(follower.sent.at(-1).error.includes('算力设备1'));
  assert.equal(follower.page.jobs.length, 0);
}

{
  const worker = setup(true);
  worker.page.pageReady = true;
  worker.page.model = { start() { return ''; }, readinessError() { return ''; }, cancel() {}, activeCount() { return 1; } };
  worker.channel.peerInfos = () => [{ epoch: 7, peerId: 'coordinator', ready: true, role: 'compute',
    name: '算力设备2', deviceUid: 'compute-2' }];
  worker.page.receive({ type: 'request', requestId: 'forwarded', messages: [{ role: 'user', content: 'A' }],
    sched: true, origin: '聊天设备1' }, 7);
  worker.page.emitDashboard();
  const board = worker.events.filter(event => event.kind === 'dashboard').at(-1);
  assert.equal(board.devices.find(device => device.role === 'self').jobs, 1);
  assert.equal(board.devices.find(device => device.role === 'compute').jobs, 0,
    'an upstream coordinator is not an inference worker');
  assert.equal(board.jobs[0].origin, '聊天设备1');
  assert.equal(board.jobs[0].source, '算力设备1');

  const ghost = setup(true);
  ghost.page.pageReady = true;
  ghost.page.serviceReady = true;
  ghost.channel.selfComputeNumber = () => 2;
  ghost.channel.peerInfos = () => [{ epoch: 7, peerId: 'compute-2', ready: true, role: 'compute',
    name: '算力设备1', helloName: '算力设备1', deviceUid: 'compute-2', slot: 1 }];
  ghost.channel.hasEpoch = epoch => epoch === 7;
  ghost.page.remoteSeen.set(7, [{ id: 'chat-live', name: '聊天A', role: 'chat' }]);
  ghost.page.remoteSeen.set(8, [{ id: 'chat-gone', name: '聊天B', role: 'chat' }]);
  ghost.page.cancelDroppedPeers();
  assert.equal(Array.from(ghost.behavior.remoteChats).join(','), '聊天A',
    'a disconnected reporter cannot keep a chat online');
  ghost.page.pollDeviceInfo();
  assert.equal(ghost.sent.filter(message => message.type === 'deviceInfoSync').length, 0,
    'a worker must not publish its incomplete star view as a global roster');
  assert.equal(ghost.page.remoteEntries().length, 1, 'a worker sees its live hub roster');
  ghost.channel.selfComputeNumber = () => 1;
  assert.equal(ghost.page.remoteEntries().length, 0,
    'promotion immediately hides old indirect chats before the next roster arrives');
  ghost.page.handleClusterSync({ devices: [{ id: 'old-chat', role: 'chat', name: '聊天设备1' }] }, 7);
  assert.equal(ghost.page.remoteSeen.has(7), false, 'a hub cannot import another reporter chat slot');

  const quiet = setup(true);
  quiet.page.serviceReady = true;
  quiet.channel.peerInfos = () => [
    { epoch: 1, peerId: 'chat', name: '聊天设备1', helloName: '聊天设备1', ready: true, role: 'chat', slot: 1 },
    { epoch: 2, peerId: 'worker', name: '算力设备2', helloName: '算力设备2', ready: true, role: 'compute', slot: 2 }
  ];
  quiet.page.pollDeviceInfo();
  assert.equal(quiet.sent.filter(message => message.type === 'deviceInfoSync').length, 1,
    'only the compute worker, not the chat link, receives the multi-frame roster');
  quiet.page.pollDeviceInfo();
  assert.equal(quiet.sent.filter(message => message.type === 'deviceInfoSync').length, 1,
    'a two-second status poll does not resend an unchanged full roster');
  quiet.channel.peerInfos = () => [
    { epoch: 1, peerId: 'chat', name: '聊天设备1', helloName: '聊天设备1', ready: true, role: 'chat', slot: 1 },
    { epoch: 3, peerId: 'chat-new', name: '聊天设备2', helloName: '聊天设备2', ready: true, role: 'chat', slot: 2 },
    { epoch: 2, peerId: 'worker', name: '算力设备2', helloName: '算力设备2', ready: true, role: 'compute', slot: 2 }
  ];
  quiet.page.pollDeviceInfo();
  assert.equal(quiet.sent.filter(message => message.type === 'deviceInfoSync').length, 2,
    'joining or leaving devices triggers immediate roster publication');
  quiet.sent.length = 0;
  quiet.page.emitDashboard = () => {};
  quiet.page.jobs.push({ id: 'busy', workerEpoch: 0 });
  quiet.page.pollDeviceInfo();
  assert.equal(quiet.sent.length, 1, 'busy polling publishes only a small load status');
  assert.equal(quiet.sent[0].modelRequests, 1);assert.equal(quiet.sent[0].type, 'deviceInfo');
  assert.equal(quiet.sent[0].memUsage, undefined);

  const order = setup(true);
  order.page.pageReady = true;
  order.channel.peerInfos = () => [
    { epoch: 4, peerId: 'chat-2', deviceUid: 'chat-2', ready: true, role: 'chat', name: '聊天设备2' },
    { epoch: 2, peerId: 'compute-2', deviceUid: 'compute-2', ready: true, role: 'compute', name: '算力设备2' },
    { epoch: 3, peerId: 'chat-1', deviceUid: 'chat-1', ready: true, role: 'chat', name: '聊天设备1' }
  ];
  order.page.emitDashboard();
  const ordered = order.events.filter(event => event.kind === 'dashboard').at(-1).devices.map(device => device.name);
  assert.equal(Array.from(ordered).join(','), '算力设备1,算力设备2,聊天设备1,聊天设备2',
    'compute devices precede chat devices and both groups are sorted by slot');
  console.log('PASS: worker-only inference counts, forwarded chat origin and disconnected roster cleanup');
}

(async () => {
  const s = setup(true);
  s.page.pageReady = true;
  s.page.serviceReady = true;
  s.page.connectNearby();
  assert.equal(s.page.serviceReady, false, 'stop near-field even with no connected peer');
  assert.equal(s.counts().disconnects, 1);
  assert.equal(s.page.autoConnect, false);
  const labels = s.events.map(event => event.connectLabel).filter(Boolean);
  assert.equal(labels.at(-1), '启用近场');
  s.page.connectNearby();
  await flush();
  assert.equal(s.page.serviceReady, true, 'second click starts near-field again');
  assert.equal(s.behavior.meshCalls, 1, 're-enabling near-field restarts compute mesh discovery');
  console.log('PASS: idle compute stop/start near-field toggles without a connected chat phone');
})().catch(error => { console.error(error); process.exitCode = 1; });

(async () => {
  const s = setup(true);
  s.page.serviceReady = true;
  s.page.emitDashboard = () => {};
  let peers = [{ epoch: 2, peerId: 'worker', deviceUid: 'worker', ready: true, role: 'compute', slot: 2 }];
  s.channel.peerInfos = () => peers;
  s.channel.hasEpoch = epoch => peers.some(p => p.epoch === epoch);
  const deliveries = [];
  s.channel.send = (message, epoch) => {
    if (message.type !== 'deviceInfoSync') return Promise.resolve(true);
    const gate = deferred(); deliveries.push({ message, epoch, gate }); return gate.promise;
  };
  s.page.jobs.push({ id: 'busy', workerEpoch: 0 });
  s.page.pollDeviceInfo();
  assert.equal(deliveries.length, 1, 'new worker gets membership even during inference');
  assert(deliveries[0].message.devices.every(d => d.memAvail === undefined && d.name === undefined),
    'busy control snapshots omit telemetry and duplicated names');
  s.page.pollDeviceInfo();
  assert.equal(deliveries.length, 1, 'unchanged pending snapshot is not flooded');
  deliveries[0].gate.resolve(false); await flush();
  s.page.pollDeviceInfo();
  assert.equal(deliveries.length, 2, 'failed delivery retries on the next poll, not after 30 seconds');
  peers = [...peers, { epoch: 3, peerId: 'third', deviceUid: 'third', ready: true, role: 'compute', slot: 3 }];
  s.page.pollDeviceInfo();
  assert.equal(deliveries.length, 4, 'topology change reaches both existing and new workers');
  assert.equal(deliveries.at(-1).message.devices.map(d => d.slot).join(','), '1,2,3');
  deliveries[2].gate.resolve(true); deliveries[3].gate.resolve(true); await flush();
  deliveries[1].gate.resolve(false); await flush();
  s.page.pollDeviceInfo();
  assert.equal(deliveries.length, 4, 'old completion cannot invalidate the newest snapshot');
  peers = peers.map(p => p.epoch === 3 ? { ...p, epoch: 30 } : p);
  s.page.cancelDroppedPeers();
  s.page.pollDeviceInfo();
  assert.equal(deliveries.length, 5, 'same UID reconnecting on a new session must receive unchanged roster');
  assert.equal(deliveries.at(-1).epoch, 30);
  assert.equal(s.page.rosterDeliveries.has(3), false, 'dead session delivery state is removed');
  s.channel.selfComputeNumber = () => 3;
  peers = [{ epoch: 1, peerId: 'hub', ready: true, role: 'compute', slot: 1 }];
  const accepted = [{ id: 'known', role: 'compute', slot: 2 }];
  s.page.remoteSeen.set(1, accepted);
  s.channel.applyRemoteRoster = () => false;
  s.page.handleClusterSync({ devices: [{ id: 'forged', role: 'compute', slot: 2 }] }, 1);
  assert.equal(s.page.remoteSeen.get(1), accepted, 'rejected membership cannot pollute the dashboard cache');
  console.log('PASS: busy multi-node membership, per-session retry and stale completion isolation');
})().catch(error => { console.error(error); process.exitCode = 1; });

// Lightweight load changes remain visible during inference, and a chat link dropping is
// reported rather than left as a silent gap the compute side cannot repair itself.
{
  const s = setup(true);
  s.page.pageReady = true;
  s.page.serviceReady = true;
  s.channel.peerInfos = () => [
    { epoch: 2, peerId: 'worker', deviceUid: 'worker', ready: true, role: 'compute', name: '算力设备2', slot: 2 },
    { epoch: 1, peerId: 'chat', deviceUid: 'chat', ready: true, role: 'chat', name: '聊天设备1', slot: 1 }
  ];
  // A chat request lands while the hub has a local job: publish the count now.
  s.page.jobs.push({ id: 'busy', key: '0:busy', epoch: 0, peer: false, workerEpoch: 0,
    answer: '', question: 'q', startedAt: 0, firstAt: 0, endedAt: 0, error: false, source: '', origin: '本机', image: '' });
  s.page.lastPublishedRunning = 0;
  s.sent.length = 0;
  s.page.emitDashboard();
  assert.equal(s.sent.filter(m => m.type === 'deviceInfo' && String(m.requestId).indexOf('load-') === 0).length, 1);
  assert.equal(s.sent[0].modelRequests, 1);assert.equal(s.sent[0].memUsage, undefined);
  assert.equal(s.page.lastPublishedRunning, 1);
  s.page.jobs.length = 0;
  s.page.emitDashboard();
  const pushed = s.sent.filter(m => m.type === 'deviceInfo' && String(m.requestId).indexOf('load-') === 0);
  assert.equal(pushed.length, 2, 'start and completion both publish load changes');
  assert.equal(pushed[1].modelRequests, 0);

  // A chat phone disappearing cannot be re-dialled from here.
  const t = setup(true);
  t.page.pageReady = true;
  t.page.serviceReady = true;
  t.channel.connectedCount = () => 0;
  t.channel.hasEpoch = () => false;
  t.page.connectionChanged(false, 6);
  const status = t.events.filter(e => e.kind === 'connection').at(-1);
  assert(status.text.includes('等待它自动重连'), 'a lost chat link says who has to re-dial: ' + status.text);
  console.log('PASS: small start/stop load pushes during inference; a lost chat link is reported as the chat side\'s to re-dial');
}

{
  const hub=setup(true),worker=setup(true);
  hub.page.serviceReady=true;worker.page.serviceReady=true;worker.channel.selfComputeNumber=()=>2;worker.channel.selfLabel=()=> '算力设备2';
  hub.channel.peerInfos=()=>[{epoch:7,peerId:'worker',deviceUid:'worker',ready:true,role:'compute',name:'算力设备2',slot:2}];
  worker.channel.peerInfos=()=>[{epoch:1,peerId:'hub',deviceUid:'hub',ready:true,role:'compute',name:'算力设备1',slot:1}];
  hub.page.showRelayTask('r',5,7,[{role:'user',content:'问题'}],'普通聊天');
  worker.page.showInferTask('forward',1,'问题','普通聊天');
  const busy=worker.sent.filter(m=>m.modelRequests===1).at(-1);assert(busy);
  hub.page.handleDeviceInfo(busy,7);
  const hd=hub.events.filter(e=>e.kind==='dashboard').at(-1),wd=worker.events.filter(e=>e.kind==='dashboard').at(-1);
  assert.equal(hd.running,0,'hub forwarding work is not local inference');
  assert.equal(hd.devices.find(d=>d.role==='self').jobs,0);assert.equal(hd.devices.find(d=>d.epoch===7).jobs,1);
  assert.equal(wd.running,1);assert.equal(wd.devices.find(d=>d.role==='self').jobs,1);
  worker.page.finishInferTask('forward',1,'答案',false);hub.page.completeJob('r',5,'答案',false);
  const stopped=worker.sent.filter(m=>m.requestId?.startsWith('load-')&&m.modelRequests===0).at(-1);assert(stopped);
  hub.page.handleDeviceInfo(stopped,7);
  assert.equal(hub.events.filter(e=>e.kind==='dashboard').at(-1).devices.find(d=>d.epoch===7).jobs,0);
  const before=hub.sent.length;hub.page.handleDeviceInfo({type:'deviceInfo',requestId:'count-only',modelRequests:0},7);
  assert.equal(hub.sent.length,before,'a count-only response must not trigger a response loop');
  console.log('PASS: actual hub/worker dashboard counts and load-only responses remain correct through a forwarded request');
}

// A split answered by the worker lets the hub observe a provisional parent before the chat's
// snapshot arrives. Publishing it locked the worker onto that parent: every later revision
// carried the chat's startedAt and was rejected, leaving 待分配/待执行 forever.
(async()=>{
  const tick=()=>new Promise(r=>setTimeout(r,5));
  const hub=setup(true), worker=setup(true), sent=[];
  hub.channel.peerInfos=()=>[{epoch:7,peerId:'chat1',role:'chat',ready:true,name:'聊天设备1'},{epoch:8,peerId:'worker2',role:'compute',ready:true,name:'算力设备2'}];
  worker.channel.selfComputeNumber=()=>2;worker.channel.selfLabel=()=> '算力设备2';
  worker.channel.peerInfos=()=>[{epoch:11,peerId:'hub1',role:'compute',ready:true,name:'算力设备1'}];
  hub.channel.send=async(message,epoch)=>{if(message.type==='infer.task'&&epoch===8){sent.push(message.task.revision);
    worker.page.receiveInference(JSON.parse(JSON.stringify(message)),11);}return true;};
  worker.page.inference={handle(message,epoch){worker.page.showInferTask(message.requestId,epoch,message.messages.at(-1).content,message.label||'')}};
  const question='查一下明天深圳到北京的高铁票，再查一下北京天气';
  let n=0;
  const forward=(sub,label,content)=>{const id='r'+(++n),messages=[{role:'user',content}];
    hub.page.taskLinks.set(hub.page.constructor.jobKey(7,id),{taskId:'T1',subtaskId:sub,origin:'聊天设备1',input:'[user]\n'+content});
    const message={type:'infer.request',version:2,requestId:'fw_'+id,messages,label,taskId:'T1',subtaskId:sub,origin:'聊天设备1'};
    hub.page.showRelayTask(id,7,8,messages,label);hub.page.forwardTaskDisplay(id,7,8,message);worker.page.receiveInference(message,11);
    return (answer)=>{worker.page.finishInferTask(message.requestId,11,answer,false);hub.page.completeJob(id,7,answer,false);};};
  const kids=(a,b)=>[{id:'s1',title:'高铁票',device:a[1],phase:a[0],detail:''},{id:'s2',title:'北京天气',device:b[1],phase:b[0],detail:''}];
  let revision=0;
  const snap=(phase,a,b,extra={})=>hub.page.receiveInference({type:'infer.task',requestId:'T1',task:{id:'T1',title:question,phase,
    revision:++revision,startedAt:1000,endedAt:0,answer:'',subtasks:kids(a,b),...extra}},7);
  forward('plan','任务拆分','## User request\n'+question)('[{"title":"高铁票","task":"查询明天深圳到北京的高铁票"},{"title":"北京天气","task":"查询北京天气"}]');
  await tick();
  assert.equal(hub.page.taskViews().length,1,'the hub still shows its provisional parent locally');
  assert.deepEqual(sent,[],'a provisional parent is never published to workers');
  snap('running',['queued',''],['queued',''],{});await tick();
  const child=forward('s1','子任务 1/2','User task:\n查询明天深圳到北京的高铁票');await tick();
  snap('running',['running','算力设备2'],['running','算力设备1']);await tick();
  child('Final: G302');await tick();
  snap('done',['done','算力设备2'],['done','算力设备1'],{endedAt:5000,answer:'汇总'});await tick();
  const shown=worker.page.taskBoard.views();
  assert.equal(shown.length,1);
  assert.equal(shown[0].phase,'done','the worker follows the chat snapshot to its final state: '+sent.join(','));
  assert.equal(shown[0].subtasks[0].device,'算力设备2');
  console.log('PASS: worker-run split -> provisional hub parent stays local -> worker follows chat snapshots to done');
})();

// Native display integration: parent ownership is distinct from actual child worker.
{
  const s=setup(true);
  s.channel.peerInfos=()=>[{epoch:7,peerId:'chat2',role:'chat',ready:true,name:'聊天设备2'},{epoch:8,peerId:'compute2',role:'compute',ready:true,name:'算力设备2'}];
  const task={id:'display_parent',title:'原始任务',phase:'running',revision:1,startedAt:1000,endedAt:0,answer:'',subtasks:[
    {id:'s1',title:'本机子任务',device:'算力设备1',phase:'running',detail:'生成中'},
    {id:'s2',title:'远端子任务',device:'算力设备2',phase:'running',detail:'生成中'}]};
  s.page.receiveInference({type:'infer.task',requestId:task.id,task},7);
  let board=s.events.filter(e=>e.kind==='dashboard').at(-1);
  assert.equal(board.groups[0].executor,'算力设备1');assert.equal(board.groups[0].origin,'聊天设备2');
  s.page.receiveInference({type:'infer.task',requestId:task.id,task:{...task,revision:2,title:'不可信的算力端主任务'}},8);
  assert.equal(s.page.taskBoard.views()[0].title,'原始任务','compute peer cannot impersonate chat owner');
  s.page.inference={handle(message,epoch){s.page.showInferTask(message.requestId,epoch,message.prompt,message.label||'')}};
  s.page.receiveInference({type:'infer.request',requestId:'child-call',prompt:'子任务输入',taskId:task.id,subtaskId:'s1'},7);
  board=s.events.filter(e=>e.kind==='dashboard').at(-1);
  assert.equal(board.jobs[0].groupKey,'7:display_parent');assert.equal(board.jobs[0].subtaskId,'s1');assert.equal(board.jobs[0].origin,'聊天设备2');
  s.page.clearFinishedJobs();assert.equal(s.page.taskBoard.views().length,1,'clearing history preserves running parent');
  s.page.taskBoard.disconnect(7);s.page.clearFinishedJobs();assert.equal(s.page.taskBoard.views().length,0);
  const worker=setup(true);worker.channel.selfComputeNumber=()=>2;worker.channel.selfLabel=()=> '算力设备2';
  worker.channel.peerInfos=()=>[{epoch:8,peerId:'hub',role:'compute',ready:true,name:'算力设备1'}];
  worker.page.inference={handle(message,epoch){worker.page.showInferTask(message.requestId,epoch,message.prompt,message.label||'')}};
  worker.page.receiveInference({type:'infer.request',requestId:'forwarded',prompt:'远端输入',taskId:task.id,subtaskId:'s2',origin:'聊天设备2'},8);
  assert.equal(worker.page.jobs[0].origin,'聊天设备2');assert.equal(worker.page.jobs[0].source,'算力设备2');
  console.log('PASS: native group ownership, chat role checks, request correlation, history cleanup and forwarded origin');
}

// Replay a purpose-labelled split using an unchanged chat client (no infer.task messages).
{
  const s=setup(true);
  s.channel.peerInfos=()=>[{epoch:7,peerId:'chat2',role:'chat',ready:true,name:'聊天设备2'},{epoch:8,peerId:'compute2',role:'compute',ready:true,name:'算力设备2'}];
  s.page.inference={handle(message,epoch){s.page.showInferTask(message.requestId,epoch,message.prompt||message.messages.at(-1).content,message.label||'')}};
  const request=(id,prompt,label)=>s.page.receiveInference({type:'infer.request',requestId:id,prompt,label},7);
  request('plan','拆分提示词\n用户请求：\n比较两个模型','任务拆分');
  assert.equal(s.events.filter(e=>e.kind==='dashboard').at(-1).groups.length,0);
  s.page.finishInferTask('plan',7,JSON.stringify([{title:'模型A',task:'介绍模型A'},{title:'模型B',task:'介绍模型B'}]),false);
  request('a','PRIVATE_PROMPT\nUser task:\n介绍模型A\nControl: PRIVATE_CONTROL','子任务 1/2');
  s.page.showRelayTask('b',7,8,[{role:'user',content:'User task:\n介绍模型B\nControl: private'}],'子任务 2/2');
  let board=s.events.filter(e=>e.kind==='dashboard').at(-1);
  assert.equal(board.groups.length,1);assert.equal(board.groups[0].executor,'算力设备1');
  assert.equal(board.groups[0].subtasks[1].device,'算力设备2');
  assert(!board.jobs.find(j=>j.id==='a').question.includes('PRIVATE_'));assert(board.jobs.find(j=>j.id==='a').input.includes('PRIVATE_CONTROL'));
  const html=fs.readFileSync(__dirname+'/../../resources/rawfile/peer-chat.html','utf8');
  const elements={};const element=()=>({handlers:{},value:'',style:{},textContent:'',innerHTML:'',scrollTop:50,classList:{add(){},remove(){}},addEventListener(t,f){this.handlers[t]=f},setAttribute(){}});
  for(const match of html.matchAll(/\bid="([^"]+)"/g))elements[match[1]]=element();
  const document={getElementById:id=>elements[id],createElement:element,addEventListener(){},activeElement:null};
  const window={chatBridge:{prepare(){},connect(){},pickImage(){},clear(){}}};
  vm.runInNewContext(html.match(/<script>([\s\S]*?)<\/script>/)[1],{document,window,Date});
  window.onNativeEvent(board);
  assert(elements.history.innerHTML.includes('比较两个模型'));assert(elements.history.innerHTML.includes('模型A'));assert(elements.history.innerHTML.includes('模型B'));assert(elements.history.innerHTML.includes('算力设备2'));
  assert(!elements.history.innerHTML.includes('PRIVATE_'));
  s.page.finishInferTask('a',7,'A推理返回',false);s.page.completeJob('b',7,'B推理返回',false);
  request('merge','用户请求：\n比较两个模型\n\n【子任务1：模型A｜已完成】\nA返回结果\n\n【子任务2：模型B｜已完成】\nB返回结果','合并结果');
  s.page.finishInferTask('merge',7,'汇总回答',false);
  board=s.events.filter(e=>e.kind==='dashboard').at(-1);
  assert.equal(board.groups[0].phase,'done');assert.equal(board.groups[0].answer,'汇总回答');
  window.onNativeEvent(board);assert(elements.history.innerHTML.includes('子任务 2/2'));
  s.page.clearFinishedJobs();assert.equal(s.events.filter(e=>e.kind==='dashboard').at(-1).groups.length,0);
  console.log('PASS: unchanged chat request replay -> native split observation -> real HTML grouping and result return, full input isolated from list');
}

// The screenshot on compute 2 exposed this gap: legacy calls had neither a
// parent snapshot nor stable child identity after being handed to the worker.
{
  const hub=setup(true), worker=setup(true), forwarded=[];
  hub.channel.peerInfos=()=>[{epoch:7,peerId:'chat2',role:'chat',ready:true,name:'聊天设备2'},{epoch:9,peerId:'chat3',role:'chat',ready:true,name:'聊天设备3'},
    {epoch:8,peerId:'worker2',role:'compute',ready:true,name:'算力设备2'}];
  worker.channel.selfComputeNumber=()=>2;worker.channel.selfLabel=()=> '算力设备2';
  worker.channel.peerInfos=()=>[{epoch:11,peerId:'hub1',role:'compute',ready:true,name:'算力设备1'},
    {epoch:12,peerId:'worker3',role:'compute',ready:true,name:'算力设备3'}];
  hub.channel.send=async(message,epoch)=>{forwarded.push(JSON.parse(JSON.stringify(message)));
    if(epoch===8&&message.type==='infer.task')worker.page.receiveInference(JSON.parse(JSON.stringify(message)),11);return true;};
  worker.page.inference={handle(message,epoch){worker.page.showInferTask(message.requestId,epoch,message.prompt,message.label||'')}};
  hub.page.inference={handle(message,epoch){hub.page.showInferTask(message.requestId,epoch,message.prompt,message.label||'')}};
  hub.page.receiveInference({type:'infer.request',requestId:'legacy-plan',prompt:'用户请求：\n分别查询车票和天气',label:'任务拆分'},7);
  hub.page.finishInferTask('legacy-plan',7,JSON.stringify([{title:'车票查询',task:'查询深圳到北京的车票'},
    {title:'天气查询',task:'查询北京天气'}]),false);
  const invoke=(id)=>{
    hub.page.showRelayTask(id,7,8,[{role:'user',content:'User task:\n查询北京天气\nControl: PRIVATE_CONTROLLER'}],'子任务 2/2');
    const message={type:'infer.request',requestId:'forward_'+id,prompt:'User task:\n查询北京天气\nControl: PRIVATE_CONTROLLER',label:'子任务 2/2',origin:'聊天设备2'};
    hub.page.forwardTaskDisplay(id,7,8,message);
    worker.page.receiveInference(message,11);
    return message;
  };
  const first=invoke('weather1');
  worker.page.finishInferTask(first.requestId,11,'Action: search',false);hub.page.completeJob('weather1',7,'Action: search',false);
  const second=invoke('weather2');
  assert.equal(first.taskId,second.taskId,'legacy rounds receive the same worker parent identity');
  assert.equal(first.subtaskId,'s2');assert.equal(second.subtaskId,'s2');
  const board=worker.events.filter(e=>e.kind==='dashboard').at(-1);
  assert.equal(board.groups.length,1);assert.equal(board.groups[0].executor,'算力设备1');
  assert.equal(board.groups[0].origin,'聊天设备2');assert.equal(board.jobs.length,2);
  assert(board.jobs.every(j=>j.groupKey===board.groups[0].key));
  const html=fs.readFileSync(__dirname+'/../../resources/rawfile/peer-chat.html','utf8');
  const elements={};const element=()=>({handlers:{},value:'',style:{},textContent:'',innerHTML:'',scrollTop:50,classList:{add(){},remove(){}},addEventListener(t,f){this.handlers[t]=f},setAttribute(){}});
  for(const match of html.matchAll(/\bid="([^"]+)"/g))elements[match[1]]=element();
  const document={getElementById:id=>elements[id],createElement:element,addEventListener(){},activeElement:null};
  const window={chatBridge:{prepare(){},connect(){},pickImage(){},clear(){}}};
  vm.runInNewContext(html.match(/<script>([\s\S]*?)<\/script>/)[1],{document,window,Date});
  window.onNativeEvent(board);
  assert(elements.history.innerHTML.includes('分别查询车票和天气'));
  assert(elements.history.innerHTML.includes('class="task-children"'));
  assert.equal((elements.history.innerHTML.match(/data-child="s2"/g)||[]).length,1);
  assert(!elements.history.innerHTML.includes('车票查询'),'a worker only lists its own child assignments');
  assert(!elements.history.innerHTML.includes('data-detail="'),'individual calls do not become duplicate task rows');
  assert(!elements.history.innerHTML.includes('PRIVATE_CONTROLLER'));
  assert(elements.history.innerHTML.includes('group-progress'));
  const untrusted={type:'infer.task',requestId:'fake',task:{...board.groups[0],id:'fake',title:'其他算力伪装的结构'},origin:'聊天设备4'};
  worker.page.receiveInference(untrusted,12);assert.equal(worker.page.taskBoard.views().length,1);
  console.log('PASS: unchanged chat -> hub split -> worker snapshots and stable child IDs -> real worker HTML hierarchy, own assignments only');
}
