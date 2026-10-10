# 基础聊天端

基础近场聊天工程，通过算力中心提交聊天 messages，接收并展示回复。IS_SERVER=false。它与 loop-chat 的 Agent/工具任务流程不同。

在 DevEco Studio 中打开本目录，或从仓库根目录使用：

```powershell
.\scripts\build-hap.ps1 -Target legacy-chat -InstallDependencies
node scripts/test-all.cjs legacy
```

连接中心后请求交给中心调度；未连接且本机已有模型时提供本地聊天路径。图片用于界面展示，当前文本模型不读取图片像素。

基础聊天的消息、输出和历史边界以本工程 pages/Index、protocol/ChatProtocol 和 llm/LocalChat 常量为准，不使用 Agent infer.* 的预算。模型位于应用 filesDir/models/Qwen2.5-7B-Instruct-Q4_N_0，包含 api_config.json、params、tokenizer.json。

环境和签名见 [构建与运行](../../docs/build-and-run.md)，设备组网见 [多算力协作](../../docs/multi-compute.md)。应用标识与版本见 [AppScope](AppScope/app.json5)。
