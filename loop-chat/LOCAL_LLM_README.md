# Loopy 本地模型接入与 Agent 推理

本文档说明如何把 Gewu 本地模型接入 Loopy，以及如何在 App 中完成普通对话、ReAct 工具任务和多设备协同推理。

## 当前实机基线

- 已验证设备：两台 HUAWEI Mate 70 Pro（`PLR-AL00`）。
- 已验证模型：`Qwen2.5-7B-Instruct-Q4_N_0`。
- 已验证后端：`knpu`。
- 已验证能力：本地会话创建、流式返回、普通对话、ReAct 工具调用、两台 Mate 70 端到端协同推理。
- 双机实测由 Gewu 把 Qwen2.5 的 28 层切分为主机 `0-12`、协作者 `13-27`；Loopy 输入 `hello` 后在 App 回显 `Hello! How can I assist you today?`。
- Mate 60 Pro（`ALN-AL00`）的当前系统运行栈在 `DrvGetL2Info ret 4` 后崩溃，不能作为可用基线。

## 调用链

```text
ArkUI pages/Index.ets
  -> getLocalLlmBinding()
  -> createLoopModelInfo()
  -> SessionBackedModel
  -> libllm.so (AKI/NAPI bridge)
  -> libqos.so / Gewu service
  -> KNPU
  -> Qwen2.5 model
```

`agent_core` 不直接引用 Native `.so`。`entry` 模块加载 `libllm.so`，将 `LlmNativeBinding` 注入 `LoopModelFactory`，因此 HAR 仍可被其他 HarmonyOS App 复用。

## 模型与配置

配置文件：

```text
entry/src/main/resources/rawfile/llm_config.json
```

当前配置：

```json
{
  "useLocalLlm": true,
  "localModelPath": "/data/storage/el2/base/haps/entry/files/model/Qwen2.5-7B-Instruct-Q4_N_0",
  "localModelBackend": "knpu",
  "localModelMaxContext": 2048,
  "localModelRequestType": "qwen2",
  "deterministicSkillRouting": false,
  "localCollaboration": {
    "enabled": false,
    "isMaster": true,
    "masterIP": "192.168.1.20",
    "masterPort": 19090,
    "broadcastPort": 7790,
    "controlPort": 19091
  }
}
```

`deterministicSkillRouting` 默认保持 `false`：所有 Skill 由 Loopy 原生 ReAct 流程选择，模型先查看 Skill 目录，再通过 `Action: read[skill_name]` 加载完整指令。`true` 仅预留给需要固定关键词直达 Skill 的受控基准测试。

`localModelBackend` 可为 `knpu`、`cpu` 或 `mlir`。当前 `Q4_N_0` 在该设备栈上只能使用 KNPU：CPU 不支持 `q4_n_0`，MLIR 不支持该量化数据。

模型目录必须包含：

```text
Qwen2.5-7B-Instruct-Q4_N_0/
  params
  tokenizer.json
  api_config.json
```

双机协同必须使用仓库内与 GeWuDemo 对齐的模型配置：

```text
model-config/Qwen2.5-7B-Instruct-Q4_N_0/api_config.json
```

该文件只声明模型、tokenizer 和权重元数据；`backend`、`max_ctx` 由 Loopy 创建
session 时的 `eval_settings` 传入。不要在模型配置中额外写入
`cache_grow_policy`、`cache_grow_size` 或 `cache_persist_policy`。当前 Mate 70
运行库在双机数据面使用这些覆盖项时可能触发
`RtSessionWriteKvCache failed, errCode: 5`，随后协作者 `eval failed`、主机
`recv token failed`，表现为 App 一直等待或“未返回消息内容”。

发送模型前先覆盖来源目录中的配置：

```bash
cp model-config/Qwen2.5-7B-Instruct-Q4_N_0/api_config.json \
  Qwen2.5-7B-Instruct-Q4_N_0/api_config.json
```

先把模型发送到可写的临时目录：

