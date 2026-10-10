# 本地 LLM 接入 ReAct Agent 设计文档

## 1. 背景与目标

本项目是一个 HarmonyOS NEXT 的 ReAct Agent（agent_core HAR 库 + entry 应用）。现有 LLM 调用通过 OpenAiCompatibleModel 走网络 HTTP 请求 OpenAI 兼容端点。现需接入一个本地 C++ LLM 推理服务（通过 llm.h 暴露），替代网络路径，同时复用其 KV-cache 能力。

**目标**：
- 不改动 ReActAgentRunner 的任何逻辑
- 通过 LocalModel 接口解耦，插入新的本地推理实现
- 单次 ReAct run 内（多步推理）复用底层 KV-cache，减少重复计算

## 2. 整体架构

三层结构，数据流自上而下：

```
ReActAgentRunner (不改动)
  |  调用 model.complete(flatPrompt)
  |  解析 Thought:/Action:/Final: 文本
  v  LocalModel 接口 (complete/dispose)
SessionBackedModel (ArkTS 适配层, 新增)
  |  flat prompt diff -> 提取增量 observation
  |  维护 messages[] 结构化对话轮次
  |  累积 token callback -> finish_reason 时 resolve
  |  session 生命周期: 创建/复用/销毁
  v  AKI JSBIND 绑定
llm_bridge.cpp (C++ 桥接层, 新增)
  |  SafetyCallback -> C 函数指针 trampoline
  |  包装 XXXXX_CreateSession/SubmitRequest 等
  |  callback 生命周期管理 (map + mutex)
  v  原始 C 接口 (llm.h)
LLM Engine (C++, 已有)
  |  session 维护 KV-cache
  |  逐 token 回调 OnResponse
```

## 3. C++ 桥接层 (llm_bridge.cpp)

### 3.1 位置与依赖

- **文件**: `entry/src/main/cpp/llm_bridge.cpp`
- **头文件**: `entry/src/main/cpp/llm.h`（你提供的原始接口）
- **AKI 依赖**: `entry/src/main/cpp/aki/`（源码 clone），CMakeLists.txt 链接 `aki_jsbind`
- **编译产物**: `libllm.so`，ArkTS 侧 `import libLlm from 'libllm.so'`

### 3.2 CMakeLists.txt 配置

```cmake
cmake_minimum_required(VERSION 3.5.0)
project(llm)
set(CMAKE_CXX_STANDARD 17)
add_subdirectory(aki)
target_link_libraries(llm PUBLIC aki_jsbind)
add_library(llm SHARED llm_bridge.cpp)
```

### 3.3 AKI 回调桥接原理

你的 C 接口用原始函数指针 `void (*XXXXX_OnResponse)(void* context, const char* response)`。ArkTS 无法直接传 C 函数指针。AKI 的 `aki::SafetyCallback` 解决了这个问题：
- ArkTS 传入 JS 函数 -> AKI 自动包装为 `aki::SafetyCallback<void(std::string)>`
- 底层用 `napi_create_threadsafe_function`，从任意线程调用时阻塞式 marshal 到 ArkTS 线程
- 有 10s 超时保护和 env 失效保护（抛 `std::runtime_error`）

桥接层把 SafetyCallback 包装成 C trampoline 函数指针，传给 `XXXXX_SubmitRequest`。

### 3.4 代码骨架

