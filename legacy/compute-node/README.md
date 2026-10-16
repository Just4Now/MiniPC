# 基础算力端

基础近场聊天的算力工程，负责设备组网、中心编号与接管、ComputeRouter 选点，以及 GEWU 推理。IS_SERVER=true。

在 DevEco Studio 中打开本目录，或从仓库根目录使用：

```powershell
.\scripts\build-hap.ps1 -Target legacy-compute-node -InstallDependencies
node scripts/test-all.cjs legacy
```

中心对普通聊天 request 选执行设备；转发带 sched 标记，对端本地执行并由中心回传。Native 会话当前 max_ctx=2048，具体聊天输出/历史限制以本工程常量为准。这些值不适用于 apps/compute-node 的 Agent infer.* 路径。

模型位于应用 filesDir/models/Qwen2.5-7B-Instruct-Q4_N_0，需 api_config.json、params、tokenizer.json。环境、签名和启动见 [构建与运行](../../docs/build-and-run.md)，设备职责见 [多算力协作](../../docs/multi-compute.md)。版本及应用标识见 [AppScope](AppScope/app.json5)。
