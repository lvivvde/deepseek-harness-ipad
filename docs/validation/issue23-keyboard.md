# #23 键盘、中文输入法与前后台验收

对应 [#23](https://github.com/lvivvde/deepseek-harness-ipad/issues/23) 中的交互项。真机证据只来自独立 bundle ID 的候选 App（Harness Candidate）。插件见 [插件安装验收](issue23-plugins.md)，预览与 HMR 见 [预览与 HMR 验收](issue23-preview-hmr.md)。

## 做了什么

- **终端辅助键：** 官方终端窗格聚焦并且软键盘弹出时，键盘上方出现一排键：Esc、Tab、Ctrl（粘滞，只作用于下一个字母）、方向键和 `| ~ / -`。
  - 键通过官方终端窗格自己的输入通道写入，只在终端可写时生效。这个通道由 `prepare.mjs` 的 `patchTerminalClient` 加到 `dsh-client-ui-sidebar-terminal` 的副本里。
  - 输入法组字期间所有键都停用，Ctrl 也会清掉；输入法上屏的文字不改写。
  - 外接硬件键盘时只剩快捷栏，键排不出现。
  - 做法与旧 App 的 `TerminalKeyRow` 相同（[`CandidateKeyRow.swift`](../../ios/HarnessApp/CandidateApp/Sources/CandidateKeyRow.swift)）。
- **网页进程被系统结束：** 系统在后台回收网页进程时，Worker 随之结束。`CandidateWebHost` 从资源源重新加载页面，Worker 按任何一次启动那样从最近的检查点恢复；检查点之后的工作不保留。日志记 `webcontent-terminated`。

## 结果

| 项目 | iPad（r28，2026-10-20） |
| --- | --- |
| 终端辅助键：Esc、Tab、Ctrl+C、方向键 | 通过 |
| 中文输入法：聊天框和终端里输入中文，不丢字，组字时回车不发送 | 通过 |
| 切到后台再回来：草稿和终端内容仍在 | 通过 |
| 外接硬件键盘 | 未测 |

`make test-candidate`、`make check` 通过；`make candidate-app` 构建完成。

## 未验证

- 外接硬件键盘。
- 网页进程被系统结束后的重新加载：无法主动触发，只有代码路径。
- 后台期间正在进行的模型任务：需要真实 Key。
