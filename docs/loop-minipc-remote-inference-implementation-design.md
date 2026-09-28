# Loop 接入 MINIPC 算力集群：落地设计与验收方案

版本：设计稿 v1.0 · 2026-09-24  
状态：基于两仓代码审查；尚未实施接入、编译新版本或完成本方案真机验证。

## 1. 结论与产品定义

**可行。推荐将 Loop 改造成“保留 Agent 和工具执行能力的远程推理客户端”，复用 MINIPC 的发现、连接、中心调度和算力端原生推理能力。**

用户仍在 Loop 中聊天、查看任务过程、使用文件和技能；模型生成放到另一台算力设备上。后续增加算力设备时，由 MINIPC 中心选择执行节点，Loop 不直接管理每台设备的模型。

但“可行”不等于“把两个工程连接起来就能一次成功”。当前代码有两个必须提前验证的条件：

1. Loop 与 MINIPC 包名不同，现有近场连接能否在实际系统、签名和可信关系下跨应用建立，尚未验证。
2. MINIPC 原生推理固定使用 2048 上下文、256 输出 token；Loop 的工具说明、历史和工具返回值可能装不下。只放宽网络消息长度不能解决这个问题。

本方案通过**先做两项阻断性验证，再分阶段实现、逐级验收**降低返工风险，不承诺未经真机验证的一次成功。

### 1.1 明确两端职责

| 内容 | Loop 手机 | MINIPC 中心 / 算力手机 |
|---|---|---|
| 聊天界面、任务过程、历史展示 | 保留 | 不接管 |
| ReAct Agent 循环、工具选择结果解析 | 保留 | 不执行 |
| 文件读写、技能加载、已接入的外部工具 | 在 Loop 原位置执行 | 不直接访问 Loop 沙箱 |
| 拼装本轮模型输入 | Loop 负责 | 校验并转换模型请求 |
| 大模型计算、原生 Session | 远程模式不创建 | 执行并释放 |
| 发现、连接、重连 | 作为聊天角色接入 | 复用中心与执行节点拓扑 |
| 选择哪台算力机 | 不选择 | 中心调度 |
| 密钥、OAuth 配置、用户工具授权 | 留在 Loop | 不因接入而复制 |

因此这里的“Loop 只作为界面”，准确地说是：**Loop 不承担大模型推理，但继续承担界面、Agent 编排和工具执行。** 如果连 Agent、工具也搬到算力端，手机文件、授权和生命周期都要重新设计，不属于本次方案。

### 1.2 本期边界

本期交付：

- Loop `entry` 应用接入 MINIPC；远程模式无需在 Loop 手机部署模型权重。
- 保持现有已注册工具、技能和聊天入口，支持多轮“推理 → 工具 → 再推理”。
- 单算力先闭环，再支持多算力自动调度、多聊天客户端隔离。
- 明确处理取消、超时、断线、上下文不足、模型失败和协议不兼容。
- 保留旧本地模式用于回归和人工切换，远程必需模式禁止自动回落到本地、云模型或脚本。

本期不交付：

- 单次推理的跨设备分层、张量并行或跨设备 KV Cache。
- 中心失效后无损续接正在生成的回答。
- 将图片直接交给当前文本 Qwen 模型理解。
- 自动获得 ApplessPhone/A2UI、AIPhone 中尚未接入 Loop entry 的全部能力。
- 任意长文档、任意数量技能、无限聊天历史都能放入有限上下文。
- 将现有原生库彻底从 Loop 安装包移除；这可另设纯远程构建产品完成。

**多台算力提升的是并发服务能力、可用节点数量和调度选择，不保证单个任务变快。** 一次模型调用仍由一台设备完整执行；一个 Agent 任务中的多轮调用可以分配到不同的兼容节点。

这里的算力设备首先指当前 MINIPC `model-end` 能运行的 HarmonyOS / GEWU 设备。接入 Windows、Linux 或其他模型运行时，需要另写执行端适配和部署方案，不能仅凭统一协议就视为已支持。

## 2. 代码基线与已经确认的问题

### 2.1 审查基线

| 项目 | 基线 |
|---|---|
| Loop | `D:\harmony`，HEAD `ccf7afd35eb4997e7b06ebf03e1c1ff931c1a22f` |
| MINIPC | `D:\MINIPC`，HEAD `7f04eddd484d9f665b008177d5d44c153e74d5af` |
| 已运行检查 | MINIPC 当前 12 个 `*.test.cjs` 测试文件全部退出成功 |
| 本次未运行 | 新接入版本的 HAP 构建、原生生命周期测试、两仓联合真机测试 |
| 修改边界 | 本次只新增设计文档，不修改业务代码、签名、模型文件或 MINIPC 现有改动 |

现有测试使用测试夹具 / 平台模拟，不能证明蓝牙、`linkEnhance`、系统权限或原生模型在目标设备上可用。

### 2.2 接入依据与差距

下表路径相对于各自仓库根目录；这是代码证据，不是已完成的改造。

| 位置 | 当前行为 | 对本方案的影响 |
|---|---|---|
| Loop `agent_core/src/main/ets/model/LocalModel.ets` | `complete(prompt, conversation?)` 返回完整字符串 | 可新增远程实现，不必重写 Agent |
| Loop `agent_core/src/main/ets/agent/ReActAgentRunner.ets` | 拼装说明、工具、历史、任务与 scratchpad；解析回答并执行工具 | Agent 留在 Loop；远程不能重复追加历史 |
| Loop `agent_core/src/main/ets/model/SessionBackedModel.ets` | 本地持续 Session，含初始提示词拆分及后续增量逻辑 | 不能直接搬用增量发送逻辑到 MINIPC |
| Loop `entry/src/main/ets/pages/Index.ets` | 直接协调本地模型、旧协同、工具、指标和运行状态 | 必须在本地初始化前分流远程模式 |
| Loop `agent_core/src/main/ets/agent/ToolRegistry.ets` | 工具注册还受技能快照、外部配置等条件影响 | 以实际注册清单验收，不按 README 宣称全部可用 |
| Loop `agent_core/src/main/ets/file/SandboxFileReadTool.ets` | 单次可读取最高 512 KiB | 返回内容可能同时超传输和模型上限 |
| MINIPC `src/chat-end/entry/src/main/ets/pages/Index.ets` | 远程请求链路主要写在页面里 | 提取客户端服务，不能直接复制聊天页覆盖 Loop |
| MINIPC `src/chat-end/entry/src/main/ets/llm/LlmTransport.ets` | 目前只有本地实现 | 不存在可直接复用的完整远程 LlmTransport |
| MINIPC 两端 `protocol/ChatProtocol.ets` | `nearby-chat-v1`；普通请求最多 7 条消息、合计 `.length <= 1800` | 为推理新增协商扩展，不能沿用旧聊天请求承载完整 Agent 输入 |
| MINIPC 两端 `nearby/LinkEnhanceChannel.ets` | BLE 发现，`linkEnhance` 传输；角色消息白名单 | 同时修改编解码、白名单、握手和转发 |
| MINIPC `src/model-end/entry/src/main/ets/cluster/ComputeRouter.ets` | 按负载、内存等选择节点 | 增加模型、协议、上下文及并发准入约束 |
| MINIPC `src/model-end/entry/src/main/ets/llm/LocalChat.ets` | 每次调用启动原生任务；当前只解析 `message.content` | 新增通用推理服务，规范响应解析和清理 |
| MINIPC `src/model-end/entry/src/main/cpp/gewu_probe.cpp` | 每请求创建 / 销毁 Session；`max_ctx=2048`；字符串参数上限 65536 字节 | 参数需要受控扩展；完整提示词每次发送；不能假设天然存在跨轮缓存 |
| 同上 | 请求 / 响应进入文件日志及 hilog | 新接入前必须默认关闭正文日志，避免工具数据泄露 |

### 2.3 两个容易误判的地方

**会话固定不是首版正确性的前提。** MINIPC 当前每次请求新建原生 Session，即便始终分配给同一设备，也不会自动复用上一轮 KV Cache。首版选用无状态调用：每次发送完整有效上下文，节点可重新选择。真正的 Session 复用留待以后单独设计。

**网络容量和模型容量是两种限制。** `1800` 是旧代码中的 JS 字符串长度限制，`65536` 是序列化消息字节限制，`2048` 是原生模型上下文配置；三者不能互相换算代替。中文、表情、JSON 转义和模型模板都会改变实际预算。

## 3. 目标架构与一次任务的流程

