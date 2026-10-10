# Agent 契约重构与回归记录

更新日期：2026-09-30

后续真机修复与安装验证见 [算力完成、Agent 报失败：设备回归记录](../docs/agent-result-regression-2026-09-30.md)。下面的 109 项测试与“未安装设备”描述仅对应此前契约重构轮次。

## 当前状态与验证边界

本文件替代此前逐轮追加、互相矛盾的修复说明，以当前源码和本次实际执行的测试为准。

**本轮结果：6 组离线运行测试全部通过（48 + 7 + 20 + 11 + 14 + 9 = 109 项测试执行），3 组严格 TypeScript noEmit 检查零错误。测试之间有重叠，不代表 109 个互不重复的需求。**

运行测试使用实际 ETS 源码经本地 TypeScript 4.9.5 转译，并模拟平台、网络和模型边界。页面测试提取并执行实际 Index 生命周期方法，不编译 ArkUI 渲染 DSL。这些检查不能替代完整 ArkTS/Hvigor 构建、真实 HTTP 服务、native 推理或双设备回归。

本次收尾没有构建、签名或安装新 HAP，也没有验证最新设备问答。此前“SDK 无效”是错误的笼统结论：已发现本地 SDK/Hvigor/JDK 和历史 HAP，历史构建存在签名材料问题；不能由此断定当前工作区已通过全工程构建。

## 问题与实际解决方案

### 工具返回被错误归属或误判

**问题**：工具返回纯文本；控制器扫描正文中的 error/not found 等词判断成功失败。LoopBackend 以一个 lastAction 关联所有结果，同一轮多个串行或并行调用会串结果。

**解决方案**：

- `AgentTool.ets` 定义 `ToolResult`：callId、status、raw、displayText，以及可选 returned、stop、finalText。
- `ToolRegistry.run` 是兼容边界：旧字符串工具仍可使用，但只按已知工具的错误信封/前缀解析状态，不扫描成功文件正文。
- 注册端生成可信 callId/metadata，不使用工具结果自行声明的权限作为执行策略。
- `AgentEvent` 携带可选 callId、toolName、input、status，保持两参数构造兼容。
- `LoopBackend` 根据 callId 关联 Action、Observation 和工具异常；无 ID 的旧事件采用 FIFO，而不是 lastAction。未知 ID 不会消费其他调用。
- Runner 用 raw 进行事实校验，用 displayText 展示；账本回退报告保留展示文本，不泄漏原始诊断 JSONL。
- A2UI 在 Registry 边界投影为 digest；成功卡片不自动代表整个用户任务完成，阻断/授权等停止结果仍停止调度。

### 缓存吞掉写入、写后读返回旧数据、写操作并行

**问题**：所有工具统一缓存。写 A、写 B、再写 A 时第三次可能被跳过；读取旧内容、写新内容、再次读取时得到旧缓存。工具名黑名单也无法阻止并行写入。

**解决方案**：

- Registry 声明 readOnly、supportsParallel、cacheable、risk；未知工具采用保守默认值。
- Runner 只有在整组工具明确为只读、低风险、允许并行时才使用 Promise.all。
- 只有明确可缓存的低风险只读工具共享进行中请求和成功缓存；写入/未知副作用工具不缓存。
- 非缓存安全操作前后清空读取缓存，包括失败路径，防止部分写入后继续读取旧结果。
- 缓存命中仍给当前调用生成独立 callId，并重新关联结果。

### 停止、断连和页面退出后的旧请求继续运行

**问题**：reset 清理了协商计时器却没有结束旧 Promise；准备阶段点击停止后继续创建 Runner；工具 await 结束后可能仍发 FINAL；页面退出后旧回调提交历史。

**解决方案**：

