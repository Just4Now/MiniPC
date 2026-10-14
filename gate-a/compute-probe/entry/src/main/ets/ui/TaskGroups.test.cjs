const assert=require('node:assert/strict');
const fs=require('node:fs');
const vm=require('node:vm');
const source=fs.readFileSync(__dirname+'/../../resources/rawfile/peer-chat.html','utf8');
const elements={};
const document={activeElement:null,handlers:{},getElementById:id=>elements[id],addEventListener(type,fn){this.handlers[type]=fn},createElement:()=>element()};
function element(){return {handlers:{},style:{},attrs:{},hidden:true,value:'',textContent:'',scrollTop:0,scrollHeight:100,clientHeight:50,isConnected:true,classList:{add(){},remove(){}},_html:'',get innerHTML(){return this._html},set innerHTML(value){this._html=value;for(const match of value.matchAll(/\bid="([^"]+)"/g))if(!elements[match[1]])elements[match[1]]=element()},addEventListener(type,fn){this.handlers[type]=fn},getAttribute(name){return this.attrs[name]||null},setAttribute(name,value){this.attrs[name]=value},appendChild(){},blur(){},focus(){document.activeElement=this},querySelector(){return element()},querySelectorAll(){return []}};}
for(const match of source.matchAll(/\bid="([^"]+)"/g))elements[match[1]]=element();
const window={chatBridge:{connect(){},pickImage(){},clear(){},prepare(){},send(){return ''},stop(){}}};
vm.runInNewContext(source.match(/<script>([\s\S]*?)<\/script>/)[1],{document,window,Date});
function target(attrs){const el=element();el.attrs=attrs;el.closest=selector=>Object.keys(attrs).some(attr=>selector==='['+attr+']')?el:null;return el;}
const now=Date.now();
const request=(id,child,extra={})=>({id,key:'5:'+id,groupKey:'5:parent',subtaskId:child,question:'【子任务 1/2】输入'+id,answer:'输出'+id,source:'算力设备1',origin:'聊天设备2',chars:3,startedAt:now-2000,firstAt:now-1000,running:false,endedAt:now,elapsedMs:2000,error:false,...extra});
const group={id:'parent',key:'5:parent',title:'原问题 <script>不能执行</script>',origin:'聊天设备2',executor:'算力设备1',phase:'running',revision:1,startedAt:now-4000,endedAt:0,answer:'',subtasks:[{id:'s1',title:'子任务A内容',device:'算力设备1',phase:'running',detail:'生成中'},{id:'s2',title:'子任务B内容',device:'算力设备2',phase:'done',detail:'已完成',result:'来自设备2的实际结果'}]};
const event={kind:'dashboard',selfLabel:'算力设备1',running:1,devices:[],groups:[group,{...group,key:'other',executor:'算力设备2',title:'其他设备负责的主任务',subtasks:group.subtasks.map(child=>({...child,device:'算力设备2'}))}],jobs:[request('call1','s1'),request('call2','s1',{startedAt:now-1000,answer:'第二次输出',running:true,endedAt:0}),request('flat','s1',{groupKey:undefined,question:'普通任务'}),request('remote','s2',{source:'算力设备2',question:'不应作为本机调用出现'})]};
window.onNativeEvent(event);
assert(elements.history.innerHTML.includes('子任务A内容'));assert(elements.history.innerHTML.includes('子任务B内容'));
assert(elements.history.innerHTML.includes('算力设备2'));assert(elements.history.innerHTML.includes('子任务 1/2'));
assert(!elements.history.innerHTML.includes('其他设备负责的主任务'));assert(!elements.history.innerHTML.includes('不应作为本机调用出现'));
assert(!elements.history.innerHTML.includes('输入call1'),'correlated calls are inside parent, not duplicated as roots');
assert.equal((elements.history.innerHTML.match(/data-child="s1"/g)||[]).length,1,'one child row contains every inference call');
assert(!elements.history.innerHTML.includes('第 1 次推理'),'individual calls are shown only after opening details');
assert(elements.history.innerHTML.includes('&lt;script&gt;不能执行&lt;/script&gt;'));
elements.history.handlers.click({target:target({'data-collapse':'5:parent'})});assert(!elements.history.innerHTML.includes('子任务B内容'));
elements.history.handlers.click({target:target({'data-collapse':'5:parent'})});
elements.history.handlers.click({target:target({'data-group':'5:parent','data-child':'s1'})});
assert.equal(elements.detailContent.textContent,'第二次输出');assert(elements.detail.innerHTML.includes('第 1 次推理'));assert(elements.detail.innerHTML.includes('第 2 次推理'));
const selector=target({'data-call':'true'});selector.value='5:call1';elements.detail.handlers.change({target:selector});assert.equal(elements.detailContent.textContent,'输出call1');
elements.detail.handlers.click({target:target({'data-tab':'runtime'})});assert(elements.detailContent.textContent.includes('请求ID：call1'));
document.handlers.keydown({key:'Escape'});
elements.history.handlers.click({target:target({'data-group':'5:parent','data-result':'s2'})});assert.equal(elements.detailContent.textContent,'来自设备2的实际结果');assert(elements.detail.innerHTML.includes('执行：算力设备2'));
assert(!elements.detailMetrics.innerHTML.includes('首字'),'child result is not represented as a fabricated model call');
document.handlers.keydown({key:'Escape'});
group.phase='done';group.endedAt=now;group.answer='最终汇总回答';for(const child of group.subtasks)child.phase='done';
window.onNativeEvent(event);elements.history.handlers.click({target:target({'data-summary':'5:parent'})});assert.equal(elements.detailContent.textContent,'最终汇总回答');
window.onNativeEvent({...event,groups:[],jobs:[]});assert.equal(elements.detail.hidden,true);
const secret='PRIVATE_SYSTEM_INPUT\nTools: PRIVATE_TOOL_SCHEMA\nUser task:\n只显示用户问题\nControl: PRIVATE_CONTROL';
const simple=request('raw','s1',{groupKey:undefined,question:secret,input:secret,answer:'PRIVATE_MODEL_PROTOCOL'});
elements.history.scrollTop=125;
window.onNativeEvent({...event,groups:[],jobs:[simple]});assert.equal(elements.history.scrollTop,125);
assert(elements.history.innerHTML.includes('只显示用户问题'));
assert(!elements.history.innerHTML.includes('PRIVATE_'),'no system input, control prompt, or model protocol leaks into the list');
elements.history.handlers.click({target:target({'data-detail':'5:raw'})});assert(!elements.detail.innerHTML.includes('PRIVATE_'));
elements.detail.handlers.click({target:target({'data-tab':'input'})});assert.equal(elements.detailContent.textContent,secret,'full input is available only in input details');
elements.detail.handlers.click({target:target({'data-tab':'output'})});
elements.detailContent.scrollHeight=500;elements.detailContent.clientHeight=100;elements.detailContent.scrollTop=120;
elements.detailContent.handlers.scroll();
window.onNativeEvent({kind:'text',requestId:'raw',text:'new streamed output'});assert.equal(elements.detailContent.scrollTop,120,'streaming preserves an explicitly scrolled output position');
document.handlers.keydown({key:'Escape'});
// A worker receives calls for a child without owning its parent group. Its task
// list must still show that child once, with all calls available inside details.
const workerCalls=[request('step1','s1',{startedAt:now-3000}),request('step2','s1',{startedAt:now-2000}),
  request('step3','s1',{startedAt:now-1000,running:true,endedAt:0}),
  request('other-child','s2',{question:'另外一个子任务'}),
  request('other-parent','s1',{groupKey:'6:parent',question:'另外一个主任务的子任务'}),
  request('ordinary1','s1',{groupKey:undefined,question:'相同的普通问题'}),
  request('ordinary2','s1',{groupKey:undefined,question:'相同的普通问题'}),
  request('excluded','s1',{source:'算力设备2'})];
window.onNativeEvent({...event,groups:[],jobs:workerCalls});
assert.equal((elements.history.innerHTML.match(/<article /g)||[]).length,4,'correlated calls and back-to-back rounds of the same plain request share a row');
assert.equal(elements.taskCount.textContent,'共 4 个任务');
assert(elements.filters.innerHTML.includes('进行中 1'));
assert(elements.history.innerHTML.includes('data-detail="5:step3"'));
assert(!elements.history.innerHTML.includes('data-detail="5:step1"'));
const rowKeys=Array.from(elements.history.innerHTML.matchAll(/data-row-key="([^"]+)"/g),match=>match[1]);
elements.history.handlers.click({target:target({'data-detail':'5:step3'})});
assert(elements.detail.innerHTML.includes('第 3 次推理'));
assert(!elements.detail.innerHTML.includes('value="5:other-child"'));
assert(!elements.detail.innerHTML.includes('value="5:other-parent"'));
assert(!elements.detail.innerHTML.includes('value="5:excluded"'));
const workerSelector=target({'data-call':'true'});workerSelector.value='5:step1';
elements.detail.handlers.change({target:workerSelector});assert.equal(elements.detailContent.textContent,'输出step1');
workerSelector.value='5:other-parent';elements.detail.handlers.change({target:workerSelector});
assert.equal(elements.detailContent.textContent,'输出step1','the selector cannot jump into another task');
document.handlers.keydown({key:'Escape'});
const nextCall=request('step4','s1',{startedAt:now,running:true,endedAt:0});
workerCalls[2].running=false;workerCalls.push(nextCall);
window.onNativeEvent({...event,groups:[],jobs:workerCalls});
assert.deepEqual(Array.from(elements.history.innerHTML.matchAll(/data-row-key="([^"]+)"/g),match=>match[1]),rowKeys,
  'later inference rounds keep the same row key and task position');
assert.equal(elements.taskCount.textContent,'共 4 个任务');
assert(elements.history.innerHTML.includes('data-detail="5:step4"'));
console.log('PASS: one row per child on coordinator and worker, scoped call details, stable row identity, split assignments, input isolation and scroll preservation');
