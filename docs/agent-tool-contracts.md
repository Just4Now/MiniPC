# 工具契约

工具实现位于 [agent_core](../loop-chat/agent_core/src/main/ets)。公共执行器按契约和实际调用状态推进，领域参数处理由工具提供方负责。

## 注册接口

`AgentTool` 提供 `name()`、`description()`、`run(input, context)`，可提供 `contract()` 和 `cancel(context)`。注册使用：

```typescript
registry.register(tool, policy, contract);
```

policy 是 `ToolExecutionPolicy`，含 readOnly、supportsParallel、cacheable、risk、可选 timeoutMs。权限由注册方提供，模型、描述文本和工具输出不能自行授予。

## 输入与输出

`ToolContract` 声明 version、inputFormat（json/text/none）、inputSchema、outputSchema，并可声明证据字段及输入准备/答案校验函数。支持的 schema 子集包括基本类型、required、properties、additionalProperties、items、enum、长度/数值/数组边界与 anyOf；不等同完整 JSON Schema 实现，不支持的声明会被拒绝。

`prepareInput` 接收实际原始任务和只读需求视图，适合保留请求约束。`recognize`、`matches` 负责领域需求与调用的关联；这些接口不提供通用自然语言理解保证。

工具可返回字符串，或类型化 `ToolResult`：

| 字段 | 含义 |
| --- | --- |
| callId | 注册表绑定的调用标识 |
| status | success、failed、empty、unavailable |
| raw / displayText | 原始结果与面向模型/界面的展示 |
| data | 用于输出 schema 和声明事实校验的结构化值 |
| returned | 是否真实返回了工具结果 |
| stop | 是否必须停止后续推进 |

类型化 status 为权威状态，不从正文中的 error 等单词猜测。旧字符串工具通过提供方的 legacyStatus/legacyData 适配。结果与调用按 ID 关联，不能用最新 Action 代替实际来源。

## 并行与缓存

- 执行器只对声明为只读、低风险且 supportsParallel 的同批调用使用并行。
- 缓存还要求 cacheable；缓存键按输入格式规范化，只缓存成功结果。
- 共享注册表会将可能改变状态的调用串行化，等待期间取消的调用不执行。
- 未声明策略按保守权限处理；非安全只读调用会使读缓存失效。

## 生命周期与校验

注册表默认工具超时为 60 秒，可由可信策略设置 timeoutMs。取消先收敛本地等待，提供方取消为尽力执行；迟到回调不覆盖新调用。close 会取消活动调用并清理资源。

输出 schema、状态与声明事实持续校验。answerValidation 明确区分 strict 与 heuristic；成功结果经过最终综合后可以放宽声明为 heuristic 的措辞检查，不放宽严格事实或调用身份。

新工具应提供真实输入/输出契约及可信策略，并加入注册表。测试入口和运行边界见 [测试](testing.md)。
