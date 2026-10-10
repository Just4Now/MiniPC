# 通信协议

## 实现

近场封装标识为 `nearby-chat-v1`。Agent 推理使用其中的 `infer.*` v2 消息，基础聊天使用 request/delta/done 等消息。Agent 两端各有一份协议实现，字段变更需同时修改与验证：

- [聊天端 ChatProtocol](../loop-chat/entry/src/main/ets/protocol/ChatProtocol.ets)
- [算力端 ChatProtocol](../gate-a/compute-probe/entry/src/main/ets/protocol/ChatProtocol.ets)

JavaScript 参考实现位于 [loop-minipc/src/protocol](../loop-minipc/src/protocol)，其模型 profile 默认值不必与设备工程相同。

## 推理消息

| 消息 | 用途 |
| --- | --- |
| infer.capabilities.get / infer.capabilities | 查询模型、输入输出预算、就绪状态和集群容量 |
| infer.request | 提交请求、输出预算和 deadlineBudgetMs |
| infer.accepted | 接受请求，可带实际执行设备信息 |
| infer.delta | 按 seq 传输结果文本 |
| infer.done | 返回 lastSeq、outputUtf8Bytes、outputSha256 和完成原因 |
| infer.error | 返回错误代码、说明与可重试状态 |
| infer.cancel | 请求停止指定推理 |
| infer.status | 更新集群 idle/total |

请求通过 requestId 和连接 epoch 隔离；子任务 owner 在客户端管理取消范围。转发节点的 forwardId 不冒充用户层调用标识。能力 profile 需先验证，ready 与链路 connected 是不同状态。

## 输入和传输预算

当前 Agent 设备实现使用以下边界：

| 项目 | 当前值 | 来源 |
| --- | --- | --- |
| 消息封装预算 | 65536 bytes | ChatProtocol |
| 分片原始数据 | 480 bytes | ChatProtocol |
| 同时未完成组包 | 8 | ChatProtocol |
| 分片组包超时 | 15 秒 | ChatProtocol |
| 模型提示内容预算 | 32768 UTF-8 bytes | InferenceHost / InferenceClient |
| 本机会话 max_ctx | 32768 tokens | 算力端 gewu_probe.cpp |
| 最大请求输出 | 2048 tokens | InferenceHost |

字节预算与 token 上下文长度不能互换。messages 模式当前允许至多两条，最后一条为 user；也保留 prompt 输入兼容。客户端使用能力协商预算限制提示，必要内容超限时返回错误，不静默截断任务和工具结果。

当前公告 gateBPassed=false，不能把公告上下文值当成已完成的模型能力认证。基础 src 双端和 JavaScript 参考 profile 有各自边界，不套用本表。

## 完整性与终态

只在分片/结果完整、序号连续、字节数和 SHA256 匹配且完成原因有效时交付模型结果。取消、长度截断、超时、断链或校验失败不能冒充正常终态。结果校验在 UTF-8 修复/展示适配前按传输文本进行。

Native 回调粒度与传输分片是不同概念：算力端 LocalChat 使用 stream=false，InferenceHost 将返回文本转换为 infer.delta。协议声明可传输增量不代表 Native 一定逐 token 回调。

## 等待、重试与取消

InferenceClient 当前协商/接受等待为 10 秒，已提交请求授予 170 秒预算，交付余量为 15 秒。等待空闲的请求另受 120 秒等待上限约束；这些不是整轮 Agent 超时。

只在接受前收到可重试拒绝时用新 ID 重发。接受后的失败直接返回给上层。取消先结束本地等待，再发送停止；停止确认窗口用于防止新请求抢占仍未清理的 host。各阶段常量见 [InferenceClient](../loop-chat/entry/src/main/ets/model/InferenceClient.ets)。
