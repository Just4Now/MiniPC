// Real SubtaskSplitter / SubtaskMerger / ParallelTaskRunner sources; ReActAgentRunner and models are controlled fakes.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
let ts;
for (const p of [process.env.TYPESCRIPT_PATH, 'typescript', 'D:/command-line-tools/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'].filter(Boolean)) {
  try { ts = require(p); break; } catch {}
}
if (!ts) throw new Error('Set TYPESCRIPT_PATH to the local compiler module');
const ets = path.resolve(__dirname, '../src/main/ets');
function load(relative, requires = {}) {
  const file = path.join(ets, relative);
  const out = ts.transpileModule(fs.readFileSync(file, 'utf8'), { fileName: file.replace(/\.ets$/, '.ts'),
    compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }, reportDiagnostics: true });
  assert.deepEqual((out.diagnostics || []).filter((d) => d.category === ts.DiagnosticCategory.Error), []);
  const mod = { exports: {} };
  vm.runInNewContext(out.outputText, { module: mod, exports: mod.exports, require: (n) => requires[n] || {}, Error, Promise, JSON, Math, Date, Array, Set, Map, String, RegExp, setTimeout, clearTimeout, console });
  return mod.exports;
}
const events = load('agent/AgentEvent.ets');
const splitter = load('agent/parallel/SubtaskSplitter.ets');
const merger = load('agent/parallel/SubtaskMerger.ets');
const PARTIAL = 'partial';

// ---- controlled ReAct runner: behaviour comes from `script[task]` ----
const state = { script: {}, active: 0, peak: 0, created: [], namespaces: [] };
class FakeRunner {
  constructor(model) { this.model = model; this.stopped = false; this.release = null; state.created.push(this); }
  requestStop() { this.stopped = true; if (this.release) this.release(); try { this.model.cancel?.(); } catch {} }
  async run(task, listener, _conversation, execution) {
    state.namespaces.push(execution.namespace);
    state.active++; state.peak = Math.max(state.peak, state.active);
    try {
      const step = state.script[task] || { final: task + ' 的结果' };
      if (step.hold) await new Promise((resolve) => { this.release = resolve; step.hold(resolve); });
      else await new Promise((resolve) => setTimeout(resolve, step.delay || 5));
      if (this.stopped) { listener(new events.AgentEvent(events.AgentEventKind.ERROR, '已停止生成')); return; }
      if (step.action) listener(new events.AgentEvent(events.AgentEventKind.ACTION, '', 'c1', step.action));
      if (step.error) { listener(new events.AgentEvent(events.AgentEventKind.ERROR, step.error)); return; }
      listener(new events.AgentEvent(events.AgentEventKind.FINAL, step.final, undefined, undefined, undefined, step.status));
    } finally { state.active--; }
  }
}
const parallel = load('agent/parallel/ParallelTaskRunner.ets', {
  '../AgentEvent': events, '../ReActAgentRunner': { ReActAgentRunner: FakeRunner, PARTIAL_FINAL_STATUS: PARTIAL },
  './SubtaskSplitter': splitter, './SubtaskMerger': merger
});

