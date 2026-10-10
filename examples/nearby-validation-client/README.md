# 近场协议验证客户端

用于验证同一应用身份下的设备发现、连接和消息回显，包含 Gate 相关消息与结果检查。它是独立 HarmonyOS 工程，不是 Agent 聊天端。

在 DevEco Studio 中打开本目录，配置依赖及签名后构建 entry。应用标识以 [AppScope](AppScope/app.json5) 为准；它与 Agent 双端使用相同 bundleName，不能在同一设备作为独立应用并存。

源码位于 entry/src/main/ets：nearby 管理连接和验证，protocol 定义消息，pages 展示界面。本工程的现有回归包含在仓库根目录 `node scripts/test-all.cjs agent` 中。

一般设备部署见 [构建与运行](../../docs/build-and-run.md)，Agent 使用入口见 [apps/agent-client](../../apps/agent-client/README.md)。
