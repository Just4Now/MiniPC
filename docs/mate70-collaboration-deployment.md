# 两台 Mate 70 的 Loopy 协同推理部署记录

## 已部署拓扑

| 角色 | 设备 | 局域网地址 | Loopy 配置 |
| --- | --- | --- | --- |
| 主机 | Mate 70 Pro，序列号尾号 `2918` | `192.168.43.1` | `isMaster: true` |
| 协作者 | Mate 70 Pro，序列号尾号 `2841` | `192.168.43.4` | `isMaster: false` |

两端均已安装 `com.example.loop`，模型均位于：

```text
/data/storage/el2/base/haps/entry/files/model/Qwen2.5-7B-Instruct-Q4_N_0
```

模型关键文件 SHA-256：

```text
api_config.json  f90cdeab7ab99d4b2f3f1f8e6e596913038aee386ebb2a1268d3bb9914e8dc71
params           dc19109754c98c18563a77fbbe343ddff95698111903cfb592df609e61f97db0
tokenizer.json   c0382117ea329cdf097041132f6d735924b697924d6f6fc3945713e96ce87539
```

当前已安装角色 HAP（含 generation 握手、安全结束确认、动态 Gewu 端口、无 Prefill 超时的 Decode 看门狗和 Native 迟到回调保护）：

```text
master  d0e0555b292c03a7928ec88403ff33928ac3562569cd3f37e11ba9590cef63b9
slave   367d03af50c250e7ce220d2073e07c5f2822498e4a8ebd9ace873c1337ea991e
```

## 启动顺序

1. 两台设备接入同一热点/局域网，确认主机地址仍为 `192.168.43.1`。
2. 先启动协作者 Loopy，等待控制端口监听后再启动主机 Loopy。
3. 首次建立 session 时让协作者 App 保持可调度；锁屏后台冻结会阻止 ArkTS 接收生命周期消息。
4. 主机输入框获得焦点后，通过 `runtime_prepare` 下发 `generation`、`resetRuntime` 和本轮动态 Gewu 端口；协作者清理旧状态并注册后返回 `runtime_ready`。
5. 主机等待资源表传播，再创建 session 并把实时 `process.pid` 发给协作者；协作者创建带 `parallel_settings` 的 co-session，回传 `session_ready` 后才开放发送。
6. 请求完成后主机发送 `session_end`，协作者排空并销毁 session，返回 `session_ended` 后下一轮才能开始。

状态条含义：绿色“已连接”代表应用控制通道握手已验证；绿色“协同会话已就绪”还代表 co-session 已确认；橙色为连接/会话准备中，红色为断开或错误。“连接设备/重连”会安全结束当前 session、重建 TCP 控制通道，并在下一次聚焦时让两端 Gewu 数据面换端口重新注册。主机在协作者返回 `session_ready` 前不会提交请求。协同页面位于前台时会对当前窗口启用保持亮屏，退出/切到后台后恢复系统策略。

控制面端口：

- `19090/TCP`：构建配置中的 Gewu 引导端口。
- `21000–21999/TCP`：主机进程实际协商的 Gewu 数据面端口；重建时轮换，避免旧监听端口的 `TIME_WAIT/Address in use`。
- `19091/TCP`：Loopy 生命周期/PID 控制通道，由协作者主动连接主机。
- `7790/UDP`：发现和兼容回退。

## 实机验收证据

2026-08-06 的同一请求中：

```text
master: ComputeLayers ... totalLayer: 28 ... layers: 0-12
slave:  ModelSetParallelConfig ... layerSeg: 13-27
master: inputTokenCount: 867, outputTokenCount: 19
master: Prefill latency: 12417.77 ms, Decode latency: 5145.56 ms
```

Loopy 主界面输入 `hello`，最终回显：

```text
Hello! How can I assist you today?
```

这证明了 App 输入、Loopy Agent、本地 Qwen2.5、Gewu 会话、双机分层和 App 回显的完整链路。仅看到设备互 ping、插件加载或单机 session 成功，不能替代这组端到端证据。

连接状态功能更新后再次实测输入 `你好`：

