# MiniPC

此迁移分支把 Agent-MiniPC 引入 MiniPC 主仓库，保留两边提交历史。`main` 仍保持原 MiniPC 版本；迁移尚未发布为稳定版。完整操作、验证和回退步骤见 [迁移记录](docs/agent-integration-2026-10-10.md)。

## 开发入口

| 目录 | 用途 | 状态 |
| --- | --- | --- |
| `loop-chat` | Agent 聊天端与通用 `agent_core` | 新开发入口，导入版本 1.2.15 |
| `gate-a/compute-probe` | Agent 算力端 | 新开发入口，导入版本 1.0.18 |
| `loop-minipc` | 远程推理协议的 JavaScript 参考实现与回归 | 参考实现，不是安装到设备的 HAP |
| `src/chat-end` / `src/model-end` | 原 MiniPC 聊天端与算力端 | 保留用于功能对照，源码未被新实现覆盖 |
| `gate-a/loop-client` | 早期近场客户端验证工程 | 历史测试入口，不作为新 Agent 聊天端 |

项目目录暂不搬迁，避免把路径变更与协议迁移混在一个提交中。新功能在 Agent 入口开发；原 MiniPC 的设备选举、中心接管、编号与路由继续作为兼容验收基线。保留旧代码不等于已经验证新旧应用可以混装互通。

Agent 最新源码含多请求、并行子任务和推理中继。实现及限制见 [并行子任务方案](docs/agent-parallel-subtasks-plan.md)。历史文档中的旧版本验收不能代替此分支的整包编译或多物理设备测试。

## 统一测试

```powershell
# 如果 TypeScript 不在默认 SDK 路径，指定其模块目录或 typescript.js
$env:TYPESCRIPT_PATH = 'D:\command-line-tools\sdk\default\openharmony\ets\build-tools\ets-loader\node_modules\typescript'
node scripts/test-all.cjs all
```

也可选 `legacy`、`agent` 或 `protocol`，分别运行原 MiniPC、Agent/算力、协议参考实现的现有测试。日志里的套件计数包含嵌套运行器；它不是设备数量或独立测试用例总数。测试使用受控平台与模型，不安装应用，不调用真实外部工具。

## 统一构建

需要 Node.js、JDK 17、HarmonyOS SDK、hvigor 和可用的 `ohpm`。SDK 路径属于本机配置，不提交到仓库。

```powershell
$env:JAVA_HOME = 'D:\MiniPC\tools\jdk\jdk-17.0.20.1+1'
$env:Path = "$env:JAVA_HOME\bin;$env:Path"
$env:DEVECO_SDK_HOME = 'D:\command-line-tools\sdk'
$env:HVIGOR_JS = 'D:\command-line-tools\hvigor\hvigor\bin\hvigor.js'

# AGenUI 是忽略的外部 HAR。可以使用 fetch-agenui.sh 获取，或提供已有文件。
$env:AGENUI_HAR = '已有 AGenUI HAR 的绝对路径'
.\scripts\build-hap.ps1 -Target agent-chat -InstallDependencies
.\scripts\build-hap.ps1 -Target agent-compute -InstallDependencies
```

旧实现对应 `legacy-chat`、`legacy-compute`。输出位于各项目 `entry/build/default/outputs/default/`。默认只生成 unsigned HAP；需要安装时，在对应工程自行配置 DevEco 签名。私钥、模型权重、SDK、构建包和本机依赖不随此次迁移复制或发布。

DevEco Studio 应分别打开 `loop-chat` 或 `gate-a/compute-probe`，而不是把仓库根目录作为 HarmonyOS 工程。二者目前使用相同 bundleName，不能当成同一设备上的两个独立应用同时安装。

## 版本与历史

- 合并前完整快照：`minipc-before-agent-20261010`，对应 MiniPC `7f04edd`。
- 原 MiniPC 程序基线：`v0.4-hub`。上面的完整快照只比它多一个文档提交。
- 原 MiniPC 版本记录：[CHANGELOG.md](CHANGELOG.md)。
- 导入的 Agent 版本记录：[CHANGELOG.agent.md](CHANGELOG.agent.md)。
- 合入 `main` 前需要完成原功能对照、新双端构建和真机验收；分支测试通过不等于已发布。

## 原 MiniPC 说明（v0.4-hub 与合并前文档）

