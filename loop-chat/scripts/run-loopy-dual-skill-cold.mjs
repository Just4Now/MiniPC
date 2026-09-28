#!/usr/bin/env node

import { execFileSync, spawnSync } from 'node:child_process';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const scriptDir = dirname(fileURLToPath(import.meta.url));
const harmonyDir = resolve(scriptDir, '..');
const workspace = resolve(harmonyDir, '..');
const hdc = '/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc';
const runner = resolve(scriptDir, 'run-loopy-bfcl-benchmark.mjs');
const defaultManifestPath = resolve(workspace,
  'benchmark_artifacts/mobile_prefill_skill_20260813/locked_1500_natural_6skills/manifest.json');
const outputRoot = resolve(workspace, 'benchmark_artifacts/dual_skill_cold_20260813');
const master = '53V0224C19002918';
const collaborator = '53V0224C19002841';
const layoutPath = '/data/local/tmp/loopy-dual-skill-layout.json';

function argValue(name, fallback = '') {
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1] : fallback;
}

const caseId = argValue('--case');
const round = argValue('--round');
const attempt = argValue('--attempt', '1');
const order = argValue('--order', 'collaborator-first');
const manifestPath = resolve(argValue('--manifest', defaultManifestPath));
if (!caseId || !round) {
  throw new Error('Use --case <id> --round <01-06> [--attempt N] [--order collaborator-first|master-first].');
}
if (!['collaborator-first', 'master-first'].includes(order)) {
  throw new Error(`Unsupported start order: ${order}`);
}

const manifest = JSON.parse(readFileSync(manifestPath, 'utf8'));
const testCase = manifest.cases.find((candidate) => candidate.id === caseId);
if (!testCase || !Array.isArray(testCase.expectedSkills) || testCase.expectedSkills.length !== 1) {
  throw new Error(`Expected exactly one Skill for case ${caseId}.`);
}
const expectedSkill = testCase.expectedSkills[0];
const roundDir = resolve(outputRoot, `${round}_${caseId}_attempt_${attempt}`);
const runnerOutput = resolve(roundDir, 'benchmark');
mkdirSync(runnerOutput, { recursive: true });

function sleep(ms) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

function shell(serial, command, commandArgs = [], timeout = 120000) {
  return execFileSync(hdc, ['-t', serial, 'shell', command, ...commandArgs], {
    cwd: workspace,
    encoding: 'utf8',
    timeout,
    maxBuffer: 16 * 1024 * 1024
  });
}

function stopAndClear(serial) {
  try {
    shell(serial, 'aa', ['force-stop', 'com.example.loop']);
  } catch (_error) {
    // A cold round may begin with the app already stopped.
  }
  // Required exact Gewu cache-clear command. Keep this as its own HDC call.
  shell(serial, 'pgrep -f gewu_service | xargs -r kill -9');
}

function lockAndVerify(serial) {
  const lockOutput = shell(serial, 'sh', ['/data/l00906474/GeWu/script/lock_oh_perf.sh']);
  const frequencies = shell(serial, 'sh', ['-c',
    "printf 'NPU_MIN='; cat /sys/class/devfreq/npufreq/min_freq; " +
    "printf 'NPU_MAX='; cat /sys/class/devfreq/npufreq/max_freq; " +
    "printf 'NPU_CUR='; cat /sys/class/devfreq/npufreq/cur_freq; " +
    "printf 'DDR_MIN='; cat /sys/class/devfreq/ddrfreq/min_freq; " +
    "printf 'DDR_MAX='; cat /sys/class/devfreq/ddrfreq/max_freq; " +
    "printf 'DDR_CUR='; cat /sys/class/devfreq/ddrfreq/cur_freq"
  ]);
  const expected = {
    NPU_MIN: '1420000000', NPU_MAX: '1420000000', NPU_CUR: '1420000000',
    DDR_MIN: '4253000000', DDR_MAX: '4253000000', DDR_CUR: '4253000000'
  };
  for (const [name, value] of Object.entries(expected)) {
    if (!frequencies.includes(`${name}=${value}`)) {
      throw new Error(`Frequency lock verification failed on ${serial}: ${frequencies}`);
    }
  }
  return `${lockOutput}\n${frequencies}`;
}

