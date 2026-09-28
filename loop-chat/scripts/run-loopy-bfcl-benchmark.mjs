#!/usr/bin/env node

import { execFileSync } from 'node:child_process';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const HARMONY_DIR = resolve(SCRIPT_DIR, '..');
const DEFAULT_MANIFEST = join(HARMONY_DIR, 'benchmarks', 'bfcl_loopy_subset.json');
const DEFAULT_HDC = '/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc';
const MASTER_SERIAL = '53V0224C19002918';
const COLLAB_SERIAL = '53V0224C19002841';
const LAYOUT_PATH = '/data/local/tmp/loopy-bfcl-layout.json';
// Keep only the application control channel warm. The native Gewu session is
// request-scoped and is created inside runAgent after Send, then submitted as
// soon as both callbacks and tensor sockets are ready.
const DUAL_CONTROL_READY_STABLE_PROBES = 4;
const MOBILE_PREFILL_OPTIONS_PREFIX = '@@LOOPY_MOBILE_PREFILL_V1:';

function parseArgs(argv) {
  const result = {
    mode: '',
    output: '',
    manifest: DEFAULT_MANIFEST,
    hdc: process.env.HDC_BIN || DEFAULT_HDC,
    cases: [],
    buckets: [],
    skills: [],
    caseTimeoutMs: 0,
    stopOnError: false
  };
  for (let index = 0; index < argv.length; index++) {
    const name = argv[index];
    const value = argv[index + 1];
    if (name === '--mode') {
      result.mode = value;
      index++;
    } else if (name === '--output') {
      result.output = resolve(value);
      index++;
    } else if (name === '--manifest') {
      result.manifest = resolve(value);
      index++;
    } else if (name === '--case') {
      result.cases.push(value);
      index++;
    } else if (name === '--bucket') {
      result.buckets.push(value);
      index++;
    } else if (name === '--skill') {
      result.skills.push(value);
      index++;
    } else if (name === '--case-timeout-ms') {
      result.caseTimeoutMs = Number(value);
      index++;
    } else if (name === '--stop-on-error') {
      result.stopOnError = true;
    } else {
      throw new Error(`Unknown or incomplete argument: ${name}`);
    }
  }
  if (result.mode !== 'single' && result.mode !== 'dual') {
    throw new Error('Use --mode single or --mode dual.');
  }
  if (result.output.length === 0) {
    throw new Error('Use --output <directory>.');
  }
  if (!Number.isFinite(result.caseTimeoutMs) || (result.caseTimeoutMs !== 0 && result.caseTimeoutMs < 10000)) {
    throw new Error('--case-timeout-ms must be 0 (unbounded) or at least 10000.');
  }
  return result;
}

function loadBenchmark(path) {
  if (!path.endsWith('.jsonl')) {
    return JSON.parse(readFileSync(path, 'utf8'));
  }
  const rows = readFileSync(path, 'utf8').split('\n')
    .filter((line) => line.trim().length > 0)
    .map((line) => JSON.parse(line));
  return {
    name: 'Mobile Prefill Skill Bench (Loopy direct adapter)',
    scope: 'Dataset prompts are sent directly to the local model; expected values remain evaluator-only.',
    cases: rows.map((row) => ({
      id: row.id,
      category: row.skill,
      upstreamId: null,
      prompt: row.prompt,
      expectedSkills: [],
      expectedToolCalls: [],
      expectedText: [],
      mobilePrefill: {
        id: row.id,
        skill: row.skill,
        contextBucket: row.context_bucket,
        approxInputTokens: row.approx_input_tokens,
        targetContextTokens: row.target_context_tokens,
        metric: row.metric,
        expected: row.expected,
        maxNewTokens: row.max_new_tokens
      }
    }))
  };
}

function hdc(options, serial, command, commandArgs = [], maxBuffer = 16 * 1024 * 1024) {
  return execFileSync(options.hdc, ['-t', serial, 'shell', command, ...commandArgs], {
    encoding: 'utf8',
    maxBuffer,
    timeout: 20000,
    stdio: ['ignore', 'pipe', 'pipe']
  });
}