```cpp
#include "llm.h"
#include <aki/jsbind.h>
#include <unordered_map>
#include <mutex>
#include <string>

struct CallbackEntry {
    XXXXX_Session session;
    XXXXX_Request request;
    aki::SafetyCallback<void(std::string)> callback;
};

static std::unordered_map<XXXXX_Request, CallbackEntry*> g_callbackMap;
static std::mutex g_mutex;

static void OnResponseTrampoline(void* context, const char* response) {
    if (!context || !response) return;
    auto* entry = static_cast<CallbackEntry*>(context);
    try { entry->callback(std::string(response)); }
    catch (const std::runtime_error&) { /* env 失效, 静默 */ }
}

static void CleanupCallback(XXXXX_Request req) {
    std::lock_guard<std::mutex> lock(g_mutex);
    auto it = g_callbackMap.find(req);
    if (it != g_callbackMap.end()) { delete it->second; g_callbackMap.erase(it); }
}

static void CleanupSessionCallbacks(XXXXX_Session session) {
    std::lock_guard<std::mutex> lock(g_mutex);
    for (auto it = g_callbackMap.begin(); it != g_callbackMap.end();) {
        if (it->second->session == session) { delete it->second; it = g_callbackMap.erase(it); }
        else ++it;
    }
}

struct CreateSessionResult { uint32_t session; uint32_t error; };
CreateSessionResult llmCreateSession(std::string attributes) {
    auto r = XXXXX_CreateSession(attributes.c_str());
    return {r.session, r.error};
}

uint32_t llmDestroySession(uint32_t session) {
    CleanupSessionCallbacks(static_cast<XXXXX_Session>(session));
    return XXXXX_DestroySession(static_cast<XXXXX_Session>(session));
}

struct SubmitRequestResult { uint32_t request; uint32_t error; };
SubmitRequestResult llmSubmitRequest(uint32_t session, std::string request,
    aki::SafetyCallback<void(std::string)> callback) {
    auto* entry = new CallbackEntry{static_cast<XXXXX_Session>(session), 0, callback};
    auto r = XXXX_SubmitRequest(static_cast<XXXXX_Session>(session),
        request.c_str(), OnResponseTrampoline, entry);
    if (r.error == XXXXX_OK) {
        entry->request = r.request;
        std::lock_guard<std::mutex> lock(g_mutex);
        g_callbackMap[r.request] = entry;
    } else delete entry;
    return {r.request, r.error};
}

uint32_t llmAbortRequest(uint32_t session, uint32_t request) {
    auto ret = XXXXX_AbortRequest(static_cast<XXXXX_Session>(session),
        static_cast<XXXXX_Request>(request));
    CleanupCallback(static_cast<XXXXX_Request>(request));
    return ret;
}

JSBIND_CLASS(CreateSessionResult) { JSBIND_PROPERTY(session); JSBIND_PROPERTY(error); }
JSBIND_CLASS(SubmitRequestResult) { JSBIND_PROPERTY(request); JSBIND_PROPERTY(error); }
JSBIND_GLOBAL() {
    JSBIND_FUNCTION(llmCreateSession);
    JSBIND_FUNCTION(llmDestroySession);
    JSBIND_FUNCTION(llmSubmitRequest);
    JSBIND_FUNCTION(llmAbortRequest);
}
JSBIND_ADDON(llm);
```

### 3.5 ArkTS 类型声明

文件 `entry/src/main/cpp/types/libllm/index.d.ts`：

```typescript
export interface CreateSessionResult { session: number; error: number; }
export interface SubmitRequestResult { request: number; error: number; }
export declare function llmCreateSession(attributes: string): CreateSessionResult;
export declare function llmDestroySession(session: number): number;
export declare function llmSubmitRequest(
  session: number, request: string, callback: (response: string) => void
): SubmitRequestResult;
export declare function llmAbortRequest(session: number, request: number): number;
```

### 3.6 线程模型

ArkTS 线程调 `llmSubmitRequest` -> C++ 调 `XXXXX_SubmitRequest`（立即返回）。LLM worker 线程逐 token 调 trampoline -> SafetyCallback marshal 到 ArkTS 线程执行回调 -> 返回 -> 继续推下一 token。每次回调 ArkTS 侧逻辑极轻（JSON.parse + 字符串拼接），10s 超时远不会触发。

## 4. ArkTS 适配层 (SessionBackedModel.ets)

### 4.1 文件位置

`agent_core/src/main/ets/model/SessionBackedModel.ets`

### 4.2 接口定义

```typescript
import { ConversationContext } from '../agent/ConversationContext';
import { LocalModel } from './LocalModel';
import libLlm from 'libllm.so';

export interface LlmMessage { role: string; content: string; }
export interface ResponseChunk { content: string; finish_reason: string | null; }
export interface SessionBackedModelOptions {
  attributes?: string;   // 默认 "{}"
  stream?: boolean;       // 默认 true
}
```

### 4.3 核心实现骨架

