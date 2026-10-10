# Agent-MiniPC 迁入 MiniPC：逐步操作记录

日期：2026-10-10（Asia/Shanghai）。独立工作目录：`D:\MiniPC-integrate`。此记录用于迁移分支，目标是保留版本基线与历史、建立可复现入口，暂不合入 `main`。

## 1. 核对仓库、分支和当前工作区

执行 `git remote -v`、`git status --short`、`git log -1 --oneline`、`git rev-list --max-parents=0 --all` 和 `git ls-remote --heads --tags origin`。

| 来源 | 分支 | 导入时提交 |
| --- | --- | --- |
| Keanu2/MiniPC | main | `7f04eddd484d9f665b008177d5d44c153e74d5af` |
| Keanu2/Agent-MiniPC | master | `ff76d8d1a90b6bb3cb1bb5431238bdc662b3c6ba` |

两条 Git 历史没有共同祖先。MiniPC 根提交是 `94038f3c53771ab839b659659ada8df4acfc5a57`，Agent 根提交是 `98562099d585b09a4a2fca96a5f8a9aa7da26885`。Agent 从重新导入开始记录，不是原 MiniPC 分支的直接后代。

MiniPC 当前 `main` 比 `v0.4-hub` 多一个文档提交：`7f04edd`。比较 `git diff --name-status v0.4-hub..HEAD` 后确认，程序源码相同，仅 README、CHANGELOG 和其他文档有变化。原工作区有未跟踪文件，因此不在那里操作，也不执行 `git add .`。

## 2. 创建独立检出

```powershell
git clone https://github.com/Keanu2/MiniPC.git D:\MiniPC-integrate
```

克隆成功，检出原 MiniPC `main`。Git 提交身份只配置在这个新仓库：`Keanu2 <60291681+Keanu2@users.noreply.github.com>`，与原提交一致；没有修改全局 Git 配置。

## 3. 固定并发布合并前快照

```powershell
git tag -a minipc-before-agent-20261010 -m "MiniPC baseline before Agent integration" 7f04eddd484d9f665b008177d5d44c153e74d5af
git push origin refs/tags/minipc-before-agent-20261010
```

已发布 annotated tag。tag 对象为 `9c5178985f2086c99c86c30e7788dcfc1fa0d9ae`，目标提交为 `7f04edd`。原有 `v0.2-nearfield`、`v0.3-cluster`、`v0.4-hub` 未移动。

## 4. 创建迁移分支并读取 Agent 历史

```powershell
git switch -c codex/integrate-agent
git remote add agent https://github.com/Keanu2/Agent-MiniPC.git
git fetch agent
```

`origin` 继续指向 MiniPC，`agent` 只是导入来源。`fetch` 读取 Agent 提交和 tag，不修改远端。它带入的本地 `v1.1.16` tag 不作为 MiniPC 新版本发布，也不使用 `git push --tags`。

## 5. 合并独立历史，暂停在提交前

```powershell
git merge --allow-unrelated-histories --no-commit --no-ff agent/master
```

产生 `.gitignore`、`CHANGELOG.md` 两个 add/add 冲突，其他目录正常导入。冲突退出码 1 表示需要人工解决，不代表导入失败。`--allow-unrelated-histories` 用于无共同祖先的仓库；`--no-commit` 留出审查时间；合并提交保留两个父节点。

## 6. 逐项解决冲突

- `.gitignore` 合并两边规则：保留 MiniPC 对 SDK、签名材料、包、缓存的忽略，也保留 Agent 对依赖、日志和设备转储的规则。
- 根 `CHANGELOG.md` 保留 MiniPC 历史，增加迁移分支 Unreleased 说明。
- Agent 原版本记录完整保存为根 `CHANGELOG.agent.md`，使其 `docs/...` 相对链接继续有效。

执行 `git add .gitignore CHANGELOG.md CHANGELOG.agent.md`，再执行 `git diff --name-only --diff-filter=U`，确认无未解决冲突。

全量 `git diff --cached --check` 检测到导入源码及第三方 AKI 中既有的空白问题。没有在迁移提交里批量格式化这些代码；冲突处理文件单独执行该检查并通过。这个初次全量检查不是成功记录。

## 7. 生成可追溯的历史合并提交

```powershell
git commit -m "Import Agent-MiniPC into migration branch"
```

提交：`a7b1dd74c9742ac007bf769fac50ab74182fbade`。两个父提交依次为 MiniPC `7f04edd` 和 Agent `ff76d8d`。