const TASK = '查北京明天的天气，并且把“早上好”翻译成英文';
const SPLIT_JSON = JSON.stringify([{ title: '北京天气', task: '查询北京明天的天气' }, { title: '翻译', task: '把“早上好”翻译成英文' }]);
function build(options = {}) {
  const log = { split: 0, merge: 0, mergePrompt: '', models: [], accepted: [] };
  const deps = {
    modelFor: (id, hooks) => { const model = { cancelled: 0, complete: async () => '', cancel() { this.cancelled++; } }; log.models.push([id, model]); if (options.modelFor) options.modelFor(id, hooks); return model; },
    splitModel: () => ({ complete: async () => { log.split++; return options.splitResponse === undefined ? SPLIT_JSON : options.splitResponse; }, cancel() {} }),
    mergeModel: () => ({ complete: async (prompt) => { log.merge++; log.mergePrompt = prompt; if (options.mergeFails) throw new Error('merge down'); return '合并后的回答'; }, cancel() {} }),
    tools: {}, maxSteps: 4, maxPromptBytes: () => 32768,
    load: () => options.load || { idle: 2, total: 2 }
  };
  const seen = { plan: null, updates: [], phases: [], events: [] };
  const observer = { onPlan: (views) => { seen.plan = JSON.parse(JSON.stringify(views)); }, onUpdate: (view) => seen.updates.push(JSON.parse(JSON.stringify(view))), onPhase: (text) => seen.phases.push(text) };
  const runner = new parallel.ParallelTaskRunner(deps);
  const conversation = { toChatMessages: () => [] };
  const run = (task = TASK) => runner.tryRun(task, conversation, observer, (event) => seen.events.push(event));
  return { runner, log, seen, run };
}
const tests = [];
const test = (name, fn) => tests.push([name, fn]);
const reset = () => { state.script = {}; state.active = 0; state.peak = 0; state.created = []; state.namespaces = []; };

