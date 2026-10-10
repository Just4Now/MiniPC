# 测试

## 运行入口

从仓库根目录运行：

```powershell
$env:TYPESCRIPT_PATH = '<TypeScript 模块目录或 typescript.js 的路径>'
node scripts/test-all.cjs all
```

可选范围：

| 参数 | 执行内容 |
| --- | --- |
| all | 所有根级入口 |
| agent | agent_core 套件、算力端及近场验证客户端测试 |
| legacy | src 基础聊天端与算力端测试 |
| protocol | loop-minipc JavaScript 参考实现测试 |

测试入口见 [scripts/test-all.cjs](../scripts/test-all.cjs)。它调用现有测试，agent_core 的 run-all 内部还有子套件；根级入口数量不能当作独立行为用例总数。

## 编译依赖

测试需要可用的 TypeScript。统一入口通过 TYPESCRIPT_PATH 将编译器路径传给子进程。旧 src helper 还支持 MINIPC_TYPESCRIPT；不同单独入口的查找顺序以其实现为准。

可单独运行：

```powershell
node loop-chat/agent_core/tests/run-all.cjs
node loop-minipc/scripts/test-all.cjs
```

部分 ETS 测试用平台声明/提供方桩转译实际源码。Index 生命周期测试执行提取的方法，不编译 ArkUI 渲染 DSL。它们不能代替 SDK 全工程编译。

## 覆盖内容

- 工具 schema、注册权限、调用关联、缓存、并行、取消和超时。
- ReAct 输出解析、需求账本、最终综合、partial 历史和页面代次。
- 子任务拆分、汇总、独立 owner 取消与共享写操作串行化。
- 消息组包、序号/字节/hash 校验、预算及接受前等待。
- 中心选举、成员清单、转发映射、节点丢失和迟到回调。

当前回归使用受控模型、平台及网络边界，不提交真实外部操作。

## SDK 与设备

SDK 构建入口见 [构建与运行](build-and-run.md)。平台类型检查通过与模型文件、Native 库、权限或设备运行库可用是不同条件。

设备检查应覆盖模型就绪、完整工具任务、多个独立请求、取消后新任务、断链后恢复及中心接管。结果需核对实际工具证据和最终展示，不把任务卡片的一次模型完成当作整轮完成。

自然语言完整性依赖模型；受控回归和编译不证明任意问法都正确，也不证明所有硬件组合都能获得并行加速。