在此提交上执行：

```powershell
git diff --quiet HEAD^1 HEAD -- src
git diff --quiet HEAD^2 HEAD -- loop-chat gate-a loop-minipc
```

两个检查均为 0：原 MiniPC `src` 和导入的 Agent 工程完全保留，没有相互覆盖。应用导入版本为聊天端 1.2.15（1000086）、算力端 1.0.18（1000018），不是旧文档中的 1.2.12/1.0.16。

## 8. 整理开发入口和本机配置

根 README 增加新旧目录职责、统一测试/构建命令、版本基线和待验收边界，同时保留原 MiniPC 说明作为对照。项目暂不搬迁，不将目录调整混入历史合并。

新增：

- `scripts/test-all.cjs`：聚合两个仓库已有回归；支持 all、legacy、agent、protocol。
- `scripts/build-hap.ps1`：显式选择 agent-chat、agent-compute、legacy-chat、legacy-compute；SDK 和 hvigor 路径来自环境变量/参数。
- `.validation/`：忽略的本地日志、工具别名目录。日志不进 Git。

`loop-chat/build-profile.json5` 移除指向个人证书路径的 signingConfigs 及产品 signingConfig，其余构建配置保留。默认生成 unsigned HAP；安装设备时由使用者配置自己的签名。未读取或复制签名私钥。

AGenUI HAR 原本被忽略，fresh clone 不含该依赖。本次使用已有 `D:\Agent-MiniPC\loop-chat\libs\agenui.har`，SHA256 为 `1D879A003ABBA4BC715A2D09026204274DD1AD984F8C305C1DE67D20001AB4BC`，复制到新检出的忽略目录供本地构建。构建脚本支持 `AGENUI_HAR` / `-AgenuiHar`，也可用已有 fetch-agenui.sh 获取。没有把 HAR、模型权重、SDK、私钥或安装包加入提交。

命令行 SDK 的 hvigor 插件在 Node 默认搜索路径之外。初次构建仅完成 ohpm，随后报 Cannot find module `@ohos/hvigor-ohos-plugin`。脚本在忽略目录生成指向本机 SDK 包的 junction，并在构建子进程使用 NODE_PATH；结束后恢复环境变量。没有把 SDK 复制或提交进仓库。

## 9. 回归首次失败与修正

首次 `node scripts/test-all.cjs all` 为 **26/29**，失败原因如下：

| 失败入口 | 原因 | 修正 |
| --- | --- | --- |
| Agent index-lifecycle | 按 LF 行末寻找方法，fresh clone 的 CRLF 导致找不到结束 | 仅在测试读取源码时统一换行 |
| 早期 loop-client LinkEnhanceChannel | 提供方新增 CoreFileKit，测试没有该 mock | 增加受控 fileIo 桩，不写真实设备文件 |
| 早期 loop-client IndexFocus | 测试 channel 缺少 recordGateFailure/runGateSuite | 补齐对应受控接口 |

原 MiniPC `src/tests/harness.cjs` 已经入库。核对时尝试复用导入 helper 后撤回，最终保留原 MiniPC helper；`git diff --quiet -- src` 为 0。没有为迁移改变旧 MiniPC 的业务源码，也没有删除或跳过失败套件。

用户中途继续任务时，前一轮执行会话已失效，日志没有最终完成标志；确认没有测试/构建进程运行后重新执行，不能把中断记录当作通过。

## 10. 最终验证

最终结果：

| 检查 | 结果 | 日志 |
| --- | --- | --- |
| `node scripts/test-all.cjs all` | 29/29 根级入口通过，含 Agent 内部 11/11 套件、3 组严格类型检查 | `.validation/regression.log` |
| Agent 聊天端 1.2.15 | SDK CompileArkTS、PackageHap、PackingCheck、assembleHap 成功 | `.validation/build-agent-chat.log` |
| Agent 算力端 1.0.18 | SDK 编译、打包检查成功 | `.validation/build-agent-compute.log` |
| 原 MiniPC 聊天端 | SDK 编译、打包检查成功 | `.validation/build-legacy-chat.log` |
| 原 MiniPC 算力端 | SDK 编译、打包检查成功 | `.validation/build-legacy-compute.log` |
| 两边提交都可从迁移分支追溯 | merge-base --is-ancestor 对两个来源均返回 0 | Git 历史 |
| 原 MiniPC src 内容 | 与合并前 tag 相同，diff 返回 0 | Git 比对 |
| Agent ETS/C++/头文件及协议参考业务源码 | 与 agent/master 相同，diff 返回 0；本轮只改构建配置、测试和文档 | Git 比对 |
| 统一入口语法 | Node check 和 PowerShell Parser 检查通过 | 本地命令 |