test('rule screen accepts bundled requests and rejects single ones', () => {
  assert.equal(splitter.shouldTrySplit(TASK), true);
  assert.equal(splitter.shouldTrySplit('北京天气怎么样？上海呢？'), true);
  assert.equal(splitter.shouldTrySplit('1. 查天气\n2. 查车次'), true);
  assert.equal(splitter.shouldTrySplit('北京明天天气怎么样'), false);
  assert.equal(splitter.shouldTrySplit('你好'), false);
});
test('parseSubtasks is strict', () => {
  const ok = splitter.parseSubtasks('说明 ' + SPLIT_JSON, TASK);
  assert.equal(ok.map((s) => s.id).join(), 's1,s2');
  const bad = (value) => splitter.parseSubtasks(typeof value === 'string' ? value : JSON.stringify(value), TASK);
  assert.equal(bad('[]'), null);
  assert.equal(bad('not json'), null);
  assert.equal(bad([{ title: 'a', task: 'only one' }]), null);
  assert.equal(bad([{ title: 'a', task: '甲' }, { title: 'b', task: '甲' }]), null, 'duplicate');
  assert.equal(bad([{ title: 'a', task: TASK }, { title: 'b', task: '乙' }]), null, 'no real split');
  assert.equal(bad([{ title: 'a', task: '查天气' }, { title: 'b', task: '根据上一步的结果穿衣' }]), null, 'dependency');
  assert.equal(bad([{ title: 'a', task: '甲' }, { title: 'b' }]), null);
  assert.equal(bad([1, 2, 3, 4, 5].map((n) => ({ title: 't', task: 'x' + n }))), null, 'too many');
});
test('idle below two or a failed rule screen never calls the model', async () => {
  reset();
  let h = build({ load: { idle: 1, total: 2 } }); assert.equal(await h.run(), false); assert.equal(h.log.split, 0);
  h = build(); assert.equal(await h.run('北京明天天气怎么样'), false); assert.equal(h.log.split, 0);
});
test('a model that declines or errors falls back without emitting anything', async () => {
  reset();
  for (const response of ['[]', 'garbage']) {
    const h = build({ splitResponse: response }); assert.equal(await h.run(), false); assert.equal(h.seen.events.length, 0); assert.equal(h.seen.plan, null);
  }
});
test('independent sub-tasks run concurrently on separate namespaces and are merged', async () => {
  reset(); state.script = { '查询北京明天的天气': { action: 'weather', final: '晴 20 度', delay: 20 }, '把“早上好”翻译成英文': { final: 'Good morning', delay: 20 } };
  const devices = {};
  const h = build({ modelFor: (id, hooks) => { devices[id] = hooks; } });
  assert.equal(await h.run(), true);
  assert.equal(state.peak, 2);
  assert.equal(new Set(state.namespaces).size, 2); assert.ok(state.namespaces.every((n) => /^p[0-9a-z]+\/s[12]$/.test(n)));
  assert.equal(h.log.merge, 1); assert.match(h.log.mergePrompt, /晴 20 度/); assert.match(h.log.mergePrompt, /Good morning/);
  const final = h.seen.events.at(-1); assert.equal(final.kind, 'FINAL'); assert.equal(final.text, '合并后的回答'); assert.equal(final.status, undefined);
  assert.deepEqual(h.seen.plan.map((v) => v.phase), ['queued', 'queued']);
  assert.ok(h.seen.updates.some((u) => u.detail === '正在调用工具：weather…'));
  assert.deepEqual(h.seen.updates.filter((u) => u.phase === 'done').map((u) => u.id).sort(), ['s1', 's2']);
});
test('concurrency never exceeds the cluster size', async () => {
  reset(); const h = build({ load: { idle: 2, total: 1 } }); assert.equal(await h.run(), true); assert.equal(state.peak, 1);
});
test('device reported by the transport reaches the sub-task row', async () => {
  reset(); const h = build({ modelFor: (id, hooks) => hooks.onAccepted('算力设备2') });
  await h.run(); assert.ok(h.seen.updates.some((u) => u.device === '算力设备2'));
});
test('a failed sub-task yields a partial answer and the merge prompt marks it unfinished', async () => {
  reset(); state.script = { '查询北京明天的天气': { error: '天气服务不可用' } };
  const h = build(); await h.run();
  assert.match(h.log.mergePrompt, /未完成/); assert.match(h.log.mergePrompt, /天气服务不可用/);
  assert.equal(h.seen.events.at(-1).status, PARTIAL);
});
test('merge failure falls back to per-sub-task sections and stays partial', async () => {
  reset(); const h = build({ mergeFails: true }); await h.run();
  const final = h.seen.events.at(-1); assert.equal(final.status, PARTIAL);
  assert.match(final.text, /1\. 北京天气/); assert.match(final.text, /2\. 翻译/);
});
test('all sub-tasks failing skips the merge call', async () => {
  reset(); state.script = { '查询北京明天的天气': { error: 'x1' }, '把“早上好”翻译成英文': { error: 'x2' } };
  const h = build(); await h.run(); assert.equal(h.log.merge, 0); assert.equal(h.seen.events.at(-1).status, PARTIAL);
});
test('stop cancels every sub-task, skips merging and reports the stop', async () => {
  reset(); const releases = [];
  state.script = { '查询北京明天的天气': { hold: (r) => releases.push(r) }, '把“早上好”翻译成英文': { hold: (r) => releases.push(r) } };
  const h = build(); const run = h.run();
  await new Promise((resolve) => setTimeout(resolve, 30));
  assert.equal(state.active, 2); h.runner.requestStop(); await run;
  assert.ok(state.created.every((r) => r.stopped)); assert.equal(h.log.merge, 0);
  assert.equal(h.seen.events.at(-1).kind, 'ERROR'); assert.equal(h.seen.events.at(-1).text, '已停止生成');
  assert.ok(h.seen.updates.every((u) => u.phase !== 'done'));
});
test('stop while splitting reports the stop and never runs sub-tasks', async () => {
  reset(); let finish;
  const h = build(); const original = h.runner.deps.splitModel;
  h.runner.deps.splitModel = () => ({ complete: () => new Promise((resolve) => { finish = () => resolve(SPLIT_JSON); }), cancel() {} });
  const run = h.run(); await new Promise((resolve) => setTimeout(resolve, 10));
  h.runner.requestStop(); finish(); assert.equal(await run, true);
  assert.equal(state.created.length, 0); assert.equal(h.seen.events.at(-1).text, '已停止生成'); void original;
});
(async () => {
  let pass = 0;
  for (const [name, fn] of tests) { try { await fn(); pass++; console.log('PASS ' + name); } catch (error) { console.error('FAIL ' + name, error); process.exitCode = 1; } }
  console.log(pass + '/' + tests.length + ' parallel runner tests passed');
})();
