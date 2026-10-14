const assert=require('node:assert/strict');
const vm=require('node:vm');
const {transpile}=require('../../../../../../tests/harness.cjs');
const box={exports:{},require:()=>({}),Map,Array,Date,JSON};
vm.runInNewContext(transpile(__dirname+'/TaskDisplayRelay.ets'),box);
const {TaskDisplayRelay}=box.exports;
const flush=async()=>{for(let n=0;n<10;n++)await Promise.resolve();};
const json=value=>JSON.parse(JSON.stringify(value));
const group=(key)=>({key,id:'same_chat_id',originEpoch:7,origin:'聊天设备2',executor:'算力设备1',
  title:'分别查询车票和天气',phase:'running',revision:1,startedAt:1000,endedAt:0,answer:'',subtasks:[
    {id:'s1',title:'车票',device:'算力设备1',phase:'running',detail:'生成中'},
    {id:'s2',title:'天气',device:'算力设备2',phase:'running',detail:'生成中'}]});
(async()=>{
  const sent=[];let complete;
  const relay=new TaskDisplayRelay((message,epoch)=>{sent.push([json(message),epoch]);return new Promise(resolve=>{complete=resolve;});});
  const first={},second={},other={};
  relay.bind('7:same_chat_id','s2',first,8);relay.bind('7:same_chat_id','s2',second,8);
  relay.bind('9:same_chat_id','s2',other,10);
  assert.equal(first.taskId,second.taskId);assert.notEqual(first.taskId,other.taskId,'two chat sessions cannot collide behind one hub');
  const task=group('7:same_chat_id');
  relay.publish([task],[8,10],['7:same_chat_id','9:same_chat_id']);
  assert.equal(sent.length,1,'snapshots go only to workers assigned this parent');
  assert.equal(sent[0][1],8);assert.equal(sent[0][0].task.id,first.taskId);
  assert.equal(sent[0][0].origin,'聊天设备2');assert.equal(sent[0][0].source,'算力设备1');
  task.subtasks[1].phase='done';task.subtasks[1].result='天气结果';
  task.subtasks[0].phase='done';task.phase='done';task.endedAt=2000;task.answer='汇总结果';
  relay.publish([task],[8,10],['7:same_chat_id','9:same_chat_id']);
  assert.equal(sent.length,1,'a pending snapshot coalesces later display changes');
  assert.equal(sent[0][0].task.subtasks[1].phase,'running','a sending snapshot is immutable');
  complete(true);await flush();
  assert.equal(sent.length,2,'the final state is delivered even when no further dashboard event arrives');
  assert.equal(sent[1][0].task.phase,'done');assert.equal(sent[1][0].task.answer,'汇总结果');
  assert(sent[1][0].task.revision>sent[0][0].task.revision);
  complete(true);await flush();relay.publish([task],[8,10],['7:same_chat_id','9:same_chat_id']);
  assert.equal(sent.length,2,'unchanged token/dashboard updates do not spam task snapshots');
  relay.publish([],[],[]);assert.equal(relay.routes.size,0,'cleared history and rejected split attempts release display routes');
  let attempts=0;
  const failed=new TaskDisplayRelay(async()=>{attempts++;throw new Error('link lost');});
  failed.bind(task.key,'s2',{},8);failed.publish([task],[8],[task.key]);await flush();
  assert.equal(attempts,1,'failed display sends never create a retry loop');
  failed.publish([task],[8],[task.key]);await flush();assert.equal(attempts,2,'a subsequent event can retry a failed display');
  console.log('PASS: worker display identity, chat-session isolation, assigned recipients, immutable snapshots, final-state coalescing and bounded failures');
})().catch(error=>{console.error(error);process.exitCode=1;});