```bash
hdc file send Qwen2.5-7B-Instruct-Q4_N_0 /data/local/tmp/model/
```

安装 App 后运行已提供的部署脚本：

```bash
hdc shell /data/local/tmp/model_deploy_loop.sh
```

脚本会完成 SHA-256 比对、拷贝、App UID/GID 修复和文件权限设置。不要直接把模型编进 HAP。

## Native 调用接口

`LlmNativeBinding` 是 ArkTS 与 Native 推理层之间的稳定边界：

```typescript
interface LlmNativeBinding {
  createSession(attributes: string): { session: number; error: number };
  destroySession(session: number): number;
  submitRequest(
    session: number,
    request: string,
    callback: (response: string) => void
  ): { request: number; error: number };
  abortRequest(session: number, request: number): number;
  enableCollaboration(info: string): number;
  disableCollaboration(): number;
  isCollaborationSupported(): boolean;
}
```

创建会话时传给 Gewu 的 attributes：

```json
{
  "model": "/data/storage/el2/base/haps/entry/files/model/Qwen2.5-7B-Instruct-Q4_N_0",
  "eval_settings": {
    "backend": "knpu",
    "max_ctx": 2048
  }
}
```

提交请求的 JSON：

```json
{
  "type": "qwen2",
  "messages": [
    { "role": "developer", "content": "system instructions" },
    { "role": "user", "content": "你好" }
  ],
  "stream": true
}
```

回调同时兼容顶层 `content` 和 Gewu `message.content` 封装：

```json
{"message":{"role":"assistant","content":"..."},"finish_reason":"stop"}
```

`finish_reason` 非空时结束本次请求。Prefill 阶段不设置应用侧超时上限，Loopy 会一直等待 Gewu 的首个回调；首个回调到达后，如果连续 30 秒没有任何后续回调则判定流式推理停滞，并从此时开始计算 600 秒 Decode 绝对安全上限，防止异常流持续回调却永不结束。页面销毁时同样调用 `abortRequest`，最后必须调用 `destroySession`。这套看门狗不会截断耗时较长的 Prefill，同时仍能识别已经开始输出后的 Decode 卡死。推理期间 App 会保持前台窗口亮屏，完成后单机模式恢复系统息屏策略。

Gewu 的回调线程可能晚于 `abortRequest/destroySession` 返回。Native 桥不能立即删除传给 `OH_QoS_GewuChatComplete` 的 opaque callback context；当前实现先原子地标记 inactive，再把上下文隔离保留到进程退出。这样迟到回调只会被忽略，不会再次触发 `aki::SafetyCallback` 的 use-after-free/SIGSEGV。

## 在 App 中直接调用本地模型

```typescript
const binding = await getLocalLlmBinding();
if (binding === null) {
  throw new Error('libllm.so is unavailable');
}

const model = new SessionBackedModel(binding, {
  attributes: buildLocalSessionAttributes(modelPath, {
    backend: 'knpu',
    maxContext: 2048
  }),
  requestType: 'qwen2',
  stream: true
});

try {
  model.setTokenStreamListener((token: string): void => {
    // 更新 ArkUI 流式文本
  });
  const answer = await model.complete('请介绍一下你自己');
  // 显示 answer
} finally {
  model.dispose();
}
```

## 接入 Loopy Agent

主界面使用的标准方式：

```typescript
const binding = await getLocalLlmBinding();
const modelInfo = await createLoopModelInfo(
  context,
  skillSnapshot,
  binding ?? undefined
);
const tools = await createConfiguredLoopToolRegistry(context, skillSnapshot);
const runner = new ReActAgentRunner(modelInfo.model, tools, 6, skillSnapshot);

await runner.run(userText, (event: AgentEvent): void => {
  // THOUGHT / SKILL / ACTION / OBSERVATION / FINAL / ERROR
});
```

App 中实际入口位于 `entry/src/main/ets/pages/Index.ets`。会话内部复用同一 Gewu session 获得 KV-cache，一次 Agent run 结束后销毁 session。

### 模型输出协议