```text
Loop 手机                                     MINIPC 集群
┌ 聊天页 / 文件空间 / 技能
│   ↓
│ ReActAgentRunner
│   ↓ complete(完整 prompt)
│ RemoteComputeModel → ComputeClient ────────→ 中心 InferenceGateway
│                                               ↓ 准入 + 调度
│                                           本机或其他算力节点
│                                           GEWU / Qwen 完整推理
│   ←──────── 有序 delta + 终态 + 来源 ──────────┘
│   ↓ 校验完整成功结果
│ Action → Loop 本地工具 → Observation → 下一轮 complete
└ Final → 展示并保存聊天结果
```

以“列出文件并总结其中一篇文章”为例：

1. Loop 组装任务、工具描述、技能及有效历史，发送第一次推理。
2. 算力机返回完整 `Action`；Loop 校验成功终态后，调用自己的文件列表工具。
3. 列表结果进入 Loop 的 scratchpad，下一次完整推理携带这个结果。
4. 模型要求读取文件，Loop 从自己的沙箱读取；必要正文会随后续 prompt 发送给算力机。
5. 模型返回 `Final`，Loop 展示并保存。

算力机无需访问 Loop 的文件路径或拥有文件权限，但**确实能接触被放入 prompt 的文件内容**。首次启用远程功能必须告知这一点。

## 4. 最先执行的两项验证（Gate A / Gate B）

这两项通过前，不投入完整的 UI 与多节点改造。

### 4.1 Gate A：真实应用身份下跨应用近场通信

现状：Loop 包名为 `com.example.loop`；MINIPC 聊天端和算力端均为 `com.jiuwen.registrychatui`。MINIPC 使用服务名 `nearby-compute`，发现广播 manufacturer 为 `0x6E77`。

执行步骤：

1. 记录两台设备系统版本、API、开发签名配置、是否为可信设备及权限状态。
2. 使用 Loop 的真实包名构建最小客户端，算力机安装 MINIPC 测试版；暂时不接模型。
3. 将客户端 `DeviceManager` 的应用身份改为 Loop 实际身份，不能照抄 MINIPC 的包名常量。
4. 复用服务名、发现规则和连接 API，完成 hello / hello_ack。
5. 双向发送短文本、含中文/表情文本及 32 KiB 测试负载，校验原始 UTF-8 字节哈希完全一致。
6. 测试权限拒绝后重新授予、蓝牙开关、切后台再回来、断开重连和重复连接。

通过标准：上述测试在目标签名与系统组合上稳定通过；没有靠临时改成同包名掩盖跨应用问题。

若失败：先定位可信设备、权限、系统能力和签名约束。当地 SDK 的 `linkEnhance` 声明说明了接口和权限，但不能证明当前跨包名组合必然可行。不得仅因服务名相同就认为可连。

若平台确有应用身份限制，输出证据后再选择：

- 为集成版确定新的统一产品身份 / 签名方案，评估应用升级、共存和沙箱迁移；或者
- 另立经用户确认的局域网传输适配层，保留本方案上层推理协议。

这属于路线调整，不在 Gate A 失败后擅自改包名、覆盖安装或换通信方式。

### 4.2 Gate B：完整 Agent 提示词的上下文与工具能力验证

先从 Loop 实际提示词构建器采集以下输入样本，仅在受控测试环境保存正文：

- 已启用工具、技能的第一轮 prompt。
- 文件列表后的第二轮 prompt。
- 读取典型短文章后的 prompt。
- 多轮对话历史与多步 scratchpad 累积后的 prompt。

逐项记录 UTF-8 字节、JSON 序列化字节、准确或经验证的 token 预算、预留输出 token、实际 Session 创建结果。

算力端依次验证目标模型包和硬件支持的上下文档位。**配置文件写 8192 不代表硬件 / GEWU 支持 8192**；Loop 现有适配代码也明确记录了部分 Mate70 配置超过 2048 可报错的情况。

通过标准：选定一个实测支持的模型 profile，能容纳本期约定的完整工具任务输入与预留输出，并至少跑通“列表 → 读取 → 总结”和一个可控工具写入任务。

若只有 2048 可用：

- 可以继续做通信原型，但不能宣称“完整保留 Loop 工具能力”已经成立。
- 对比精简提示词、减少一次暴露的工具、历史裁剪、文件分段后的质量；这些都是需单独验收的产品变化。
- 如果约定任务仍装不下，应更换经过验证的模型 / 算力配置，或明确缩减范围，再继续开发。

门槛是“真实任务装得下且能稳定执行”，不是机械要求某个上下文数字。

## 5. Loop 侧详细设计

### 5.1 模型抽象与模式选择

新增 `RemoteComputeModel implements LocalModel`，保留现有 `complete(prompt, conversation?)` 接口。内部委托 `ComputeClient`，收齐并验证成功终态后才 resolve 完整模型文本。

远程模式的固定规则：

- 不在远程适配器中再次拼接 `conversation`：现有 runner 的 prompt 已包含历史。
- 不复用 `SessionBackedModel` 的“只发送新增部分”逻辑。
- 不往返回文本追加“由算力设备 N 推理”；来源是独立元数据，不能污染 `Action` / `Final` 解析。
- 远程 runner 使用 `skillsInSystemPrompt=false`，确保技能信息进入真正发出的提示词；以测试防止遗漏或双重注入。
- `complete` 出错必须 reject 明确错误，不能把“连接失败”等错误文本当模型回答 resolve。

新增明确模式枚举：`local`、`cloud`、`scripted`、`remote_required`。升级已有用户不自动改模式；选择远程后保持严格远程策略。

`Index.runAgent` 在任何本地权重探测、原生 Session 创建、旧协同准备和本地 benchmark 分支前完成分流。远程模式不得启动旧 Gewu 双机协同。

`LoopModelFactory` 返回类型增加 `remote` 类型及来源描述。旧模式与旧接口继续可用；不能让原工厂的 cloud / scripted 默认回退绕过远程失败。

### 5.2 客户端服务与生命周期

新增应用级 `ComputeClient`，职责为发现、连接、版本协商、请求映射、流聚合、取消和遥测。页面只订阅状态，不直接维护链路内部状态。

连接状态：`STOPPED → DISCOVERING → CONNECTING → NEGOTIATING → READY`；失败进入 `DISCONNECTED` 或 `INCOMPATIBLE`。收到旧 `prepared` 不能直接当作新推理服务 READY。

运行状态：`IDLE → WAITING_FOR_COMPUTE → RUNNING_MODEL ↔ RUNNING_TOOL → SUCCEEDED / FAILED / CANCELLED`。

所有异步回调必须同时校验：

- 当前连接 `connectionEpoch`。
- 当前页面 / Agent 运行的 `runGeneration`。
- 当前 `agentRunId`、`requestId`。
- 请求是否已进入终态。

页面销毁、清空聊天、应用退出及按“停止”时统一触发运行取消。首版采用保守后台策略：进入后台取消活跃任务并暂停近场；回前台恢复发现，不自动恢复旧 Agent。需要后台持续任务时另行设计系统支持，不假定普通页面定时器能一直运行。

### 5.3 工具执行与取消

为 runner 增加可选运行控制对象，例如 `AgentRunControl`，保持旧调用方兼容。实现以下检查点：模型调用前 / 后、工具执行前 / 后、并行工具各自开始前、提交最终结果前。

- 流式 `Action` 未完整生成时绝不执行工具。
- 成功终态也需确认当前 run 尚未取消，然后才能解析和执行。
- `finishReason=length`、序号缺失、连接中断、解析失败均不能把半截 Action 当作合法操作。
- 取消已开始的文件写入或外部发送不保证回滚；记录“操作可能已完成”，不能显示成完全未执行。
- 失败后不自动重新运行整个 Agent，尤其不能重复发送邮件、提交表单或写文件。
- 对现有外部写操作保留其授权 / 确认边界；没有的地方列入安全补充，不因“模型在远端”放宽权限。

### 5.4 UI 最小变化

保留 Loop 布局，只新增：模式选择、连接状态、停止按钮、错误恢复入口，以及本轮推理来源 / 耗时。

展示顺序：发现算力 → 正在连接 → 正在检查模型能力 → 就绪 → 排队 / 推理 / 执行工具。

部分模型输出可用于运行过程展示，但对话的正式结果仍由 runner 决定；“生成完成”不等于“Agent 任务完成”。取消或失败的半截结果不作为成功 assistant 历史保存。

## 6. 推理协议：保留旧聊天，新增协商扩展

### 6.1 兼容原则

