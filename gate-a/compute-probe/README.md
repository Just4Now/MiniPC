# 算力端

`NearbyConfig.ets` 里 `IS_SERVER = true`。打开是仪表盘，能看到谁连上来了、哪条任务在跑。底部也能自己打字提问。

组网和选点规则在仓库根目录的 [README.md](../../README.md)，版本变化在 [CHANGELOG.md](../../CHANGELOG.md)。

这台机会 BLE 广播 manufacturer `0x6E77`、type `1`；组网确定编号后更新广播。聊天机只连接算力设备1，由它统一收发和调度。算力设备2等执行节点只与设备1保持算力链路，不接普通聊天请求。设备1收到不带 `sched` 的 `request` 时，`pickNode` 按空闲路数和可用内存在集群里选执行机。派出去的请求带 `sched=true`，对面必须自己跑。本机可以同时开多路 GEWU，CreateSession 失败才回「模型繁忙」。底部输入框还是一次一路。

1号停用后，存活算力里排名最靠前的一台在至少15秒、连续三次成功扫描都未见原中心时接管；短暂断链或仍能扫到原中心时不接管。后加入的算力不自己占「2号」，等中心按安装 UID 编号。

空闲时，内存、温度、CPU 和正在跑的路数每 2 秒轻量同步。成员变化由中心立刻发给其他算力：推理中只发精简名单，空闲时发完整清单，没变化则 30 秒保底。聊天机不收这份集群清单。聊天设备由当前中心按安装 UID 编号。标题会显示自己是第几号。任务标题是「聊天设备N  由算力设备N推理」。也可以附图，同样只显示在任务卡上。点「停用近场」会关掉广播。

平时选点是 `pickNode`。底部输入 `__route_auto__`、`__route_split__`、`__route_pin1__`、`__route_pin2__` 只用于对照实验，默认仍是自动。

聊天端的 Agent 模式和普通聊天使用 `infer.*` 链路。该链路优先选空闲设备；全部在跑时，继续在负载最低的可用设备上开启独立 Gewu Session，不再按每台一路拒绝请求。请求按来源连接和请求编号隔离输出、取消、错误与任务卡，断开一个来源只停止它的请求。原生启动失败仍按实际错误返回；仪表盘的空闲数继续表示没有在跑请求的设备数量。

推理开始/结束会向算力同伴推送小型 `deviceInfo` 消息（模型名和正在生成的路数），忙时也每 2 秒刷新；完整内存、温度等遥测仍让位于推理。完整的 `stream:false` 回答到达后立即发送终态和结果，原生 Session 清理、缓存释放单独收尾，不计作仍在生成。任务卡异常也不会阻断协议回包。

退到后台不再主动断开近场，也不再取消正在运行的推理。聊天端与算力端在存在实际连接时申请系统的 `multiDeviceConnection` 后台长时任务（系统可能显示后台任务通知），最后一个连接断开或 Ability 销毁后释放。前台扫描在后台暂停，现有链路仍可回传结果；窗口常亮仅在前台生效。后台任务申请失败会记录到 `NearbyChat` 日志，返回前台时允许重试。相关系统要求见 [HarmonyOS 长时任务说明](https://developer.huawei.com/consumer/cn/doc/harmonyos-references-V14/js-apis-resourceschedule-backgroundtaskmanager-V14)。

性能对比使用相同输入、输出上限及预热状态，先检查 `NearbyChat` 的 `infer route` / `infer begin` 请求编号和设备，再比较生成耗时及整批任务完成时间。卡片数量、过期的负载统计或各卡耗时相加不能证明两台设备在共同执行。

模型放在 `filesDir/models/Qwen2.5-7B-Instruct-Q4_N_0`，要有 `api_config.json`、`params`、`tokenizer.json`。backend=knpu，max_ctx=2048。输入大约 1000 字，单次 `max_tokens=256`。多台聊天机可以一起问；历史最多留 3 轮（6 条消息）且合计不超过 1800 字，只在这次运行里保留。

源码在 `entry/src/main/ets`。选点看 `cluster/ComputeRouter.ets`，页面在 `pages`。

模型不打进 HAP。编译：

```bat
set JAVA_HOME=D:\MiniPC\tools\jdk\jdk-17.0.20.1+1
set DEVECO_SDK_HOME=D:\command-line-tools\sdk
D:\command-line-tools\hvigor\bin\hvigorw.bat --mode module -p module=entry@default -p product=default assembleHap --no-daemon
```

选点测试是 `cluster/ComputeRouter.test.cjs`。