function networkIdentity(serial, expectedAddress) {
  const output = shell(serial, 'sh', ['-c', 'ip -o -4 addr; ip route']);
  if (!output.includes(`inet ${expectedAddress}/24`)) {
    throw new Error(`Unexpected network identity on ${serial}: ${output}`);
  }
  return output;
}

function clearLogs(serial) {
  try {
    shell(serial, 'hilog', ['-r']);
  } catch (_error) {
    // Timestamped runner evidence still isolates the round if clearing is unavailable.
  }
}

function start(serial) {
  shell(serial, 'aa', ['start', '-a', 'EntryAbility', '-b', 'com.example.loop', '-m', 'entry']);
}

function walk(node, visitor) {
  if (node === null || typeof node !== 'object') return;
  visitor(node);
  if (Array.isArray(node.children)) {
    for (const child of node.children) walk(child, visitor);
  }
}

function readUi(serial) {
  let lastError = '';
  for (let attemptIndex = 0; attemptIndex < 5; attemptIndex++) {
    try {
      shell(serial, 'uitest', ['dumpLayout', '-p', layoutPath]);
      const layout = JSON.parse(shell(serial, 'cat', [layoutPath]));
      let collaborationStatus = '';
      let modelStatus = '';
      walk(layout, (node) => {
        const text = node.attributes?.originalText ?? '';
        if (text.startsWith('主机 ·') || text.startsWith('协作者 ·')) collaborationStatus = text;
        if (text.startsWith('Local LLM:')) modelStatus = text;
      });
      return { collaborationStatus, modelStatus };
    } catch (error) {
      lastError = error instanceof Error ? error.message : String(error);
      sleep(500);
    }
  }
  throw new Error(`UI probe failed on ${serial}: ${lastError}`);
}

function waitForStableAutomaticConnection(startedAtMs) {
  let consecutive = 0;
  let lastState = null;
  while (Date.now() - startedAtMs < 60000) {
    const masterUi = readUi(master);
    const collaboratorUi = readUi(collaborator);
    const connected = masterUi.collaborationStatus.includes('协作者已连接') &&
      collaboratorUi.collaborationStatus.includes('已连接主机');
    consecutive = connected ? consecutive + 1 : 0;
    lastState = { masterUi, collaboratorUi, connected, consecutive };
    if (consecutive >= 4) {
      return { ...lastState, connectionMs: Date.now() - startedAtMs };
    }
    sleep(1000);
  }
  throw new Error(`Automatic connection did not stabilize: ${JSON.stringify(lastState)}`);
}

function rate(tokens, ms) {
  return Number.isFinite(tokens) && Number.isFinite(ms) && ms > 0 ? tokens * 1000 / ms : null;
}

function compactStats(stats) {
  return {
    ...stats,
    prefillTokensPerSecond: rate(stats.inputTokensTotal, stats.prefillMsTotal),
    decodeTokensPerSecond: rate(stats.outputTokensTotal, stats.decodeMsTotal)
  };
}

