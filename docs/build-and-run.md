# 构建与运行

## 工程选择

| 构建目标 | 工程目录 | 应用职责 |
| --- | --- | --- |
| `agent-chat` | `loop-chat` | Agent 聊天、工具执行与汇总 |
| `agent-compute` | `gate-a/compute-probe` | 本地推理、设备组网和路由 |
| `legacy-chat` | `legacy/chat-end` | 基础聊天端 |
| `legacy-compute` | `legacy/model-end` | 基础算力端 |

`examples/nearby-client` 是近场协议验证客户端，可在 DevEco Studio 中单独打开。它不替代 Agent 聊天端。`loop-minipc` 是 JavaScript 协议参考实现，没有 HAP 构建目标。

## 工具与依赖

需要 Node.js、JDK 17、HarmonyOS SDK、hvigor 和 `ohpm`。工程的兼容 SDK 为 `6.0.2(22)`，目标 SDK 为 `6.1.0(23)`；设备还需提供对应的系统能力，SDK 编译成功不能代替设备支持检查。

Agent 聊天端引用 AGenUI HAR。可使用 [获取脚本](../loop-chat/scripts/fetch-agenui.sh)，该脚本固定下载版本并校验 SHA256，需要 Bash、curl 和 shasum；也可通过 `AGENUI_HAR` 或 `-AgenuiHar` 指定已有文件。HAR 位于 `loop-chat/libs/agenui.har`，不入库。Native 构建使用已包含的 AKI 源码和 SDK 系统库。

## 命令行构建

下面是 Windows PowerShell 入口，路径占位符需替换为实际位置：

```powershell
$env:JAVA_HOME = '<JDK 17 目录>'
$env:Path = "$env:JAVA_HOME\bin;$env:Path"
$env:DEVECO_SDK_HOME = '<HarmonyOS SDK 目录>'
$env:HVIGOR_JS = '<hvigor.js 的完整路径>'
$env:AGENUI_HAR = '<agenui.har 的完整路径>'

.\scripts\build-hap.ps1 -Target agent-chat -InstallDependencies
.\scripts\build-hap.ps1 -Target agent-compute -InstallDependencies
```

`-InstallDependencies` 执行 `ohpm install --all`；依赖安装完成后可以省略。其他目标使用相同入口。脚本从环境/参数定位工具，并在本地忽略目录连接命令行 SDK 自带插件。

构建产物位于各工程 `entry/build/default/outputs/default/`。默认没有签名配置时生成 unsigned HAP；设备安装需要在工程内配置自己的签名材料。签名私钥、SDK、依赖、模型和构建包不入库。

## DevEco Studio

分别打开目标工程目录，例如 `loop-chat`、`gate-a/compute-probe`，同步依赖，配置签名并构建 `entry`。仓库根目录不是单个 HarmonyOS 工程。

Agent 聊天端、算力端和验证客户端使用 `com.jiuwen.registrychatui`，不同角色应安装到不同设备；在同一设备安装会更新同名应用。基础双端的应用标识以其 AppScope 为准。

## 部署模型

算力端从应用 filesDir 下读取：

```text
models/Qwen2.5-7B-Instruct-Q4_N_0/
├── api_config.json
├── params
└── tokenizer.json
```

三个文件都需要存在、非空且可读。应用 filesDir 是系统提供的目录，不要照抄其他设备的绝对沙盒路径。模型不会打进 HAP。设备系统需要支持 GEWU/KNPU，实际会话创建失败会通过应用错误状态返回。

## 启动

1. 在算力设备部署模型，安装算力端；在聊天设备安装 Agent 聊天端。
2. 开启蓝牙，完成设备信任/组网并授予应用所需权限。
3. 在算力设备启用近场服务，等待设备发现和中心编号；聊天端连接中心。
4. 等待能力协商成功后提交任务。多台算力的加入与调度见 [多算力协作](multi-compute.md)。

工具查询需要网络时，网络在聊天端使用。需要授权的工具另行配置，见 [外部集成](integrations.md)。Qwen2.5-7B 是文本模型，图片附件不作为视觉输入。

## 常见错误

| 现象 | 检查 |
| --- | --- |
| 本地 HAR 找不到 | 获取 AGenUI，或设置 AGENUI_HAR |
| hvigor/插件找不到 | 检查 SDK、HVIGOR_JS 和命令行工具布局 |
| unsigned HAP 无法安装 | 配置设备签名并重新构建 |
| 模型未就绪 | 检查模型文件和设备 GEWU/KNPU 支持 |
| 无可连接中心 | 检查信任关系、蓝牙、权限、算力服务和设备编号 |
| 输入超过传输预算 | 缩小任务或文件范围；限制按 UTF-8 字节计，见通信协议 |