普通对话：

```text
Thought: No tool is needed.
Final: 你好，我是运行在手机上的本地模型。
```

执行工具：

```text
Thought: I need the device time.
Execution: serial
Action: time[{}]
```

获得 Observation 后：

```text
Thought: I have the result.
Final: 现在是 10:30。
```

兼容层额外接受：

- `Final Answer:`、`Answer:`、`最终答案：`、`答案：`。
- 不含 Action 的纯自然语言回复，作为普通对话的 Final。
- `Action: tool[input]`、`Action: tool(input)`。
- `Action: tool` 加下一行 `Action Input: ...`。

包含 `Action:` 的输出不会被当成普通文本，避免将未执行的工具调用伪装成成功回复。

## 协同推理

当前实现已对齐 PR #1 的页面启动、输入聚焦、Send/Clear 三时机，但使用真实 Gewu 参数，不再固定传空 JSON。完整设计见 `docs/collaboration-design.md`。单机 HAP 默认保持 `localCollaboration.enabled=false`。

启用前必须探测系统接口：

```typescript
if (!binding.isCollaborationSupported()) {
  throw new Error('Gewu collaboration is unavailable');
}

const info = buildLocalCollaborationInfo({
  isMaster: true,
  masterIP: '192.168.1.20',
  masterPort: 19090
});
if (info === undefined || binding.enableCollaboration(info) !== 0) {
  throw new Error('Failed to enable collaboration');
}
```

只有协作者的 session 增加 `parallel_settings`。`caller` 必须是主机 Loopy 进程的实时 PID，由 `CollaborationController` 在 session 创建时动态发送，不能写死在配置中：

```json
"parallel_settings": {
  "caller": 30206,
  "is_co": true
}
```

上面的 `30206` 只是一次实机日志示例，不应复制到配置。热点场景下由协作者主动连接主机 TCP `controlPort`，主机沿已建立连接下发 PID；UDP 7790 仅作为发现和兼容回退。配置中的 `masterPort: 19090` 是引导值；为绕过 Gewu 监听端口关闭后无法立即重绑的问题，主机实际从 21000–21999 选择进程专属端口，并在 `runtime_prepare` 中下发给协作者。19091 始终只用于 Loopy 控制面，不能和 Gewu 数据面混用。

主从角色配置模板：

```text
entry/src/main/resources/rawfile/llm_config.collab-master.example.json
entry/src/main/resources/rawfile/llm_config.collab-slave.example.json
```

打包前把对应模板内容写入 `llm_config.json`。两端 `masterIP`、引导 `masterPort`、`broadcastPort`、`controlPort` 必须一致，只有 `isMaster` 不同；运行时动态端口由协议自动协商，无需手工修改。

### App 连接状态与重连按钮

主界面顶部的状态条来自应用层 `hello/hello_ack` 握手和 3 秒心跳，不是根据“端口能连通”猜测：

- 绿色：主从控制通道已完成握手；文案为“协同会话已就绪”时，协作者还已成功创建 co-session 并回传 `session_ready`。
- 橙色：正在等待连接、重连或准备双机 session。
- 红色：控制通道断开、Gewu 初始化失败或 co-session 创建失败。
- 灰色：协同未启用。

“连接设备/重连”会先通过 generation 屏障安全结束已有 session，再重新建立 TCP 控制通道；下一次聚焦输入框时，主机旋转到新的 Gewu 数据端口，协作者清理旧数据面并重新注册。首次成功后后续会话复用资源表，避免每轮触发驱动和端口抖动。该顺序同时避免主机退化为 `0-27`、`GetCoSessionInfoByMasterInfo` 401 和 `Failed to recv emb`。

主机只在收到协作者的 `session_ready` 后才允许开始推理。15 秒内未收到确认时，本次请求直接失败并提示保持协作者 Loopy 在前台，不会退化成单机答案后仍显示为协同。绿色“已连接”证明控制面在线；双机算力真正参与仍以主机 `layers: 0-12`、协作者 `layerSeg: 13-27` 以及两端同一请求的 `Start infer` 为准。