下面保留原说明用于功能对照。它描述 `src/chat-end` / `src/model-end`，不能直接套用于新 Agent 的推理预算和并行执行。
算力协同，由算力端和聊天端组成，靠蓝牙近场连接。具有两个独立 HAP。

现在的版本是 [v0.4-hub](https://github.com/Keanu2/MiniPC/releases/tag/v0.4-hub)。改过什么看 [CHANGELOG.md](CHANGELOG.md)。

## 怎么跑起来的

算力机（`src/model-end`，`IS_SERVER = true`）先用 manufacturer `0x6E77`、type `1` 的 BLE 广播互相发现，按组网时可用内存选出算力设备1。启动后留 10 秒选举窗口，编号确定后才发布编号广播；广播只在编号真正变化且没有在途任务时更新。聊天机只连接可信的算力设备1，连上之后标题显示「聊天设备N」，状态栏写「协同已就绪」。算力设备1统一接收、调度并回传，其他算力设备只与它保持算力链路。

算力设备1停用后，存活算力按旧排名确认接管：至少15秒、三次成功完成的扫描均未发现旧中心后，由当前可见存活成员中排名最靠前的一台接管为1号并发布新广播；聊天端在接管窗口内继续有限次重连，不会直接连仍编号为2的节点。已连上中心的执行节点不再自己猜编号，等中心按安装 UID 分配；第三台、第四台不会再都自称算力设备2。

轻量内存、温度、CPU 和推理路数在空闲时每 2 秒更新。成员变化由中心立刻同步：推理进行中只发精简名单（身份、角色、编号、ready），空闲时发完整清单，没有变化则 30 秒保底。失败会按连接重试。细节、容量边界和尚未做完的真机轮次见 [2026-09-23 多算力审查](docs/multi-compute-membership-review-2026-09-23.md)。更早的中心接管和广播修复见 [2026-09-22 修复记录](docs/nearby-identity-and-hub-failover-fix-2026-09-22.md)，其中「推理期间不发后台控制消息」已被上面的精简名单替代。

消息走 `linkEnhance`，协议叫 `nearby-chat-v1`，帧大概 480 字节 Base64，编解码在 `protocol/ChatProtocol.ets`。

聊天机连上中心后所有新请求都发给算力设备1；仅在未连接中心且本机部署权重时保留离线本地推理。1号接到请求后按负载和可用内存选执行机。代码在 `cluster/ComputeRouter.ets` 的 `pickNode`。派出去的请求带 `sched=true`，对面必须自己跑并经1号回传结果。

算力编号按组网时的可用内存排一次（余量最大的是算力设备1，平手按安装 UID），内存后来涨跌不再改号；中心失效后按存活成员重新编号。界面上只显示「算力设备N / 聊天设备N」，不出现手机蓝牙名。聊天机由当前中心按安装 UID 分配不重复编号，同一近场服务会话保留已分配号码供重连使用；更换中心后可能重新分配，不是物理设备永久编号。回复末尾的「由算力设备N推理」是协调机改写 `done.source` 写上去的。

两端都能附图，但现在这颗 Qwen2.5-7B-Instruct 是文本模型，图只显示在气泡/任务卡里，既不进推理也不走近场。

签名用本机 `tools/signing`，证书别提交。模型文件也不进 Git，放到应用 `filesDir/models/Qwen2.5-7B-Instruct-Q4_N_0`。

## 目录

| | 干什么 | 开关 |
|---|---|---|
| `src/model-end` | 跑模型、选点、仪表盘 | `nearby/NearbyConfig.ets` 里 `IS_SERVER = true` |
| `src/chat-end` | 聊天界面 | `IS_SERVER = false` |

HarmonyOS 规定源码在 `entry/src/main/ets/` 下面。我们只多了一层分类：

- `protocol/` 消息字段和分片
- `nearby/` `linkEnhance`、BLE、角色开关
- `llm/` 本机 GEWU
- `cluster/` 内存和模型采样；选点只在模型端的 `ComputeRouter.ets`
- `media/` 选图
- `ui/` WebView 桥
- `pages/` 页面
- `entryability/` 生命周期

设备编号文案在模型端 `cluster/DeviceLabels.ets`。两端的 `ChatProtocol.ets` 目前是各一份拷贝，改字段要两边一起动。

编 HAP 的命令写在 [算力端 README](src/model-end/README.md) 和 [聊天端 README](src/chat-end/README.md)。
