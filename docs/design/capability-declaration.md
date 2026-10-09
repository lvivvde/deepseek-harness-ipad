# 能力声明：首个兼容范围（#17）

每项能力在任务开始前，都按固定路径执行：

- `native`：在 App 内原生执行，不需要 Linux。
- `linux`：在本项目的 Linux 插件里执行。
- `unsupported`：不提供。

路径一旦确定，就不会改用另一条路径重跑。App 读取 `LinuxPlugin.declaration(project:)` 并显示给用户；下表与代码中的 `CapabilityDeclaration.scope` 一一对应，由 `LinuxPluginTests.testCapabilityDocumentMatchesTheDeclaredScope` 检查。

## 范围

| 能力 | 路径 | 说明 |
| --- | --- | --- |
| `session` | `native` | 官方 Worker 的会话、模型 Agent 与检查点 |
| `fs.read` | `native` | 官方 read 工具，经网关读原生工作区 |
| `fs.write` | `native` | 官方 write 工具；租约期间保存为草稿 |
| `fs.edit` | `native` | 官方 edit 工具；租约期间保存为草稿 |
| `fs.search` | `native` | 官方 glob、grep 工具，按 ripgrep 语义原生实现 |
| `git.read` | `native` | 原生只读 Git 子集，与系统 `git` 差分测试一致；超出子集以退出码 128 拒绝 |
| `review` | `native` | 变更摘要与审阅 |
| `drafts` | `native` | 草稿与冲突的查看、应用和丢弃 |
| `shell` | `linux` | 整段 shell、管道、安装脚本和依赖外部命令的程序 |
| `subprocess` | `linux` | 官方工具派生的子进程 |
| `hook.command` | `linux` | 运行外部命令的 hook |
| `git.write` | `linux` | 一切会修改仓库的 Git 操作，包括 commit、checkout 和 push |
| `workspace.fifo` | `unsupported` | 9P 共享模式 `none` 不能在 Linux 挂载的原生工作区里创建 FIFO |
| `workspace.unix-socket` | `unsupported` | 同上，不能创建 Unix socket |

需要 FIFO 或 Unix socket 的工具，改用 guest 内的私有路径（如 `/tmp`），而不是原生工作区。做不到的，就按上表声明为 `unsupported`。

## 当前是否可用

声明除路径外还带插件状态，以及每一项当前是否可用：

| 插件状态 | 何时 | `linux` 项 |
| --- | --- | --- |
| `NOT_ENABLED` | 项目未启用插件，且 Linux 可用 | 不可用，原因 `LINUX_PLUGIN_NOT_ENABLED` |
| `PREPARING` | 准备中 | 可用，任务等待就绪 |
| `READY` | 就绪 | 可用 |
| `FAILED` | 准备失败或 VM 退出 | 不可用，原因 `LINUX_PREPARE_FAILED` 或 `LINUX_VM_EXITED` |
| `UNAVAILABLE` | 私有符号缺失（无论项目是否启用插件），或 Linux 已绑定到另一个项目 | 不可用，原因 `LINUX_PRIVATE_SYMBOL_MISSING` 或 `LINUX_BOUND_TO_OTHER_PROJECT` |

`native` 项在任何状态下都可用。`unsupported` 项始终不可用，原因 `SHARE_MODE_NONE`。阶段规则见 [linux-plugin-scheduling.md](linux-plugin-scheduling.md)。

## 收紧与扩展

- #39 关口 3 确认的 4 项收紧见 [native-official-tools.md](native-official-tools.md)。
- 关口 5 的限制见 [git-writes-and-hooks.md](git-writes-and-hooks.md)。

范围的任何变化，都先改 `CapabilityDeclaration.scope` 和本表，并经用户确认。#17 的测量结果只决定范围大小，不改变路径的划分。
