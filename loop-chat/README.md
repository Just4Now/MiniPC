# Loop — HarmonyOS NEXT

HarmonyOS NEXT port of the Loop ReAct agent starter. Matches the Android app:

- Chat UI with message input, send control, and event transcript
- `ReActAgentRunner` with Thought / Action / Observation / Final
- `ToolRegistry` with `time`, `note`, configured integrations, and optional Skill tools
- OpenAI-compatible HTTP adapter (DashScope / Qwen) plus scripted fallback

## Open in DevEco Studio

1. Install [DevEco Studio](https://developer.huawei.com/consumer/en/deveco-studio/) with HarmonyOS NEXT SDK **6.0.1 (API 21)** for the checked-in build profile. AGenUI itself requires HarmonyOS NEXT SDK **5.0.5 (API 17)+**.
2. Open the `harmony/` folder as a project (not the repo root).
3. Configure signing under **File → Project Structure → Signing Configs** for device or emulator runs.
4. Sync/build, then run the `entry` module on a phone emulator or device.

If `ohpm install` fails looking for `@ohos/hvigor`, that package ships with DevEco Studio and must **not** be listed in `oh-package.json5` `devDependencies`. Use **File → Sync and Refresh Project** instead.

## AIPhone backend verification

Run the Loopy-side smoke before wiring this HAR into AIPhoneDemo:

```bash
cd harmony
DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk \
  node scripts/verify-aiphone-backend.mjs
```

The smoke builds the `agent_core` HAR and checks the AIPhone contract in this repo:

- `LoopBackend` registers the AIPhone tool definitions and `dynamic.search`.
- Tool output is emitted as AIPhone A2UI JSONL lines.
- The migrated AIPhone runtime includes travel, train, flight, food, Gmail, YouTube, Calendar, Maps, social, and dynamic tool execution.
- Unsafe send tools are blocked instead of auto-executed, and missing provider/OAuth config remains a truthful runtime error instead of mock data.

To validate from AIPhoneDemo without touching the main working tree, create a temporary worktree and patch only that copy:

```bash
cd harmony
DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk \
  node scripts/aiphonedemo-worktree-smoke.mjs --reset-worktree
```

That command prepares `/Users/luoyige/DevEcoStudioProjects/AIPhoneDemo-loopy-verify`, swaps its model client to `@loop/agent-core`, syncs local provider config when `tool-gateway/.env.local` exists, and builds a signed HAP. Add `--device-smoke` to install the temporary HAP and run AIPhoneDemo's `scripts/aiphone-device-smoke.mjs --full-regression` against the device.

When `--device-smoke` is used, the script reads the connected device API from `hdc shell param get const.ohos.apiversion`. API 22 devices get a temporary worktree-only product SDK patch to `6.0.2(22)` before build/install; API 23 devices use `6.1.0(23)`. Override this with `AIPHONE_VERIFY_PRODUCT_SDK='6.0.2(22)'` when you need to force a specific verification target.

## LLM provider config

Harmony reads provider settings from a raw resource file:

`entry/src/main/resources/rawfile/llm_config.json`

### Option A — sync from Android `local.properties`

If you already use the repo-root `local.properties` for Android:

```bash
chmod +x scripts/sync-harmony-llm-config.sh
./scripts/sync-harmony-llm-config.sh
```

That writes `llm_config.json` from:

```properties
llm.providerName=ali-bailian-openai
llm.apiKey=...
llm.baseUrl=https://dashscope.aliyuncs.com/compatible-mode/v1
llm.model=qwen-plus
```

### Option B — copy the example file

```bash
cp entry/src/main/resources/rawfile/llm_config.example.json \
   entry/src/main/resources/rawfile/llm_config.json
```

Edit `llm_config.json` and set `apiKey`.

If the provider is not configured, the app uses `ScriptedLocalModel` (same fallback as Android).

## Composio

The regular Loop chat registers a `composio` meta tool, discovers ACTIVE connected accounts at
startup, then lazily creates a tool-router session. Copy
`entry/src/main/resources/rawfile/composio_config.example.json` to `composio_config.json` and set
the scoped project `apiKey` plus the stable connected-account `userId`. The local config is ignored
by Git. Discovered tools execute immediately, including tools with side effects; production apps
should proxy Composio through their own backend.

## ModelScope MCP

The regular Loop chat registers a `modelscope` meta tool. For the current demo it connects directly
to ModelScope from the phone, without a local Gateway.

Copy `entry/src/main/resources/rawfile/modelscope_config.example.json` to
`entry/src/main/resources/rawfile/modelscope_config.json` and configure (the local file is
ignored by Git):

```json
{
  "mode": "direct",
  "modelscopeApiBaseUrl": "https://modelscope.cn",
  "modelscopeToken": "your ModelScope token"
}
```

The phone calls ModelScope's operational MCP API, lists only the account's activated Hosted MCP
tools, and reuses the shared `GenericMcpClient` for Streamable HTTP `tools/list` and `tools/call`.
Search and execute are separate phases: execute accepts only a `qualifiedName` returned by the most
recent search. The demo executes only tools whose MCP annotations explicitly declare
`readOnlyHint: true` and do not declare `destructiveHint: true`; unannotated, write, and destructive
tools are blocked until a real confirmation flow exists.

The token is still packaged into the app rawfile, so this direct mode is for internal demos only.
Do not commit `modelscope_config.json` or ship this credential layout as a production architecture.

## Source layout

```text
agent_core/                   # HAR — shared ReAct agent library
  Index.ets                   # Public exports
  src/main/ets/
    agent/ReActAgentRunner.ets
    agent/ToolRegistry.ets
    model/OpenAiCompatibleModel.ets
    model/ScriptedLocalModel.ets
    model/LlmProvider.ets
    model/LoopModelFactory.ets

entry/                        # App UI module
  src/main/ets/
    pages/Index.ets           # Unified Loop chat + on-screen UI panel
    agenui/A2uiFallbackView.ets
    entryability/EntryAbility.ets

libs/
  agenui.har                  # AGenUI SDK (fetch via scripts/fetch-agenui.sh)
```

`entry/oh-package.json5` references the HAR:

```json5
"dependencies": {
  "@loop/agent-core": "file:../agent_core"
}
```

UI code imports from `@loop/agent-core`:

```typescript
import { ReActAgentRunner, ToolRegistry, createLoopModel } from '@loop/agent-core';
```

## Conversation memory

Loop keeps a history of user messages and final assistant answers in `ConversationContext`. Each successful run appends one user/assistant pair; failed runs are not stored. History is persisted to device preferences via `ConversationStore` and restored on launch (last 50 turns). Use **Clear** to reset the session and wipe stored history.

## Android parity notes

| Android | Harmony |
|---------|---------|
| `MainActivity.java` | `pages/Index.ets` |
| `local.properties` → Gradle `resValue` | `rawfile/llm_config.json` |
| `HttpURLConnection` | `@ohos.net.http` |
| `ExecutorService` + `Handler` | `async/await` in event handler |
| `INTERNET` permission in manifest | `ohos.permission.INTERNET` in `module.json5` |

## Replace the model

Implement `LocalModel` in `agent_core/src/main/ets/model/LocalModel.ets` and wire it in `LoopModelFactory.ets`. Keep responses compatible with:

```text
Thought: ...
Action: tool_name[input]
Final: ...
```
