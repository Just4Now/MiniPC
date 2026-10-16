# Agent 执行流程

## 当前调用链

```text
apps/agent-client / Index
  → ParallelTaskRunner（满足拆分条件时）或 ReActAgentRunner
  → RemoteComputeModel / InferenceClient
  → 近场算力中心 / InferenceRelay
  → InferenceHost / LocalChat / GEWU
```

模型决定任务如何处理及答复内容，聊天端执行注册工具、记录实际结果并发布最终答复。算力端一次模型调用结束，不表示完整 Agent 任务已经结束。

## 普通执行

1. 读取当前请求和工具契约，建立已识别的需求账本。
2. 模型返回工具 Action 或 Final；解析和整批参数校验通过后才能调度工具。
3. 工具注册表为实际调用分配标识、校验调用契约并规范化结果。
4. 执行器将真实结果作为 Observation，继续处理未完成查询或依赖操作。
5. 有工具结果的页面任务最多再进行一次隔离的最终综合，然后校验并发布答复。

示例协议：

```text
Execution: serial
Action: calculator[{"expression":"(12+3)*4"}]
```

模型不得自行生成 Observation；Action 和 Final 不能混在一个执行响应中。可选 Plan 用于声明需求，不代表已执行、已获得结果或获得权限。

## 结果与最终答复

工具状态包括 success、failed、empty、unavailable。模型汇总失败不会把已经成功的工具改为失败；执行器保留真实证据并标记综合未完成。工具结果展示与最终模型答复分别处理，完整答复可包含解释、建议和额外写作。

最终综合只接收当前请求与当前证据，没有工具调度权限。它不能重新执行操作，也不能进入无限复核循环。已完成、可缓存的安全只读调用重复出现时，可转入综合；写操作或执行结果不确定的操作不自动重放。

## 上下文与历史

独立新任务取得工具证据后，执行提示不再把旧助手答案当成本轮事实；有明确引用的追问可保留引用上下文。最终综合在提示和模型 context 两处隔离旧答案。

完整答复保存到会话历史；partial 答复在界面显示，但历史只保存未完成说明。总耗时是界面信息，不进入模型对话。

## 停止和超时

页面退出、停止或链路中断会结束本地等待，并取消相关模型/工具调用。请求代次、owner 和调用命名空间隔离迟到结果。取消是停止推进，不保证已经开始的外部操作被回滚。

## 结构化任务接口

`TaskContract`、`TaskPlanner`、`TaskCoordinator`、`ReActTaskWorker` 和 `ModelTaskAggregator` 提供目标字段、依赖图、Worker 与证据聚合接口。严格 taskContracts 模式需要显式启用；普通页面默认使用 ReAct，并由 `ParallelTaskRunner` 处理独立子任务。

这两套接口不能混为同一条已经接线的执行路径。普通 ReAct 只能强制契约识别或 Plan 声明的必需项；框架不能证明模型从任意自然语言中识别了全部需求。

工具扩展见 [工具契约](agent-tool-contracts.md)，子任务与设备调度见 [多算力协作](multi-compute.md)。源码位于 [agent-core/agent](../apps/agent-client/agent-core/src/main/ets/agent)。
