# Pro 的 Qwen3.5 初始化失败

2026-10-20 15:22，MateBook Pro（3QC0124C20000251，HAD-W32，算力 HAP 1.0.46）选用 Qwen3.5-9B。授权已经生效：SELinux 为 Permissive，三个现有 NPU/heap 节点属于应用 UID 20020179，组和 660 模式保留。

## 已确认的失败链路

1. GEWU 使用应用沙箱模型路径创建 KNPU 会话，运行时接口 major=1、minor=2。
2. `libgewurt_base.so` 加载 `/vendor/lib64/passthrough/indirect/libgewurt_kernel.so` 时，找不到 `binary_op_sub_float_float_launch`。
3. 日志明确写出 `Some CCE kernel symbols failed to load, KNPU backend disabled.` 和 `is_npu_supported_dtype_ptr is nullptr`。
4. `gewu_service` 随后在 `llm::KirinNPU::Context::Context()` 中空指针跳转，SIGSEGV，PC=0。崩溃时间 15:22:23.122，进程 UID 7842，PID 18307。

销毁会话阶段的 `permission denied` 出现在服务崩溃并重启之后，不能把它当成本轮初始化失败的首因。

## 与 Pro S 对照

两台设备的 `libgewurt_base.so`、`libgewurt_runtime.so`、`libgewurt_qw35.so` 和 `libgewusvc_model.so` SHA-256 均一致。但 kernel 不同：

| 文件 | Pro | Pro S |
| --- | --- | --- |
| kernel 字节数 | 630760 | 1019720 |
| kernel SHA-256 | a360862c31ac8f3cc74cd3959ae956b8390723ebb1ae3dc5e1d908e5661f7f23 | eef5cc56bb9e1a5f592fdd38eb3142ef763c7015497afff848de49cef773303c |
| 导出 binary_op_sub_float_float_launch | 无 | 有 |
| 导出 is_npu_supported_dtype | 无 | 有 |

已用 llvm-nm 检查两个设备实际库文件的动态导出。直接故障是新运行库与 Pro 上保留的旧 kernel 接口不配套，不是本次应用驱动授权未生效。

需要提供与当前 GEWU 版本、Pro 芯片及驱动匹配的 kernel。首次定位仅对照接口，未替换系统库、改变模型选择或安装应用；后续授权验证结果如下。

## 授权验证：Pro S kernel 在 Pro 上仍无法完成推理

用户授权后，将 Pro 原库备份到设备 `/data/local/tmp/minipc-kernel-test-20261020-1526/original-kernel.so`，临时替换为 Pro S 的 kernel，校验 SHA-256 为 `eef5cc56bb9e1a5f592fdd38eb3142ef763c7015497afff848de49cef773303c`。没有编译或安装 HAP，重开现有 1.0.46 应用，在本机输入 `1+1=`。

- 缺失算子符号报错消失，运行时识别平台为 `changsha`，`KNPU Standalone Runnable: Yes`。
- 正式应用接口 `create=0`、`submit=0`，打开 `/dev/dma_heap/system_heap` 并进入模型运行初始化。
- 15:29:18.930 报 `[KirinNPU] Captured TASK_FAILURE exception from KNPU runtime.`、`NPU HARDWARE TIMEOUT OR FAULT` 和错误码 `56060020`（`KnpuRtStreamSynchronize`）。
- 服务以 `GEWURT_ERR_EXCEPTION` 未捕获异常退出（SIGABRT，PID 21349）。应用收到空内容、`finish_reason=abort`，没有答案；不是推理成功。

这次验证证明补齐接口只能解决第一层加载问题，Pro S 的 kernel 尚不能在该 Pro 的当前软硬件组合上直接工作。仅凭此日志不能区分具体算子、编译芯片目标或驱动运行时版本问题，也不能据此认定设备物理损坏。

测试结束已恢复原 kernel，SHA-256 再次确认为 `a360862c31ac8f3cc74cd3959ae956b8390723ebb1ae3dc5e1d908e5661f7f23`，所有者/组 root:root、模式 644、SELinux 标签 `vendor_lib_file` 保留，并重新打开应用。权限授权及原 Qwen3.5 模型选择保持原状。首次 HDC 上传将相对本地路径展开为远端目录，替换失败后立即恢复并核对原库，再使用绝对本地路径上传、核验普通文件类型与哈希后完成正式验证。

原始 GEWU 进程日志、应用回调、崩溃转储和内核日志位于 `.hvigor/pro-gewu-2026-10-20/pros-kernel-test-*`。后续需要 Pro 平台适配的 kernel（日志平台 `changsha`），以及提供方确认与当前 GEWU、NPU 驱动运行时的配套关系。

原始日志、崩溃转储和两个 kernel 的只读副本保存在 `.hvigor/pro-gewu-2026-10-20/`。

## 2026-10-21：按用户要求回滚 Harden / Pro

设备仍为 `3QC0124C20000251`。用户确认该机称为 Harden，选择 Qwen2.5-7B 后也在模型加载阶段失败：文件可读，create/submit 成功，但约 0.6 秒返回空内容及 `finish_reason=abort`。当时仍是新增 GEWU 核心库和旧 kernel 混用。

用户要求停止新库测试并还原。以该设备自身只读分区 `/mnt/lower/usr/system`、`/mnt/lower/vendor` 为来源，恢复 15 项原版库和 GEWU 服务配置；5 项新增模块移出加载目录。未使用另一台 Pro 的原库，也未修改权重或模型选择。

文件级回滚已完成，15 项 SHA-256 校验全部通过，但应用推理尚未恢复可用。全原版组合的公开 QoS 路径返回 create=801，日志表明当前系统调用入口加载客户端时要求 `GewuEnableCollaboration`，原版客户端仅导出四个基础接口，没有这个符号。短暂保留更新版客户端验证时，create=0 而 submit/destroy=201，服务端出现调用不对应的记录，不能作为兼容组合。该尝试已经撤回，最终客户端也恢复为原版 158688 bytes。不能把文件恢复等同于 7B 已经运行成功。

最终设备保持全部原版 GEWU 文件、Qwen2.5-7B 选择，应用已经重开。后续需要找到此前可用的配套 QoS/GEWU 接口版本，或单独处理现有系统入口与原服务的兼容性；本次未为此修改或编译 HAP。

回滚前文件、原版快照、移出的新增模块和校验清单保存在设备 `/data/local/tmp/minipc-gewu-restore-20261021-1208/`，本机另存完整备份 `.hvigor/harden-qwen2-2026-10-21/gewu-rollback-backup.tgz`。诊断记录及恢复脚本位于同一本机目录。