function sleep(milliseconds) {
  const buffer = new SharedArrayBuffer(4);
  Atomics.wait(new Int32Array(buffer), 0, 0, milliseconds);
}

function walk(node, visitor) {
  if (node === null || typeof node !== 'object') {
    return;
  }
  visitor(node);
  if (Array.isArray(node.children)) {
    for (const child of node.children) {
      walk(child, visitor);
    }
  }
}

function readLayout(options) {
  let lastError;
  for (let attempt = 0; attempt < 3; attempt++) {
    try {
      hdc(options, MASTER_SERIAL, 'uitest', ['dumpLayout', '-p', LAYOUT_PATH]);
      return JSON.parse(hdc(options, MASTER_SERIAL, 'cat', [LAYOUT_PATH]));
    } catch (error) {
      lastError = error;
      sleep(1000);
    }
  }
  throw lastError;
}

function layoutState(options) {
  const layout = readLayout(options);
  let transcript = '';
  let sendEnabled = false;
  let sendText = '';
  let collaborationStatus = '';
  let modelStatus = '';
  let inputValue = '';
  walk(layout, (node) => {
    const attributes = node.attributes;
    if (attributes === undefined) {
      return;
    }
    const originalText = attributes.originalText || '';
    if (originalText.startsWith('Loop is ready.')) {
      transcript = originalText;
    }
    if (originalText === 'Send' || originalText === '...') {
      sendText = originalText;
      sendEnabled = attributes.enabled === 'true';
    }
    if (originalText.startsWith('主机 ·')) {
      collaborationStatus = originalText;
    }
    if (originalText.startsWith('Local LLM:')) {
      modelStatus = originalText;
    }
    if (attributes.type === 'TextInput' && attributes.hint === 'Message Loop') {
      inputValue = originalText;
    }
  });
  return { transcript, sendEnabled, sendText, collaborationStatus, modelStatus, inputValue };
}

function enterPrompt(options, prompt) {
  let lastState;
  let injectionAttempted = false;
  for (let attempt = 0; attempt < 3; attempt++) {
    try {
      const existing = layoutState(options);
      if (injectionAttempted && existing.inputValue.length > 0) {
        return existing;
      }
      hdc(options, MASTER_SERIAL, 'uitest', [
        'uiInput', 'inputText', '500', '2580', prompt
      ]);
      injectionAttempted = true;
      lastState = waitUntil('prompt injection', 10000, () => {
        const state = layoutState(options);
        return { ok: state.inputValue.length > 0, value: state };
      });
      return lastState;
    } catch (_error) {
      sleep(1000);
    }
  }
  throw new Error(`Prompt injection failed: ${JSON.stringify(lastState)}`);
}

function clearLogs(_options) {
  // Keep lifecycle evidence for an already-prepared session. Per-case timer
  // rows are isolated by submitAtMs below, so destructive buffer clearing is
  // neither necessary nor safe for the ready-state probe.
}

function dumpTagLogs(options, serial, tag) {
  let output = '';
  for (let attempt = 0; attempt < 3; attempt++) {
    output = hdc(options, serial, 'hilog', [
      '-x', '-v', 'epoch', '-v', 'msec', '-T', tag
    ], 8 * 1024 * 1024);
    if (output.trim().length > 0) {
      return output;
    }
    sleep(250);
  }
  return output;
}

function dumpLogs(options, serial) {
  // Keep GEWU_LLM out: it prints full logits and can swamp a device log dump.
  // GEWU contains the timer/layer evidence; the app tags carry lifecycle and
  // ReAct execution evidence.
  const llmLifecycle = dumpTagLogs(options, serial, 'GEWU_LLM').split('\n')
    .filter((line) => line.includes('[Session] Start infer n_token'))
    .join('\n');
  return [
    dumpTagLogs(options, serial, 'GEWU'),
    llmLifecycle,
    dumpTagLogs(options, serial, 'CollabController'),
    dumpTagLogs(options, serial, 'LoopSkill')
  ].join('\n');
}

