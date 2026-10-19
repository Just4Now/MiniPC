const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const html = fs.readFileSync(__dirname + '/../../resources/rawfile/peer-chat.html', 'utf8');
const elements = {};
function element() {
  return { handlers: {}, style: {}, hidden: true, value: '', textContent: '', innerHTML: '',
    classList: { add() {}, remove() {} }, addEventListener(type, fn) { this.handlers[type] = fn; },
    setAttribute() {}, querySelectorAll() { return []; }, querySelector() { return element(); } };
}
for (const match of html.matchAll(/\bid="([^"]+)"/g)) elements[match[1]] = element();
const document = { getElementById: id => elements[id], addEventListener() {}, createElement: element };
const selections = [];
let error = '', currentState = null, tick;
const window = { chatBridge: { selectModel(name) { selections.push(name); return error; },
  models() { return JSON.stringify(currentState); } } };
vm.runInNewContext(html.match(/<script>([\s\S]*?)<\/script>/)[1], {
  document, window, Date, setInterval(fn) { tick = fn; }
});
const options = [{name:'Qwen2.5-7B-Instruct-Q4',vision:false}, {name:'Qwen-2.5-vl-3B-instruct-Q4',vision:true}];
const state = {selected: options[0].name, options, locked:false};
const dashboard = modelSettings => window.onNativeEvent({kind:'dashboard',devices:[],jobs:[],groups:[],modelSettings});
dashboard(state);
assert.equal(elements.settings.hidden, true, 'model selection stays off the home page');
elements.openSettings.handlers.click();
assert.equal(elements.settings.hidden, false);
assert.equal(elements.selectedModel.value, options[0].name);
assert(elements.modelHint.textContent.includes('只处理文字'));
assert(elements.selectedModel.innerHTML.includes('仅带图片'));
elements.selectedModel.value = options[1].name;
elements.selectedModel.handlers.change();
assert(elements.modelHint.textContent.includes('只处理带图片'));
dashboard(state);
assert.equal(elements.selectedModel.value, options[1].name, 'telemetry polls preserve the unsaved choice');
dashboard({...state,locked:true});
assert.equal(elements.selectedModel.disabled, true);
assert.equal(elements.applyModels.disabled, true);
currentState = state;
tick();
assert.equal(elements.selectedModel.disabled, false, 'native cleanup unlocks the open selector even with near-field disabled');
assert.equal(elements.applyModels.disabled, false, 'the draft survives inference ending');
error = '保存失败';
elements.applyModels.handlers.click();
assert.equal(elements.modelMessage.textContent, error);
assert.equal(elements.applyModels.disabled, false, 'failed persistence can be retried');
error = '';
elements.applyModels.handlers.click();
assert.equal(selections.at(-1), options[1].name);
assert.equal(elements.applyModels.disabled, true);
dashboard({...state,selected:options[1].name});
assert(elements.modelHint.textContent.includes('只处理带图片'));
elements.selectedModel.value = '';
elements.selectedModel.handlers.change();
assert(elements.modelHint.textContent.includes('自动模式'));
elements.applyModels.handlers.click();
assert.equal(selections.at(-1), '', 'automatic routing can be restored');
dashboard({selected:'Missing',options,locked:false});
assert(elements.selectedModel.innerHTML.includes('不可用'));
assert(elements.modelHint.textContent.includes('不可用'));
assert(html.includes('aria-label="设置"'), 'the home page opens model selection from settings');
assert(!html.includes('<summary>模型选择'), 'the home page no longer expands model selection inline');
elements.closeSettings.handlers.click();
assert.equal(elements.settings.hidden, true);
console.log('PASS: single-model selector, input-type hints, draft preservation, busy lock, persistence errors and automatic mode');
