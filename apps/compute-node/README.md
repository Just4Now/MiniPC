# Agent 算力端

HarmonyOS NEXT 算力应用，使用 GEWU/KNPU 运行本地模型，并作为近场算力中心或执行节点处理请求。角色设置位于 entry/src/main/ets/nearby/NearbyConfig.ets，IS_SERVER=true。

## 构建与部署

在 DevEco Studio 中打开本目录，或从仓库根目录运行：

```powershell
.\scripts\build-hap.ps1 -Target compute-node -InstallDependencies
```

部署模型与签名步骤见 [构建与运行](../../docs/build-and-run.md)。模型从应用 filesDir/models/Qwen2.5-7B-Instruct-Q4_N_0 读取。版本号以 [AppScope](AppScope/app.json5) 为准。

## 执行入口

- pages/Index：看板、近场生命周期和请求分派。
- llm/InferenceRelay：中心选点、转发和响应映射。
- llm/InferenceHost：一台设备的当前请求、准入和结果发送。
- llm/LocalChat 与 cpp/gewu_probe.cpp：Native 模型请求和清理。
- cluster/DevicePool：空闲节点选择；nearby/LinkEnhanceChannel：组网、编号和接管。

工具执行位于聊天端。Agent infer.* v2 与基础聊天 request 分别处理，不能混用输入预算。当前 Native max_ctx=32768，最大输出 2048 tokens，提示内容预算 32768 UTF-8 bytes；能力公告不是模型能力认证。

协议见 [通信协议](../../docs/protocol.md)，调度见 [多算力协作](../../docs/multi-compute.md)。默认保留最多 40 条已完成任务记录，服务前台监听或任务运行时保持窗口唤醒。

## 测试

从仓库根目录运行 `node scripts/test-all.cjs agent`，其中包含本工程的连接、路由、Native 生命周期适配及窗口测试。覆盖范围见 [测试](../../docs/testing.md)。