function logsSince(logs, timestampMs) {
  return logs.split('\n').filter((line) => {
    const match = line.match(/^(\d+\.\d+)\s/);
    return match !== null && Number(match[1]) * 1000 >= timestampMs - 1000;
  }).join('\n');
}

function waitUntil(description, timeoutMs, probe) {
  const startedAt = Date.now();
  let lastValue;
  while (timeoutMs === 0 || Date.now() - startedAt < timeoutMs) {
    lastValue = probe();
    if (lastValue.ok) {
      return lastValue.value;
    }
    sleep(750);
  }
  throw new Error(`Timed out waiting for ${description}: ${JSON.stringify(lastValue?.value)}`);
}

function waitForDualControlConnection(options) {
  let consecutiveReady = 0;
  return waitUntil('stable automatic collaboration control connection', 60000, () => {
    const state = layoutState(options);
    const connected = state.collaborationStatus.includes('协作者已连接') ||
      state.collaborationStatus.includes('协同会话已就绪');
    consecutiveReady = connected ? consecutiveReady + 1 : 0;
    return {
      ok: consecutiveReady >= DUAL_CONTROL_READY_STABLE_PROBES,
      value: {
        connected,
        consecutiveReady,
        collaborationStatus: state.collaborationStatus
      }
    };
  });
}

function firstEventTime(logs, marker) {
  for (const line of logs.split('\n')) {
    if (!line.includes(marker)) {
      continue;
    }
    const match = line.match(/^(\d+\.\d+)\s/);
    if (match !== null) {
      return Number(match[1]) * 1000;
    }
  }
  return null;
}

function nativeReadinessBeforeSubmit(masterLogs, collaboratorLogs, notBeforeMs) {
  const master = logsSince(masterLogs, notBeforeMs);
  const collaborator = logsSince(collaboratorLogs, notBeforeMs);
  const nativeSubmitAtMs = firstEventTime(master, 'ChatComplete:');
  const events = {
    controlSessionReadyAtMs: firstEventTime(master, 'collaborator session_ready'),
    masterDataServer30001AtMs: firstEventTime(master, 'self ip: 192.168.43.1, port: 30001'),
    masterDataServer30002AtMs: firstEventTime(master, 'self ip: 192.168.43.1, port: 30002'),
    collaboratorDataClient30001AtMs: firstEventTime(collaborator, 'peer ip: 192.168.43.1, port: 30001'),
    collaboratorDataClient30002AtMs: firstEventTime(collaborator, 'peer ip: 192.168.43.1, port: 30002'),
    masterSessionCallbackAtMs: firstEventTime(master, 'start register session trans cbk'),
    collaboratorSessionCallbackAtMs: firstEventTime(collaborator, 'start register session trans cbk')
  };
  const eventTimes = Object.values(events);
  const allReadyEventsPresent = eventTimes.every((value) => value !== null);
  const readyBeforeNativeSubmit = nativeSubmitAtMs !== null && allReadyEventsPresent &&
    eventTimes.every((value) => value <= nativeSubmitAtMs);
  const checks = {
    allReadyEventsPresent,
    readyBeforeNativeSubmit,
    noFreshDisconnect: !master.includes('device disconnected') &&
      !collaborator.includes('device disconnected')
  };
  return {
    ready: Object.values(checks).every(Boolean),
    nativeSubmitAtMs,
    events,
    checks
  };
}