协同启用时，Loopy 会对前台窗口调用 `setWindowKeepScreenOn(true)`，避免默认息屏冻结控制通道；页面退出或切到后台后恢复系统策略。若控制面已经绿灯但 co-session 返回 `401`，保持两端解锁并回到 Loopy 前台，在主机点击一次“重连”，然后重新聚焦输入框。待主机显示“协同会话已就绪，可以发送”后再提交任务。

本地模型不限制 Prefill 首响应时长；首个回调到达后采用两级 Decode 看门狗：流式回调停顿 30 秒、Decode 绝对上限 600 秒。Decode 超时会停止当前请求并把资源表标为待重建，下次聚焦自动走新端口恢复；它不是自动降级信号，协同未就绪时仍会直接阻止请求。需要注意：如果 Gewu 在 Prefill 阶段永久不回调，用户需要通过清空会话、退出页面或重启服务主动取消。

退出时调用 `disableCollaboration()`。旧设备或旧 SDK 缺少符号时返回 `801 / OH_QOS_GEWU_NOSYS`，不应崩溃 App。

## 构建和安装

构建前确认新 Gewu 包已补齐以下 Native 依赖：

```text
entry/src/main/cpp/aki/
entry/src/main/cpp/gewu/include/qos.h
```

缺少 `aki/` 时，CMake 会报 `add_subdirectory given source "aki" which is not an existing directory`。这是源码构建依赖缺失，与手机上的 KNPU/Gewu 运行时兼容性不是同一问题。

```bash
cd harmony

DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk \
JAVA_HOME=/Applications/DevEco-Studio.app/Contents/jbr/Contents/Home \
NODE_HOME=/Applications/DevEco-Studio.app/Contents/tools/node \
/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw \
  --mode module -p product=default assembleHap --no-daemon
```

对 HAP 签名后安装：

```bash
hdc install -r entry-default-signed.hap
hdc shell aa start -a EntryAbility -b com.example.loop
```

覆盖安装要求新旧 HAP 签名一致。出现 `install sign info inconsistent` 时，先备份 App 数据，再卸载旧签名版本。

## 验收

1. 启动 App，顶部应显示 `Local LLM: Qwen2.5-7B-Instruct (Gewu)`。
2. 输入普通问题，应收到 `Final` 回复，不应出现 `Model did not return an Action or Final answer.`。
3. 输入“请使用 time 工具告诉我现在时间”，应依次看到 `Action`、`Observation`、`Final`。
4. 双机模式下先确认状态条为绿色；聚焦输入框后应显示“协同会话已就绪，可以发送”。
5. 主端 Gewu 日志应出现 `layers: 0-12`，协作者出现 `layerSeg: 13-27`，两端都应出现同一请求的 `Start infer` 和相同 `inputTokenCount`。
6. 每轮结束应出现匹配 generation 的 `session_ended`；连续三轮和手动重连后一轮都应成功。
7. `pidof gewu_service` 应返回正常进程，新请求不应生成 `cppcrash-gewu_service` 或 `cppcrash-com.example.loop` fault log。
8. 发送后如立即报 `DrvGetL2Info ret 4`，这是设备 Gewu/KNPU/驱动运行栈问题，不是 ReAct 兼容层问题。

本次双机实测记录与部署哈希见 `docs/mate70-collaboration-deployment.md`。

## 关键源码

```text
agent_core/src/main/ets/model/SessionBackedModel.ets
agent_core/src/main/ets/model/LoopModelFactory.ets
agent_core/src/main/ets/model/LlmProvider.ets
agent_core/src/main/ets/agent/ReActAgentRunner.ets
agent_core/src/main/ets/agent/ReActResponseCompatibility.ets
entry/src/main/ets/llm/LocalLlmBinding.ets
entry/src/main/cpp/llm_bridge.cpp
entry/src/main/resources/rawfile/llm_config.json
entry/src/main/ets/pages/Index.ets
```
