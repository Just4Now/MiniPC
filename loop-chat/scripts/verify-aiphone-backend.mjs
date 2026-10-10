#!/usr/bin/env node
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  symlinkSync
} from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const scriptDir = dirname(fileURLToPath(import.meta.url));
const harmonyRoot = resolve(scriptDir, '..');
const repoRoot = resolve(harmonyRoot, '..');
const hvigorRoot = '/Applications/DevEco-Studio.app/Contents/tools/hvigor';
const hvigor = '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/bin/hvigor.js';
const sdkHome = process.env.DEVECO_SDK_HOME || '/Applications/DevEco-Studio.app/Contents/sdk';
const jbrHome = '/Applications/DevEco-Studio.app/Contents/jbr/Contents/Home';
const harOutput = resolve(harmonyRoot, 'agent_core/build/default/outputs/default/agent_core.har');

const checks = [];

function pass(name) {
  checks.push({ name, ok: true });
  console.log(`PASS ${name}`);
}

function fail(name, detail) {
  checks.push({ name, ok: false });
  console.error(`FAIL ${name}`);
  if (detail) {
    console.error(`     ${detail}`);
  }
}

function assert(condition, name, detail = '') {
  if (condition) {
    pass(name);
  } else {
    fail(name, detail);
  }
}

function read(relativePath) {
  return readFileSync(resolve(repoRoot, relativePath), 'utf8');
}

function assertContains(text, needle, name) {
  assert(text.includes(needle), name, `missing ${needle}`);
}

function runHarBuild() {
  assert(existsSync(hvigor), 'DevEco hvigor is installed', hvigor);
  assert(existsSync(sdkHome), 'DevEco SDK home exists', sdkHome);
  if (!existsSync(hvigor) || !existsSync(sdkHome)) {
    return;
  }

  const nodePathRoot = mkdtempSync(resolve(tmpdir(), 'loopy-hvigor-'));
  const scopeRoot = resolve(nodePathRoot, '@ohos');
  mkdirSync(scopeRoot, { recursive: true });
  symlinkSync(resolve(hvigorRoot, 'hvigor'), resolve(scopeRoot, 'hvigor'), 'dir');
  symlinkSync(resolve(hvigorRoot, 'hvigor-ohos-plugin'), resolve(scopeRoot, 'hvigor-ohos-plugin'), 'dir');

  let result;
  try {
    result = spawnSync(process.execPath, [
      hvigor,
      '--mode',
      'module',
      '-p',
      'module=agent_core@default',
      '-p',
      'product=default',
      'assembleHar',
      '--analyze=normal',
      '--parallel',
      '--incremental',
      '--no-daemon'
    ], {
      cwd: harmonyRoot,
      env: {
        ...process.env,
        DEVECO_SDK_HOME: sdkHome,
        OHOS_SDK_HOME: resolve(sdkHome, 'default/openharmony'),
        JAVA_HOME: jbrHome,
        NODE_PATH: nodePathRoot,
        PATH: `${resolve(jbrHome, 'bin')}:${process.env.PATH ?? ''}`
      },
      encoding: 'utf8'
    });
  } finally {
    rmSync(nodePathRoot, { recursive: true, force: true });
  }

  if (result.stdout.trim().length > 0) {
    console.log(result.stdout.trim());
  }
  if (result.stderr.trim().length > 0) {
    console.error(result.stderr.trim());
  }
  const built = result.status === 0 &&
    result.stdout.includes('BUILD SUCCESSFUL') &&
    existsSync(harOutput);
  assert(built, 'agent_core HAR builds', `exit status ${result.status}; HAR exists=${existsSync(harOutput)}`);
}

