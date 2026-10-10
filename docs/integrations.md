# 工具与外部集成

默认工具在 [ToolRegistry](../loop-chat/agent_core/src/main/ets/agent/ToolRegistry.ets) 中注册，工具在聊天端执行。算力设备只处理模型推理请求。

## 内置工具

| 类别 | 工具 |
| --- | --- |
| 时间与计算 | time、calculator、date_calculator、unit_convert |
| 文件空间 | list_sandbox_files、read_sandbox_file、search_sandbox_files；写入工具按配置注册 |
| 公开查询 | weather_search、air_quality、train_search、map_search |
| Skill | 有 Skill 快照时注册 read，用于读取运行时指令 |

文件路径相对应用工作区，工具拒绝绝对路径和父目录越界。查询工具需要网络或相应提供方服务；失败、空结果和不可用以实际返回为准。文件示例属于应用资源，不是仓库工程说明。

## 配置模板

配置文件位于 `loop-chat/entry/src/main/resources/rawfile/`。复制对应 example 模板到没有 example 后缀的文件后配置：

| 模板 | 配置文件 | 用途 |
| --- | --- | --- |
| [llm_config.example.json](../loop-chat/entry/src/main/resources/rawfile/llm_config.example.json) | llm_config.json | 模型工厂的本地/HTTP 配置 |
| [composio_config.example.json](../loop-chat/entry/src/main/resources/rawfile/composio_config.example.json) | composio_config.json | Composio 集成 |
| [modelscope_config.example.json](../loop-chat/entry/src/main/resources/rawfile/modelscope_config.example.json) | modelscope_config.json | ModelScope Direct |

这些本机配置被 Git 忽略。不要将模板中的空值或占位符当成有效授权。近场 Agent 的 RemoteComputeModel 不依赖 HTTP API key，llm_config 的云端配置不会覆盖已经发送的近场请求。

## Composio

需要 userId，并提供 apiKey/baseUrl 或 proxyBaseUrl；代理还可使用 proxyApiKey。先查询获授权工具及 schema，再执行返回的 toolSlug。没有配置/账户时集成显示不可用，不阻止本地公共工具注册。

集成调用可能产生外部副作用，是否执行由实际工具契约与授权决定，不能由模型自行授予权限。

## ModelScope

当前实现使用 Direct 客户端。需要 modelscopeToken 和有效的 modelscopeApiBaseUrl；配置模板的 mode=direct 与该实现对应。搜索返回工具定义后再执行，不能将此模块描述为必须启动的本地 Gateway。

## A2UI 与复用接口

agent_core 包含 A2UI、LoopBackend 和 AIPhone 适配接口，供接入方初始化模型、工具和配置。当前仓库不是 Android 工程，也不包含 AIPhoneDemo 应用；这些库接口不等于已经部署的外部项目。

扩展工具的输入、输出和权限规则见 [工具契约](agent-tool-contracts.md)。