- `InferenceClient.reset/cancelActive` 结束原协商/推理等待；取消传输失败也不会让本地 Promise 悬挂；过期请求 ID 的响应被忽略。
- 保留兼容但未就绪的算力 profile 的 readinessReason，不再统一误报“版本不支持”。
- `LocalModel` 增加可选 cancel，RemoteComputeModel 转发取消；Runner 停止时调用该能力并在模型/工具 await 后检查停止状态。
- `Index` 用 pageActive 和 remoteRunGeneration 界定运行归属。readiness、协商、Skill 和 Registry await 后检查代际；回调和 finally 也检查归属。
- 停止立即失效旧代际、清理监听/占位符；退出页面先停止 Runner，再断连和关闭资源。旧 finally 不会清除新运行的监听或提交旧答案。
- 正常 Final 只提交一次气泡，历史只持久化一次。原始模型 token 不作为正式回答展示。

停止不等于回滚：已经发生的文件写入、外部副作用不能被撤销；没有取消 API 的工具可能继续完成，但不能再污染已停止的界面。

### 工具有结果但账本仍显示未完成

**问题**：工具接受 query/prompt 别名和标点，而账本只接受 query；北京市/北京比较不对称；“明天”与等价 ISO 日期按文字比较。天气和空气结果也可能相互串证据。

**解决方案**：

- 显式 `TaskRequirement` 按工具、实体、日期登记结果，调用 ID 防止不同调用串线。
- 支持工具已接受的 query/prompt 别名、句末标点、城市“市”后缀双向等价。
- 每次创建账本保存自己的时间锚点；比较时把相对日期转换为该次运行的日历日期，展示仍保留用户的“今天/明天”等原词。移除模块加载时固定日期，避免隔夜失效。
- 不再使用整条任务的全局槽位改写工具参数，保留实际调用的 query/context。
- failed、empty、unavailable 是真实终态，不因无法得到成功结果而无限重试。

账本是保守的显式中文需求识别器，不是任意语言的完整任务规划器。无法明确识别的需求仍由模型处理，不能承诺消除所有复杂请求漏答。

### Final 数值误匹配、综合建议覆盖不足

**问题**：0°C 可以作为 20°C 的子串误通过；混合天气/AQI 回答把每个数值拿去与所有工具比较；只有北京的穿衣建议可能满足上海的要求。

**解决方案**：

- 数值按工具类别提取完整 token 后比较，不用子串匹配；温度、AQI/PM2.5、车次分别校验。
- 实体和日期覆盖先于综合建议判断，不允许“建议/适合”等词绕过缺失城市检查。
- 成功且覆盖符合检查的模型 Final 保留，包括穿衣等解释；只有校验失败且修复次数耗尽时使用诚实的账本回退。
- 未完成项必须明确标为未完成，不能用 Control 文本、之前的对话或模型伪造的 Observation 填充证据。

当前校验仍是文本启发式，不是形式化事实证明；复杂排版、别名、单位表达仍需要进一步契约测试。

### Action 协议与 Prompt 预算

- 全部 Action 先解析再执行：任一 malformed/unknown Action 使整组不执行。支持合法 JSON、多行、括号、注册 dotted 名称及既有 `read[skill-name]` 协议。
- 不把损坏参数改成空对象，不接受混合 Action/Final，不因字符串里的括号错误截断 JSON。
- 控制器反馈使用 Control；仅真实返回工具数据生成 Observation，派发异常生成关联错误事件。
- Prompt 按完整历史/工具回合分组裁剪，保留完整工具契约、当前任务、最新完整工具回合和后续控制信息；必要材料本身超限时明确失败，不硬切 UTF-8、JSON 或工具协议。
- Index 将协商预算回调交给 Runner；客户端再次按 `min(32768, profile.maxPromptBytes)` 校验。超限不会静默发送缺失任务的输入。

## 其他保留的实现