function parseToolCalls(transcript) {
  const calls = [];
  const pattern = /\nTool\n([^\n(]+)\(/g;
  for (let match = pattern.exec(transcript); match !== null; match = pattern.exec(transcript)) {
    calls.push(match[1].trim());
  }
  return calls;
}

function parseSkillLoads(transcript) {
  const skills = [];
  const pattern = /\nSkill\n([^\n]+)/g;
  for (let match = pattern.exec(transcript); match !== null; match = pattern.exec(transcript)) {
    skills.push(match[1].trim());
  }
  return skills;
}

function parseStats(logs) {
  const inputs = [...logs.matchAll(/inputTokenCount:\s*(\d+)/g)].map((match) => Number(match[1]));
  const outputs = [...logs.matchAll(/outputTokenCount:\s*(\d+)/g)].map((match) => Number(match[1]));
  const prefills = [...logs.matchAll(/Prefill latency:\s*([0-9.]+)\s*ms/g)].map((match) => Number(match[1]));
  const decodes = [...logs.matchAll(/Decode latency:\s*([0-9.]+)\s*ms/g)].map((match) => Number(match[1]));
  const count = Math.max(inputs.length, outputs.length, prefills.length, decodes.length);
  const inferences = [];
  for (let index = 0; index < count; index++) {
    inferences.push({
      inputTokens: inputs[index] ?? null,
      outputTokens: outputs[index] ?? null,
      prefillMs: prefills[index] ?? null,
      decodeMs: decodes[index] ?? null
    });
  }
  const sum = (values) => values.reduce((total, value) => total + value, 0);
  return {
    inferences,
    inputTokensTotal: sum(inputs),
    outputTokensTotal: sum(outputs),
    prefillMsTotal: sum(prefills),
    decodeMsTotal: sum(decodes)
  };
}

function withoutHealthProbe(stats, logs) {
  if (!logs.includes('paired health probe passed') || stats.inferences.length < 1) {
    return stats;
  }
  // A cold round may include one or more failed probes before the successful
  // probe. The user request is always the final inference after that marker.
  const inferences = stats.inferences.slice(-1);
  const sumField = (name) => inferences.reduce((total, inference) => total + (inference[name] ?? 0), 0);
  return {
    inferences,
    inputTokensTotal: sumField('inputTokens'),
    outputTokensTotal: sumField('outputTokens'),
    prefillMsTotal: sumField('prefillMs'),
    decodeMsTotal: sumField('decodeMs')
  };
}

function sameArray(left, right) {
  return left.length === right.length && left.every((value, index) => value === right[index]);
}

function evaluateCase(testCase, transcript, masterLogs) {
  const actualToolCalls = parseToolCalls(transcript);
  const actualSkills = parseSkillLoads(transcript);
  const expectedSkills = testCase.expectedSkills || [];
  const expectedToolCalls = testCase.expectedToolCalls || [];
  const toolCallsCorrect = sameArray(actualToolCalls, expectedToolCalls);
  const skillsCorrect = sameArray(actualSkills, expectedSkills);
  // Expected markers often also occur in the user prompt. Evaluate only the
  // agent event/output portion so echoed requirements cannot become a pass.
  const userStart = transcript.indexOf('\nYou\n');
  const afterUser = userStart >= 0 ? transcript.slice(userStart + 6) : transcript;
  const eventMarkers = ['\nThought\n', '\nAction\n', '\nObservation\n', '\nTool\n', '\nSkill\n', '\nLoop\n', '\nError\n'];
  const eventOffsets = eventMarkers.map((marker) => afterUser.indexOf(marker)).filter((offset) => offset >= 0);
  const responseTranscript = eventOffsets.length > 0 ? afterUser.slice(Math.min(...eventOffsets)) : '';
  const textCorrect = (testCase.expectedText || []).every((text) => responseTranscript.includes(text));
  const executionCorrect = testCase.expectedExecution === undefined ||
    masterLogs.includes(`model chose execution=${testCase.expectedExecution}`);
  return {
    pass: skillsCorrect && toolCallsCorrect && textCorrect && executionCorrect &&
      !transcript.includes('\nError\n'),
    expectedSkills,
    actualSkills,
    skillsCorrect,
    expectedToolCalls,
    actualToolCalls,
    toolCallsCorrect,
    textCorrect,
    executionCorrect
  };
}

function extractDirectAnswer(transcript) {
  const marker = '\nLoop\n';
  const start = transcript.lastIndexOf(marker);
  if (start < 0) {
    return '';
  }
  return transcript.slice(start + marker.length).trim();
}

function runCase(options, testCase, outputDir) {
  console.log(`[${options.mode}] ${testCase.id}: clearing conversation`);
  const sessionNotBeforeMs = Date.now();
  hdc(options, MASTER_SERIAL, 'uitest', ['uiInput', 'click', '1160', '235']);
  sleep(2500);
  clearLogs(options);

  const submittedPrompt = testCase.mobilePrefill === null || testCase.mobilePrefill === undefined
    ? testCase.prompt
    : `${MOBILE_PREFILL_OPTIONS_PREFIX}${testCase.mobilePrefill.maxNewTokens}:0@@\n${testCase.prompt}`;
  let dualPreflight = null;
  if (options.mode === 'dual') {
    dualPreflight = {
      control: waitForDualControlConnection(options),
      native: null
    };
  } else {
    sleep(1000);
  }
  // Validate the always-on connection before focusing the input: the software
  // keyboard can move the status row outside the visible layout tree.
  enterPrompt(options, submittedPrompt);

  const stateBefore = layoutState(options);
  if (!stateBefore.sendEnabled || stateBefore.sendText !== 'Send') {
    throw new Error(`Send button is not ready before ${testCase.id}: ${JSON.stringify(stateBefore)}`);
  }

  const submitAtMs = Date.now();
  hdc(options, MASTER_SERIAL, 'uitest', ['uiInput', 'click', '1110', '2590']);
  const finalState = waitUntil(`${testCase.id} completion`, options.caseTimeoutMs, () => {
    const state = layoutState(options);
    // uitest inputText may normalize ASCII punctuation into full-width glyphs,
    // so byte-for-byte prompt matching can hide an already completed response.
    const conversationChanged = state.transcript !== stateBefore.transcript &&
      state.transcript.includes('\nYou\n');
    return {
      ok: conversationChanged && state.sendEnabled && state.sendText === 'Send',
      value: state
    };
  });
  const completedAtMs = Date.now();
  sleep(2500);

  const masterLogs = dumpLogs(options, MASTER_SERIAL);
  const collaboratorLogs = options.mode === 'dual' ? dumpLogs(options, COLLAB_SERIAL) : '';
  const caseDir = join(outputDir, testCase.id);
  mkdirSync(caseDir, { recursive: true });
  writeFileSync(join(caseDir, 'master.hilog.txt'), masterLogs);
  if (options.mode === 'dual') {
    writeFileSync(join(caseDir, 'collaborator.hilog.txt'), collaboratorLogs);
  }
  writeFileSync(join(caseDir, 'transcript.txt'), finalState.transcript);

  const recentMasterLogs = logsSince(masterLogs, submitAtMs);
  const recentCollaboratorLogs = logsSince(collaboratorLogs, submitAtMs);
  const masterStats = options.mode === 'dual'
    ? withoutHealthProbe(parseStats(recentMasterLogs), recentMasterLogs)
    : parseStats(recentMasterLogs);
  const collaboratorStats = options.mode === 'dual'
    ? withoutHealthProbe(parseStats(recentCollaboratorLogs), recentMasterLogs)
    : null;
  const evaluation = evaluateCase(testCase, finalState.transcript, recentMasterLogs);
  const nativePreflight = options.mode === 'dual'
    ? nativeReadinessBeforeSubmit(masterLogs, collaboratorLogs, sessionNotBeforeMs)
    : null;
  if (dualPreflight !== null) {
    dualPreflight.native = nativePreflight;
  }
  const collaborationEvidence = options.mode === 'dual' ? {
    masterLayers: masterLogs.includes('layers: 0-12'),
    collaboratorLayers: collaboratorLogs.includes('layerSeg: 13-27') ||
      collaboratorLogs.includes('"layers":"13-27"'),
    masterStartedInfer: masterStats.inferences.length > 0,
    collaboratorStartedInfer: collaboratorStats.inferences.length > 0,
    sessionReady: masterLogs.includes('collaborator session_ready'),
    dataPlaneReadyBeforeSubmit: nativePreflight?.ready === true,
    sessionEnded: recentMasterLogs.includes('collaborator session_ended') ||
      recentCollaboratorLogs.includes('remote session_end'),
    matchingFirstInputTokens: masterStats.inferences.length > 0 && collaboratorStats.inferences.length > 0 &&
      masterStats.inferences[0].inputTokens === collaboratorStats.inferences[0].inputTokens,
    matchingUserInputTokens: masterStats.inferences.length > 0 && collaboratorStats.inferences.length > 0 &&
      masterStats.inferences[masterStats.inferences.length - 1].inputTokens ===
        collaboratorStats.inferences[collaboratorStats.inferences.length - 1].inputTokens
  } : null;

  const result = {
    mode: options.mode,
    id: testCase.id,
    category: testCase.category,
    upstreamId: testCase.upstreamId,
    prompt: testCase.prompt,
    submitAtMs,
    completedAtMs,
    e2eMs: completedAtMs - submitAtMs,
    modelStatus: stateBefore.modelStatus,
    modelOutput: extractDirectAnswer(finalState.transcript),
    mobilePrefill: testCase.mobilePrefill ?? null,
    evaluation,
    master: masterStats,
    collaborator: collaboratorStats,
    collaborationEvidence,
    dualPreflight
  };
  writeFileSync(join(caseDir, 'result.json'), `${JSON.stringify(result, null, 2)}\n`);
  console.log(`[${options.mode}] ${testCase.id}: e2e=${result.e2eMs}ms pass=${evaluation.pass}`);
  return result;
}

function writeMobilePrefillResults(outputDir, results) {
  const adapted = results.filter((result) => result.mobilePrefill !== null && result.mobilePrefill !== undefined)
    .map((result) => {
      const source = result.mobilePrefill;
      const primary = result.master.inferences[0] ?? {};
      const collaborator = result.collaborator?.inferences?.[0] ?? null;
      const prefillMs = primary.prefillMs ?? null;
      const decodeMs = primary.decodeMs ?? null;
      const inputTokens = primary.inputTokens ?? null;
      const outputTokens = primary.outputTokens ?? null;
      return {
        id: source.id,
        skill: source.skill,
        context_bucket: source.contextBucket,
        approx_input_tokens: source.approxInputTokens,
        target_context_tokens: source.targetContextTokens,
        metric: source.metric,
        expected: source.expected,
        answer: result.modelOutput ?? '',
        max_new_tokens: source.maxNewTokens,
        backend: `hdc_loopy_direct_${result.mode}`,
        total_ms: result.e2eMs,
        // The current Loopy UI bridge does not expose host-observed first-token
        // delivery. Preserve it as null and report native Gewu Prefill instead.
        ttft_ms: null,
        native_metrics: {
          prefill_ms: prefillMs,
          prefill_tokens: inputTokens,
          prefill_tps: prefillMs > 0 && inputTokens !== null ? inputTokens * 1000 / prefillMs : null,
          decode_ms: decodeMs,
          decode_tokens: outputTokens,
          decode_tps: decodeMs > 0 && outputTokens !== null ? outputTokens * 1000 / decodeMs : null,
          collaborator: collaborator
        },
        status: result.error === undefined ? 'ok' : 'error',
        error: result.error ?? null
      };
    });
  if (adapted.length === 0) {
    return;
  }
  writeFileSync(join(outputDir, 'mobile_prefill_results.jsonl'),
    adapted.map((row) => JSON.stringify(row)).join('\n') + '\n');
}

function writeCsv(outputDir, results) {
  const columns = [
    'mode', 'id', 'category', 'pass', 'e2e_ms', 'inference_calls', 'input_tokens_total',
    'output_tokens_total', 'prefill_ms_total', 'decode_ms_total', 'actual_skills', 'actual_tool_calls',
    'dual_master_started', 'dual_collaborator_started', 'dual_matching_input_tokens'
  ];
  const escape = (value) => `"${String(value ?? '').replaceAll('"', '""')}"`;
  const rows = results.map((result) => [
    result.mode,
    result.id,
    result.category,
    result.evaluation.pass,
    result.e2eMs,
    result.master.inferences.length,
    result.master.inputTokensTotal,
    result.master.outputTokensTotal,
    result.master.prefillMsTotal,
    result.master.decodeMsTotal,
    result.evaluation.actualSkills.join('|'),
    result.evaluation.actualToolCalls.join('|'),
    result.collaborationEvidence?.masterStartedInfer,
    result.collaborationEvidence?.collaboratorStartedInfer,
    result.collaborationEvidence?.matchingFirstInputTokens
  ]);
  writeFileSync(join(outputDir, 'results.csv'), [columns, ...rows]
    .map((row) => row.map(escape).join(','))
    .join('\n') + '\n');
}

function main() {
  const options = parseArgs(process.argv.slice(2));
  const manifest = loadBenchmark(options.manifest);
  const cases = manifest.cases.filter((testCase) => {
    const idSelected = options.cases.length === 0 || options.cases.includes(testCase.id);
    const bucketSelected = options.buckets.length === 0 ||
      options.buckets.includes(testCase.mobilePrefill?.contextBucket);
    const skillSelected = options.skills.length === 0 ||
      options.skills.includes(testCase.mobilePrefill?.skill);
    return idSelected && bucketSelected && skillSelected;
  });
  if (cases.length === 0) {
    throw new Error('No benchmark cases selected.');
  }
  mkdirSync(options.output, { recursive: true });
  const connected = execFileSync(options.hdc, ['list', 'targets'], { encoding: 'utf8' });
  if (!connected.includes(MASTER_SERIAL) || (options.mode === 'dual' && !connected.includes(COLLAB_SERIAL))) {
    throw new Error(`Required devices are not connected: ${connected.trim()}`);
  }
  const initialState = layoutState(options);
  const expectedModel = options.mode === 'dual' ? 'Gewu Collaboration' : 'Qwen2.5-7B-Instruct (Gewu)';
  if (!initialState.modelStatus.includes(expectedModel)) {
    throw new Error(`Wrong HAP for ${options.mode}: ${initialState.modelStatus}`);
  }
  const results = [];
  for (const testCase of cases) {
    try {
      results.push(runCase(options, testCase, options.output));
    } catch (error) {
      const failure = {
        mode: options.mode,
        id: testCase.id,
        category: testCase.category,
        prompt: testCase.prompt,
        mobilePrefill: testCase.mobilePrefill ?? null,
        modelOutput: '',
        error: error instanceof Error ? error.stack : String(error)
      };
      const caseDir = join(options.output, testCase.id);
      mkdirSync(caseDir, { recursive: true });
      try {
        const failureState = layoutState(options);
        writeFileSync(join(caseDir, 'master.hilog.txt'), dumpLogs(options, MASTER_SERIAL));
        if (options.mode === 'dual') {
          writeFileSync(join(caseDir, 'collaborator.hilog.txt'), dumpLogs(options, COLLAB_SERIAL));
        }
        writeFileSync(join(caseDir, 'transcript.txt'), failureState.transcript);
      } catch (snapshotError) {
        failure.snapshotError = snapshotError instanceof Error ? snapshotError.stack : String(snapshotError);
      }
      writeFileSync(join(caseDir, 'failure.json'), `${JSON.stringify(failure, null, 2)}\n`);
      console.error(`[${options.mode}] ${testCase.id}: FAILED ${failure.error}`);
      results.push({
        ...failure,
        evaluation: { pass: false, actualSkills: [], actualToolCalls: [] },
        e2eMs: null,
        master: { inferences: [], inputTokensTotal: 0, outputTokensTotal: 0, prefillMsTotal: 0, decodeMsTotal: 0 },
        collaborationEvidence: null
      });
      if (options.stopOnError) {
        break;
      }
    }
  }
  writeFileSync(join(options.output, 'results.json'), `${JSON.stringify({
    benchmark: manifest.name,
    scope: manifest.scope,
    generatedAt: new Date().toISOString(),
    mode: options.mode,
    results
  }, null, 2)}\n`);
  writeCsv(options.output, results);
  writeMobilePrefillResults(options.output, results);
  process.exitCode = results.every((result) => result.evaluation.pass) ? 0 : 2;
}

main();