```typescript
const COMPLETE_TIMEOUT_MS = 40000;
const MAX_ATTEMPTS = 2;

export class SessionBackedModel implements LocalModel {
  private sessionId: number | null = null;
  private messages: LlmMessage[] = [];
  private lastPrompt: string = '';
  private lastResponse: string = '';
  private options: SessionBackedModelOptions;
  private tokenStreamListener: ((token: string) => void) | null = null;
  private disposed = false;

  constructor(options?: SessionBackedModelOptions) { this.options = options ?? {}; }

  setTokenStreamListener(l: ((t: string) => void) | null): void { this.tokenStreamListener = l; }

  dispose(): void {
    if (this.disposed) return;
    this.disposed = true;
    if (this.sessionId !== null) { libLlm.llmDestroySession(this.sessionId); this.sessionId = null; }
  }

  async complete(prompt: string, _conv?: ConversationContext): Promise<string> {
    let lastError = '';
    for (let attempt = 0; attempt < MAX_ATTEMPTS; attempt++) {
      try { return await this.completeOnce(prompt); }
      catch (error) {
        lastError = error instanceof Error ? error.message : `${error}`;
        if (attempt + 1 >= MAX_ATTEMPTS || !this.isRetryable(lastError))
          throw new Error(`LLM request failed: ${lastError}`);
      }
    }
    throw new Error(`LLM request failed: ${lastError}`);
  }

  private async completeOnce(prompt: string): Promise<string> {
    this.updateMessages(prompt);
    if (this.sessionId === null) {
      const r = libLlm.llmCreateSession(this.options.attributes ?? '{}');
      if (r.error !== 0) throw new Error(`CreateSession failed: error=${r.error}`);
      this.sessionId = r.session;
    }
    const requestJson = JSON.stringify({ messages: this.messages, stream: this.options.stream ?? true });
    return new Promise<string>((resolve, reject) => {
      let buffer = ''; let settled = false; let timer: number = -1;
      const finish = (action: () => void): void => {
        if (settled) return; settled = true;
        if (timer !== -1) clearTimeout(timer); action();
      };
      timer = setTimeout(() => finish(() => reject(new Error('LLM request timed out.'))), COMPLETE_TIMEOUT_MS);
      const sr = libLlm.llmSubmitRequest(this.sessionId!, requestJson, (response: string) => {
        const chunk = this.parseResponseChunk(response);
        if (chunk.content.length > 0) { buffer += chunk.content; this.tokenStreamListener?.(chunk.content); }
        if (chunk.finish_reason !== null && chunk.finish_reason !== undefined) {
          finish(() => {
            const text = buffer.trim();
            if (text.length === 0) { reject(new Error('No message content returned.')); return; }
            this.lastPrompt = prompt; this.lastResponse = text; resolve(text);
          });
        }
      });
      if (sr.error !== 0) finish(() => reject(new Error(`SubmitRequest failed: error=${sr.error}`)));
    });
  }

  // --- Prompt -> Messages 转换 ---

  private updateMessages(prompt: string): void {
    if (this.messages.length === 0) {
      this.messages = this.parseInitialPrompt(prompt);
    } else {
      const diff = this.diffPrompt(prompt);
      if (diff !== null) {
        this.messages.push({ role: 'assistant', content: diff.assistantText });
        this.messages.push({ role: 'user', content: diff.userText });
      } else {
        this.rebuildSession();
        this.messages = this.parseInitialPrompt(prompt);
      }
    }
  }

  private parseInitialPrompt(prompt: string): LlmMessage[] {
    const marker = '\nUser task:\n';
    const idx = prompt.indexOf(marker);
    if (idx < 0) return [{ role: 'user', content: prompt }];
    return [
      { role: 'developer', content: prompt.substring(0, idx + 1).trim() },
      { role: 'user', content: prompt.substring(idx + marker.length).trim() }
    ];
  }

  private diffPrompt(prompt: string): { assistantText: string; userText: string } | null {
    const sp = this.stripDatetimeLine(prompt);
    const sl = this.stripDatetimeLine(this.lastPrompt);
    if (!sp.startsWith(sl)) return null;
    const suffix = sp.substring(sl.length).trim();
    if (suffix.length === 0) return null;
    const lastResp = this.lastResponse.trim();
    if (!suffix.startsWith(lastResp)) return null;
    return { assistantText: lastResp, userText: suffix.substring(lastResp.length).trim() };
  }

  private stripDatetimeLine(text: string): string {
    const prefix = 'Current device local datetime: ';
    const startIdx = text.indexOf(prefix);
    if (startIdx < 0) return text;
    const lineEnd = text.indexOf('\n', startIdx);
    if (lineEnd < 0) return text;
    return text.substring(0, startIdx) + text.substring(lineEnd + 1);
  }

  private rebuildSession(): void {
    if (this.sessionId !== null) { libLlm.llmDestroySession(this.sessionId); this.sessionId = null; }
    this.messages = []; this.lastPrompt = ''; this.lastResponse = '';
  }

  private parseResponseChunk(response: string): ResponseChunk {
    try {
      const json = JSON.parse(response) as ResponseChunk;
      return { content: json.content ?? '', finish_reason: json.finish_reason ?? null };
    } catch (_e) { return { content: response, finish_reason: null }; }
  }

  private isRetryable(message: string): boolean {
    const lower = message.toLowerCase();
    if (lower.indexOf('http 4') >= 0 || lower.indexOf('http 5') >= 0) return false;
    return lower.indexOf('timeout') >= 0 || lower.indexOf('connection') >= 0 || lower.indexOf('network') >= 0;
  }
}
```