保留外层 `protocol: "nearby-chat-v1"`、现有分片格式和旧消息语义，新增 **inference v2 扩展**；这里的 v2 是新推理能力版本，不是把所有旧报文直接改名。

1. 新节点在 `hello` / `hello_ack` 增加可选 `inferenceVersions: [2]`。旧版本对这些额外字段当前不做强制拒绝；通过兼容测试锁定行为。
2. 只有双方宣告支持 v2 后，才能发送 `infer.*` 消息。
3. 新版校验器严格校验扩展字段的类型、数量和长度。角色白名单也必须同步更新。
4. 新 Loop 连接旧中心时显示“算力端版本不支持”，不退回 1800 字旧请求。
5. 新中心继续服务旧聊天端；旧算力节点可以继续承接旧请求，但不能接收 v2。
6. 节点间也需要协商；中心不能因自己支持 v2，就把 v2 转给只会 v1 的执行节点。

### 6.1.1 2026-09-24 决定：同一条链路同时支持两套消息

算力端继续使用包名 `com.jiuwen.registrychatui` 和服务名 `nearby-compute`。覆盖安装，不卸载，模型文件留在应用沙箱。

同一条近场连接上同时保留两套消息，互不替代：

- 旧聊天端仍然发送 `request` / `cancel`，算力端仍然回复 `delta` / `done` / `error`。限制仍是最多 7 条消息、正文约 1800 字。`hello_ack` 上新增的 `inferenceVersions` 对旧端是可忽略字段。
- Loop 只有在自己的 `hello` 和算力端的 `hello_ack` 都包含 `inferenceVersions: [2]` 之后，才发送 `infer.capabilities.get` 和 `infer.request`。没有 `[2]` 时界面显示「算力端版本不支持」，不退回旧 `request`，也不改走本机或云端模型。
- 工具仍在 Mate 60 的 Loop Agent 里执行。算力端只完成一次完整提示词的 `complete()`。
- 2026-09-24 晚：原生会话 `max_ctx` 从自行设置的 2048 提高到 4096，单次输出仍为 256。远程 Agent 改为短提示词，不再附带文章流程、技能全文和长工具说明。`gateBPassed` 仍为 false，不把 8192 写成已验证。
- 2026-09-24 真机（1.0.3，`max_ctx` 2048）：能力协商成功，界面变为「已就绪」。随后一条 Loop 任务在发出前被拒绝，原因是「当前模型上下文不足」。
- 2026-09-24 真机（1.0.4，`max_ctx` 4096，短提示词）：Mate 70 覆盖安装后模型权重仍为 5827010560 字节。发送「ping」时提示词 721 字，客户端发出 `infer.request`，算力端返回 `infer.accepted`，约 11 秒后 `infer.done`（`finishReason=stop`，11 字节）。Mate 60 界面显示用户气泡「ping」和回复「pong」。`gateBPassed` 仍为 false。旧 `request` 路径仍留在算力端。

### 6.2 能力发现与模型 profile

握手后发送 `infer.capabilities.get`，中心返回 `infer.capabilities`。每个可路由模型 profile 至少包含：

| 字段 | 含义 |
|---|---|
| `modelId` / `modelRevision` | 模型及受控版本，不仅是显示名称 |
| `promptFormat` | 例如 `loop-react-split-v1`，说明提示词模板解释方式 |
| `maxContextTokens` / `maxOutputTokens` | 当前硬件与模型实际通过验证的上限 |
| `maxPromptBytes` / `maxWireBytes` | 原始 prompt UTF-8 与整条报文字节上限 |
| `tokenBudgetMode` | `exact` 或明确标记的 `certified-conservative`；不能把估算冒充精确统计 |
| `streaming` / `cancellation` | 支持项 |
| `ready` / `readinessReason` | 模型文件、加载自检、资源状态 |

模型 profile 由算力端本地配置管理，绑定模型清单、模板、backend、上下文和允许生成参数。远端不允许上传任意模型路径、原生 attributes 或日志路径。

`modelRevision` 应由发布时生成的模型 / tokenizer / 模板清单摘要确定，不能仅填一个相同显示名就认为节点兼容；模型文件更新后使旧认证结果失效，重新自检并发布能力。

中心能力来自健康、兼容的节点集合。最终仍逐请求重新准入：之前展示 READY，不代表下一次一定有可用槽位。大上下文请求不能路由给只支持小上下文的节点。

### 6.3 消息契约

以下字段是**拟新增设计**，现有代码尚未实现。所有请求类消息都带有长度受限的 `requestId`，所有错误带稳定 `code` 与供用户展示的 `message`。

| 消息 | 关键字段与行为 |
|---|---|
| `infer.request` | `version=2, clientInstanceId, agentRunId, requestId, modelId, modelRevision, promptFormat, prompt, maxOutputTokens, deadlineBudgetMs` |
| `infer.accepted` | `requestId, state=queued/preparing, source?`；代表接收，不代表完成 |
| `infer.status` | `requestId, state, elapsedMs`；排队 / 加载 / prefill 活跃状态，无正文 |
| `infer.delta` | `requestId, seq, text`；seq 从 1 递增，text 是增量而不是累计全文 |
| `infer.ack` | `requestId, ackSeq`；累计确认流片段，用于背压 |
| `infer.done` | `requestId, lastSeq, outputUtf8Bytes, outputSha256, finishReason, source, metrics?` |
| `infer.error` | `requestId, code, message, retryable`；不能带未经清洗的原生 / 文件内容 |
| `infer.cancel` | `requestId`；取消当前连接所属请求 |
| `infer.cancelled` | `requestId`；执行端已终止并清理，或排队任务已移除 |

`clientInstanceId` 是应用本次启动生成的随机 ID；`agentRunId` 是一次用户任务；`requestId` 是一次 `complete`。一个任务可以有多个 requestId。

请求示例：

```json
{
  "protocol": "nearby-chat-v1",
  "type": "infer.request",
  "version": 2,
  "clientInstanceId": "boot-7f...",
  "agentRunId": "run-5d...",
  "requestId": "req-91...",
  "modelId": "qwen25-7b-instruct-q4",
  "modelRevision": "locally-certified-revision",
  "promptFormat": "loop-react-split-v1",
  "prompt": "完整的本轮 Loop 提示词",
  "maxOutputTokens": 512,
  "deadlineBudgetMs": 180000
}
```

首版不开放客户端随意调 temperature、top_p、backend 等字段。沿用并记录 profile 中经验证的生成设置，避免看似统一、实际各节点参数不同。

### 6.4 提示词转换

为尽量保持 Loop 本地模型行为，定义并测试 `loop-react-split-v1`：按当前 `SessionBackedModel` 初始请求规则，以第一个 `\nUser task:\n` 分界，将前段按已验证的 developer / system 支持方式传入，后段作为 user 内容；没有分界时按当前兼容规则处理。

这需要使用真实 GEWU 模型验证角色支持，不能因为旧 ChatProtocol 只有 user / assistant 就擅自把 developer 丢掉。如果 profile 采用单 user 包装，必须是另一个明确的 promptFormat 并单独做工具质量回归。

转换只做一次；Agent 原有工具列表、技能、历史和本轮 scratchpad 不能漏掉。首版可以复用经过测试的纯函数拆分实现；后续再考虑由 runner 直接输出结构化消息。

### 6.5 终态与完整性

客户端只在以下条件全部满足时让 `complete` 成功：

1. 收到当前请求的 `infer.done`，且从 1 到 `lastSeq` 无缺失。
2. 拼接结果 UTF-8 字节数与哈希匹配；终态来自当前连接世代。
3. finishReason 为当前 profile 允许的正常完成原因，而非截断、取消或未知错误。
4. 本地运行未取消，输出非异常空值，未超过协商上限。

重复 seq 内容一致则忽略；内容冲突、越界或缺失则失败。`done/error/cancelled` 中只能有一个成为最终结论。取消与 done 竞争时，以客户端运行控制是否已取消为准：用户停止后不能再触发工具。

中心采用**执行节点原始输出哈希透传**，不得修改 text 后重写哈希掩盖传输错误。推理来源和编号另设元数据。

首版不做断线续传、结果重放或自动补执行。连接断开使在途请求失败，避免把不确定执行状态伪装为成功。

## 7. 传输、大小限制与超时

### 7.1 首版默认值

下列为建议起始配置，需由 Gate A / B 和压力测试校准；协商时取双方可接受的较小值。模型 profile 的实际能力优先于表中的目标值。

