# #17 完成条件核对

2026-10-14 核对，基线 main `fb34cfa`。iPad 上装的是候选 r16。逐条对照 [#17](https://github.com/lvivvde/deepseek-harness-ipad/issues/17) 的“完成条件”。真机证据只来自独立 bundle ID 的候选 App，macOS 只算回归证据。

## 结论

完成条件都有真机或文档证据，没有不通过的项。几处缺口已写进能力声明或记为技术债，不算通过，也不阻断。是否关闭 #17 由用户决定。

## 逐条核对

| 完成条件 | 结果 | 证据 |
| --- | --- | --- |
| #39 已关闭 | 通过 | 2026-10-09 关闭，六项关口证据在 #39 评论 |
| 未启用插件的项目不启动 VM | 通过（真机） | G6：阶段 DISABLED，命令被拒 `LINUX_PLUGIN_NOT_ENABLED`，VM 未启动。见 [测量](ipad-candidate-measurements.md)“插件生命周期” |
| 已启用的项目打开即预热，并发时只启动一次 | 通过（真机） | G4：打开即 PREPARING，并发 3 条命令加 1 条取消，VM 只启动 1 次。见 [测量](ipad-candidate-measurements.md)“预热调度” |
| 准备期间界面可用 | 通过（真机） | G4：PREPARING 期间原生写、读、`rg` 都没有等 Linux（16 ms、不到 1 ms、不到 1 ms） |
| 等待的任务恰好继续一次 | 通过（真机），有兼容限制 | G4：3 条等待的命令都在 ready 后各得到一次结果，没有重跑。其中只有 1 条运行，另 2 条 `LEASE_BUSY`：同项目命令不排队，已写进能力声明 `shell` 的 `ONE_COMMAND_AT_A_TIME` |
| 取消有明确结果 | 通过（真机） | 等待中取消为 `CANCELLED_BEFORE_DISPATCH`，没有在 guest 中运行；运行中取消为 `CANCEL_REQUESTED`，命令带 `cancelled=true` 结束。见 [执行验收](ipad-linux-execution.md) |
| 启动失败有明确结果并保留诊断 | 通过（真机），部分只在 macOS | r12 导入的项目因工作区根权限挂载检查失败，项目进入 `LINUX_PREPARE_FAILED`，诊断 `MOUNT_CHECK_FAILED`，模型如实回报（已修正）。`VM_START_FAILED`、`READY_TIMEOUT`、证明被拒等原因只有 `LinuxBringUpTests` |
| VM 退出有明确结果并保留诊断 | 通过（真机） | G6 与 `execution`：项目 `FAILED(LINUX_VM_EXITED)`，诊断已保存，之后命令被拒，原生写入照常，VM 不重启 |
| 原生修改能被 Linux 读到 | 通过（真机） | 冷启动阶段：原生写入的文件 guest 立刻读到 |
| Linux 修改和产物能被原生读到 | 通过（真机） | 冷启动阶段：guest 写入的文件命令结束即原生可见；Gate1 模型 bash 写的 `e2e.txt` 原生核对一致；终端写的 `f` 出现在工作区；2026-10-14 终端写的 `panel-check.txt` 在 iPad 文件面板里显示，租约以 `COMPLETED` 释放并记下这个文件 |
| 能力声明文档已提交 | 通过 | [能力声明](../design/capability-declaration.md)，与代码一致由 `LinuxPluginTests` 检查；候选缺口逐项列出，App 侧栏显示 |
| 测量记录已提交 | 通过 | [测量与迁移演练](ipad-candidate-measurements.md)：性能、G4、G6、内存、存储、后台恢复、watcher；HMR 归 #23 |
| #14 组件清单已提交 | 通过 | [分发组件](../design/distribution-components.md)。本次又按 r16 收据核对：guest 输入 3 个、framework 22 个、网页根目录 139 个文件、npm 包 318 个、适配 12 项，摘要都与 r9 相同 |
| 数据访问范围和项目隔离边界写明 | 通过 | [调度与隔离边界](../design/linux-plugin-scheduling.md)“数据访问范围与项目隔离边界”：写明容器不是项目隔离，列出原生与 Linux 各自的边界和已知缺口 |

“交付与数据”一条另有真机迁移演练：合成备份、旧导出器备份和用户的真实备份都导入成功，正式 Harness 照常打开。见 [测量与迁移演练](ipad-candidate-measurements.md)“真实备份演练”。

## 不算通过的项

**已写进能力声明的缺口：**

- 同一项目的 Linux 命令不排队（`ONE_COMMAND_AT_A_TIME`）。
- 只有在 shell 中运行的 git 走 Linux（`SHELL_ONLY`）；hook 没有官方调用方（`NO_OFFICIAL_CALLER`）；子进程只支持 `bash -c`（`BASH_C_ONLY`）。
- minimal 预设的常驻 bash 被拒（`ARGV_REFUSED`）。默认预设不受影响。

**只有 macOS 测试、真机未验：** 存储失败注入、VM 退出的确定时序、断连与迟到的停止证明、显式 revoke、终端只接受 `/bin/bash -i`、空闲终端在第一行前不持租约。清单见 [执行验收](ipad-linux-execution.md)“未在真机验证”。

**#17 保留的插件技术债：** 设备安装占用、峰值内存、8 GB 下限、真实低空间和删除回收没有完整验证。后台只测了约 2 分钟。

**其他未查明的小问题：**

- 导入的会话文件，修改时间变成了导入时间。
- 修复导入配对之前，有一次界面一直显示“Importing…”，r16 上没有复现。
- 缺 Key 改为 401 后，真机上还没在缺 Key 时发过一轮。
- 正式 Harness 在后台约 80 分钟后，第一次恢复卡在页面端口转发，再次恢复成功。正式 App 不在 #17 范围内，只作记录。
