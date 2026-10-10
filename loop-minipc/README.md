# 远程推理协议参考实现

Node.js CommonJS 模块，用于描述和测试聊天端、推理网关、准入与流交付行为。该目录不构建 HAP，也不是自动启动的独立生产服务器。

入口为 [src/index.js](src/index.js)，导出 ComputeClient、RemoteComputeModel、NearbySession、InferenceGateway、NativeInferenceService 等接口。接入方提供传输和 Native 执行边界。

| 目录 | 内容 |
| --- | --- |
| src/protocol | infer v2、UTF-8、SHA256、分片和提示拆分 |
| src/loop | 客户端、运行控制和模型适配 |
| src/minipc | profile、准入、网关、Native 事件分派和节点选择 |
| scripts | 受控时钟与测试 |

从仓库根目录运行：

```powershell
node loop-minipc/scripts/test-all.cjs
# 或通过统一入口
node scripts/test-all.cjs protocol
```

profile 默认值和网关容量属于本参考实现，不能据此推断 HarmonyOS 设备工程的当前 Native 参数。设备消息定义见 [通信协议](../docs/protocol.md)，覆盖边界见 [测试](../docs/testing.md)。