| 项目 | 首版建议 | 说明 |
|---|---:|---|
| 整条序列化 wire message | 保持 65536 字节硬上限 | 与现有分片上限一致，不直接全局放大 |
| 原始 prompt UTF-8 | 最多 32768 字节 | 仍须同时满足 JSON 报文与 token 预算 |
| 原生请求 JSON | 不超过 65536 字节 | 转换成 messages 后再检查，不能只查 wire payload |
| 单个 delta | 最多 1024 UTF-8 字节 | 按 Unicode 边界切割，不能拆坏代理对 |
| delta 合并 | 最多等待 50 ms，或达到 1024 字节 | 尽量减少每 token 一条消息 |
| 单请求聚合输出 | 最多 32768 UTF-8 字节 | 另受 maxOutputTokens 约束，越界失败并取消 |
| 输出 token | 默认选择 `min(512, profile上限)` | 当前旧版固定 256，需新增参数路径后才能生效 |
| 单 Loop 活跃 Agent | 1 | 先保证页面和文件操作状态可控 |
| 每算力执行槽 | 1，包含旧聊天 / 本机输入 / 新远程请求 | 避免新旧通道绕过准入同时抢原生资源 |
| 中心等待队列 | 总计 4 个，每客户端最多 1 个排队请求 | 超限明确返回 BUSY，不无限等待 |
| 单连接发送队列 | 最多 32 条且最多 128 KiB | 比当前 64 条后直接断链更早背压 |
| 单请求未消费原生输出缓冲 | 最多 128 KiB | 缓冲包含事件包装；不能无限增长 |

如正常 prompt 在转义后超过 wire 或 native JSON 上限，返回 `PAYLOAD_TOO_LARGE`，不切成多个不完整的模型请求。传输分片只负责还原一条消息，不等于拆分语义上下文。

### 7.2 发送队列与背压

现有 `sendData` 是发送调用，不是对端消费确认；原实现把一条消息的所有帧串行发送，且积压达到阈值会断连。接入长 prompt 与持续流后，需要增加有界队列。

具体策略：

1. delta 按上表合并；每跳最多保留 16 个未确认 seq，且未确认文本总量不超过 16 KiB。
2. 接收方每 4 个 seq 或 200 ms 发一次累计 ack，终态前立即确认最后一批。
3. 中心与执行节点、Loop 与中心分别管理窗口；中心只有下游缓冲有容量时才向上游继续释放信用。
4. 控制消息有独立小队列，cancel / error / ack 优先；长消息在分片边界允许控制帧插入，不能让取消一直排在长 prompt 后面。
5. 普通状态心跳允许合并成最新一条；正文 delta 不允许丢弃或覆盖。
6. 原生输出无法暂停且缓冲耗尽时，取消本次生成并返回 `BACKPRESSURE_OVERFLOW`，不继续撑满内存。
7. terminal 不能越过尚未送达的正文；除取消 / 错误明确丢弃残余结果外，先发送完整 delta，再发送 done。

分片交错必须保留现有单连接最多 8 个未完成消息的约束；首版实际只允许一条大数据消息与少量控制消息并行，不用“优先级”制造无限重组状态。

### 7.3 超时分层

| 超时 | 首版起始值 | 到时动作 |
|---|---:|---|
| 连接后能力协商 | 10 秒 | 标记不兼容或连接失败，不进入 READY |
| 请求发完后的 accepted 等待 | 10 秒 | 取消并失败，不能假定未执行而自动重发 |
| 排队等待 | 30 秒 | 中心移除排队任务，返回 QUEUE_TIMEOUT |
| 分片无进展 | 15 秒 | 丢弃该未完成消息并报告错误 |
| 单条分片消息绝对上限 | 60 秒 | 防止每隔几秒发一点永久占用内存 |
| 请求状态心跳 | 每 2 秒 | 排队、加载和 prefill 都可发送 |
| 请求无任何有效进展 / 心跳 | 15 秒 | 断定请求失联，启动取消 / 清理 |
| 一次推理硬上限 | 默认 180 秒 | 不因心跳无限延期；可按认证 profile 调整 |
| 单次 Agent 总时限 | 10 分钟且最多保留原有 10 步上限 | 任一先到则停止新调用 |
| 取消清理等待 | 10 秒 | 超时将执行节点隔离，不把占用槽当作已释放 |

现有分片 15 秒按创建时间计算；新的无进展与绝对上限需要显式修改，不是简单把常量加大。

每台设备用自己的单调时钟计时。`deadlineBudgetMs` 由中心按已消耗时长递减后下传，不跨设备比较墙上时钟；端到端客户端也独立保留自己的截止时间。

## 8. 上下文管理：保住能力，不静默丢数据

### 8.1 准入公式

模型侧最终准入必须满足：

```text
模板化输入 token 数 + 预留输出 token 数 + 已认证安全余量
    <= 当前模型 profile 的 maxContextTokens
```

优先使用与实际 tokenizer 和模板一致的 token 计数。当前代码没有可直接依赖的公开 token-count 接口，实施时要验证：能否复用模型 tokenizer 实现、厂商是否提供计数能力，以及模板的实际开销。

若短期只有保守估算，必须将 profile 标为 `certified-conservative`，限定经过验证的输入范围，并在模型拒绝时返回明确错误；不得声称“字节数合格就保证不超上下文”。未经验证的分词实现不是精确计数。

Loop 先做快速字节 / 历史预算预检；算力端用最终模板再次校验。中心按对应预算只选满足条件的节点；节点仍保留最后一道校验，防止能力变化。

### 8.2 提示词各部分的处理规则

| 内容 | 首版规则 |
|---|---|
| Agent 格式规则、工具权限和沙箱约束 | 必须保留，不能截断 |
| 当前用户任务 | 必须保留；过大时要求缩小输入 |
| 当前实际注册的工具说明 | 基线先完整保留；精简需另做质量回归 |
| 当前任务关键 scratchpad / 工具调用配对 | 不从中间截断，不丢未完成行动依据 |
| 历史对话 | 按完整 user / assistant 轮次从最旧开始移出模型上下文，UI 历史不删除 |
| 技能 | 维持现有加载语义；动态选择技能是后续优化，不偷偷只发一部分 |
| 大文件 / 大工具返回 | 在发送前明确检测超限；告知限制，不把静默截断当完整读取 |

所有裁剪记录结构化元数据，如 `historyTurnsOmitted`，界面可提示“较早对话未参与本次推理”。不得把中间工具记录剪掉后仍声称拥有完整上下文。

### 8.3 长文件的交付边界

512 KiB 的文件读取能力不能直接等价为 512 KiB 的模型分析能力。

首版必须做到：小文件端到端通过；超限文件明确拒绝 / 引导缩小，模型不能基于残缺正文假装总结全篇。

如果用户验收范围包含超过预算的文章，增加一个独立子任务：

- 工具支持按字节范围分页并安全处理 UTF-8，返回 `offset / nextOffset / eof / totalBytes`。
- 由确定性控制逻辑分段提取 / 总结，再做合并；每步使用同样远程推理与取消机制。
- 给出覆盖范围与未处理范围；避免只看第一段就结束。
- 当前 runner 内置“读取一篇后直接总结”的提示规则也要相应调整并回归。

这是工作流改造，不能在协议扩容中顺带宣称已经解决。交付前必须在验收报告中标明是否包含这一子任务。

## 9. MINIPC 侧：接入、调度与原生执行

### 9.1 从页面提取服务，不替换现有 UI

算力端新增 `InferenceGateway`，负责 v2 请求校验、排队、路由、转发映射、取消和终态。`pages/Index.ets` 只接入事件、展示任务，不继续增加大段协议与原生状态逻辑。

新增 `NativeInferenceService` 作为 v2 原生执行层。保留旧 `LocalChat.start` 语义和 v1 报文，通过共同的 `ComputeAdmission` 分配原生槽位。旧聊天请求也必须经过准入，否则“一台一槽”只是表面配置。

必须同时新增进程级 `NativeEventDispatcher`，作为 `probe.takeEvents()` 的唯一消费者，再按 nativeId 分发给旧聊天和新推理服务。当前原生 `takeEvents()` 会取出并清空整个全局事件队列；若两个服务各自轮询，会互相取走对方事件。只加业务服务、不统一事件消费是不完整的改造。

### 9.2 节点选择与混合版本

按以下顺序选择：