## 5. Prompt -> Messages 转换策略

### 5.1 问题

`ReActAgentRunner.buildPrompt` 每步把完整上下文重拼成 flat 文本：`[system规则+工具+历史+task] [response1] [Observation1] [response2] [Observation2] ...`。前缀稳定（除 timestamp），scratchpad 每步增长。直接整块发给 service，KV-cache 每步失效。

### 5.2 映射

| ReAct scratchpad 项 | messages 映射 | KV-cache |
|---|---|---|
| response (Thought+Action) | {role:"assistant", content:response} | service 自己生成并存 cache |
| Observation (工具结果) | {role:"user", content:observation} | 唯一需要传的增量 |

转换后每步只 prefill 一小段 Observation，cache 完美复用，语义零损失。

### 5.3 Timestamp 处理

`buildPrompt` 含 `currentLocalDateTime()`，每步变化。diff 前先 strip 掉这行。system message 时间戳取自首次调用，后续不更新（几秒到几分钟偏差不影响相对日期推断）。

### 5.4 Diff 失败兜底

前缀不匹配时：销毁旧 session -> 创建新 session -> 重新解析 prompt -> cache 重建。保证正确性，单 run 内不应发生但兜底必须有。

## 6. 回调数据流 (端到端)

1. **ReActAgentRunner**: `response = await model.complete(flatPrompt)`
2. **SessionBackedModel**: diff 提取 observation -> 追加 messages -> `llmSubmitRequest`
3. **AKI Bridge**: trampoline 包装 -> `XXXXX_SubmitRequest`（立即返回）
4. **LLM Engine**: 逐 token 调 trampoline
5. **SafetyCallback -> ArkTS callback**: 解析 JSON -> 追加 buffer -> finish_reason 时 resolve
6. **SessionBackedModel**: 存 lastPrompt/lastResponse -> 返回给 ReActAgentRunner
7. **ReActAgentRunner**: parse Thought/Action/Final

## 7. 集成: 替换网络 LLM

### 7.1 现有调用链

**路径一 (主聊天)**: `Index.ets` `runAgent()` -> `createLoopModelInfo` -> `OpenAiCompatibleModel` 或 `ScriptedLocalModel`

**路径二 (AIPhone)**: `LoopBackend.buildModel` -> `OpenAiCompatibleModel` 或 `ScriptedLocalModel`

### 7.2 替换策略: 工厂加分支

`llm_config.json` 加 `"useLocalLlm": true` 开关。`LoopModelFactory.createLoopModelInfo` 加分支：`useLocalLlm` 时返回 `new SessionBackedModel()`。`LoopBackend.buildModel` 加同等分支。`Index.ets` `runAgent()` 结束后调 `dispose()`。`ReActAgentRunner` 不改动。

**LoopModelFactory.ets 改动:**

```typescript
import { SessionBackedModel } from './SessionBackedModel';
export interface LoopModelInfo {
  model: LocalModel;
  mode: 'llm' | 'scripted' | 'local';
  modelName: string;
}
// createLoopModelInfo 中加:
if (config.useLocalLlm) {
  return { model: new SessionBackedModel(), mode: 'local', modelName: 'local-llm' };
}
```

**LoopBackend.ets 改动 (buildModel):**

```typescript
if (settings.useLocalLlm) { return new SessionBackedModel(); }
```

**Index.ets 改动 (runAgent 后清理):**

```typescript
await runner.run(task, listener);
if (modelInfo.model instanceof SessionBackedModel) {
  (modelInfo.model as SessionBackedModel).dispose();
}
```

### 7.3 Session 生命周期

