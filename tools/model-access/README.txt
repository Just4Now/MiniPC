MiniPC 模型权限工具（Windows 10/11 x64）

将整个 MiniPC-Model-Access 文件夹复制到另一台 Windows 电脑即可使用。
已附带 HDC 和所需的 libusb_shared.dll，不需要安装 DevEco 或修改 SDK 路径。
如果使用 ZIP，请先完整解压，不要在压缩包内直接运行 BAT。

使用方法
1. 用 USB 连接算力设备，开启设备调试，并在设备上允许这台电脑连接。
2. 设备需要已有 root HDC 权限，且已安装并打开过 MiniPC 算力应用。
3. 双击 Enable-Access.bat，按显示的设备编号选择。可输入 1,2 选择多台设备。
4. 脚本开启权限并重启选中设备上的算力应用，之后在应用设置中选择模型。

Check-Access.bat：检查权限状态，不重启应用。
Restore-Access.bat：恢复保存的原权限，并重启算力应用。
设备编号自动发现，不固定绑定 Pro 或 Pro S 的序列号。

权限作用
保存原权限，设置 SELinux 为 Permissive，并将现有 NPU、内存驱动节点授权给
当前应用 UID。保留驱动节点原有的组与权限模式，不安装开机策略。
设备重启后需要重新开启。原权限备份保存在设备中，迁移工具文件夹不会丢失备份。
若设备被单独修改过权限，脚本会报冲突，不自动覆盖原权限记录。

模型前提
工具只负责权限，不包含模型权重、HAP、VL SDK 或 GEWU 算子库。
VL、Qwen3.5 需要提前部署与目标芯片及系统配套的模型和运行库。
已验证 Pro S 可以使用对应的配套环境；此前 Pro 使用 Pro S 算子库的测试失败，
单纯开启权限不能解决该兼容问题。无需向工具中复制手机的库。
此处的设备型号结论来自此前测试，不代表工具自动完成模型推理验证。

常见问题
- 没有设备：检查 USB 线、设备调试和连接授权；另一台电脑可能需要安装设备 USB 驱动。
- root 权限不足：请先由设备管理员配置可用的 root HDC 连接。
- 初始化失败后仍不能加载：重新运行 Enable-Access.bat 会重启算力应用。
- 旧版本 HDC 冲突：关闭其他开发工具后重试；本工具不会自动停止其他 HDC 服务。

命令行示例（可选）
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\launch.ps1 -Action Status
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\launch.ps1 -Action Start -Device 设备序列号

hdc 目录保留了 SDK 工具的 NOTICE.txt 和版本信息。