1. 节点连接有效、当前世代匹配、没有被清理超时隔离。
2. 已协商 inference v2，支持指定 promptFormat。
3. modelId、modelRevision 和模板一致，满足上下文 / 输出 / 负载预算。
4. 模型经过真实加载自检；不能仅凭文件存在就视为可执行。
5. 有空闲执行槽时沿用已有负载、内存等规则择优；无槽则进入有界公平队列。

多客户端按客户端轮转取队列，不能让一个客户端连续占满所有待执行名额。执行槽在 native destroy / end 确认后释放，而不是收到 finish_reason 时提前释放。

同一请求只路由一次。执行节点收到中心调度请求后必须本机执行，不能再次调度造成循环。只有通过握手认证为中心角色的链路可以发送内部调度标志；客户端伪造 `sched=true` 应拒绝。

首版不启用 run affinity：完整 prompt 使请求自包含，继续复用原负载策略即可。未来做会话缓存时，必须再加 Session 身份、版本、占用、驱逐、丢失重放和负载平衡设计。

### 9.3 请求身份与取消隔离

网关以 `连接所属可信设备 + clientInstanceId + requestId` 建立请求键，同时绑定当前 origin epoch。安装 UID 用于标识和展示，**不是认证凭据**；设备编号更不是授权身份。

中心转发到执行节点时创建独立 `forwardId`，保存：来源连接 / epoch、原 requestId、执行节点 / epoch、forwardId、截止时间、输出计数及终态标记。

内部转发仍使用 `infer.request`，将 `requestId` 替换为 forwardId，增加仅内部角色允许的 `sched=true` 和受限来源标签，完整保留 prompt、profile、promptFormat 与生成参数，并递减剩余时限。执行节点只接受当前已确认中心链路的内部请求。中心回传时恢复原 requestId；不能将 v2 重新打包为丢失参数的旧 `request(messages)`。

- 不同客户端使用相同 requestId，不得串流或互相取消。
- 只允许请求所属来源连接取消；重连的新 epoch 不能随便接管旧请求。
- 中心收到取消后移除队列项，或向正确执行节点发取消；执行节点按自己的 nativeId 取消。
- cancel 可能先于长请求重组完成：中心为当前来源和 requestId 保存有界取消墓碑，迟到的完整请求不得启动执行。
- 来源连接断开时，主动取消它所有转发与本地任务，不能只清理 UI 映射。
- 执行节点掉线时，相关请求失败；不能把已经输出一半的调用悄悄换节点继续。
- 完成请求保留有界终态墓碑，例如 256 项 / 5 分钟。重复投递不再次执行，只返回已终止状态；不恢复完整结果缓存。

禁止对单个请求调用无参数的全局 `probe.cancel()`，以免取消其他用户任务。原生 nativeId 只存在执行节点内，不能当作跨设备 ID。

### 9.4 原生桥改造

建议新增独立 `startInference` 导出，保留现有三参数 `start` 不变，降低旧聊天回归风险。新增导出接收本地服务已校验的请求与有限配置，不接受客户端直接透传的任意 attributes。

改造项：

1. 将 `max_ctx` 从固定 2048 改为本地认证 profile 的值；对范围和允许档位双重校验。
2. 将输出 token 从固定 256 改为经过校验的请求值；超过 profile 上限直接拒绝，不静默缩小；实际生效值返回元数据。
3. 原生请求序列化后再次检查 65536 字节边界、NUL、非法字段与模型路径白名单。
4. 统一解析 `message.content` 与已验证的顶层 `content` 形态；未知格式明确失败，不能丢 token 后继续。
5. 解析 finish_reason 后触发完成清理；必须等 native end / destroy 的结果，才能发成功终态并释放槽。
6. 增加原生执行 watchdog，不能无限等待条件变量；超时尝试 Abort，再执行合法生命周期清理。
7. 对回调、takeEvents 和输出缓冲设限；取消、错误、end 事件不能被普通响应挤掉。
8. 保留现有“整数任务 ID 查活跃任务”的迟到回调防护，避免销毁后的指针访问。
9. 默认日志只写 ID、阶段、错误码、耗时和大小，不写 request / response 正文。

如果厂商 Abort / Destroy 本身阻塞，应用层超时不能证明底层资源已释放。此时将节点标记不可接单，提示人工重启模型服务 / 应用；不能继续宣称 ready 并反复创建 Session。是否需要单独进程隔离，依据真机故障注入结果另定。

### 9.5 中心失效

复用 MINIPC 现有接管和重新发现机制；其接管条件包括至少 15 秒及多次成功扫描，不是严格的固定时长恢复保证，也不是通用分布式一致性协议。

首版语义：

- 旧中心连接断开，当前模型调用失败并停止 Agent。
- 新中心出现后 Loop 重新握手和能力协商；仅对新任务服务。
- 不自动重放旧 Agent，不把旧节点的迟到输出拼入新回答。
- 用户选择重试前展示已完成工具步骤，避免误以为前次操作完全没有发生。

## 10. 安全、权限与可观测性

### 10.1 权限与信任

Loop 按目标系统声明并运行时申请实际所需权限，参考现有 MINIPC 的分布式数据同步、蓝牙、位置及网络配置；逐项验证是否必需，不机械扩大权限。

保留可信设备筛选；BLE 广播、名称、slot、短 UID 都不能独立作为授权依据。Gate A 需要确认平台链路的可信身份保障；若无法证明，必须补配对授权和会话认证后才能传输真实文件内容。

发现结果与身份、能力消息均视为不可信输入：限制字符串、数组、数字范围、报文大小、排队数量；禁止非法角色发请求或取消他人任务。

工具返回内容也视为不可信数据，不能因来自文件或算力机而覆盖工具权限规则。远程接入本身不解决已有 Agent 的提示注入问题，敏感写操作仍需要本地权限与确认控制。

### 10.2 隐私与日志

默认不上传密钥、OAuth token、整个配置文件、无关文件、整个历史数据库。只传本轮推理需要的 prompt；发出前对已知密钥字段和认证头脱敏，但不能宣称自动脱敏能识别全部私人信息。

两端日志仅记录 requestId、运行阶段、模型版本、字节数、节点匿名标识、耗时和错误码；特别检查 native 文件日志与 hilog，不能只清理 ArkTS 日志。

正文调试仅在显式开发开关下短期开启，界面警告，限定保存时间和访问方式；验收材料使用虚构文件与测试凭据。默认不记录原始 prompt 哈希，避免低熵敏感文本被字典匹配。

### 10.3 指标定义

| 指标 | 采集位置 / 定义 |
|---|---|
| 客户端首片延迟 | Loop 开始发送请求到收到第一个有效 delta；包含排队、传输与加载 |
| 客户端模型调用耗时 | complete 开始到成功终态验证结束 |
| 排队 / Session 创建 / prefill / 生成 / 清理耗时 | 执行端各自单调时钟；只有实际能测到的阶段才上报 |
| 输入 / 输出 token | 真实计数可用才显示；未知为 null，不从字符数伪造 |
| 收发字节、重试、断线、取消清理耗时 | 通信与服务层 |
| Agent 总耗时、工具耗时、模型调用次数 | Loop runner |
| 来源 | modelId、revision、实际执行设备；中心不一定是执行设备 |

不能把“发现了三台设备”显示成“本次用了三台共同推理”，也不能把各节点时钟相减算网络耗时。现有只认 `SessionBackedModel` 的 UI 指标分支需抽象公共遥测接口。

## 11. 逐文件改造清单

以下新增文件名为建议落点，实施时可随仓库规范调整，但职责及测试不可省略。`L/` 代表 `D:\harmony`，`M/` 代表 `D:\MINIPC`。

### 11.1 Loop

