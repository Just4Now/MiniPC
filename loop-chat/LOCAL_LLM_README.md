# 本地模型适配

本工程的本地适配使用 LocalLlmBinding 注入 LlmNativeBinding，SessionBackedModel 调用 libllm.so，由 AKI 桥接 GEWU。配置来自 rawfile 的 llm_config.json。

页面默认使用 RemoteComputeModel 连接算力端；它与本地适配、GEWU 会话协作具有不同的配置和生命周期。本地适配的 localModelPath 不等于算力端固定的 filesDir/models 目录。

接口、配置模板和源码见 [本地模型接口](../docs/local-model.md)，一般双端部署见 [构建与运行](../docs/build-and-run.md)。
