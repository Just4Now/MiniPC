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

## 多模态（Qwen2.5-VL-3B-NPU）

带图请求走本机 VL 引擎（`libqwenvl_engine.so` + NPU 版 `libqwen2vl_sdk.so` + 22 库 `libai_runtime` 闭包）。这些 `.so` 是**私有预编译产物，不在仓库内**，需本机放置到 `entry/src/main/cpp/libs/arm64-v8a/` 后随 HAP 打包：清单见 `entry/src/main/cpp/libs.manifest.json`，放置脚本 `scripts/place-vl-libs.ps1`。

缺库时 CMake 自动改编空实现（`napi_engine_stub.cpp`），应用仍可构建并只跑纯文本——多模态是可整体摘除的模块，不影响其余功能。

模型目录与文本模型并列：

```
filesDir/models/Qwen2.5-VL-3B-NPU/
  ├── vl_params        # VL 权重（NPU/CPU 版均可，容忍加载失败回退）
  ├── tokenizer.json
  └── manifest.json    # 可选：{"capabilities":["text","vision"]}
                       # 缺省时按 VL 布局自动声明 text+vision
```

- **就绪判定**：目录存在 `vl_params` 即按 VL 文件集（vl_params + tokenizer.json）检查，不再要求 `api_config.json/params`。
- **调度**：带图请求带 `needs:['vision']`；设备能力 = 所有就绪模型能力并集，VL 目录就绪即自动上报 `vision`。聊天端发图 → Hub 本机有能力则本机 VL 直答，否则路由到集群里有 VL 的算力端，全集群无 vision 时 fail closed（不会降级给纯文本模型）。
- **本地分流**：`Index.startModel` 中带图请求优先走 `VlLlmTransport`（裸 base64 解码落盘 → VL 引擎），纯文本仍走 GEWU `LocalChat`。
- **首次加载**：约 5.3GB 权重，数十秒到数分钟；加载期 UI 为 busy 态。诊断落盘 `/data/storage/el2/base/cache/qwenvl_preflight.txt`（native）与 `qwenvl_ets.txt`（ETS 层）。
- **取消**：VL 引擎为单任务，`cancel` 停在下一个 token 边界；`release` 卸载权重释放内存。

源码在 `entry/src/main/ets`。选点看 `cluster/ComputeRouter.ets`，页面在 `pages`，VL 引擎管理在 `llm/QwenVlManager.ets`、传输适配在 `llm/VlLlmTransport.ets`，模型发现在 `llm/ModelRegistry.ets`。

工具执行位于聊天端。Agent infer.* v2 与基础聊天 request 分别处理，不能混用输入预算。当前 Native max_ctx=32768，最大输出 2048 tokens，提示内容预算 32768 UTF-8 bytes；能力公告不是模型能力认证。

协议见 [通信协议](../../docs/protocol.md)，调度见 [多算力协作](../../docs/multi-compute.md)。默认保留最多 40 条已完成任务记录，服务前台监听或任务运行时保持窗口唤醒。

## 测试

从仓库根目录运行 `node scripts/test-all.cjs agent`，其中包含本工程的连接、路由、Native 生命周期适配及窗口测试。覆盖范围见 [测试](../../docs/testing.md)。

选点测试是 `cluster/ComputeRouter.test.cjs`；模型发现/能力测试 `llm/ModelRegistry.test.cjs`；VL 通道测试 `llm/VlLlmTransport.test.cjs`；页面分流测试 `pages/IndexFocus.test.cjs`。