| 文件 / 目录 | 动作 | 交付内容 |
|---|---|---|
| `L/agent_core/src/main/ets/model/RemoteComputeModel.ets` | 新增 | LocalModel 适配、完整结果校验、取消及遥测桥 |
| `L/agent_core/src/main/ets/model/LoopModelFactory.ets` | 修改 | 显式模式选择，严格远程，无静默 fallback |
| `L/agent_core/src/main/ets/model/LlmProvider.ets` | 修改 | 读取新模式配置，兼容旧配置默认行为 |
| `L/agent_core/src/main/ets/agent/AgentRunControl.ets` | 新增 | runGeneration、取消、截止时间与检查点 |
| `L/agent_core/src/main/ets/agent/ReActAgentRunner.ets` | 修改 | 运行控制、上下文预算入口、截断失败处理 |
| `L/agent_core/src/main/ets/compute/ComputeClient.ets` | 新增 | 无 UI 的推理客户端与请求生命周期 |
| `L/agent_core/src/main/ets/compute/ComputeTransport.ets` | 新增 | 平台无关接口；便于用 fake transport 测试 |
| `L/agent_core/src/main/ets/compute/InferenceProtocol.ets` | 新增 | v2 类型、字段校验、序列校验和错误码 |
| `L/entry/src/main/ets/compute/NearbyComputeTransport.ets` | 新增 | 适配 MINIPC 的发现、linkEnhance、分片和握手 |
| `L/entry/src/main/ets/compute/ComputeService.ets` | 新增 | 应用级服务实例和页面订阅 |
| `L/entry/src/main/ets/pages/Index.ets` | 修改 | 远程入口分流、状态、停止、错误、通用指标 |
| `L/entry/src/main/ets/entryability/EntryAbility.ets` | 修改 | 前后台生命周期和统一取消 |
| `L/entry/src/main/module.json5`、资源 strings | 修改 | 实际所需权限与说明 |
| `L/build-profile.json5`、模块构建配置 | 修改 | 独立远程产品 / 验证 SDK；不覆盖旧产品默认值 |
| 本地配置示例 | 修改 | 新 mode 字段，不提交真实凭据 |

平台相关近场实现放在 entry，agent_core 通过注入 `ComputeTransport` 使用它，避免让全部 AIPhone / HAR 调用方被迫依赖新的近场 API 和权限。

### 11.2 MINIPC

| 文件 / 目录 | 动作 | 交付内容 |
|---|---|---|
| `M/src/model-end/entry/src/main/ets/inference/InferenceGateway.ets` | 新增 | 请求准入、排队、转发、隔离、终态 |
| 同目录 `InferenceProtocol.ets` | 新增 | v2 校验与 Loop 对齐 |
| 同目录 `ComputeAdmission.ets` | 新增 | 所有入口共享执行槽、公平队列 |
| 同目录 `ModelProfiles.ets` | 新增 | 模型版本、认证参数、能力声明与预检 |
| `M/src/model-end/entry/src/main/ets/llm/NativeInferenceService.ets` | 新增 | v2 原生执行、输出规范化、清理与指标 |
| 同目录 `NativeEventDispatcher.ets` | 新增 | 唯一 takeEvents 消费者与 nativeId 分发 |
| 同目录 `LocalChat.ets` | 修改 | 接入统一准入及事件分发；保留旧接口行为 |
| `M/src/model-end/entry/src/main/ets/cluster/ComputeRouter.ets` | 修改 | 能力过滤、槽位、来源失联清理、forwardId 映射 |
| `M/src/model-end/entry/src/main/ets/pages/Index.ets` | 修改 | 新消息分流到服务，旧路径纳入共同准入 |
| 两端 `protocol/ChatProtocol.ets` | 修改 | 可选能力广告；新端扩展分派；旧请求限制不变 |
| 两端 `nearby/LinkEnhanceChannel.ets` | 按职责修改 | 白名单、协商、队列、控制优先、分片超时 |
| `M/src/model-end/entry/src/main/cpp/gewu_probe.cpp` | 修改 | startInference、受控参数、watchdog、日志和缓冲 |
| `M/src/model-end/entry/src/main/cpp/types/libgewu_probe/Index.d.ts` | 修改 | 同步新增原生导出声明 |
| `M/src/model-end/entry/src/main/cpp/tests/gewu_probe_lifecycle.cpp` | 扩展 | 超时、取消竞争、迟到回调、销毁失败等 |

MINIPC 原聊天端是兼容性对照，不把其 UI 搬到 Loop。它可以继续作为 v1 客户端；若共同修改底层传输实现，应同步协议测试，防止两份文件悄悄分叉。

### 11.3 协议同步与交付物

在 `L/contracts/compute-inference-v2/` 保存唯一协议说明、JSON 样本与 golden fixtures；实现分别放入两仓，测试对同一批样本进行编解码和拒绝校验。以版本及 fixture 哈希校验同步，不依赖开发机的绝对路径作为运行时依赖。

拟新增测试 / 工具脚本：

- `L/scripts/test-remote-compute.cjs`：Loop 远程模型、runner 取消、假传输测试统一入口。
- `L/scripts/verify-compute-contract.cjs`：比较两仓协议版本和 fixtures，报告不一致。
- `L/scripts/collect-compute-smoke.ps1`：按明确设备 ID 收集脱敏指标与版本信息，不抓取全部用户日志。
- MINIPC 各新服务对应 `*.test.cjs`，沿用现有 harness。
- `docs/loop-minipc-gate-report.md`：Gate A / B 结果和确定的 profile。
- `docs/loop-minipc-acceptance-report.md`：设备矩阵、用例、性能和已知限制。

这些是待实现交付物，当前除本设计文档外尚未创建。

## 12. 分阶段执行与退出条件

| 阶段 | 实施任务 | 阶段完成条件 | 失败时处理 |
|---|---|---|---|
| P0 基线冻结 | 记录两仓状态、设备、签名、模型版本；运行现有测试；备份可用安装包 | 可恢复的基线和无遗漏配置清单 | 先修复 / 记录基线问题，不混入接入缺陷 |
| P1 可行性闸门 | Gate A 跨应用链路；Gate B prompt、上下文及工具实验 | 两份证据报告均通过 | 停止主体开发，明确调整产品身份或模型范围 |
| P2 合同与假算力 | 协议、状态机、fake transport、确定性 Action 回放、取消测试 | 不依赖真实模型也能证明工具闭环和故障语义正确 | 修正协议 / 状态机，不用换模型掩盖问题 |
| P3 单算力闭环 | 新 native 接口、事件分发、单节点能力协商、远程模式 UI | Loop 无权重完成聊天和约定工具任务；失败不回落 | 分层定位传输、模板、模型、工具问题 |
| P4 集群与兼容 | 多节点过滤 / 调度、公平队列、新旧混用、中心接管 | 多客户端不串流；旧请求不回归；故障清理正确 | 先降为单节点验收，不宣称集群已完成 |
| P5 稳定化 | 压测、隐私检查、权限、后台、部署和回滚演练 | 第 14 节所有必须项通过，无阻断缺陷 | 保持测试状态，不按“能演示一次”发布 |

优先顺序不是“先做漂亮 UI”，而是“连得上 → 装得下 → 协议可靠 → 单机闭环 → 集群 → 交付”。

工作量只做条件估算：熟悉两个工程的开发者，在设备、签名和模型档位都可用的前提下，可按约 2–3 个工作周安排开发与真机回归；Gate A / B 若失败，原生 SDK 问题、模型适配或新增长文件工作流需另估，不承诺固定完成日期。

## 13. 构建、部署与首次联调手册

### 13.1 准备清单

- 第一轮至少两台手机：A 运行 Loop，B 运行 MINIPC 算力端。
- 集群验收增加算力手机 C；多客户端隔离验收再增加 Loop 手机 D。可以按阶段借用设备，但相应用例必须真机完成。
- 每台登记：设备 ID、型号、系统 API、签名许可、蓝牙及可信状态、模型版本、模型文件校验摘要、可用内存。
- B / C 部署认证过的完整权重和 tokenizer，路径为各应用 `filesDir/models/Qwen2.5-7B-Instruct-Q4_N_0`，不是 Loop 旧配置中的 `files/model/...`。
- A 不部署权重作为必测场景；没有本地权重不等于安装包自动没有 native `.so`。
- 使用测试文件、测试外部账号；外部工具仍需要对应网络和凭据，远程模型不会替它们提供外网能力。

### 13.2 SDK 与应用安装注意事项

当前 Loop 产品为 target API 21 / compatible API 17；MINIPC 为 target API 23 / compatible API 22。首版远程产品按 MINIPC 当前支持矩阵验证，优先 API 22 / 23 真机。不要在未知设备上宣称旧 API 17 仍支持完整近场功能。

为 Loop 新增独立远程产品配置，保留旧 default。`agent_core` 平台无关接口不强行提高所有消费方最低版本；entry 的远程产品使用实测匹配的 SDK。

MINIPC 聊天端与算力端包名相同，在同一设备上安装不同角色构建可能覆盖应用，而不是并排共存。部署前确认设备角色，不以卸载旧应用作为默认步骤。

签名证书、私钥、密码、真实 provider 配置不得写进本文件、提交到仓库或放进日志。改包名 / 签名可能影响沙箱和升级，必须单独确认，不作为自动修复办法。

### 13.3 本机命令基线

以下 PowerShell 命令基于本机已发现的工具路径。当前即可执行的是测试 / 旧产品构建；Loop 的 `remote` 产品需完成上述新增配置后才能构建。实际实施时先检查路径和依赖状态。

