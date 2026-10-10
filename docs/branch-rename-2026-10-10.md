# 迁移分支改名记录

日期：2026-10-10。用户要求分支名称不带 codex 前缀；新名称为 `integrate-agent`。

1. 确认工作区干净，旧本地/远端分支都是 `91e3563cfb0e1edf8b0bf929e2f3f95c59362113`；新远端分支不存在，原 PR #1 为 Draft，目标 main。
2. 保存原 PR 说明到忽略的 `.validation/rename-pr-body.md`，使用 GitHub 原生改名接口：
   ```powershell
   gh api --method POST repos/Keanu2/MiniPC/branches/codex%2Fintegrate-agent/rename -f new_name=integrate-agent
   ```
   返回新分支 integrate-agent，提交仍是 91e3563；原远端分支已消失，没有重写历史或合并 main。
3. 改名并重新设置本地跟踪关系：
   ```powershell
   git branch -m integrate-agent
   git fetch origin --prune
   git branch --set-upstream-to=origin/integrate-agent integrate-agent
   ```
   fetch 使用系统已有代理的单命令参数，未修改全局 Git 或代理配置。旧 origin/codex/integrate-agent 跟踪引用已清理。
4. GitHub 改名来源分支会关闭以它为来源的开放 PR，官方说明见 [Renaming a branch](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-branches-in-your-repository/renaming-a-branch)。改名后检查 PR #1 状态，保留其讨论和提交记录，不执行合并。为新来源分支创建 [草稿 PR #2](https://github.com/Keanu2/MiniPC/pull/2)，base=main，head=integrate-agent。
5. 更新 README 的当前分支、当前 PR 和后续命名要求。在迁移/同步记录开头增加改名提示，保留历史已执行命令和旧 PR 作为审计记录；查看基线后回到开发分支的示例改用新名称。更新本聊天的 PR 附件为 #2。
6. 只提交上述文档调整并推送新分支。检查新分支包含原全部提交、工作区干净、PR #2 保持 Draft、main 仍为 7f04edd，且远端没有旧分支。

本次未修改应用代码、构建配置、版本号或安装包；前一轮 29/29 回归和双端 SDK 构建记录继续适用，无需为分支改名重复执行。今后在 `D:\MiniPC-integrate` 使用 `integrate-agent` 分支；其他代码仓库及其分支名称未变。
