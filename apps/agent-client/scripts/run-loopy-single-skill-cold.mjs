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
const outputRoot = resolve(workspace, 'benchmark_artifacts/single_skill_cold_20260813_quick');
const master = '53V0224C19002918';
const collaborator = '53V0224C19002841';
const originalBundle = 'com.example.loop';
const singleBundle = 'com.example.l00p';
const layoutPath = '/data/local/tmp/loopy-single-skill-layout.json';

function argValue(name, fallback = '') {
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1] : fallback;
}

const caseId = argValue('--case');
const round = argValue('--round');
const attempt = argValue('--attempt', '1');
const manifestPath = resolve(argValue('--manifest', defaultManifestPath));
if (!caseId || !round) {
  throw new Error('Use --case <id> --round <01-06> [--attempt N].');
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

function stopBundle(serial, bundle) {
  try {
    shell(serial, 'aa', ['force-stop', bundle]);
  } catch (_error) {
    // A cold round may begin with the app already stopped.
  }
}

function stopAndClearBoth() {
  stopBundle(master, originalBundle);
  stopBundle(master, singleBundle);
  stopBundle(collaborator, originalBundle);
  // Required exact Gewu cache-clear command. Keep each device as its own HDC call.
  shell(master, 'pgrep -f gewu_service | xargs -r kill -9');
  shell(collaborator, 'pgrep -f gewu_service | xargs -r kill -9');
}

function lockAndVerify(serial) {
  const expected = {
    NPU_MIN: '1420000000', NPU_MAX: '1420000000', NPU_CUR: '1420000000',
    DDR_MIN: '4253000000', DDR_MAX: '4253000000', DDR_CUR: '4253000000'
  };
  let evidence = '';
  for (let attemptIndex = 1; attemptIndex <= 3; attemptIndex++) {
    const lockOutput = shell(serial, 'sh', ['/data/l00906474/GeWu/script/lock_oh_perf.sh']);
    // Reassert the benchmark's exact target values because available_frequencies
    // was observed to reorder once immediately after a Gewu inference.
    shell(serial, 'sh', ['-c',
      "echo 1420000000 > /sys/class/devfreq/npufreq/max_freq; " +
      "echo 1420000000 > /sys/class/devfreq/npufreq/min_freq; " +
      "echo 4253000000 > /sys/class/devfreq/ddrfreq/max_freq; " +
      "echo 4253000000 > /sys/class/devfreq/ddrfreq/min_freq"
    ]);
    sleep(250);
    const frequencies = shell(serial, 'sh', ['-c',
      "printf 'NPU_MIN='; cat /sys/class/devfreq/npufreq/min_freq; " +
      "printf 'NPU_MAX='; cat /sys/class/devfreq/npufreq/max_freq; " +
      "printf 'NPU_CUR='; cat /sys/class/devfreq/npufreq/cur_freq; " +
      "printf 'DDR_MIN='; cat /sys/class/devfreq/ddrfreq/min_freq; " +
      "printf 'DDR_MAX='; cat /sys/class/devfreq/ddrfreq/max_freq; " +
      "printf 'DDR_CUR='; cat /sys/class/devfreq/ddrfreq/cur_freq"
    ]);
    evidence += `attempt=${attemptIndex}\n${lockOutput}\n${frequencies}`;
    if (Object.entries(expected).every(([name, value]) => frequencies.includes(`${name}=${value}`))) {
      return evidence;
    }
  }
  throw new Error(`Frequency lock verification failed on ${serial}: ${evidence}`);
}

function clearLogs(serial) {
  try {
    shell(serial, 'hilog', ['-r']);
  } catch (_error) {
    // The runner additionally isolates metrics by the submit timestamp.
  }
}

function walk(node, visitor) {
  if (node === null || typeof node !== 'object') return;
  visitor(node);
  if (Array.isArray(node.children)) {
    for (const child of node.children) walk(child, visitor);
  }
}

function readModelStatus() {
  shell(master, 'uitest', ['dumpLayout', '-p', layoutPath]);
  const layout = JSON.parse(shell(master, 'cat', [layoutPath]));
  let modelStatus = '';
  let sendReady = false;
  walk(layout, (node) => {
    const text = node.attributes?.originalText ?? '';
    if (text.startsWith('Local LLM:')) modelStatus = text;
    if (text === 'Send' && node.attributes?.enabled === 'true') sendReady = true;
  });
  return { modelStatus, sendReady };
}

function waitForSingleReady() {
  const startedAt = Date.now();
  let lastState = null;
  while (Date.now() - startedAt < 60000) {
    try {
      lastState = readModelStatus();
      if (lastState.modelStatus.includes('Qwen2.5-7B-Instruct (Gewu)') && lastState.sendReady) {
        return { ...lastState, readyMs: Date.now() - startedAt };
      }
    } catch (_error) {
      // Retry while the ability is rendering.
    }
    sleep(1000);
  }
  throw new Error(`Single-device app did not become ready: ${JSON.stringify(lastState)}`);
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
  stopAndClearBoth();
  sleep(3000);
  clearLogs(master);
  clearLogs(collaborator);
  writeFileSync(resolve(roundDir, 'master-lock-pre.log'), lockAndVerify(master));
  writeFileSync(resolve(roundDir, 'collaborator-lock-pre.log'), lockAndVerify(collaborator));

  shell(master, 'aa', ['start', '-a', 'EntryAbility', '-b', singleBundle, '-m', 'entry']);
  const ready = waitForSingleReady();
  writeFileSync(resolve(roundDir, 'single-ready.json'), `${JSON.stringify({
    bundle: singleBundle,
    collaborationEnabled: false,
    clickedConnectOrReconnect: false,
    ...ready
  }, null, 2)}\n`);

  const run = spawnSync(process.execPath, [
    runner,
    '--mode', 'single',
    '--manifest', manifestPath,
    '--case', caseId,
    '--output', runnerOutput,
    '--case-timeout-ms', '0',
    '--stop-on-error'
  ], { cwd: workspace, stdio: 'inherit' });
  if (run.error) throw run.error;
  if (run.status !== 0) throw new Error(`Benchmark runner exited ${run.status ?? run.signal}`);

  const result = JSON.parse(readFileSync(resolve(runnerOutput, caseId, 'result.json'), 'utf8'));
  const accepted = result.evaluation?.pass === true &&
    result.evaluation?.actualSkills?.length === 1 &&
    result.evaluation.actualSkills[0] === expectedSkill &&
    result.master?.inferences?.length >= 1 &&
    result.master?.inputTokensTotal >= 1200 && result.master?.inputTokensTotal <= 1700 &&
    result.master?.outputTokensTotal > 0 &&
    result.master?.prefillMsTotal > 0 && result.master?.decodeMsTotal > 0 && result.e2eMs > 0;
  if (!accepted) {
    throw new Error(`Single-Skill acceptance failed: ${JSON.stringify({
      evaluation: result.evaluation,
      master: result.master,
      e2eMs: result.e2eMs
    })}`);
  }

  writeFileSync(resolve(roundDir, 'master-lock-post.log'), lockAndVerify(master));
  writeFileSync(resolve(roundDir, 'collaborator-lock-post.log'), lockAndVerify(collaborator));
  writeFileSync(resolve(roundDir, 'round-result.json'), `${JSON.stringify({
    round,
    attempt,
    caseId,
    expectedSkill,
    targetInputTokens: testCase.targetInputTokens ?? 1500,
    priorObservedInputTokens: testCase.observedInputTokens ?? null,
    beganAt,
    bundle: singleBundle,
    originalDualBundleTouched: false,
    cacheClearCommand: 'pgrep -f gewu_service | xargs -r kill -9',
    caseTimeoutMs: 0,
    frequenciesVerifiedBeforeAndAfter: true,
    appReadyMs: ready.readyMs,
    e2eMs: result.e2eMs,
    output: result.modelOutput,
    evaluation: result.evaluation,
    master: compactStats(result.master),
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
  stopAndClearBoth();
  writeFileSync(resolve(roundDir, 'cache-clear.log'),
    `${beganAt} pre-test and ${new Date().toISOString()} post-test: both devices executed pgrep -f gewu_service | xargs -r kill -9\n`);
}

if (completed) {
  console.log(`SINGLE SKILL COLD PASS round=${round} case=${caseId} skill=${expectedSkill}`);
}
