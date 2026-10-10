'use strict';
// Existing regressions from both repositories; no device or external side effects.
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const root = path.resolve(__dirname, '..');
const mode = process.argv[2] || 'all';
if (!['all', 'legacy', 'agent', 'protocol'].includes(mode)) {
  console.error('Usage: node scripts/test-all.cjs [all|legacy|agent|protocol]');
  process.exit(2);
}
function discover(relative) {
  const found = [];
  function walk(dir) {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const file = path.join(dir, entry.name);
      if (entry.isDirectory()) walk(file);
      else if (entry.name.endsWith('.test.cjs')) found.push(file);
    }
  }
  walk(path.join(root, relative));
  return found.sort();
}
const groups = {
  legacy: [...discover('src/chat-end/entry/src/main/ets'), ...discover('src/model-end/entry/src/main/ets')],
  agent: [path.join(root, 'loop-chat/agent_core/tests/run-all.cjs'),
    ...discover('gate-a/compute-probe/entry/src/main/ets'),
    ...discover('gate-a/loop-client/entry/src/main/ets')],
  protocol: [path.join(root, 'loop-minipc/scripts/test-all.cjs')]
};
const suites = mode === 'all' ? Object.values(groups).flat() : groups[mode];
const compiler = process.env.TYPESCRIPT_PATH;
let failures = 0;
for (const suite of suites) {
  const relative = path.relative(root, suite).replaceAll('\\', '/');
  console.log('\nRUN ' + relative);
  const result = spawnSync(process.execPath, [suite, ...(compiler ? [compiler] : [])], {
    cwd: root, stdio: 'inherit', env: process.env
  });
  if (result.error || result.status !== 0) {
    failures++;
    console.error('FAILED ' + relative + ': ' + (result.error?.message || 'exit=' + result.status));
  }
}
console.log('\nINTEGRATION ' + (suites.length - failures) + '/' + suites.length + ' suites passed (' + mode + '). SDK builds and physical-device acceptance are separate.');
if (failures) process.exitCode = 1;