function verifySourceContracts() {
  const protocol = read('harmony/agent_core/src/main/ets/a2ui/A2uiProtocol.ets');
  const llmProvider = read('harmony/agent_core/src/main/ets/model/LlmProvider.ets');
  const packagedLlmConfig = JSON.parse(read('harmony/entry/src/main/resources/rawfile/llm_config.json'));
  const openAiModel = read('harmony/agent_core/src/main/ets/model/OpenAiCompatibleModel.ets');
  const scriptedModel = read('harmony/agent_core/src/main/ets/model/ScriptedLocalModel.ets');
  const aiphoneA2ui = read('harmony/agent_core/src/main/ets/aiphone/AiphoneA2ui.ets');
  const definitions = read('harmony/agent_core/src/main/ets/aiphone/AiphoneToolDefinitions.ets');
  const executor = read('harmony/agent_core/src/main/ets/aiphone/AiphoneToolExecutor.ets');
  const backend = read('harmony/agent_core/src/main/ets/aiphone/LoopBackend.ets');
  const index = read('harmony/agent_core/Index.ets');
  const runtimeDefinitions = read('harmony/agent_core/src/main/ets/aiphone/runtime/ToolDefinitionRegistry.ets');
  const runtimeGateway = read('harmony/agent_core/src/main/ets/aiphone/runtime/ToolGatewayClient.ets');
  const conversationContext = read('harmony/agent_core/src/main/ets/agent/ConversationContext.ets');
  const conversationStore = read('harmony/agent_core/src/main/ets/agent/ConversationStore.ets');
  const skillParser = read('harmony/agent_core/src/main/ets/skill/SkillMarkdownParser.ets');
  const skillSnapshot = read('harmony/agent_core/src/main/ets/skill/SkillSnapshot.ets');
  const skillStore = read('harmony/agent_core/src/main/ets/skill/SkillStore.ets');
  const skillReadTool = read('harmony/agent_core/src/main/ets/skill/SkillReadTool.ets');
  const sandboxFileReadTool = read('harmony/agent_core/src/main/ets/file/SandboxFileReadTool.ets');
  const sandboxFileWriteTool = read('harmony/agent_core/src/main/ets/file/SandboxFileWriteTool.ets');
  const sandboxDirectoryTools = read('harmony/agent_core/src/main/ets/file/SandboxDirectoryTools.ets');
  const sandboxWorkspace = read('harmony/agent_core/src/main/ets/file/SandboxWorkspace.ets');
  const sandboxWorkspaceStore = read('harmony/agent_core/src/main/ets/file/SandboxWorkspaceStore.ets');
  const bundledWorkspaceTemp = read('harmony/entry/src/main/resources/rawfile/workspace/temp.txt');
  const runner = read('harmony/agent_core/src/main/ets/agent/ReActAgentRunner.ets');
  const reactCompatibility = read('harmony/agent_core/src/main/ets/agent/ReActResponseCompatibility.ets');
  const sessionBackedModel = read('harmony/agent_core/src/main/ets/model/SessionBackedModel.ets');
  const collaborationController = read('harmony/entry/src/main/ets/llm/CollaborationController.ets');
  const collaborationInitStart = collaborationController.indexOf('async init(): Promise<boolean>');
  const collaborationReadyStart = collaborationController.indexOf(
    'async ensureReadyForInference(',
    collaborationInitStart
  );
  const collaborationInit = collaborationInitStart >= 0 && collaborationReadyStart > collaborationInitStart
    ? collaborationController.slice(collaborationInitStart, collaborationReadyStart)
    : '';
  const genericMcp = read('harmony/agent_core/src/main/ets/aiphone/runtime/GenericMcpClient.ets');
  const modelScope = read('harmony/agent_core/src/main/ets/modelscope/ModelScopeDirectClient.ets');
  const modelScopeSearchStart = modelScope.indexOf('async search(useCase: string)');
  const modelScopeExecuteStart = modelScope.indexOf('async execute(qualifiedName: string', modelScopeSearchStart);
  const modelScopeExecuteEnd = modelScope.indexOf('private async fetchOperationalServers', modelScopeExecuteStart);
  const modelScopeSearch = modelScopeSearchStart >= 0 && modelScopeExecuteStart > modelScopeSearchStart
    ? modelScope.slice(modelScopeSearchStart, modelScopeExecuteStart)
    : '';
  const modelScopeExecute = modelScopeExecuteStart >= 0 && modelScopeExecuteEnd > modelScopeExecuteStart
    ? modelScope.slice(modelScopeExecuteStart, modelScopeExecuteEnd)
    : '';
  const modelScopeEmptyGuard = modelScopeSearch.indexOf('if (emptyObservation.length > MAX_OBSERVATION_CHARS)');
  const modelScopeCandidateLoop = modelScopeSearch.indexOf('for (let index = 0; index < selected.length; index++)');
  const modelScopeCandidateBound = modelScopeSearch.indexOf('if (candidateObservation.length > MAX_OBSERVATION_CHARS)');
  const modelScopeCandidateRollback = modelScopeSearch.indexOf('candidates.pop()', modelScopeCandidateBound);
  const modelScopeAuthorization = modelScopeSearch.indexOf(
    'this.discoveredTools.add(candidates[index].qualifiedName)',
    modelScopeCandidateRollback
  );
  const registry = read('harmony/agent_core/src/main/ets/agent/ToolRegistry.ets');
  const reactRunner = read('harmony/agent_core/src/main/ets/agent/ReActAgentRunner.ets');
  const demoEntry = read('harmony/entry/src/main/ets/pages/Index.ets');
  const deviceBenchmark = read('harmony/scripts/run-loopy-bfcl-benchmark.mjs');
  const initializeCollaborationStart = demoEntry.indexOf('private async initializeModel');
  const prepareCollaborationStart = demoEntry.indexOf(
    'private prepareCollaborationSession(): void',
    initializeCollaborationStart
  );
  const initializeCollaboration = initializeCollaborationStart >= 0 &&
    prepareCollaborationStart > initializeCollaborationStart
    ? demoEntry.slice(initializeCollaborationStart, prepareCollaborationStart)
    : '';
  const sandboxBrowserStart = demoEntry.indexOf('@Builder\n  sandboxBrowserView');
  const sandboxBrowserEnd = demoEntry.indexOf('private async runAgent', sandboxBrowserStart);
  const sandboxBrowser = sandboxBrowserStart >= 0 && sandboxBrowserEnd > sandboxBrowserStart
    ? demoEntry.slice(sandboxBrowserStart, sandboxBrowserEnd)
    : '';
  const onSendFinishedStart = collaborationController.indexOf('onSendFinished(): void');
  const onClearStart = collaborationController.indexOf('onClear(): void', onSendFinishedStart);
  const onInferenceFailedStart = collaborationController.indexOf('onInferenceFailed(', onClearStart);
  const onSendFinished = onSendFinishedStart >= 0 && onClearStart > onSendFinishedStart
    ? collaborationController.slice(onSendFinishedStart, onClearStart)
    : '';
  const onClear = onClearStart >= 0 && onInferenceFailedStart > onClearStart
    ? collaborationController.slice(onClearStart, onInferenceFailedStart)
    : '';
  const connectionStateStart = collaborationController.indexOf('private onConnectionStateChanged');
  const refreshConnectedStatusStart = collaborationController.indexOf(
    'private refreshConnectedStatus',
    connectionStateStart
  );
  const connectionStateHandler = connectionStateStart >= 0 && refreshConnectedStatusStart > connectionStateStart
    ? collaborationController.slice(connectionStateStart, refreshConnectedStatusStart)
    : '';
  const runtimeDir = resolve(repoRoot, 'harmony/agent_core/src/main/ets/aiphone/runtime');
  const socialHubStart = runtimeGateway.indexOf('async function callLocalSocialHubTool');
  const socialHubEnd = runtimeGateway.indexOf('async function callLocalXTool', socialHubStart);
  const socialHubFunction = socialHubStart >= 0 && socialHubEnd > socialHubStart
    ? runtimeGateway.slice(socialHubStart, socialHubEnd)
    : '';
  const streamablePath = resolve(repoRoot, 'harmony/agent_core/src/main/ets/modelscope/StreamableMcpClient.ets');
  const uiToolPath = resolve(repoRoot, 'harmony/agent_core/src/main/ets/agent/UiTool.ets');
  const legacySocialPaths = [
    'SocialBridge.ets',
    'SocialCapabilityProbe.ets',
    'SocialNotificationArchive.ets'
  ].map((name) => resolve(runtimeDir, name));
  const multiAgentPaths = [
    'AgentMessageTypes.ets',
    'CreateUiTaskTool.ets',
    'LeaderAgent.ets',
    'LeaderAgentPrompt.ets',
    'LeaderToolRegistry.ets',
    'LoopAgentPrompt.ets',
    'MessageBus.ets',
    'MessageDrivenAgent.ets',
    'ReActAgent.ets',
    'UIMakerAgent.ets',
    'UIMakerAgentPrompt.ets',
    'UIMakerToolRegistry.ets'
  ].map((name) => resolve(repoRoot, 'harmony/agent_core/src/main/ets/agent', name));
  assert(
    !sessionBackedModel.includes('FIRST_RESPONSE_TIMEOUT_MS') &&
      !sessionBackedModel.includes('firstResponseTimer') &&
      !sessionBackedModel.includes('LLM first response timed out'),
    'local LLM Prefill has no application-side timeout'
  );
  assert(
    !sessionBackedModel.includes('RESPONSE_IDLE_TIMEOUT_MS') &&
      !sessionBackedModel.includes('ABSOLUTE_COMPLETE_TIMEOUT_MS') &&
      !sessionBackedModel.includes('armIdleTimer') &&
      !sessionBackedModel.includes('armAbsoluteTimer') &&
      !sessionBackedModel.includes('LLM response timed out after stream stalled.') &&
      !sessionBackedModel.includes('LLM response exceeded absolute time limit.'),
    'local LLM Decode has no application-side timeout'
  );
  assertContains(sessionBackedModel, 'async probeSession(timeoutMs: number): Promise<boolean>',
    'distributed inference verifies the paired native data plane before the user request');
  assertContains(sessionBackedModel, 'private requestQueue: Promise<void> = Promise.resolve();',
    'local native requests share one non-rejecting serial queue');
  assertContains(sessionBackedModel, 'const lease = await this.acquireRequestLease();',
    'normal inference acquires the native Session request lease');
  assertContains(sessionBackedModel, 'await this.releaseRequestLease(lease, true);',
    'normal inference holds its request lease through the native drain');
  assertContains(sessionBackedModel, 'epoch !== this.requestEpoch',
    'queued requests cannot cross a Clear or Session replacement boundary');
  assertContains(sessionBackedModel, "activeRequestCancel?.('Session closed while the request was active.');",
    'closing a Session settles an aborted native request and releases its serial lease');
  assertContains(sessionBackedModel, 'resetting prompt state without replacing session',
    'prompt diff fallback preserves the paired native Session');
  assert(
    !sessionBackedModel.includes('private rebuildSession(): void'),
    'prompt reconstruction cannot silently replace only one side of the paired Session'
  );
  assertContains(collaborationController, 'requestDrainMs: COLLABORATION_REQUEST_DRAIN_MS',
    'collaboration requests use the post-finish Gewu KV drain');
  assertContains(sessionBackedModel, "messages: [{ role: 'user', content: 'ping' } as LlmMessage]",
    'paired data-plane probe uses the stable v6 one-token request');
  assertContains(collaborationController, 'await this.model.probeSession(COLLABORATION_PROBE_TIMEOUT_MS)',
    'collaboration readiness runs the stable v6 health probe');
  assertContains(collaborationController, 'const COLLABORATION_PROBE_TIMEOUT_MS = 60000;',
    'the one-token health probe allows the measured cold Prefill to finish');
  assertContains(collaborationController, 'paired health probe passed attempt=',
    'collaboration readiness records a successful paired health probe');
  const collaborationEnabledIndex = collaborationInit.indexOf('this.collaborationEnabled = true;');
  const nativeEnableIndex = collaborationInit.indexOf('await this.ensureNativeCollaborationEnabled();');
  const masterSettleIndex = collaborationInit.indexOf('await this.delay(MASTER_NATIVE_LISTENER_STABILIZE_MS);');
  const controlStartIndex = collaborationInit.indexOf('await this.controlChannel.start();');
  assert(
    collaborationEnabledIndex >= 0 && nativeEnableIndex > collaborationEnabledIndex &&
      masterSettleIndex > nativeEnableIndex && controlStartIndex > masterSettleIndex,
    'the master enables and settles Gewu before the application control listener starts'
  );
  assert(
    collaborationInit.includes('if (!this.isMaster && this.controlChannel.isConnected())'),
    'a collaborator opened after the master enables Gewu only after the control handshake'
  );
  assertContains(collaborationController,
    "if (state === 'connected') {\n      if (!this.isMaster) {\n        this.ensureNativeCollaborationEnabled()",
    'a collaborator opened first enables Gewu when the fixed control channel connects');
  assertContains(collaborationController, 'private readinessPromise: Promise<boolean> | null = null;',
    'background preparation and send-time readiness share one promise');
  assertContains(collaborationController, 'private sessionRequested = false;',
    'session preparation is explicitly armed by the master interaction');
  assertContains(collaborationController,
    'if (this.controlChannel.isConnected() && this.sessionPrepared && this.collaboratorReady',
    'ready sessions are reused only while the control connection is still live');
  assertContains(connectionStateHandler,
    'this.resourceTableReady = false;\n    if (this.sessionPrepared) {\n      this.beginSessionTeardown();\n    } else {\n',
    'disconnect invalidates prepared and half-built paired sessions');
  assertContains(onSendFinished, 'this.model.resetRunState();',
    'a completed turn resets only the per-run prompt state');
  assert(
    !onSendFinished.includes('beginSessionTeardown()') && !onSendFinished.includes('prewarmSession()'),
    'normal consecutive turns preserve the verified native session and KV cache'
  );
  assertContains(onClear, 'this.beginSessionTeardown();',
    'Clear cooperatively destroys the current paired session');
  assertContains(onClear, 'this.restartSessionAfterClear();',
    'Clear serializes teardown before preparing the replacement session');
  assert(
    !initializeCollaboration.includes('this.prepareCollaborationSession();'),
    'opening the master page keeps the v6 connection alive without creating a session'
  );
  assertContains(demoEntry,
    ".onClick(() => {\n          this.prepareCollaborationSession();\n        })",
    'clicking the master collaboration card starts model and session preparation');
  assertContains(demoEntry,
    ".onFocus(() => {\n            this.prepareCollaborationSession();\n          })",
    'focusing the message dialog starts the same model and session preparation');
  assertContains(demoEntry, 'controller.prewarmSession();',
    'the master status card can retry background preparation');
  assertContains(demoEntry, 'if (this.sandboxBrowserVisible)',
    'the sandbox browser switches inside the collaboration page without router teardown');
  assertContains(demoEntry,
    "if (this.collaborationVisible && this.collaborationIsMaster) {\n          Button('📁')",
    'only the collaboration master exposes the sandbox browser entry');
  assertContains(sandboxBrowser, 'ensureSandboxWorkspace();',
    'the workspace root exists before browsing');
  assertContains(sandboxBrowser, 'sandboxWorkspacePath(relativePath)',
    'the sandbox browser resolves paths under the shared workspace root');
  assertContains(sandboxBrowser, "part.length === 0 || part === '.' || part === '..'",
    'the sandbox browser rejects traversal and malformed relative paths');
  assertContains(sandboxBrowser, "fs.readTextSync(absolutePath, { encoding: 'utf-8' })",
    'the sandbox browser provides a local read-only text preview');
  assert(
    !sandboxBrowser.includes('fs.write') &&
      !sandboxBrowser.includes('fs.unlink') &&
      !sandboxBrowser.includes('fs.rename') &&
      !sandboxBrowser.includes('this.runAgent'),
    'the sandbox browser cannot mutate files or invoke the Agent'
  );
  assertContains(reactRunner, 'Loopy file space (文件空间)',
    'the system prompt defines the Loopy file-space concept');
  assertContains(reactRunner, 'relative to the workspace root',
    'the system prompt maps sandbox file-tool paths to the workspace root');
  assertContains(reactRunner, "const ARTICLE_ANALYSIS_MEMORY = '<memory>\\n'",
    'the system prompt includes the article-analysis memory block');
  assertContains(reactRunner, '第一步：调用 list_sandbox_files',
    'article analysis lists workspace files first');
  assertContains(reactRunner, '第二步：调用 read_sandbox_file',
    'article analysis reads the selected file second');
  assertContains(reactRunner, '第三步：读取成功后停止调用工具',
    'article analysis returns a concise final summary after reading');
  assertContains(connectionStateHandler, 'if (this.isMaster && this.sessionRequested)',
    'reconnection restores only a session that the user already requested');
  assertContains(deviceBenchmark, 'withoutHealthProbe(parseStats(recentMasterLogs), recentMasterLogs)',
    'device benchmark excludes the pre-submit health probe from user metrics');
  assertContains(llmProvider, 'localBenchmarkDirect?: boolean;',
    'local configuration gates direct benchmark mode');
  assertContains(llmProvider, 'deterministicSkillRouting?: boolean;',
    'local configuration reserves deterministic Skill routing');
  assertContains(llmProvider, 'deterministicSkillRouting: json?.deterministicSkillRouting ?? false,',
    'deterministic Skill routing defaults off when omitted');
  assert(packagedLlmConfig.deterministicSkillRouting === false,
    'packaged Loopy configuration uses normal ReAct Skill routing');
  assert(packagedLlmConfig.localModelMaxContext === 2048,
    'packaged Loopy uses the Gewu-supported KNPU context window');
  assertContains(sessionBackedModel, 'DEFAULT_LOCAL_LLM_MAX_CONTEXT: number = 2048;',
    'local LLM default matches the Gewu-supported KNPU context window');
  assertContains(sessionBackedModel, 'max_tokens: generation?.max_tokens',
    'ordinary local inference omits max_tokens while benchmarks may set it explicitly');
  assertContains(demoEntry, 'if (localConfig.benchmarkDirect && modelInfo.mode ===',
    'Loopy direct benchmark bypass is explicitly gated');
  assertContains(sessionBackedModel,
    'completeBenchmark(prompt: string, maxTokens: number, temperature: number = 0)',
    'local benchmark explicitly controls temperature and output tokens');
  assertContains(demoEntry, 'benchmarkRequest.prompt,',
    'Loopy strips benchmark controls before model submission');
  assert(
    demoEntry.indexOf('if (localConfig.benchmarkDirect && modelInfo.mode ===') <
      demoEntry.indexOf('new ReActAgentRunner('),
    'Loopy direct benchmark bypasses the ReAct and Skill prompt builders'
  );
  assertContains(deviceBenchmark, 'function loadBenchmark(path)',
    'device benchmark runner accepts package JSONL datasets');
  assertContains(deviceBenchmark, 'mobile_prefill_results.jsonl',
    'device benchmark runner exports package-compatible results');

  assertContains(protocol, "export const A2UI_VERSION = 'v0.9.1';", 'AIPhone A2UI version is v0.9.1');
  assertContains(llmProvider, "endsWith('/v1/chat/completions')", 'model base URL can be full chat completions URL');
  assertContains(llmProvider, "endsWith('/v1')", 'model base URL can be OpenAI v1 root');
  assertContains(openAiModel, 'buildRequestJson', 'OpenAI-compatible model applies custom parameters');
  assertContains(openAiModel, 'customParametersJson', 'OpenAI-compatible model reads custom parameter JSON');
  assertContains(openAiModel, 'search(/"model"\\s*:/)', 'custom parameters cannot replace model');
  assertContains(openAiModel, 'search(/"messages"\\s*:/)', 'custom parameters cannot replace messages');
  assertContains(openAiModel, 'Execution: serial | parallel', 'OpenAI-compatible model advertises multi-tool execution');
  assert(!scriptedModel.includes('Action: note'), 'scripted model never emits the removed note tool');
  assert(!registry.includes('class NoteTool'), 'the ToolRegistry no longer implements the note tool');
  assert(!registry.includes('register(new NoteTool())'), 'the ToolRegistry no longer registers the note tool');
  assert(!reactRunner.includes('Use note'), 'the ReAct system prompt no longer mentions the note tool');
  assert(!existsSync(uiToolPath), 'the generic ui tool implementation is deleted');
  assert(
    !registry.includes('UiTool') && !registry.includes('new UiTool()'),
    'the ToolRegistry never registers or lists the generic ui tool'
  );
  assert(
    !runner.includes('UI_TOOL_NAME') &&
      !runner.includes('runUiTool') &&
      !runner.includes('Use the ui tool') &&
      !runner.includes('Do not call ui'),
    'the ReAct runtime and system prompt contain no generic ui tool path'
  );
  assert(!skillSnapshot.includes('Use the ui tool'),
    'the Skill system prompt contains no generic ui tool instruction');
  assert(!scriptedModel.includes('Action: ui'),
    'the scripted fallback cannot synthesize a ui tool call');
  assert(!index.includes('UiRenderHandler'),
    'the public agent API no longer exposes a ui tool render handler');
  assert(
    !demoEntry.includes('buildUiHandler') &&
      !demoEntry.includes("startsWith('ui(')") &&
      !demoEntry.includes('AgentEventKind.UI'),
    'the Loopy entry has no generic ui tool execution or event path'
  );
  assertContains(aiphoneA2ui, 'export function aiphoneInfoJsonl', 'AIPhone final answer helper exists');
  assertContains(aiphoneA2ui, "component: 'InfoRows'", 'final answer helper renders InfoRows');

  const ids = [...definitions.matchAll(/toolId:\s*'([^']+)'/g)].map((match) => match[1]);
  const runtimeIds = [...runtimeDefinitions.matchAll(/toolId:\s*'([^']+)'/g)].map((match) => match[1]);
  const uniqueIds = new Set(ids);
  const runtimeUniqueIds = new Set(runtimeIds);
  assert(ids.length === uniqueIds.size, 'AIPhone tool ids are unique');
  assert(runtimeIds.length === runtimeUniqueIds.size, 'runtime tool ids are unique');
  assert(ids.length >= 22, 'AIPhone tool registry has expected breadth', `found ${ids.length}`);
  for (const id of [
    'travel.search',
    'train.search',
    'flight.search',
    'food.search',
    'hotel.search',
    'hotel.detail',
    'social.reply.draft',
    'mail.search',
    'mail.thread.read',
    'mail.draft.create',
    'gmail.mail.search',
    'gmail.thread.read',
    'gmail.draft.create',
    'gmail.message.send',
    'media.video.search',
    'youtube.video.search',
    'calendar.events.search',
    'calendar.event.create',
    'maps.place.search',
    'maps.place.details'
  ]) {
    assert(uniqueIds.has(id), `registered ${id}`);
    assert(runtimeUniqueIds.has(id), `runtime registered ${id}`);
  }
  assertContains(definitions, "toolId === 'dynamic.search'", 'dynamic.search is treated as registered');
  assertContains(definitions, 'return TOOL_DEFINITIONS.length;', 'tool definition count uses source list');
  assert(ids.every((id) => runtimeUniqueIds.has(id)), 'public and runtime tool registries align');

  const runtimeFiles = readdirSync(runtimeDir).filter((name) => name.endsWith('.ets'));
  assert(runtimeFiles.length >= 30, 'AIPhone runtime files are vendored into Loopy', `found ${runtimeFiles.length}`);

  assertContains(executor, 'isRegisteredToolId(toolId)', 'executor rejects unknown tools through runtime registry');
  assertContains(executor, 'callToolGateway(', 'executor delegates to runtime tool gateway');
  assertContains(executor, 'defaultToolGatewayUrl()', 'executor uses local AIPhone tool route');
  assertContains(executor, 'result.raw.trim().length > 0', 'executor returns runtime A2UI JSONL');

  assertContains(runtimeGateway, 'async function callLocalTravelSearch', 'runtime includes travel execution');
  assertContains(runtimeGateway, 'async function callLocalTrainSearch', 'runtime includes train execution');
  assertContains(runtimeGateway, 'async function callLocalFlightSearch', 'runtime includes flight execution');
  assertContains(runtimeGateway, 'async function callLocalFoodSearch', 'runtime includes food execution');
  assertContains(runtimeGateway, 'async function callLocalHotelTool', 'runtime includes hotel execution');
  assertContains(runtimeGateway, 'async function callLocalMailTool', 'runtime includes aggregate mail execution');
  assertContains(runtimeGateway, 'async function callLocalGmailTool', 'runtime includes Gmail execution');
  assertContains(runtimeGateway, 'async function callLocalMediaTool', 'runtime includes media video execution');
  assertContains(runtimeGateway, 'async function callLocalYouTubeTool', 'runtime includes YouTube execution');
  assertContains(runtimeGateway, 'async function callLocalCalendarTool', 'runtime includes Calendar execution');
  assertContains(runtimeGateway, 'async function callLocalMapsTool', 'runtime includes Maps execution');
  assertContains(runtimeGateway, 'async function buildDynamicToolJsonl', 'runtime includes dynamic tool execution');
  assertContains(runtimeGateway, 'gmailBlockedSendA2ui(surfaceId, toolId)', 'runtime blocks Gmail direct send');
  assertContains(runtimeGateway, '不会模拟 Gmail 邮件', 'runtime does not simulate Gmail');
  assert(
    socialHubFunction.includes("toolId === 'social.reply.draft'") &&
      socialHubFunction.includes('socialHubClient.draft(') &&
      socialHubFunction.includes('socialHubDraftA2ui(') &&
      !socialHubFunction.includes('sendReply('),
    'runtime drafts SocialHub replies instead of sending',
    'missing scoped draft branch/call/render or found sendReply'
  );

  assertContains(backend, 'allToolDefinitions()', 'LoopBackend registers AIPhone definitions');
  assertContains(backend, "registry.register(new AiphoneTool(\n      'dynamic.search'", 'LoopBackend registers dynamic.search');
  assertContains(backend, 'splitJsonl(jsonl)', 'LoopBackend splits AIPhone JSONL');
  assertContains(backend, 'this.callbacks.onA2uiJsonl?.(line)', 'LoopBackend emits AIPhone JSONL lines');
  assertContains(backend, 'runAiphoneTool(', 'LoopBackend delegates tool execution to AIPhone executor');
  assertContains(backend, 'a2uiLineCount === 0', 'LoopBackend only emits final surface when no tool UI exists');
  assertContains(backend, 'aiphoneInfoJsonl', 'LoopBackend emits A2UI for plain final answers');

  assertContains(index, 'export { LoopBackend,', 'public export includes LoopBackend');
  assertContains(index, "export { runAiphoneTool }", 'public export includes runAiphoneTool');
  assertContains(index, 'aiphoneInfoJsonl', 'public export includes final answer helper');
  assertContains(index, 'allToolDefinitions', 'public export includes tool definitions');
  assertContains(index, 'configureLocalProviderConfigFromRawJson', 'public export includes provider raw JSON config');
  assertContains(index, 'prepareGmailOAuthAuthorizationUrl', 'public export includes Gmail OAuth helper');
  assertContains(index, 'AssetCredentialStore', 'public export includes dynamic credential store');
  assertContains(conversationContext, 'static fromMessages', 'conversation context can restore messages');
  assertContains(conversationStore, 'MAX_STORED_TURNS: number = 50', 'conversation store keeps the last 50 turns');
  assertContains(conversationStore, 'JSON.parse(raw)', 'conversation store parses persisted JSON defensively');
  assertContains(conversationStore, 'role !== ConversationRole.USER && role !== ConversationRole.ASSISTANT', 'conversation store ignores unknown roles');
  assertContains(conversationStore, 'return new ConversationContext()', 'conversation store falls back to an empty conversation');
  assertContains(skillParser, 'export function parseSkillMarkdown', 'skill markdown parser is present');
  assertContains(skillStore, 'if (pathExists(targetPath))', 'bundled skills do not overwrite sandbox files');
  assertContains(skillStore, 'await ensureBundledSkillsInSandbox(context)', 'sandbox skills are initialized before loading');
  assertContains(skillStore, '`${context.filesDir}/${SKILLS_ROOT}`',
    'skills stay under their original filesDir/skills location');
  assertContains(skillStore, "const REMOVED_BUNDLED_SKILLS: string[] = ['financial-article-analysis'];",
    'retired bundled financial skill is removed from upgraded installations');
  assertContains(skillReadTool, 'this.normalizeInput(input)',
    'Skill reads normalize model-emitted arguments before lookup');
  assertContains(skillReadTool, "(first === '\"' && last === '\"')",
    'Skill reads accept quoted names emitted by the local model');
  assert(!registry.includes('ensureSandboxWorkspace();'),
    'configured tools do not touch the workspace before Agent execution');
  assertContains(registry, 'registry.register(new SandboxFileReadTool(context));',
    'configured tools expose the sandbox file reader');
  assertContains(registry, 'registry.register(new SandboxListTool(context));',
    'configured tools expose the workspace directory lister');
  assertContains(sandboxFileReadTool, "return 'read_sandbox_file';",
    'sandbox file reads have a dedicated ReAct tool name');
  assertContains(sandboxWorkspace,
    '/data/storage/el2/base/haps/entry/files/workspace',
    'all sandbox file tools share the requested fixed workspace root');
  assertContains(sandboxWorkspaceStore, "const BUNDLED_WORKSPACE_FILES: string[] = ['temp.txt'];",
    'the packaged temp file is synchronized into the workspace');
  assertContains(bundledWorkspaceTemp, 'hhhh',
    'the requested temp file is included in the HAP resources');
  assertContains(sandboxWorkspace, "normalized.startsWith('/') || normalized.indexOf(':') >= 0",
    'workspace paths reject absolute paths');
  assertContains(sandboxWorkspace, "part.length === 0 || part === '.' || part === '..'",
    'workspace paths reject traversal segments');
  assertContains(sandboxFileReadTool, 'sandboxWorkspacePath(relativePath)',
    'sandbox reads resolve under the workspace root');
  assertContains(sandboxFileReadTool, 'await ensureBundledWorkspaceFiles(this.context);',
    'sandbox reads initialize packaged workspace files lazily');
  assertContains(sandboxFileWriteTool, 'sandboxWorkspacePath(relativePath)',
    'sandbox writes resolve under the workspace root');
  assertContains(sandboxFileWriteTool, 'await ensureBundledWorkspaceFiles(this.context);',
    'sandbox writes initialize packaged workspace files lazily');
  assertContains(sandboxDirectoryTools, 'return sandboxWorkspacePath(relativePath);',
    'sandbox directory listings resolve under the workspace root');
  assertContains(sandboxDirectoryTools, 'await ensureBundledWorkspaceFiles(this.context);',
    'sandbox directory listings initialize packaged workspace files lazily');
  assertContains(sandboxFileReadTool, 'fs.readTextSync(absolutePath',
    'sandbox file reads return real UTF-8 file contents');
  assertContains(runner, 'AgentEventKind.SKILL', 'ReAct emits selected skills');
  assertContains(skillSnapshot, 'findByNaturalLanguageTask(task: string)',
    'Skill snapshot supports deterministic natural-language routing');
  assertContains(runner, 'const routedSkill = this.deterministicSkillRouting',
    'deterministic Skill routing is gated inside ReAct');
  assertContains(runner, 'deterministicSkillRouting: boolean = false',
    'direct Skill routing is disabled by default');
  assertContains(demoEntry, 'localConfig.deterministicSkillRouting',
    'Loopy passes the explicit Skill routing configuration to ReAct');
  assertContains(runner, 'natural-language skill selected name=',
    'ReAct logs a natural-language selected Skill');
  assertContains(runner, "Return exactly Thought: <brief reason> followed by Final: <answer>. Do not call tools.",
    'ReAct uses the compact no-tool prompt for routed Skills');
  assertContains(runner, '`${routedSkill.instructions()}\\n\\n`',
    'ReAct injects routed Skill instructions before inference');
  assertContains(runner, "const wrappers: string[] = ['Final:', 'Final Answer:', 'Answer:'];",
    'ReAct executes tool actions nested in local-model final-answer wrappers');
  assertContains(reactCompatibility, 'matchingPrefix(inlineValue, CONTROL_PREFIXES)',
    'compatibility layer does not render nested tool control lines as final text');
  assertContains(genericMcp, 'annotations: tool.annotations', 'MCP annotations are preserved');
  assertContains(modelScope, "from '../aiphone/runtime/GenericMcpClient'", 'ModelScope reuses GenericMcpClient');
  assertContains(modelScope, 'annotations.readOnlyHint !== true', 'ModelScope requires explicit read-only annotations');
  assertContains(modelScope, 'annotations.destructiveHint === true', 'ModelScope blocks destructive annotations');
  assertContains(modelScopeSearch, 'this.discoveredTools.clear()', 'ModelScope search resets the executable discovery set');
  assertContains(modelScopeSearch, 'annotations: tool.mcpTool.annotations', 'ModelScope search returns MCP annotations');
  assert(
    modelScopeEmptyGuard >= 0 &&
      modelScopeCandidateLoop > modelScopeEmptyGuard &&
      modelScopeCandidateBound > modelScopeCandidateLoop &&
      modelScopeCandidateRollback > modelScopeCandidateBound &&
      modelScopeAuthorization > modelScopeCandidateRollback &&
      modelScopeSearch.indexOf('return JSON.stringify(observation)', modelScopeAuthorization) > modelScopeAuthorization,
    'ModelScope authorizes only complete bounded search candidates',
    'missing ordered empty guard, candidate rollback, final-set authorization, or complete observation return'
  );
  assertContains(
    modelScopeExecute,
    'modelScopeExecutionDecision(this.discoveredTools.has(normalized), selectedMcpTool)',
    'ModelScope execute uses the latest-search safety gate'
  );
  assertContains(
    modelScopeExecute,
    "this.mcp.callTool(tool.registration, '', args)",
    'ModelScope execute calls the selected MCP registration'
  );
  assert(!modelScope.includes('domainBoost'), 'ModelScope has no domain boost');
  assert(!/飞常准|12306|天气|weather|searchFlightsByDepArr|searchFlightItineraries|getFlightPriceByCities/i.test(modelScope), 'ModelScope has no domain-specific routing');
  assert(!existsSync(streamablePath), 'ModelScope does not duplicate MCP transport');
  assertContains(registry, 'new ModelScopeTool', 'configured registry exposes ModelScope');
  assertContains(runner, "this.tools.has('modelscope')", 'ModelScope prompt is gated by actual registration');
  assertContains(index, "./src/main/ets/modelscope/ModelScopeTool", 'public export includes ModelScope');
  assert(!legacySocialPaths.some((path) => existsSync(path)), 'obsolete social bridge files are absent');
  assertContains(index, "./src/main/ets/agent/ConversationStore", 'public export preserves conversation persistence');
  assertContains(index, "./src/main/ets/skill/SkillSnapshot", 'public export preserves Skill support');
  assert(!multiAgentPaths.some((path) => existsSync(path)), 'hos has no message-driven multi-agent runtime');
  assert(
    !index.includes('LeaderAgent') &&
      !index.includes('UIMakerAgent') &&
      !index.includes('MessageDrivenAgent') &&
      !index.includes('LinkedMessageBus'),
    'public API exposes only the single ReAct runtime'
  );
  assertContains(demoEntry, 'new ReActAgentRunner(', 'Loopy entry directly runs one ReAct agent');
  assertContains(demoEntry, 'createConfiguredLoopToolRegistry(', 'single ReAct entry receives the configured tool registry');
  assertContains(demoEntry, "if (modelInfo.mode !== 'scripted')",
    'local and network LLM paths both load the Skill snapshot');
  assertContains(demoEntry, 'skillSnapshot = this.skillSnapshot ?? await createSkillSnapshot(context);',
    'collaboration and single-device local inference can load sandbox Skills');
  assertContains(reactRunner, 'class ActionPlan', 'single ReAct runner parses multi-tool plans');
  assertContains(reactRunner, "type ExecutionMode = 'parallel' | 'serial';", 'single ReAct runner supports serial and parallel execution');
  assertContains(reactRunner, 'executeParallelToolCalls(', 'single ReAct runner executes independent tools in parallel');
  assertContains(reactRunner, "return 'serial';", 'unsafe or unspecified multi-tool plans fall back to serial execution');
  assertContains(skillSnapshot, 'Execution: parallel', 'skill prompt documents parallel tool calls');
  assertContains(skillSnapshot,
    'Never read or invoke skill_creator unless the user explicitly asks to create or update a Skill.',
    'skill prompt forbids implicit skill_creator selection');
}

runHarBuild();
verifySourceContracts();

const failed = checks.filter((check) => !check.ok);
if (failed.length > 0) {
  console.error(`\n${failed.length} verification check(s) failed.`);
  process.exit(1);
}

console.log(`\nAIPhone Loopy backend smoke passed (${checks.length} checks).`);