四个本地 unsigned HAP 的 SHA256（安装包未提交）：

| 工程 | SHA256 |
| --- | --- |
| Agent 聊天 | `621DCCC23F458AEAFAEB8576226760678E70EC300D98E7797EFC0688D1E86231` |
| Agent 算力 | `46AC7233A8AAE322E1E906FCE8B0CC74BAE49DE5334399D7CA5C866D1A6BEDA5` |
| 原 MiniPC 聊天 | `1BB13251382F0EEF3847EA668C291E27C0FFE64F0F283C547199AF91D0B2D4DE` |
| 原 MiniPC 算力 | `6D2D2D451ACE91E39A13DB1A188D9EDB346D86D22018E192642EA7B6AC955B65` |

构建使用本机 JDK 17、SDK 命令行工具与已有 HAR；预期出现 No signingConfig 警告，并有原工程既有 API 权限、可抛异常等 SDK 警告。此次没有签名或安装设备。受控回归、编译及 hash 核对不能代替实际多物理设备验收。

## 11. 分支发布与审查

构建入口、测试适配和此记录另作提交，发布命令如下；实际提交与 PR 地址记录在本文末尾。

```powershell
git commit -m "Add migration documentation and reproducible validation entry points"
git -c push.followTags=false push -u origin codex/integrate-agent
gh pr create --repo Keanu2/MiniPC --base main --head codex/integrate-agent --draft --title "Import Agent-MiniPC on an integration branch" --body-file .validation/pr-body.md
```

发布只针对该分支，不强制推送，不发布全部本地 tag。草稿 PR 用于迁移审查，不执行 main 合并。Agent-MiniPC 原 master 不修改。

## 12. 回到旧版本与下一阶段

在本迁移检出没有未提交修改时，可查看基线：

```powershell
git switch --detach minipc-before-agent-20261010
# 查看完成后回到迁移分支
git switch codex/integrate-agent
```

当前 `main` 未变，因此无需回滚主线；合并前完整代码与文档由 tag 保留。原两个工作目录的未跟踪文件没有复制进新仓库，也没有清理。

合入主线前还需要：原 MiniPC 选举/接管/编号/路由与新 Agent 功能对照、实际双端和多算力任务测试、取消/断链恢复、评估是否统一共享协议与项目目录。此次引入现有并行/中继代码，不声称已经在迁移分支重新验证多物理设备加速，也不为 Qwen 的特定问法添加规则。旧乱码问题按此前用户要求不处理。

## 13. 已发布结果与最终核对

- 历史导入提交：`a7b1dd74c9742ac007bf769fac50ab74182fbade`。
- 文档、构建入口和测试适配提交：`b139c4953c15ec4964f5a3a953877fdcd7271c31`。
- MiniPC 远端分支：[codex/integrate-agent](https://github.com/Keanu2/MiniPC/tree/codex/integrate-agent)。
- 合并前 tag：[minipc-before-agent-20261010](https://github.com/Keanu2/MiniPC/tree/minipc-before-agent-20261010)。
- 草稿 PR：[Keanu2/MiniPC #1](https://github.com/Keanu2/MiniPC/pull/1)，base=`main`，head=`codex/integrate-agent`，状态 OPEN / Draft。没有执行 PR 合并或发布稳定版本。
- 发布后 `git ls-remote` 核实 MiniPC main 仍为 `7f04eddd484d9f665b008177d5d44c153e74d5af`，Agent-MiniPC master 仍为 `ff76d8d1a90b6bb3cb1bb5431238bdc662b3c6ba`。

此发布记录单独提交并推送：

```powershell
git add docs/agent-integration-2026-10-10.md
git commit -m "Record published integration branch and draft review"
git -c push.followTags=false push origin codex/integrate-agent
```

后续继续开发请使用 `D:\MiniPC-integrate` 的 `codex/integrate-agent` 分支。原 `D:\MiniPC`、`D:\Agent-MiniPC` 工作区保持原分支及未跟踪文件。该记录对应“独立迁移分支 + 待验收后合入主线”的阶段成果，不代表已经统一所有运行时协议或完成真机兼容验收。
