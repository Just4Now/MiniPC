# MiniPC

MiniPC 是面向 HarmonyOS NEXT 的近场算力协同项目。聊天端负责用户交互、Agent 工具调用和结果汇总；算力端运行本地模型并处理推理请求。设备之间通过 BLE 发现和 `linkEnhance` 通信。

## 功能

- Agent 根据任务调用注册工具，支持文件读取、计算、单位换算、天气、车次和地点查询。
- 独立子任务支持并发推理和结果汇总，算力中心负责请求路由。
- 算力设备支持发现、编号、中心选举和接管，界面显示设备状态与任务记录。
- 推理请求支持取消、超时和结果完整性校验；聊天端显示任务总耗时。

## 目录

| 目录 | 用途 |
| --- | --- |
| `loop-chat` | Agent 聊天端 HarmonyOS 工程 |
| `loop-chat/agent_core` | Agent 执行流程、工具注册和子任务编排 |
| `gate-a/compute-probe` | 算力端 HarmonyOS 工程 |
| `loop-minipc` | 远程推理协议的 JavaScript 参考实现及测试 |
| `src/chat-end`、`src/model-end` | 基础聊天端与算力端工程 |
| `gate-a/loop-client` | 近场连接与协议验证客户端 |
| `scripts` | 测试和构建入口 |

Agent 聊天端与算力端分别使用 `loop-chat`、`gate-a/compute-probe`。版本号以各工程的 `AppScope/app.json5` 为准。

## 环境要求

- Node.js、JDK 17、DevEco Studio 或 HarmonyOS 命令行工具，以及 `ohpm`。
- 工程配置的兼容 SDK 为 `6.0.2(22)`，目标 SDK 为 `6.1.0(23)`。
- 支持 `linkEnhance` 的 HarmonyOS 设备。
- 聊天端构建需要 AGenUI HAR，可通过 `loop-chat/scripts/fetch-agenui.sh` 获取，或使用已有 HAR。

## 构建

在 DevEco Studio 中分别打开 `loop-chat` 和 `gate-a/compute-probe`，同步依赖并构建 `entry` 模块。

Windows 命令行构建可使用下面的入口。路径占位符需替换为实际安装位置：

```powershell
$env:JAVA_HOME = '<JDK 17 安装目录>'
$env:Path = "$env:JAVA_HOME\bin;$env:Path"
$env:DEVECO_SDK_HOME = '<HarmonyOS SDK 目录>'
$env:HVIGOR_JS = '<hvigor.js 的完整路径>'
$env:AGENUI_HAR = '<agenui.har 的完整路径>'

.\scripts\build-hap.ps1 -Target agent-chat -InstallDependencies
.\scripts\build-hap.ps1 -Target agent-compute -InstallDependencies
```

基础双端工程对应 `legacy-chat`、`legacy-compute`。构建产物位于各工程的 `entry/build/default/outputs/default/`。

默认构建生成 unsigned HAP。安装到设备前，需要在相应工程配置签名。聊天端和算力端使用相同 bundleName，应分别安装到不同设备。

## 模型与运行

算力端使用 GEWU 加载 `Qwen2.5-7B-Instruct-Q4_N_0`。模型文件不包含在安装包中，需要放入算力端应用的：

```text
filesDir/models/Qwen2.5-7B-Instruct-Q4_N_0/
├── api_config.json
├── params
└── tokenizer.json
```

1. 在算力设备安装算力端应用并部署模型文件。
2. 开启设备蓝牙，完成所需的可信设备组网并授予应用权限。
3. 在算力端启用近场服务，在聊天端连接算力设备。
4. 等待模型服务就绪后，在聊天端提交任务。

外部查询工具需要网络连接；需要授权的集成还需配置相应服务。工具执行在聊天端进行，模型推理通过算力中心调度。Qwen2.5-7B 是文本模型，图片附件不作为视觉输入。

## 测试

从仓库根目录运行：

```powershell
# TypeScript 不在默认路径时，指定其模块目录或 typescript.js。
$env:TYPESCRIPT_PATH = '<TypeScript 模块目录或 typescript.js 路径>'
node scripts/test-all.cjs all
```

`all` 运行全部测试入口；也可使用 `agent`、`legacy`、`protocol` 分别运行 Agent、基础双端和协议参考实现的测试。测试使用受控模型和平台接口，真机运行需在目标设备上验证。

## 版本记录

功能变更见 [CHANGELOG.md](CHANGELOG.md)，Agent 版本记录见 [CHANGELOG.agent.md](CHANGELOG.agent.md)。
