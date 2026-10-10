# Agent 上游同步记录：c9afb30

日期：2026-10-10（Asia/Shanghai）。工作目录 `D:\MiniPC-integrate`，分支 `codex/integrate-agent`，现有草稿 PR [MiniPC #1](https://github.com/Keanu2/MiniPC/pull/1)。此次同步保持 MiniPC main 与基线 tag 不变。

## 来源与范围

- 同步前迁移分支：`bb0358b49f44d3d177ebe3649c51430e0b450d72`。
- 上次 Agent 来源：`ff76d8d1a90b6bb3cb1bb5431238bdc662b3c6ba`。
- 本次来源：`c9afb306f67d619a2cf2e9ba4791611ffd5dccae`，GitHub Agent-MiniPC master 最新提交，父提交为 ff76d8d。
- 版本：聊天端 1.2.16，算力端 1.0.19。

上游变更共 5 个文件：双端 AppScope 版本、双端 Index 页面及 Agent 页面生命周期测试。聊天端增加本次任务总耗时，耗时只用于显示、不进入模型对话历史；算力端完成任务卡上限由 8 改为 40，避免较长并行任务的卡片很快被挤出。

## 实际操作

1. 检查新检出的 `git status --short`、分支、远端和现有 PR；工作区没有未提交改动。
2. 普通 HTTPS Git 连接暂时失败，先读取本地 Agent 已提交内容：
   ```powershell
   git fetch D:\Agent-MiniPC master:refs/remotes/agent/local-master
   git diff --stat ff76d8d..agent/local-master
   git diff ff76d8d..agent/local-master
   ```
   本地未跟踪文件没有复制。随后 `gh api repos/Keanu2/Agent-MiniPC/commits/master --jq '.sha'` 确认远端也是 c9afb30。
3. 合并更新：
   ```powershell
   git merge --no-ff --no-commit agent/local-master
   git diff --name-only --diff-filter=U
   ```
   自动合并成功，无冲突。无需再次使用 allow-unrelated-histories，因为上次导入已建立共同历史。保留之前的无签名构建配置、CRLF 测试兼容和早期客户端测试桩。
4. 确认系统已有且启用的本机代理 `127.0.0.1:7897`。只在单条 Git 命令上使用 `-c http.proxy=http://127.0.0.1:7897`，随后正式 fetch 两个 GitHub 远端并验证来源一致：
   ```powershell
   git -c http.proxy=http://127.0.0.1:7897 fetch agent
   git -c http.proxy=http://127.0.0.1:7897 fetch origin
   git diff --quiet agent/master agent/local-master
   ```
   比对返回 0。没有更改全局 Git 配置、系统代理或远端地址。
5. 更新 README 当前版本、根 CHANGELOG 的上游同步说明，并将此记录链接追加到首次迁移文档；首次导入的提交和验收记录保留为历史，不改写。
6. 使用统一入口执行现有回归：
   ```powershell
   node scripts/test-all.cjs all
   ```
   **29/29 根级入口通过**，包含 Agent 内部 11/11 套件及 3 组严格类型检查。日志 `.validation/sync-c9afb30-regression.log`。
7. 使用已配置的本机 SDK/JDK/hvigor 构建两个发生变化的工程：
   ```powershell
   .\scripts\build-hap.ps1 -Target agent-chat
   .\scripts\build-hap.ps1 -Target agent-compute
   ```
   两个工程 CompileArkTS、PackageHap、PackingCheck、assembleHap 全部成功，生成 unsigned HAP，未安装到设备。日志 `.validation/sync-c9afb30-build-agent-chat.log`、`.validation/sync-c9afb30-build-agent-compute.log`。旧 MiniPC src 未变，因此不重复编译旧双端；其测试仍在本轮全量回归中运行。
8. 检查 staged diff、原 MiniPC src 与基线一致，以及 Agent 业务源码与 c9afb30 一致；生成同步合并提交并正常推送到 `origin/codex/integrate-agent`。现有草稿 PR 自动包含新提交，并更新说明。没有创建新的发布 tag、强制推送或合并 main。

## 本次构建包核对

| 包 | SHA256 |
| --- | --- |
| Agent 聊天端 1.2.16 | `000495383F2B57170FFC55E2ECE69F0504D9FE4D78D0A3770B8816737CF5783B` |
| Agent 算力端 1.0.19 | `0CC8A837877CA31A3EAB3A993FCDA43AD591AC2FA5B7540D6C12ABE8E649CC25` |

包、日志、依赖和本机 SDK 不入库。此同步没有新增业务修补，仅引入上游变更及同步文档。原 MiniPC main 仍为 `7f04eddd484d9f665b008177d5d44c153e74d5af`；基线 tag 保持原目标。具体同步提交可从本分支最近的双父提交追溯，上游 c9afb30 保留为祖先。物理设备验收仍未在此轮执行，草稿 PR 保持 Draft。