```powershell
# 1. 查看设备；后续每条 hdc 命令都明确 -t，避免发到错误设备。
$hdcExe = 'C:\Users\1\tools\hdc\hdc.exe'
& $hdcExe list targets

# 2. 运行 MINIPC 现有及后续新增的 cjs 测试。
$nodeExe = 'C:\Users\1\.cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe'
$testFiles = rg --files D:\MINIPC\src -g '*.test.cjs'
$failedFiles = @()
foreach ($testFile in $testFiles) {
  & $nodeExe $testFile
  if ($LASTEXITCODE -ne 0) { $failedFiles += $testFile }
}
if ($failedFiles.Count -gt 0) { throw ('测试失败: ' + ($failedFiles -join ', ')) }

# 3. 配置已存在的 JDK / SDK，构建算力端。
$env:JAVA_HOME = 'D:\MINIPC\tools\jdk\jdk-17.0.20.1+1'
$env:DEVECO_SDK_HOME = 'D:\command-line-tools\sdk'
$hvigorExe = 'D:\command-line-tools\hvigor\bin\hvigorw.bat'
Push-Location D:\MINIPC\src\model-end
try {
  & $hvigorExe --mode module -p module=entry@default -p product=default assembleHap --no-daemon
  if ($LASTEXITCODE -ne 0) { throw '算力端构建失败' }
} finally { Pop-Location }

# 4. 在 remote 产品及其 entry target 完成配置后构建 Loop。
Push-Location D:\harmony
try {
  & $hvigorExe --mode module -p module=entry@default -p product=remote assembleHap --no-daemon
  if ($LASTEXITCODE -ne 0) { throw 'Loop 远程产品构建失败' }
} finally { Pop-Location }
```

依赖未同步时，先使用 DevEco 对相应工程执行 Sync and Refresh，并按本地工程规范处理 ohpm；不要为了消除构建错误把 SDK 自带的 hvigor 随意写进业务依赖。

安装前从构建产物目录确认唯一的已签名 HAP、包名、版本和哈希，再使用 DevEco 或 `hdc -t <明确设备ID> install -r <已核实HAP绝对路径>` 更新。此处故意不填写猜测的设备 ID 和产物文件名。

模型文件通过当前设备支持的合法调试部署流程放入**算力应用自己的 filesDir**；先确认目标应用和目录可写。不要假设任意设备都允许直接写 `/data/app/...`，也不要用广域删除命令清理模型。

### 13.4 启动顺序与首次闭环

1. 只启动 B 算力端，授权，等待中心角色与真实模型自检完成。
2. 启动 A 的 Loop 远程产品，选择 `remote_required`；确认旧协同未启动。
3. 查看协商结果：v2、modelId/revision、上下文预算、算力来源。
4. 先发“请只回复 OK”，确认得到成功终态，Loop 本地 CreateSession / Submit 计数为零。
5. 使用固定测试文件跑列表 → 读取 → 总结；检查文件读取发生在 A，模型执行发生在 B。
6. 生成中停止，确认 UI 立即停止接纳输出、B 最终清理并能执行下一任务。
7. 断开 B，A 应提示无算力；不能出现本地 / 云模型回答。
8. 恢复 B，重新发现并执行一个新任务；不续接前次半截回答。
9. 加入 C，确认兼容 profile 和角色后，使用两个客户端验证调度；不要以单个串行任务“没同时用两台”判定失败。

### 13.5 回滚

- 部署前保存两仓基线提交、未提交改动列表、原签名 HAP、配置备份和模型版本摘要；不把私钥打进普通备份包。
- 功能开关关闭新入口，人工切回已验收旧模式；明确提示这会改变计算位置。
- 算力端使用兼容性经过验证的旧 HAP 更新回滚；若系统不支持保留数据降级，先停止并决定数据迁移方式，不直接卸载。
- 不删除模型、聊天历史、技能或工作空间；回滚不能靠 `git reset --hard`、批量卸载或清空沙箱。
- 保留脱敏故障指标定位问题，不长期保留敏感 prompt 正文。

## 14. 测试矩阵与发布门槛

测试分三层，不能相互替代：纯逻辑自动化、SDK 编译 / 原生测试、真实设备联调。AI 回答具有不确定性，因此协议正确性用确定性假模型验证，模型任务效果另用固定语料重复测量。

### 14.1 必须通过的自动化用例

| 类别 | 必测内容 | 期望 |
|---|---|---|
| 协商 | 新新、新旧、旧新、不支持版本、非法能力字段 | 未协商不发送 infer；旧请求行为不变 |
| 字段与边界 | 空 ID、超长 ID、负数 / NaN、未知角色、非法枚举、过大数组 | 启动原生前拒绝 |
| 消息大小 | ASCII、中文、表情、换行、引号、反斜杠、恰好上限及上限+1 | 按实际 UTF-8 / JSON 计量，无截断 |
| 分片 | 乱序、重复、冲突、缺片、多消息交错、空闲 / 绝对超时 | 正确重组或明确失败，不污染下一请求 |
| 流完整性 | 重复 seq、冲突 seq、缺失 seq、错误哈希、done 先到 | 只有完整且一致的流可 resolve |
| 模型接口 | prompt 全量发送、历史不重复、技能不缺失、来源不混入正文 | 与约定 promptFormat 一致 |
| 工具闭环 | 假模型依次返回列表、读取、Final；一次写入后模型断线 | 本地工具按次序执行；写入不自动重做 |
| 输出截断 | 半截 Action、合法 Action 后仍以 length 结束、空输出 | 不执行该轮工具，报告模型输出失败 |
| 取消 | 发送前、分片途中、排队、CreateSession 中、生成中、工具中、done 竞争 | 本地只落一个终态，不再触发后续工具 |
| 隔离 | 两客户端相同 requestId；旧 epoch 回调；重连后复用 ID | 不串流、不跨用户取消 |
| 超时 | 无 accepted、prefill 无 delta 但有 status、硬时限、取消清理超时 | 活跃状态不误判；硬上限不可被心跳绕过 |
| 背压 | 慢消费者、ack 丢失、native 超速、控制消息优先 | 内存有界；取消不饿死；不静默丢正文 |
| 准入 | 旧聊天 / 本机 / v2 同时请求，队列满，异构上下文 | 共享槽位；不超卖；只选兼容节点 |
| 原生事件 | v1 与 v2 同时订阅、迟到响应、未知 nativeId | 只有单一事件消费者，无误吞事件 |
| 生命周期 | clear、页面退出、应用后台、服务停用 | 清理请求、订阅、定时器和链路 |
| 日志 | prompt 含测试密钥与标记文本，检查 ArkTS / native / hilog | 默认日志找不到正文及测试密钥 |
| 远程严格性 | 算力不可达、权重缺失、协议旧、模型失败 | 不调用 Loop native / 云模型 / 脚本 fallback |

协议字段具体约束在 P2 固化到 schema 与 fixtures：ID 使用受限 ASCII、长度不超过 128；模型 / 模板标识不超过 128；错误展示文本不超过 1024 UTF-8 字节；能力 profile 列表最多 16 项；版本列表最多 4 项；seq / token / 时间均为范围内的有限整数。各条消息只接受所属字段，内部路由字段不暴露给普通聊天角色。

### 14.2 真机用例

| 编号 | 场景 | 验收条件 |
|---|---|---|
| D01 | A 无模型权重，B 有模型 | A 正常完成任务；A native 创建 / 提交计数为零 |
| D02 | 单轮聊天与 10 轮连续对话 | 历史按预算使用；无重复注入；裁剪有记录 |
| D03 | 列表 → 读取 → 总结 | 所述内容来自测试文件；不虚构读取结果 |
| D04 | 受控文件写入后再读取 | 写入在 A 沙箱，内容符合任务，无重复副作用 |
| D05 | 技能及实际启用的 Composio / ModelScope 工具 | 配置有效时正常调用；未配置 / 无外网时如实报错 |
| D06 | 超大文件、超长任务、工具结果超预算 | 明确限制，不静默截断后冒充完成 |
| D07 | 连续 20 次取消，覆盖不同执行阶段 | 下一次任务均可启动；无迟到工具调用；清理失败则隔离 |
| D08 | 20 次发现 / 连接 / 断开循环 | 无重复订阅、串流或不可恢复的 busy |
| D09 | 切后台、锁屏、返回前台 | 按保守取消策略工作，重新就绪后只接新任务 |
| D10 | 两客户端、两算力，各连续提交任务 | 任务归属正确；两兼容节点可被选中；队列公平 |
| D11 | 一个算力节点模型缺失 / 上下文较小 / 版本旧 | 被正确排除，不拖垮其他兼容节点 |
| D12 | 执行节点断电 / 掉线 | 相关请求失败且 Agent 停止，其他任务隔离 |
| D13 | 中心停用，新中心接管 | 旧任务失败可见；新连接完成协商后能执行新任务 |
| D14 | 旧 MINIPC 聊天端连接新算力端 | 旧聊天、取消及页面行为无阻断回归 |
| D15 | 低内存、热降频、慢链路持续 30 分钟 | 无无界内存增长、死锁、持续泄漏或正文丢失 |
| D16 | 权限拒绝 / 撤销、蓝牙关闭、不可信设备 | 错误可理解，无绕过安全边界，无隐式本地回落 |