- 本地计算器、日期计算、单位换算、文件搜索已注册。
- 文件搜索隔离坏文件，限制深度 8、条目 500、单文件 256 KiB、总读取 4 MiB、结果 20，并报告不完整结果；不跟随观察到的符号链接。
- Session/OpenAI 响应解析处理完整性、错误和结束原因。原生 tool_calls 不属于当前文本 ReAct 合同，明确拒绝，不静默丢弃。
- ModelScope 校验 URL；工具名字映射避免长名称截断碰撞。
- 工作区已有算力端输出上限和 native stall/abort 修改；本轮离线测试不证明这些已在设备生效。

## 本次实际执行的验证

在仓库根目录运行，以下命令本次均成功：

| 命令 | 结果 | 范围 |
|---|---|---|
| `node loop-chat/agent_core/tests/react-runner.test.cjs` | 48/48 | 实际 ETS 核心、模拟模型/工具依赖 |
| `node loop-chat/agent_core/tests/inference-budget.test.cjs` | 7/7 | 协商预算与发送前校验 |
| `node loop-chat/agent_core/tests/support-models.test.cjs` | 20/20 | SSE/native/ModelScope/本地工具离线契约 |
| `node loop-chat/agent_core/tests/integration-contract.test.cjs` | 11/11 | 调用关联、策略、reset/cancel |
| `node loop-chat/agent_core/tests/integration-lifecycle.test.cjs` | 14/14 | 生命周期、A2UI 投影和错误 trace |
| `node loop-chat/agent_core/tests/index-lifecycle.test.cjs` | 9/9 | 实际页面方法；不包含 ArkUI DSL |
| `node loop-chat/agent_core/tests/react-core.typecheck.cjs` | 零错误 | 7 个实际 ETS 文件，Registry/Skill/平台声明桩 |
| `node loop-chat/agent_core/tests/support-models.typecheck.cjs` | 零错误，2 个 TS28040 警告 | 11 个实际 ETS 文件，真实安装 SDK 声明 |
| `node loop-chat/agent_core/tests/integration-contract.typecheck.cjs` | 零错误 | 5 个实际 ETS 文件与 wire 声明，平台桩 |
| `git diff --check` | 通过 | 空白检查，不等于编译或功能验证 |

两条 SDK 警告位于 SandboxWorkspace.mkdirSync 和 ModelScopeDirectClient HTTP 请求异常传播。

## 仍未完成的验证与迁移

1. 本次未完成全工程 ArkTS/Hvigor 构建、签名、HAP 安装、真实双设备问答和线上接口回归；不要把离线通过称作设备问题已复现并解决。
2. 部分旧工具仍返回字符串，由工具限定的兼容层识别已知错误前缀；并非所有 Provider 都已原生返回结构化状态。
3. 通用 JSON Schema 校验、所有模型后端的主动取消、统一 CompletionResult、Host 发送确认/错误状态机和完整 Gateway 拆分尚未全部迁移。
4. callId 当前用于运行内关联；全链路稳定 runId/stepId、算力卡片输入/输出明确分区、版本指纹仍需后续工作。
5. 地图使用的是地点文本搜索，不能把它描述成已实现精确“附近半径搜索/最近距离排序”；高德 Key、公共接口可达性等实际条件不由本地模拟测试保证。
6. 账本的日期等价匹配不等于天气 Provider 已支持任意 ISO 日期；Provider 的日期支持范围需单独验证。
7. 没有清理用户原有改动、提交或推送 Git，也没有重装设备应用。

## 已废弃的修复说法

以下旧策略已被替代，不应再作为当前说明：

- 任意工具都缓存、所有合法兄弟 Action 可以部分执行；
- 在 Observation 中注入“你还没有完成全部查询”等控制提示；
- 用全局城市/日期改写每个工具输入；
- 直接截断整个 prompt 到 30000 bytes；
- 只增加少量英文结束原因就断言已修复所有算力失败；
- 仅凭 git diff --check 宣布功能或设备修复通过；
- 认为旧的 31/31 或迁移中的 26/31、38/41 测试报告代表当前源码结果。
