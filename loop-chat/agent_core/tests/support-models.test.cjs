/* Offline actual-ETS regression suite. Run: node loop-chat/agent_core/tests/support-models.test.cjs
 * TYPESCRIPT_PATH optionally selects an already installed TypeScript compiler; no downloads. */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const os = require('node:os');
let ts;
for (const candidate of [process.env.TYPESCRIPT_PATH, 'typescript', 'D:/command-line-tools/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'].filter(Boolean)) {
  try { ts = require(candidate); break; } catch {}
}
if (!ts) throw new Error('Set TYPESCRIPT_PATH to a locally installed TypeScript compiler.');
const root = path.resolve(__dirname, '../src/main/ets');
const options = { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS, strict: true };
const noop = () => {};
let httpFactory = () => { throw new Error('No network allowed'); };
let virtual = new Map(), handles = new Map(), nextFd = 1, reads = 0, opens = 0, bytesRead = 0, listed = 0;
const prefix = '/data/storage/el2/base/haps/entry/files/workspace';
function setup(entries = {}) {
  virtual = new Map([['', { kind: 'dir' }], ...Object.entries(entries)]); handles = new Map(); reads = opens = bytesRead = listed = 0;
}
function key(p) { assert.ok(p === prefix || p.startsWith(prefix + '/')); return p.slice(prefix.length).replace(/^\//, ''); }
function stat(k) {
  const e = virtual.get(k); if (!e || e.statError) throw new Error('unreadable ' + k);
  return { size: e.size ?? Buffer.byteLength(e.text ?? ''), isSymbolicLink: () => e.kind === 'link', isDirectory: () => e.kind === 'dir', isFile: () => !e.kind || e.kind === 'file' };
}
const fsStub = {
  OpenMode: { READ_ONLY: 0, NOFOLLOW: 0o400000, NONBLOCK: 0o4000 },
  lstatSync: p => stat(key(p)),
  statSync: fd => stat(handles.get(fd)),
  listFileSync(p, opts) {
    listed++; const k = key(p); if (virtual.get(k)?.listError) throw new Error('list denied');
    assert.equal(opts.recursion, false); assert.ok(opts.listNum <= 501);
    return [...virtual.keys()].filter(x => x !== k && (k ? x.startsWith(k + '/') : true) && !x.slice(k ? k.length + 1 : 0).includes('/')).map(x => x.slice(k ? k.length + 1 : 0)).slice(0, opts.listNum);
  },
  openSync(p, mode) { const k = key(p); assert.ok(mode & fsStub.OpenMode.NOFOLLOW); assert.ok(mode & fsStub.OpenMode.NONBLOCK); if (virtual.get(k)?.openError || stat(k).isSymbolicLink()) throw new Error('open denied'); const fd = nextFd++; handles.set(fd, k); opens++; return {fd}; },
  readSync(fd, buffer, opts) { reads++; const entry = virtual.get(handles.get(fd)); if (entry.readError) throw new Error('read denied'); const src = entry.raw ? Buffer.from(entry.raw) : Buffer.from(entry.text ?? 'x'.repeat(entry.size ?? 0)); const count = Math.min(opts.length, src.length - opts.offset, entry.chunk ?? Infinity); new Uint8Array(buffer).set(src.subarray(opts.offset, opts.offset + count)); bytesRead += count; return count; },
  closeSync(file) { handles.delete(file.fd); }
};
const stubs = {
  '@ohos.file.fs': { default: fsStub },
  '@ohos.util': { default: { TextDecoder: { create: (encoding, opts) => { const decoder = new TextDecoder(encoding, opts); return { decodeToString: (data, opts) => decoder.decode(data, opts) }; } } } },
  '@ohos.url': { default: { URL } },
  '@ohos.net.http': { default: { createHttp: () => httpFactory(), RequestMethod: { POST: 'POST', GET: 'GET' }, HttpDataType: { STRING: 0 } } },
  '@kit.PerformanceAnalysisKit': { hilog: { info: noop, warn: noop } },
  '../skill/SkillLog': { skillLogInfo: noop, skillLogInfoChunks: noop, skillLogWarn: noop },
  '../aiphone/runtime/AiphoneLogger': { aiLogInfo: noop },
  '../skill/SkillSnapshot': { buildSkillsSection: () => '' },
  '../aiphone/runtime/GenericMcpClient': { GenericMcpClient: class {} }
};
const cache = new Map();
function load(relative) {
  const file = path.resolve(root, relative);
  if (cache.has(file)) return cache.get(file).exports;
  const output = ts.transpileModule(fs.readFileSync(file, 'utf8'), {fileName: file.replace(/\.ets$/, '.ts'), compilerOptions: options, reportDiagnostics: true});
  assert.deepEqual((output.diagnostics || []).filter(d => d.category === ts.DiagnosticCategory.Error).map(d => ts.flattenDiagnosticMessageText(d.messageText, '\n')), [], file);
  const module = {exports: {}}; cache.set(file, module);
  const requireLocal = name => {
    if (stubs[name]) return stubs[name];
    if (name.startsWith('.')) return load(path.resolve(path.dirname(file), name + '.ets'));
    throw new Error('Missing offline stub: ' + name);
  };
  vm.runInThisContext('(function(require,module,exports){' + output.outputText + '\n})', {filename: file})(requireLocal, module, module.exports);
  return module.exports;
}
const {parseTextCompletion} = load('model/TextCompletionResponse.ets');
const {SessionBackedModel, parseSessionResponseChunk} = load('model/SessionBackedModel.ets');
const {OpenAiCompatibleModel} = load('model/OpenAiCompatibleModel.ets');
const {ModelScopeConfig} = load('modelscope/ModelScopeConfig.ets');
const {ModelScopeDirectClient} = load('modelscope/ModelScopeDirectClient.ets');
const {DateCalculatorTool, UnitConvertTool, SandboxSearchTool} = load('agent/LocalUtilityTools.ets');
const {searchWorkspace} = load('file/BoundedWorkspaceSearch.ets');
const tests = [];
const test = (name, fn) => tests.push({name, fn});
const frame = obj => 'data: ' + JSON.stringify(obj) + '\n\n';
const chunk = (content, reason = null) => ({choices: [{index: 0, delta: {content}, finish_reason: reason}]});
const good = frame(chunk('Final: hi')) + frame(chunk('', 'stop')) + 'data: [DONE]\n\n';
const provider = {isConfigured: () => true, chatCompletionsUrl: () => 'https://offline.invalid', model: 'test', apiKey: 'not-secret', customParametersJson: ''};
function native() {
  const calls = [], aborted = [], destroyed = [];
  const binding = {createSession: () => ({session: 1, error: 0}), destroySession: s => {destroyed.push(s); return 0;}, submitRequest: (s, r, cb) => {calls.push({s, r, cb}); return {request: calls.length, error: 0};}, abortRequest: (s, r) => {aborted.push(r); return 0;}, enableCollaboration: () => 0, disableCollaboration: () => 0, isCollaborationSupported: () => false};
  return {calls, aborted, destroyed, model: new SessionBackedModel(binding)};
}
const tick = () => new Promise(resolve => setImmediate(resolve));
test('SSE handles comments metadata empty events multiline CRLF and usage', () => {
  const body = ': ping\r\nid: 2\r\nretry: 100\r\ndata:\r\n\r\nevent: message\r\ndata: {"choices":\r\ndata: [{"delta":{"content":"Final: hi"},"finish_reason":"stop"}]}\r\n\r\n' + frame({choices: [], usage: {total_tokens: 2}}) + 'data: [DONE]\n\n';
  assert.equal(parseTextCompletion(body), 'Final: hi');
});
test('SSE rejects malformed truncated and provider-error responses', () => {
  for (const body of [good.replace('Final: hi', 'Final: hi').replace('data: [DONE]\n\n', ''), good.replace('data: [DONE]\n\n', 'data: [DONE]'), frame(chunk('partial')) + 'data: [DONE]\n\n', 'data: {broken}\n\n' + good, frame({error: {message: 'failure'}}), 'event: error\ndata: bad\n\n', good + 'data: {"error":"late"}\n\n']) assert.throws(() => parseTextCompletion(body));
});
test('JSON and SSE reject non-stop completion and tool calls', () => {
  for (const reason of ['length', 'error', 'content_filter', 'tool_calls', 'function_call', null]) {
    assert.throws(() => parseTextCompletion(frame(chunk('partial', reason)) + 'data: [DONE]\n\n'));
    assert.throws(() => parseTextCompletion(JSON.stringify({choices: [{message: {content: 'partial'}, finish_reason: reason}]})));
  }
  assert.throws(() => parseTextCompletion(frame({choices:[{delta:{tool_calls:[]},finish_reason:'stop'}]})+'data: [DONE]\n\n'), /unsupported/);
  assert.equal(parseTextCompletion(JSON.stringify({choices:[{message:{content:'Final: ok'},finish_reason:'stop'}]})), 'Final: ok');
});
test('HTTP model awaits late dataEnd and destroys request', async () => {
  let destroyed = 0;
  httpFactory = () => { const events = {}; return {on: (name, fn) => {events[name] = fn;}, requestInStream: async () => {setImmediate(() => {const bytes = Buffer.from(good); events.dataReceive(bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength)); events.dataEnd();}); return 200;}, destroy: () => destroyed++}; };
  assert.equal(await new OpenAiCompatibleModel(provider).complete('hi'), 'Final: hi'); assert.equal(destroyed, 1);
});
test('HTTP model propagates malformed response and always destroys', async () => {
  let destroyed = 0;
  httpFactory = () => { const events={}; return {on: (k,v) => events[k]=v, requestInStream: async () => {const bytes=Buffer.from('data: {bad}\n\n'); events.dataReceive(bytes.buffer.slice(bytes.byteOffset,bytes.byteOffset+bytes.byteLength)); events.dataEnd(); return 200;}, destroy: () => destroyed++}; };
  await assert.rejects(new OpenAiCompatibleModel(provider).complete('hi'), /malformed JSON/); assert.equal(destroyed,1);
});
test('native choice finish_reason completes and queued lifecycle remains serial', async () => {
  assert.equal(parseSessionResponseChunk(JSON.stringify(chunk('x','stop'))).finish_reason, 'stop');
  const n=native(); const a=n.model.complete('a'), b=n.model.complete('b'); await tick(); assert.equal(n.calls.length,1);
  n.calls[0].cb(JSON.stringify(chunk('Final: a','stop'))); assert.equal(await a,'Final: a'); await tick(); assert.equal(n.calls.length,2);
  n.calls[1].cb(JSON.stringify({choices:[{message:{content:'Final: b'},finish_reason:'stop'}]})); assert.equal(await b,'Final: b'); assert.equal(n.destroyed.length,0); n.model.dispose(); assert.equal(n.destroyed.length,1);
});
test('native rejects length/error partials and releases serial lease', async () => {
  for (const response of [chunk('partial','length'),chunk('partial','error'),{error:{message:'bad'}}]) {
    const n=native(); const pending=n.model.complete('bad'); const rejected=assert.rejects(pending); await tick(); n.calls[0].cb(JSON.stringify(response)); await rejected;
    const next=n.model.complete('good'); await tick(); n.calls[1].cb(JSON.stringify(chunk('ok','stop'))); assert.equal(await next,'ok'); n.model.dispose();
  }
});
test('native close cancels active and queued requests', async () => {
  const n=native(), a=n.model.complete('a'), b=n.model.complete('b'); const ra=assert.rejects(a), rb=assert.rejects(b); await tick(); n.model.closeSession(); await Promise.all([ra,rb]); assert.equal(n.calls.length,1); assert.deepEqual(n.aborted,[1]);
});
test('native one-token probe permits length but not error', async () => {
  for (const reason of ['length','error']) {const n=native(); n.model.prepareSession(); const p=n.model.probeSession(1000); await tick(); n.calls[0].cb(JSON.stringify(chunk('p',reason))); assert.equal(await p,reason==='length'); n.model.dispose();}
});
test('ModelScope validates host URL rather than regex authority', () => {
  for (const value of ['https://modelscope.cn','http://localhost:8080/api','https://[::1]:443/api']) assert.ok(new ModelScopeConfig('', 'key', value).isConfigured(),value);
  for (const value of ['https://','https:///path','https://?x','https://#x','https://user@:443','ftp://host','https://host:bad','https://host:99999','https://a b','https://user:pass@host','https://host/?x','https://host/#x']) assert.equal(new ModelScopeConfig('', 'key', value).isConfigured(),false,value);
});
test('ModelScope unique long/sanitized names dispatch original exact tools', async () => {
  const client=new ModelScopeDirectClient(new ModelScopeConfig('', 'key', 'https://modelscope.cn'));
  const names=['a/b','a?b','x'.repeat(150)+'a','x'.repeat(150)+'b']; const called=[];
  client.fetchOperationalServers=async()=>[{serverId:'same',name:'server',description:'',endpoint:'https://offline.invalid/mcp'}];
  client.mcp={preflight:async()=>({ok:true,tools:names.map(name=>({name,description:'find',inputSchema:{},annotations:{readOnlyHint:true}}))}),callTool:async(reg)=>{called.push(reg.mcpToolName);return {status:'ok'};}};
  const result=JSON.parse(await client.search('find')); assert.equal(new Set(result.tools.map(t=>t.qualifiedName)).size,4);
  for (const tool of result.tools) {assert.ok(tool.qualifiedName.length<=96);await client.execute(tool.qualifiedName,{}); assert.equal(called.at(-1),tool.name);}
});
test('dates use civil days and reject overflow invalid dates and fractional offsets', async () => {
  const tool=new DateCalculatorTool();
  for(const [query,answer] of [['2011-12-29到2011-12-31相差几天','相差 2 天'],['2024-02-28到2024-03-01','相差 2 天'],['0099-01-01到0099-01-02','相差 1 天']]) assert.equal(await tool.run(JSON.stringify({query})),answer);
  for(const query of ['2023-02-29到2023-03-01','9'.repeat(400)+'天后','1.5天后','-1天后','3652058天后']) assert.match(await tool.run(JSON.stringify({query})),/失败/);
});
test('units reject coercions and report unsupported conversions truthfully', async () => {
  const tool=new UnitConvertTool();
  for(const value of [null,true,'5',[],{}]) assert.match(await tool.run(JSON.stringify({value,from:'km',to:'mi'})),/有限数字/);
  assert.match(await tool.run('{bad}'),/JSON/); assert.match(await tool.run('{"value":1,"from":"km","to":"kg"}'),/不支持/);
  assert.match(await tool.run('{"value":1,"from":"madeup","to":"madeup"}'),/不支持/);
  assert.match(await tool.run('{"value":1.7e308,"from":"mi","to":"km"}'),/有限数字/);
  assert.equal(await tool.run('{"value":1,"from":"kb","to":"bytes"}'),'1 kb = 1024 bytes');
});
test('kilometers and meters convert locally in both directions', async () => {
  const tool=new UnitConvertTool();
  for(const [value,from,to,answer] of [[5,'km','m','5 km = 5000 m'],[5000,'m','km','5000 m = 5 km'],[0.005,'km','m','0.005 km = 5 m'],[0,'km','m','0 km = 0 m'],[-2,'km','m','-2 km = -2000 m']]) {
    assert.equal(await tool.run(JSON.stringify({value,from,to})),answer);
  }
  assert.match(await tool.run(JSON.stringify({value:1e308,from:'km',to:'m'})),/有限数字/);
});
test('search isolates failed files and rejects links without opening', async () => {
  setup({'a.txt':{text:'needle',openError:true},'b.txt':{text:'needle',chunk:2},'link.txt':{kind:'link'},'sub':{kind:'dir',listError:true}});
  const result=await new SandboxSearchTool({}).run('{"query":"needle"}'); assert.match(result,/b.txt/); assert.match(result,/PARTIAL/); assert.equal(opens,1); assert.equal(handles.size,0);
});
test('search unreadable root is failure, not no match', () => {setup({'':{kind:'dir',listError:true}});assert.match(searchWorkspace('x'),/根目录无法读取/);});
test('search depth entries per-file total-byte and result limits', () => {
  setup(Object.fromEntries(Array.from({length:550},(_,i)=>['f'+i+'.txt',{text:'absent'}]))); assert.match(searchWorkspace('needle'),/PARTIAL/);assert.equal(opens,500);
  setup({'huge.txt':{size:262145}});assert.match(searchWorkspace('needle'),/PARTIAL/);assert.equal(opens,0);
  setup(Object.fromEntries(Array.from({length:30},(_,i)=>['f'+i+'.txt',{size:262144}]))); assert.match(searchWorkspace('needle'),/PARTIAL/);assert.equal(bytesRead,4194304);
  setup(Object.fromEntries(Array.from({length:30},(_,i)=>['f'+i+'.txt',{text:'needle'}])));const result=searchWorkspace('needle');assert.equal((result.match(/\[MATCH\]/g)||[]).length,20);assert.match(result,/PARTIAL/);assert.equal(opens,20);
  const entries={};for(let i=1;i<=10;i++)entries[Array(i).fill('d').join('/')]={kind:'dir'};setup(entries);assert.match(searchWorkspace('needle'),/PARTIAL/);assert.ok(listed<=9);
});

test('native synchronous callbacks and failing observers still settle', async () => {
  const binding={createSession:()=>({session:1,error:0}),destroySession:()=>0,submitRequest:(_s,_r,cb)=>{cb(JSON.stringify(chunk('Final: sync','stop')));return {request:1,error:0};},abortRequest:()=>0,enableCollaboration:()=>0,disableCollaboration:()=>0,isCollaborationSupported:()=>false};
  const model=new SessionBackedModel(binding,{requestListener:()=>{throw new Error('observer');},responseListener:()=>{throw new Error('observer');}});
  model.setTokenStreamListener(()=>{throw new Error('observer');});assert.equal(await model.complete('a'),'Final: sync');assert.equal(await model.complete('b'),'Final: sync');model.dispose();
});
test('native malformed callback rejects instead of hanging', async () => {
  const n=native();const pending=n.model.complete('bad');const rejected=assert.rejects(pending,/Malformed/);await tick();n.calls[0].cb('{bad');await rejected;n.model.dispose();
});
test('ModelScope mapping is stable under catalog reordering', async () => {
  async function mapping(reverse) {
    const client=new ModelScopeDirectClient(new ModelScopeConfig('', 'key', 'https://modelscope.cn'));
    const servers=['b','a'].map(serverId=>({serverId,name:serverId,description:'',endpoint:'https://'+serverId+'.invalid/mcp'}));
    client.fetchOperationalServers=async()=>reverse?servers.reverse():servers;
    client.mcp={preflight:async()=>({ok:true,tools:(reverse?['y','x']:['x','y']).map(name=>({name,description:'find',inputSchema:{},annotations:{readOnlyHint:true}}))})};
    return JSON.parse(await client.search('find')).tools.map(t=>[t.serverId,t.name,t.qualifiedName]);
  }
  assert.deepEqual(await mapping(false),await mapping(true));
});
test('search invalid UTF-8 and short reads close handles honestly', () => {
  setup({'a.txt':{text:'needle',readError:true},'b.txt':{text:'needle',chunk:1},'c.txt':{size:1,raw:[255]}});
  assert.match(searchWorkspace('needle'),/PARTIAL/);assert.equal(handles.size,0);
  setup({'':{kind:'link'}});assert.match(searchWorkspace('needle'),/根目录无法读取/);assert.equal(opens,0);
});

async function main(){for(const {name,fn} of tests){await fn();console.log('PASS '+name);} console.log(`PASS ${tests.length} offline actual-ETS tests (TypeScript ${ts.version}).`);}
main().catch(error=>{console.error(error);process.exitCode=1;});
