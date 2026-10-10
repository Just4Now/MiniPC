# Agent 聊天端

HarmonyOS NEXT 聊天应用，负责 Agent 执行、工具调用、子任务编排和结果展示。默认页面通过 RemoteComputeModel 使用近场算力设备；本机工具在聊天设备运行。

## 构建与运行

在 DevEco Studio 中打开本目录，安装 AGenUI 依赖并构建 entry。仓库根目录的命令行入口：

```powershell
.\scripts\build-hap.ps1 -Target agent-chat -InstallDependencies
```

环境、签名和连接步骤见 [构建与运行](../docs/build-and-run.md)。本工程 bundleName 为 com.jiuwen.registrychatui，应与算力端分别安装到不同设备。版本号以 [AppScope](AppScope/app.json5) 为准。

## 代码入口

| 路径 | 职责 |
| --- | --- |
| entry/src/main/ets/pages/Index.ets | 页面、会话历史、任务状态和最终展示 |
| entry/src/main/ets/model | 近场模型适配、多请求与取消范围 |
| entry/src/main/ets/nearby | 设备发现和近场通信 |
| entry/src/main/ets/protocol | 推理消息及分片校验 |
| agent_core/src/main/ets/agent | ReAct、工具契约和任务接口 |
| agent_core/src/main/ets/agent/parallel | 独立子任务拆分、执行和汇总 |

流程见 [Agent 执行](../docs/agent-workflow.md)、[多算力协作](../docs/multi-compute.md) 和 [外部集成](../docs/integrations.md)。本地 Native 适配接口见 [本地模型](../docs/local-model.md)。

## 测试

从仓库根目录运行 `node scripts/test-all.cjs agent`；也可单独执行 `node loop-chat/agent_core/tests/run-all.cjs`。TypeScript 环境及覆盖范围见 [测试](../docs/testing.md)。