let completed = false;
const beganAt = new Date().toISOString();
try {
  stopAndClear(master);
  stopAndClear(collaborator);
  sleep(3000);
  clearLogs(master);
  clearLogs(collaborator);
  writeFileSync(resolve(roundDir, 'master-lock-pre.log'), lockAndVerify(master));
  writeFileSync(resolve(roundDir, 'collaborator-lock-pre.log'), lockAndVerify(collaborator));
  writeFileSync(resolve(roundDir, 'network-identity.log'), [
    networkIdentity(master, '192.168.43.1'),
    networkIdentity(collaborator, '192.168.43.4')
  ].join('\n'));

  const first = order === 'master-first' ? master : collaborator;
  const second = order === 'master-first' ? collaborator : master;
  const appsStartedAtMs = Date.now();
  start(first);
  sleep(2000);
  start(second);
  const connection = waitForStableAutomaticConnection(appsStartedAtMs);
  writeFileSync(resolve(roundDir, 'automatic-connection.json'), `${JSON.stringify({
    order,
    clickedConnectOrReconnect: false,
    ...connection
  }, null, 2)}\n`);

  const run = spawnSync(process.execPath, [
    runner,
    '--mode', 'dual',
    '--manifest', manifestPath,
    '--case', caseId,
    '--output', runnerOutput,
    '--case-timeout-ms', '0',
    '--stop-on-error'
  ], { cwd: workspace, stdio: 'inherit' });
  if (run.error) throw run.error;
  if (run.status !== 0) throw new Error(`Benchmark runner exited ${run.status ?? run.signal}`);

  const result = JSON.parse(readFileSync(resolve(runnerOutput, caseId, 'result.json'), 'utf8'));
  const evidence = result.collaborationEvidence ?? {};
  const accepted = result.evaluation?.pass === true &&
    result.evaluation?.actualSkills?.length === 1 &&
    result.evaluation.actualSkills[0] === expectedSkill &&
    evidence.masterStartedInfer === true &&
    evidence.collaboratorStartedInfer === true &&
    evidence.matchingUserInputTokens === true &&
    evidence.dataPlaneReadyBeforeSubmit === true &&
    evidence.sessionEnded === true &&
    result.master?.inputTokensTotal >= 1200 && result.master?.inputTokensTotal <= 1700 &&
    result.collaborator?.inputTokensTotal >= 1200 && result.collaborator?.inputTokensTotal <= 1700;
  if (!accepted) {
    throw new Error(`Dual-Skill acceptance failed: ${JSON.stringify({ evaluation: result.evaluation, evidence })}`);
  }

  const masterPost = lockAndVerify(master);
  const collaboratorPost = lockAndVerify(collaborator);
  writeFileSync(resolve(roundDir, 'master-lock-post.log'), masterPost);
  writeFileSync(resolve(roundDir, 'collaborator-lock-post.log'), collaboratorPost);
  writeFileSync(resolve(roundDir, 'round-result.json'), `${JSON.stringify({
    round,
    attempt,
    caseId,
    expectedSkill,
    targetInputTokens: testCase.targetInputTokens ?? 1500,
    priorObservedInputTokens: testCase.observedInputTokens ?? null,
    order,
    beganAt,
    clickedConnectOrReconnect: false,
    cacheClearCommand: 'pgrep -f gewu_service | xargs -r kill -9',
    frequenciesVerifiedBeforeAndAfter: true,
    automaticConnectionMs: connection.connectionMs,
    e2eMs: result.e2eMs,
    output: result.modelOutput,
    evaluation: result.evaluation,
    master: compactStats(result.master),
    collaborator: compactStats(result.collaborator),
    collaborationEvidence: evidence,
    dualPreflight: result.dualPreflight,
    pass: true
  }, null, 2)}\n`);
  completed = true;
} catch (error) {
  writeFileSync(resolve(roundDir, 'cold-round-failure.json'), `${JSON.stringify({
    round,
    attempt,
    caseId,
    expectedSkill,
    beganAt,
    error: error instanceof Error ? error.stack : String(error)
  }, null, 2)}\n`);
  throw error;
} finally {
  stopAndClear(master);
  stopAndClear(collaborator);
  writeFileSync(resolve(roundDir, 'cache-clear.log'),
    `${beganAt} pre-test and ${new Date().toISOString()} post-test: both devices executed pgrep -f gewu_service | xargs -r kill -9\n`);
}

if (completed) {
  console.log(`DUAL SKILL COLD PASS round=${round} case=${caseId} skill=${expectedSkill}`);
}
