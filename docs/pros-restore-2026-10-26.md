# 新 Pro S 环境恢复（2026-10-26）

目标设备：`7QB0126509000223`，MOR-M1，OpenHarmony-7.0.0.113。算力端保持现有 1.0.48 HAP，应用 UID 为 20020177。本次没有重新编译或安装 HAP。

## 恢复结果

已部署并在实际算力 HAP 内验证：

| 模型 | 验证 | 结果 |
| --- | --- | --- |
| Qwen3.5-9B-Q4_N_0_G128 | 输入 `1+1=`，系统 GEWU、knpu、max_ctx=32768 | 返回 `1+1=2`；create/submit/destroy 均为 0；finish_reason=stop；约 3.4 秒 |
| Qwen-2.5-vl-3B-instruct-Q4_N_0_G128 | 系统图片选择器附加已知狗图片，提问“只回答图片中的动物名称。” | 返回“狗狗”；实际任务耗时 6.129 秒，首字 2.916 秒；应用内 SDK chat rc=0 |

VL 首次默认“请描述这张图片。”也识别出狗，但后续出现大量重复文字，至 512 上下文结束：任务耗时 56.222 秒，输出 608 字。模型可加载和推理不等于长回答质量已解决；本次未修改应用或 SDK 来修复这一问题。

默认模型已切回 Qwen3.5-9B，可在算力端“设置 → 当前模型 → 应用选择”切换到 VL。原 Qwen2.5-7B 目录保留。当前手动选模会限制本机能力：Qwen3.5 用于文字，VL 用于带图请求。没有将本次结果表述为长上下文、多请求并发或远端 Agent 全链路验收。

## 配套运行库与重启

用户提供的完整包位于设备：
`/data/local/tmp/MOR_SO_2026_10_26`。

按包内提取脚本的目录映射部署 23 项运行库（19 项原有文件、4 项新增文件），包括系统 GEWU 客户端/服务/模型模块、QoS、1.2 代理与服务、Qwen3.5 模块、配套基础库及 changsha kernel。全部安装后 SHA-256 校验通过，设备重启后再次通过。

关键一致性：

- `libgewusvc_model.so`：`2789d39c4fedcd75ad37f5298b8b8b9e626cc5d2f597c82227e716d1d65d51f1`。
- changsha `libgewurt_kernel.so`：`eef5cc56bb9e1a5f592fdd38eb3142ef763c7015497afff848de49cef773303c`。
- 与旧 Pro S 成功记录一致。

首次原位替换后，应用可见新库，而 GEWU 服务的挂载视图仍为旧库，造成 create=0、submit/destroy=201。重启 MOR 后服务加载了同一套新库；模型类型识别正常。没有为解决此问题改用内部模型工厂接口。

包中的 `gewu_service.cfg` 和两个 softbus 权限 JSON 已备份，但本次没有替换这些权限配置。

## 临时运行权限

设备重启后恢复 Enforcing 与默认驱动所有者，Qwen3.5 的权重 mmap 被拒绝。用户另行明确同意恢复旧机的临时权限方案后，已通过现有脚本开启：

```powershell
& D:\Agent-MiniPC\scripts\vl-app-access.ps1 -Device 7QB0126509000223 -Action Start -RestartApp
```

当前为全局 SELinux Permissive；四个节点仅将所有者改为当前算力应用 UID，保留原组与 660：

- `/dev/npu0`
- `/dev/npu_manager`
- `/dev/dma_heap/system_heap`
- `/dev/dma_heap/npu_device_hugepage_heap`

配置持续至 Stop 或设备重启，没有新增开机放宽策略。重启后要再次运行上面的 Start；重装应用导致 UID 改变时，应先 Stop 再 Start。通常仅重启应用不需要重新授权。

查看与恢复原权限：

```powershell
& D:\Agent-MiniPC\scripts\vl-app-access.ps1 -Device 7QB0126509000223 -Action Status
& D:\Agent-MiniPC\scripts\vl-app-access.ps1 -Device 7QB0126509000223 -Action Stop -RestartApp
```

Stop 会恢复本次启动保存的 Enforcing 和节点原所有者，现有私有模型路径的推理可能随之不可用。状态保存在设备 `/data/local/tmp/minipc-vl-app-access/state`；脚本会归档旧启动状态，不重放旧 inode 权限。

## 模型与备份

模型位于应用 `files/models/`。目录 700、文件 600，所有者/组为当前应用 UID/GID；文本模型使用仓库的 `configs/models/qwen3_5/api_config.json`，文件名为下划线版本 `api_config.json`。VL 使用应用 SDK 生成配置，权重布局为 `vl_params + tokenizer.json`。

四个大文件源/目标 SHA-256 一致：

| 文件 | SHA-256 |
| --- | --- |
| Qwen3.5 params | `ebba60e999ad9b2f7c0666219181872af31c9a2c163393643c60783c9a328e54` |
| Qwen3.5 tokenizer | `5f9e4d4901a92b997e463c1f46055088b6cca5ca61a6522d1b9f64c4bb81cb42` |
| VL vl_params | `b6dfadfa0c7e3405b7e7d6831f56660ff8c763345ea26e9f4aebd420fb472ae0` |
| VL tokenizer | `c0382117ea329cdf097041132f6d735924b697924d6f6fc3945713e96ce87539` |

设备备份和安装/回滚材料：
`/data/local/tmp/minipc-pros-restore-20261026/`。

开发机副本和验收证据：
`D:\Agent-MiniPC\.hvigor\pros-restore-2026-10-26\`，包含：

- `original-runtime.tgz`：原系统库与配置备份，SHA-256 `ed81e3eeb6b657e592f7c39b08fd0f86f2ada68fab7626a7426a81177fdef62a`。
- `runtime-map.txt`、`before.sha256`、`before-metadata.txt`、`installed.sha256`。
- `install-runtime.sh`：安装/回滚脚本；校验设备、源文件、原备份与当前目标，拒绝覆盖第三方改动。回滚可跨设备重启；脚本语法已检查，本次未执行破坏性回滚演练。
- `qwen35-after-access.jsonl`：真实 HAP 的成功文本推理日志。
- `vl-app-preflight.txt`、`vl-app-ets.txt`、`vl-short-detail-ui.json`：真实 HAP 的 VL 日志和“狗狗”回答。
- `package/`：用户提供 SO 包的本地副本。

回滚系统库时，在系统可写且现有库仍与本次版本/原备份匹配的前提下：

```powershell
$hdcPath = 'D:\command-line-tools\sdk\default\openharmony\toolchains\hdc.exe'
& $hdcPath -t 7QB0126509000223 shell 'sh /data/local/tmp/minipc-pros-restore-20261026/install-runtime.sh rollback'
```

回滚原运行库后 Qwen3.5 将失去本次新增的支持。系统服务若仍保留旧挂载视图，应重启设备；重启也会恢复默认权限。

诊断时临时关闭的 hilog 隐私格式已经恢复开启。媒体库保留一张本次导入的已知狗图片，文件名 `minipc-restore-dog-20261026.jpg`，便于复测。
