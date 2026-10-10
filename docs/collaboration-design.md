# Loopy + Gewu 协同推理设计

本文档将 [HysenX-LI/loopy#1](https://github.com/HysenX-LI/loopy/pull/1) 的协同生命周期设计，对齐到当前可构建的 Gewu/KNPU 实现。

## 对齐结论

PR #1 的三时机设计保留：

1. 页面启动：探测并启用 Gewu collaboration，然后广播 `hello`。
2. 输入框获得焦点：提前创建 session，然后广播 `session_start`。
3. Send、Clear 或页面退出：结束 session；退出时同时关闭 collaboration。

旧 PR 中的 `XXXXX_*`、固定 `enableCollaboration('{}')` 和“底层自行发现 IP”不再使用。真实接口是：

```text
OH_QoS_GewuEnableCollaboration(coInfo)
OH_QoS_GewuDisableCollaboration()
```

`coInfo` 必须明确给出角色和主设备地址：

```json
{"isMaster":true,"masterIP":"192.168.1.20","masterPort":19090}
```

协作者的协同 session 还必须带主机进程的实时 PID：

```json
"parallel_settings": { "caller": 30206, "is_co": true }
```

PID 每次进程启动都会变化。`30206` 仅是实机示例；实现使用 `process.pid` 动态同步，不从配置读取固定 caller。

## 调用链

```text
Index.ets
  -> CollaborationController
       -> CollaborationBroadcaster (UDP discovery/fallback)
       -> CollaborationControlChannel (collaborator-initiated TCP lifecycle)
       -> SessionBackedModel.prepareSession / closeSession
       -> LlmNativeBinding.enable / disable / supported
  -> libllm.so
  -> libqos.so / gewu_service
  -> KNPU devices
```

App 控制通道只同步生命周期、主机 PID 和本轮 Gewu 端口，不承载模型、Prompt、Token 或推理结果。模型协同链路由 Gewu 运行库建立。Mate 70 热点会限制热点主机主动向客户端发包，因此协作者主动连接主机 TCP 19091，主机沿现有连接返回消息。配置中的 19090 是引导端口；当前实现会为主机进程选择 21000–21999 中的运行时端口，并通过控制通道下发给协作者，避开 Gewu 监听端口关闭后的 `TIME_WAIT/Address in use`。

TCP 19091 上的应用协议还包含 `hello/hello_ack`、`heartbeat/heartbeat_ack`、`runtime_prepare/runtime_ready` 和 `session_start/session_ready/session_end/session_ended`。每条会话消息均带递增 `generation`，迟到消息不能结束新会话。只有握手完成后界面才显示绿色“已连接”；只有协作者成功创建带 `parallel_settings` 的 co-session 并返回 `session_ready` 后，主机才显示“协同会话已就绪”并允许提交模型请求。连接中断或等待就绪超时会阻止推理，不会以主机单机结果冒充协同结果。

Gewu 的协同开关保存在设备侧 `gewu_service`，App 被强停或换签安装后可能遗留 `co is already enabled`。初始化时会 best-effort 清理本机残留。点击“重连”会先安全结束现有 session、重建 TCP 控制通道，并把数据面标为待重建；下次聚焦输入框时主机换到新端口，协作者按握手参数重新注册。

每次主机创建会话前按以下顺序准备数据面：

1. 主机启动一个新进程专属的 Gewu 动态端口；错误恢复时再旋转到下一端口。
2. 主机通过 `runtime_prepare(resetRuntime, masterPort, generation)` 让协作者清理旧数据面并注册到该端口。
3. 协作者完成本地 Gewu 注册后返回 `runtime_ready`，主机再等待资源角色表传播完成。
4. 主机会话创建并确认得到 `0-12/13-27` 分层后发送 `session_start`。
5. 协作者创建 co-session，稳定后发送 `session_ready`；主机收到确认后才执行模型请求。
6. 请求结束后主机发送 `session_end`，协作者排空回调、销毁 session 并返回 `session_ended`；下一轮必须等待该屏障。

不能在主机会话创建后再 disable/enable 任一端，否则会丢失 caller、退化成主机 `0-27` 单机分层，或令协作者 `GetCoSessionInfoByMasterInfo` 返回 401。数据面重建只发生在创建 session 之前，并由同一 generation 的控制握手协调。首轮验证成功后复用资源表；空闲心跳只维持运行库活性。

Native 回调上下文不能在 `abortRequest/destroySession` 返回时立即释放：Gewu 仍可能回送迟到回调。`llm_bridge.cpp` 先把回调标记为 inactive，再将上下文隔离保留到进程退出，避免 `aki::SafetyCallback` 的 use-after-free/SIGSEGV。Prefill 不设置应用侧首响应超时；首个 Native 回调到达后才启动 30 秒流式回调停顿和 600 秒 Decode 绝对上限两级看门狗。30 秒停顿阈值用于识别已开始输出后的数据面卡死，600 秒只作为持续回调却永不结束时的最终保护。推理期间 App 保持前台窗口亮屏。这样不会截断长 Prefill 或仍在正常输出 token 的请求；代价是 Gewu 如果在首回调前永久卡住，需要用户通过清空会话、退出页面或重启服务主动取消。

## 配置

`entry/src/main/resources/rawfile/llm_config.json`：

```json
{
  "useLocalLlm": true,
  "localModelPath": "/data/storage/el2/base/haps/entry/files/model/Qwen2.5-7B-Instruct-Q4_N_0",
  "localModelBackend": "knpu",
  "localModelMaxContext": 2048,
  "localModelRequestType": "qwen2",
  "deterministicSkillRouting": false,
  "localCollaboration": {
    "enabled": false,
    "isMaster": true,
    "masterIP": "192.168.1.20",
    "masterPort": 19090,
    "broadcastPort": 7790,
    "controlPort": 19091
  }
}
```

`deterministicSkillRouting=false` 使用 Loopy 原生 ReAct Skill 选择和 `read` 加载流程；确定性关键词路由只作为显式开启的基准测试配置保留。

- 单机版本保持 `enabled: false`，避免设备栈不匹配时影响普通聊天。
- 主设备使用 `isMaster: true`；从设备使用 `false`，两端构建配置的 `masterIP` 和引导 `masterPort` 应一致。实际 Gewu 端口由主机运行时协商，TCP 19091 控制端口保持固定。
- 当前配置打包在 HAP rawfile 中，因此主、从角色需要分别构建 HAP。后续如需同一 HAP 自动组网，应把角色和主机地址迁移到 App 设置或设备发现结果。

## 回退规则

- `isCollaborationSupported() === false`：不启用协同，普通本地模型仍可用。
- `enableCollaboration()` 非 0：关闭 UDP，普通本地模型仍可用。
- 配置缺少有效 `masterIP` 或端口：不创建控制器。
- UDP 广播失败：TCP 控制通道继续工作；若两者都不可用，则不应宣称协同 session 已建立。
- Mate 60 当前的 `DrvGetL2Info ret 4` 属于设备 Gewu/KNPU 栈问题，不能靠 App 层广播修复。

## 验收

1. 两台设备在同一局域网，安装各自角色配置的 HAP。
2. 两端 `isCollaborationSupported()` 均为 `true`。
3. 启动 App 后无 `enableCollaboration` 错误，协作者成功主动连接主机 TCP 19091，界面显示绿色“已连接”。
4. 聚焦输入框后状态先变橙色，两端都成功 `prepareSession`，主机收到 `session_ready` 并显示“协同会话已就绪，可以发送”。
5. 主端发送 Prompt 后出现 `Action/Observation/Final` 或普通 `Final`，两端 `gewu_service` 均保持存活。
6. 连续三轮请求均出现成对的 token 统计和 `session_ended`；手动重连后下一轮仍成功。
7. 退出页面后调用 `disableCollaboration()`，没有新增 `cppcrash-gewu_service` 或 `cppcrash-com.example.loop`。

## 2026-08-06 实机结果

- 主机：Mate 70 `192.168.43.1`，Loopy PID `61754`；协作者：Mate 70 `192.168.43.4`，Loopy PID `34139`。
- 连续三轮 generation 为 `1/3/5`，重连恢复轮为 `7`；每轮均为主机 `0-12`、协作者 `13-27`。
- 输入 token 分别为 `871/892/906/931`，两端每轮数值一致，并均收到 `session_ended`。
- 首轮主机 prefill/decode 为 `5710.53/3078.26 ms`，协作者为 `5554.07/3087.87 ms`。
- App 回显依次为 `你好！`、`2`、`广州是一座历史悠久、文化繁荣且现代化发展的城市。`，重连后回显 `OK`。
- 四轮后两端 App 与 `gewu_service` 均存活，TCP 19091 仍为 `ESTABLISHED`；没有新增 Loopy/Gewu crash，设备中最近的 Loopy crash 仍是修复前的 `20260806193035187`。