```text
master: ComputeLayers ... layers: 0-12
slave:  ModelSetParallelConfig ... layerSeg: 13-27
master + slave: 同一请求均出现 Start infer
master: inputTokenCount: 867, outputTokenCount: 18
master: Prefill latency: 5501.98 ms, Decode latency: 4307.15 ms
slave:  inputTokenCount: 867, outputTokenCount: 17
slave:  Prefill latency: 5356.20 ms, Decode latency: 4321.89 ms
App:    你好！有什么可以帮助你的吗？
```

断开协作者后，主机在 9 秒心跳窗口后由绿色切换为橙色“正在等待协作者连接”，按钮切换为“连接设备”；恢复协作者前台后重新握手并变绿。

稳定性修复后的连续验收：

| 轮次 | generation | 两端 input tokens | 主机 prefill/decode | 协作者 prefill/decode | App 回显 |
| --- | ---: | ---: | --- | --- | --- |
| 1 | 1 | 871 | 5710.53 / 3078.26 ms | 5554.07 / 3087.87 ms | `你好！` |
| 2 | 3 | 892 | 5873.02 / 1036.49 ms | 5316.57 / 1046.25 ms | `2` |
| 3 | 5 | 906 | 6346.15 / 2830.24 ms | 6137.26 / 2834.59 ms | 广州一句话介绍 |
| 手动重连后 | 7 | 931 | 6242.17 / 783.43 ms | 6077.10 / 783.73 ms | `OK` |

四轮均出现主机 `layers: 0-12`、协作者 `layerSeg: 13-27`、两端同一 `Start infer`、匹配的 `inputTokenCount` 和 `session_ended`。结束后两端 Loopy 进程仍存活，TCP 19091 仍为 `ESTABLISHED`，没有新增 `cppcrash-com.example.loop` 或 `cppcrash-gewu_service`。

2026-08-13 修复模型配置中的 KV-cache 覆盖项后，在同一条 App 控制连接上连续执行
6 条自然语言 Skill 请求（输入 1316–1469 tokens）。6/6 请求均在两端出现同一
`Start infer`、有效 `PrintStats` 和 `session_ended`，未再出现
`RtSessionWriteKvCache`、`eval failed` 或 `recv token failed`。其中 5/6 任务答案
通过预期校验；S04 是模型文本值未命中预期，不是协同链路失败。完整结果位于：

```text
benchmark_artifacts/mobile_prefill_skill_20260813/locked_1500_natural_6skills/gewu_demo_config_reuse_6skills
```

根因是旧 `api_config.json` 额外覆盖了 `cache_grow_policy`、`cache_grow_size` 和
`cache_persist_policy`。这些选项并不存在于 GeWuDemo 的 7B 配置，在当前 Mate 70
运行库中会使协作者的分布式 KV-cache 写入偶发返回错误码 5。当前配置严格使用
GeWuDemo 的模型元数据，让缓存策略由运行库协商；后端和上下文上限继续由 Loopy
session 的 `eval_settings` 指定。

## 已知边界

- HAP 中角色和主机 IP 目前是构建时 rawfile 配置；网络地址变化后需要重新配置/打包。
- 协作者在 session 建立前被系统冻结时，App 控制消息不会执行；前台页面会保持亮屏，但切到后台后主机会显示未连接并阻止请求。
- 绿色“已连接”只证明控制面在线，不能单独证明双机算力已分层。点击输入框后应等待“协同会话已就绪”；最终仍以主机 `0-12`、协作者 `13-27` 以及两端同一请求的 `Start infer` 为准。
- 若协作者被冻结或离开前台，co-session 可能超时或返回 `401`。保持两端解锁并回到 Loopy 前台，点击主机“重连”恢复控制通道，再重新聚焦输入框；数据面会在下一次会话准备中自动按正确顺序刷新。
- Gewu 的 `abort/destroy` 不提供“所有异步回调已排空”的确认。Native 桥会先停用回调，再把上下文隔离到进程退出；这会为每次被中止的请求保留很小的回调对象，但避免此前 `aki::SafetyCallback` 的 use-after-free 崩溃。
- UDP 255.255.255.255 在热点主机上可能失败；它只是发现/回退链路。只要 TCP 19091 双端为 `ESTABLISHED` 且握手心跳正常，不影响协同。日志前端将此项显示为黄色而非红色。
- 工作区直接构建要求提供 `entry/src/main/cpp/aki/`；本次 HAP 使用与当前 SDK 匹配的 AKI 构建源，构建完成后未把临时源码副本留在仓库中。