D05 应采用测试账号与允许的操作；未配置某工具不能记为“通过”，应标记“不适用 / 未验证”，并在交付范围中明确。

### 14.3 可量化发布标准

必须满足：

- 现有 12 个 MINIPC 测试文件继续通过，新增协议 / 状态机 / 路由测试全部通过。
- 目标产品 ArkTS 编译、HAP 签名和原生生命周期测试通过；不能用 JS 转译测试代替真实 SDK 编译。
- Gate A / B 与 D01–D16 的适用必须项通过，无 P0 / P1 阻断缺陷。
- 确定性假模型的端到端测试连续 100 次无串流、无重复工具执行、无终态冲突。
- 选择至少 10 个实际任务，每项运行 5 次，分别记录模型格式合格率、工具正确率、任务完成率和失败原因；总体任务完成率建议不低于 90%，且任何安全性违规均阻断发布。未达到时调整模型 / prompt / 范围，不降低协议标准来“通过”。
- 取消后的 Loop UI 在 1 秒内进入已停止状态；远端资源在配置清理期限内释放，否则节点被隔离且界面明确提示。
- 在无故障基准样本中收集至少 30 次调用的首片和总耗时 P50 / P95，记录输入规模、冷启动 / 热状态、执行节点和设备温度。P1 后与用户确定性能预算，未确定前不承诺毫秒级或固定倍数加速。
- 默认日志不包含测试正文、OAuth token 或 API key；远程模式失败时本地 / 云 fallback 调用计数为零。

其中 90% 是拟定的模型质量发布目标，不是现有实测成绩，也不是对所有自然语言任务的保证。

## 15. 错误码与用户恢复指引

| 错误码 | 用户提示方向 | 自动处理 |
|---|---|---|
| `NO_COMPUTE` | 尚未发现可用算力设备 | 空闲时按既有有限重连节奏重试发现 |
| `PROTOCOL_UNSUPPORTED` | 请升级算力端到支持该协议的版本 | 不发送旧格式大 prompt |
| `MODEL_UNAVAILABLE` | 模型未部署、未通过自检或没有兼容节点 | 刷新能力，不切到别的模型冒充同一模型 |
| `PAYLOAD_TOO_LARGE` | 本轮输入超过传输限制 | 要求缩小任务 / 启用已验收的分段工作流 |
| `CONTEXT_TOO_LARGE` | 当前模型上下文不足 | 完整轮次裁剪后仍不足则停止，不裁掉安全规则 |
| `BUSY` / `QUEUE_TIMEOUT` | 算力繁忙，请稍后重试 | 不无限排队，不自动重跑 Agent |
| `REQUEST_TIMEOUT` / `CONNECTION_LOST` | 本轮推理中断，部分工具操作可能已完成 | 取消当前请求，等待用户决定是否新建重试 |
| `MODEL_OUTPUT_TRUNCATED` | 回复未完整生成，未执行本轮新工具操作 | 不解析半截 Action；可让用户选择重试 |
| `MODEL_EXECUTION_FAILED` | 模型加载、提交或清理失败 | 报告阶段，必要时隔离节点 |
| `BACKPRESSURE_OVERFLOW` / `STREAM_CORRUPTED` | 链路无法完整交付结果 | 取消并清理，不返回部分成功 |
| `CANCELLED` | 已停止；已开始的外部操作未必可撤销 | 不继续下一轮，不默认再执行 |

“可重试”仅表达未来新请求可能成功，不授权自动重发。首版不自动重试模型调用，更不自动重跑整个 Agent；底层单帧的有限重传仍由带去重的传输层处理。

## 16. 风险清单与最后的决策

| 风险 | 优先级 | 控制措施 |
|---|---|---|
| 不同应用身份下近场链路受限 | 阻断 | Gate A 真机验证后再推进 |
| 2048 上下文无法装下实际工具任务 | 阻断 | Gate B 认证 profile；不拿传输扩容替代模型适配 |
| 小模型能聊天但不能稳定输出工具格式 | 阻断 | 假模型验证基础设施，真实语料单独评估模型能力 |
| 取消 / 重连导致旧结果触发新工具 | 高 | epoch、runGeneration、一次性终态与检查点 |
| 工具已产生副作用后任务重试 | 高 | 禁止自动重放；显式展示已执行步骤 |
| v1 / v2 多入口竞争 native 事件及资源 | 高 | 单一事件消费、共享准入和 nativeId 隔离 |
| 长 prompt、流式 token 导致队列溢出 | 高 | 字节上限、合并、ack 窗口、控制优先和压力测试 |
| 文件内容 / 凭据进入算力日志 | 高 | native 与 ArkTS 默认去正文；真实数据传输前通过隐私验收 |
| 原生 Abort / Destroy 卡死 | 高 | watchdog、节点隔离、故障上报；必要时后续进程隔离 |
| SDK / 产品身份变化影响旧用户安装 | 高 | 独立产品、保留旧配置、按设备明确部署 |
| 中心失效被误认为无损容灾 | 中 | 明确只恢复新任务，不续接旧生成 |
| 多设备没有缩短单任务耗时 | 中 | 分开衡量吞吐与延迟；不承诺单任务加速 |

### 16.1 实施前默认采用的选择

为了避免进入实现后反复变更，建议按以下默认值启动，无需先扩大范围：

1. 先做 Loop entry，不改 ApplessPhone / AIPhone 产品界面。
2. 先一台 Loop + 一台算力，通过后再扩展集群。
3. 首版无状态完整上下文、严格远程、单 Agent、单节点一执行槽。
4. 默认进入后台取消，不做后台常驻与断线续传。
5. 先以文本及上下文内的文件任务验收；长文件分段单独列项。
6. 模型 / 上下文档位以 Gate B 实测确定，不预先硬设为 8192。
7. 权限、包名、签名或通信技术需要路线调整时，先拿证据再确认。

### 16.2 何时可以说“完成”

只有当 **Loop 手机不需要权重、不运行本地模型，却能通过 MINIPC 完成聊天和约定工具闭环；遇到取消、断线、忙碌、上下文不足时行为可预测；集群和旧版本通过对应回归**，才能把此项标记为交付完成。

最终交付包必须包含：两仓代码与版本、可安装签名产物的校验摘要、认证模型 profile、Gate 报告、测试 / 性能 / 隐私报告、部署和回滚步骤、明确的未支持事项。所有私钥、真实密钥和模型权重按原有安全方式分发，不混入公开文档。

**现在最值得做的下一步是 P0 / P1 验证原型，而不是一次性重写两仓。两道闸门通过后，本方案可按阶段直接转为开发任务和验收清单。**

## 附录：主要代码入口

- [Loop 模型接口](D:/harmony/agent_core/src/main/ets/model/LocalModel.ets)
- [Loop Agent 执行器](D:/harmony/agent_core/src/main/ets/agent/ReActAgentRunner.ets)
- [Loop 本地模型适配](D:/harmony/agent_core/src/main/ets/model/SessionBackedModel.ets)
- [Loop entry 页面](D:/harmony/entry/src/main/ets/pages/Index.ets)
- [MINIPC 当前协议](D:/MINIPC/src/model-end/entry/src/main/ets/protocol/ChatProtocol.ets)
- [MINIPC 近场链路](D:/MINIPC/src/model-end/entry/src/main/ets/nearby/LinkEnhanceChannel.ets)
- [MINIPC 调度器](D:/MINIPC/src/model-end/entry/src/main/ets/cluster/ComputeRouter.ets)
- [MINIPC 原生推理桥](D:/MINIPC/src/model-end/entry/src/main/cpp/gewu_probe.cpp)