- 单次 run 内: 同一 SessionBackedModel 贯穿 maxSteps 次循环 -> KV-cache 复用
- 跨用户消息: 新 model -> 新 session -> cache 重建（跨任务历史由 ConversationContext 管理）
- run 结束后调 `dispose()` 销毁 session

## 8. 错误处理与超时

| 场景 | 处理 |
|---|---|
| CreateSession 失败 | 抛 Error, ReActAgentRunner 发 ERROR 事件 |
| SubmitRequest 失败 | 传输层错误重试 1 次 |
| 超时 (40s) | reject, 重试 1 次 |
| SafetyCallback env 失效 | trampoline try-catch |
| Diff 失败 | 重建 session |
| 空响应 | reject |

抛出的 `Error.message` 会直接成为 `AgentEvent(ERROR)` 发给 UI，信息要面向用户可读。

## 9. 文件清单

### 新增文件

| 文件 | 说明 |
|---|---|
| `entry/src/main/cpp/llm_bridge.cpp` | C++ AKI 桥接层 |
| `entry/src/main/cpp/llm.h` | LLM 引擎头文件 (已有) |
| `entry/src/main/cpp/types/libllm/index.d.ts` | ArkTS 类型声明 |
| `entry/src/main/cpp/CMakeLists.txt` | CMake 构建 |
| `entry/src/main/cpp/aki/` | AKI 源码 (git clone) |
| `agent_core/src/main/ets/model/SessionBackedModel.ets` | ArkTS 适配层 |

### 修改文件

| 文件 | 改动 |
|---|---|
| `LoopModelFactory.ets` | `createLoopModelInfo` 加 `useLocalLlm` 分支 |
| `LoopBackend.ets` | `buildModel` 加同等分支 |
| `Index.ets` | `runAgent()` 结束后调 `dispose()` |
| `llm_config.json` | 加 `"useLocalLlm": true` 开关 |

### 不改动文件

| 文件 | 原因 |
|---|---|
| `ReActAgentRunner.ets` | 只依赖 `LocalModel` 接口, 透明 |
| `OpenAiCompatibleModel.ets` | 网络 LLM 保留 |
| `ScriptedLocalModel.ets` | 降级路径保留 |

## 10. 实现顺序

1. **C++ 桥接层**: clone AKI -> 写 `llm_bridge.cpp` -> CMakeLists -> 编译 `libllm.so`
2. **类型声明**: 写 `index.d.ts`
3. **ArkTS 适配层**: 写 `SessionBackedModel.ets`
4. **单元测试 (无 LLM)**: mock callback 验证 diff/messages/超时/重试
5. **工厂集成**: 改 `LoopModelFactory` + `llm_config.json`
6. **端到端测试**: 接真实 LLM 引擎
7. **KV-cache 验证**: 对比每次新 session vs 同 session 复用的推理时间
8. **AIPhone 路径**: 改 `LoopBackend.buildModel`
9. **dispose 清理**: 改 `Index.ets` `runAgent`

## 11. 测试计划

| 测试项 | 方法 |
|---|---|
| trampoline 正确调用 SafetyCallback | mock XXXX_SubmitRequest |
| env 失效不 crash | 销毁 JS 线程后调 trampoline |
| destroySession 清理无泄漏 | 创建 N 个 request 后 destroy |
| Diff 正确提取 observation | 用真实 buildPrompt 多步输出喂 diffPrompt |
| Timestamp strip | 构造只差 timestamp 的两个 prompt |
| Diff 失败兜底 | 构造前缀不匹配场景 |
| ReAct 端到端 | 接真实 LLM 验证 Thought/Action/Final |
| KV-cache 命中 | 同一 run 多步对比首步 vs 后续步推理时间 |

## 12. 假设与待定项

### 假设

- 回调 `response` 是 JSON, 含 `content` 和 `finish_reason`。字段名可改, 只改 `parseResponseChunk`
- `XXXXX_CreateSession` 轻量 (模型已加载)
- service KV-cache 基于对话轮次, 发完整 messages 即可命中
- service 接受任意文本作为 user content
- service 不后处理 assistant 输出
- `attributes` 当前传 `"{}"`
- AKI 源码放 `entry/src/main/cpp/aki/`

### 待定

- `attributes` JSON 具体字段
- `request` JSON 具体字段 (当前按 OpenAI messages 格式)
- 回调 `response` JSON 具体字段名
- `useLocalLlm` 开关放 `llm_config.json` 还是 `LocalModelSettings`
