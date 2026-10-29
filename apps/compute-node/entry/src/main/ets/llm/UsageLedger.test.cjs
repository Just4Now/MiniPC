const assert = require('node:assert/strict');
const vm = require('node:vm');
const { transpile } = require('../../../../../../../tests/ets-harness.cjs');
const files = {};
const fileIo = {
  OpenMode: { CREATE: 1, READ_WRITE: 2, TRUNC: 4 },
  readTextSync(path) { if (!(path in files)) throw new Error('missing'); return files[path]; },
  openSync(path) { files[path] = ''; return { fd: path }; },
  writeSync(fd, text) { files[fd] = text; },
  closeSync() {},
  renameSync(from, to) { files[to] = files[from]; delete files[from]; }
};
const context = { exports: {}, require(name) {
  if (name === '@kit.CoreFileKit') return { fileIo };
  return {};
}};
vm.runInNewContext(transpile(__dirname + '/UsageLedger.ets'), context);
const ledgerApi = context.exports;
const cst = (day, hour, minute) => Date.UTC(2026, 9, day, hour - 8, minute);

assert.equal(ledgerApi.flashPeak(cst(26, 9, 0)), true, 'Monday 09:00 Beijing is peak');
assert.equal(ledgerApi.flashPeak(cst(26, 8, 59)), false);
assert.equal(ledgerApi.flashPeak(cst(26, 11, 59)), true);
assert.equal(ledgerApi.flashPeak(cst(26, 12, 0)), false);
assert.equal(ledgerApi.flashPeak(cst(26, 14, 0)), true);
assert.equal(ledgerApi.flashPeak(cst(26, 17, 59)), true);
assert.equal(ledgerApi.flashPeak(cst(26, 18, 0)), false);
assert.equal(ledgerApi.flashPeak(cst(31, 10, 0)), false, 'Saturday is off-peak');
assert.equal(ledgerApi.flashPeak(cst(25, 10, 0)), false, 'Sunday is off-peak');
assert.equal(ledgerApi.flashMicroYuan(1000, 250, cst(26, 10, 0)), 4000);
assert.equal(ledgerApi.flashMicroYuan(1000, 250, cst(26, 8, 59)), 2000);
assert.equal(ledgerApi.flashMicroYuan(-5, 1.5, cst(26, 10, 0)), 0);

const peak = cst(26, 10, 0);
const ledger = ledgerApi.emptyUsage();
assert.equal(ledgerApi.recordLocalCall(ledger, '0:plan', '0:task', 1000, 100, peak), true);
assert.equal(ledgerApi.recordLocalCall(ledger, '0:child', '0:task', 400, 50, peak), true);
assert.equal(ledger.completedTasks, 0, 'rounds of one parent are not separate tasks yet');
assert.equal(ledgerApi.savedTokens(ledger), 1550);
assert.equal(ledger.savedMicroYuan, 1000 * 2 + 100 * 8 + 400 * 2 + 50 * 8);
assert.equal(ledgerApi.recordFinishedTask(ledger, '0:task'), true);
assert.equal(ledger.completedTasks, 1);
assert.equal(ledgerApi.recordFinishedTask(ledger, '0:task'), false);
assert.equal(ledgerApi.recordFinishedTask(ledger, '0:other'), false);
assert.equal(ledgerApi.recordLocalCall(ledger, '0:plan', '0:task', 1000, 100, peak), false);
assert.equal(ledgerApi.savedTokens(ledger), 1550);

const alone = ledgerApi.emptyUsage();
assert.equal(ledgerApi.recordLocalCall(alone, '0:once', '', 10, 5, cst(31, 10, 0)), true);
assert.equal(alone.completedTasks, 1);
assert.equal(alone.savedMicroYuan, 10 * 1 + 5 * 4);

ledgerApi.saveUsage('/data', ledger);
const restored = ledgerApi.loadUsage('/data');
assert.equal(restored.completedTasks, 1);
assert.equal(restored.promptTokens, 1400);
assert.equal(restored.completionTokens, 150);
assert.equal(ledgerApi.recordLocalCall(restored, '0:plan', '0:task', 1, 1, peak), false);
assert.equal(ledgerApi.recordFinishedTask(restored, '0:task'), false);
files['/data/usage-ledger.json'] = '{';
assert.equal(ledgerApi.loadUsage('/data').completedTasks, 0);
assert.equal(ledgerApi.loadUsage('').completedTasks, 0);
ledgerApi.saveUsage('', ledger);
files['/old/usage-ledger.json'] = JSON.stringify({
  completedTasks: 3, promptTokens: 10, completionTokens: 5, savedMicroYuan: 9, servedTasks: [], countedTasks: []
});
const old = ledgerApi.loadUsage('/old');
assert.equal(old.completedTasks, 3);
assert.equal(old.priceMode, 'flash');
assert.equal(old.inputPerMillion, 1000000);
assert.equal(old.outputPerMillion, 4000000);

const edited = ledgerApi.emptyUsage();
assert.equal(ledgerApi.applyUsageSettings(edited, JSON.stringify({
  tasks: '4', tokens: '100', yuan: '1.5', priceMode: 'custom', inputYuan: '2', outputYuan: '8'
})), '');
assert.equal(edited.completedTasks, 4);
assert.equal(edited.promptTokens, 100);
assert.equal(edited.completionTokens, 0);
assert.equal(edited.savedMicroYuan, 1500000);
assert.equal(edited.inputPerMillion, 2000000);
assert.equal(edited.outputPerMillion, 8000000);
assert.equal(JSON.parse(ledgerApi.usageSettingsJson(edited)).yuan, '1.5');
assert.equal(ledgerApi.recordLocalCall(edited, 'c1', '', 10, 1, cst(31, 10, 0)), true);
assert.equal(edited.savedMicroYuan, 1500000 + 28, 'custom rates ignore the flash window');
assert.equal(edited.completedTasks, 5);
assert.equal(ledgerApi.applyUsageSettings(edited, '{"reset":true}'), '');
assert.equal(edited.completedTasks, 0);
assert.equal(edited.promptTokens, 0);
assert.equal(edited.completionTokens, 0);
assert.equal(edited.savedMicroYuan, 0);
assert.equal(edited.priceMode, 'custom');
assert.equal(ledgerApi.recordLocalCall(edited, 'c1', '', 10, 1, cst(31, 10, 0)), false, 'reset keeps call dedup');
assert.equal(edited.savedMicroYuan, 0);
assert.equal(ledgerApi.recordLocalCall(edited, 'c2', '', 10, 0, peak), true);
assert.equal(edited.savedMicroYuan, 20);
const flashOnly = ledgerApi.emptyUsage();
flashOnly.inputPerMillion = 9000000;
assert.equal(ledgerApi.recordLocalCall(flashOnly, 'f', '', 10, 5, cst(31, 10, 0)), true);
assert.equal(flashOnly.savedMicroYuan, 10 * 1 + 5 * 4);
assert.equal(ledgerApi.applyUsageSettings(edited, '{"tasks":"x","tokens":"1","yuan":"0","priceMode":"flash","inputYuan":"1","outputYuan":"4"}'), '累计完成请填写非负整数。');
assert.equal(ledgerApi.formatMicroYuan(4000), '0.004');
console.log('PASS: flash peak windows, parent task counted once, call dedup and ledger file survive a reload');
