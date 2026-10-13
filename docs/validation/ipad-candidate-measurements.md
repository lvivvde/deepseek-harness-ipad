# iPad 候选 App 的 #17 测量与迁移演练

2026-10-11，签名安装到用户的 iPad，分支 `feat/issue17-measure-migrate`（r10–r13 构建，探针相同，只差下文说明的修正；r13 加了探针阶段 `imported`）。对应 [#17](https://github.com/lvivvde/deepseek-harness-ipad/issues/17) 的“测量”和“交付与数据”两条。按 #17，这些结果只决定兼容范围的大小，不阻断方向。

## 方法

候选 App 内置 `MeasureProbe`（`ios/HarnessApp/Sources/Candidate/MeasureProbe.swift`）。只有设置了启动环境变量 `HARNESS_CANDIDATE_MEASURE=<阶段>`，它才会运行，而且只跑这一个阶段，走 Worker 桥接相同的原生操作，不需要模型或 Key。每个阶段使用自己的项目，自己判定 `passed`，只把数字和固定码写到数据根下的 `probe/measure-<阶段>.json`，并带上本次启动的 `run` 编号和完成标记 `done`。

Mac 上的私有驱动脚本负责安装、启动、切到“文件”App 再切回，以及拉回记录。脚本和原始记录都放在忽略的 `build/candidate/device/` 里。

内存数字取自 `TASK_VM_INFO`：`phys_footprint` 及其峰值，加上 `os_proc_available_memory`。存储数字是数据根下每个顶层条目实际分配的大小，加上 `.app` 的大小。

## 结果

### 性能（冷启动 3 次，都 `passed`）

| 指标 | 3 次 |
| --- | --- |
| 进程启动 → 原生宿主就绪（探针开始） | 46–58 ms |
| 打开项目（原生调用返回） | 10–16 ms |
| 打开 → Linux `ready` | 9.7–10.0 s |
| 进程启动 → Linux `ready` | 9.8–10.0 s |
| 第一条命令（`true`） | 0.99–1.03 s |
| 之后 5 条命令 | 0.52–0.69 s |

所有探针都没有在启动环境里打开官方页面，所以上表不含 WKWebView 和 Worker 的加载时间。

### 预热调度（G4，`passed`）

- 打开后项目进入 PREPARING。准备期间，原生写、原生读和原生 `rg` 分别用了 16 ms、不到 1 ms 和不到 1 ms，阶段仍是 PREPARING，都没有等 Linux。
- 准备期间同时发出 3 条 Linux 命令，再发 1 条随后取消的命令：
  - 取消的那条结果是 `CANCELLED_BEFORE_DISPATCH`，没有在 guest 中运行。
  - 3 条都等到 Linux `ready`（约 9.8 s）之后才有结果：1 条 `COMPLETED`，另外 2 条立即被拒，结果是 `REFUSED:LEASE_BUSY`。工作区里只有完成的那条留下的文件。
  - 整个过程只启动了 1 次 VM。
- **兼容限制**：同一项目内的 Linux 命令不排队。写租约被一条命令占用时，其余命令立即被拒（`LEASE_BUSY`）。桥接只对终端写入做重试（每 250 ms 一次，最长 70 s），shell 命令不重试。所以模型如果并行发出多条 shell 工具调用，只有一条会运行。候选声明的 `shell` 一项因此附上原因 `ONE_COMMAND_AT_A_TIME`。每条命令只得到一次结果，被拒的命令不会再运行。

### 插件生命周期（G6，`passed`）

- 未启用插件的项目：阶段为 DISABLED，命令被拒（`LINUX_PLUGIN_NOT_ENABLED`），没有启动 VM。
- 第一个启用插件的项目：进入 READY，命令完成。
- 同一进程里的第二个启用插件的项目：阶段为 UNAVAILABLE，原因 `LINUX_BOUND_TO_OTHER_PROJECT`，命令被拒。
- 在进程内停止 VM，模拟意外退出：项目进入 FAILED（`LINUX_VM_EXITED`），诊断已保存，之后的命令被拒（`LINUX_VM_EXITED`），原生写入照常成功（`create`）。VM 始终只启动过 1 次，没有重启。

### 内存

| 时刻 | `phys_footprint` |
| --- | --- |
| 原生宿主就绪、Linux 未启动 | 约 9 MB |
| Linux `ready` | 约 470 MB |
| 跑完命令和监听检查后的峰值 | 约 505–516 MB |

各阶段结束时，系统报告的剩余可用内存都在 4.6 GB 左右。

### 存储

- `.app` 约 1.17 GB。
- 数据根里，这些测量项目、日志和会话检查点合计只有几 MB。合成迁移再加约 17 MB。
- 设备总容量和剩余空间只记在私有记录里。

### 后台恢复

用设备工具把“文件”App 调到前台约 121 s，再切回候选 App：

- **离开期间有命令在运行**（`background`，每 2 s 跑一条 `cut -d' ' -f1 /proc/uptime`）：
  - 离开时正在运行的那条命令用了 119.5 s，结果是写者未知（`WRITER_UNKNOWN`）。这符合 App 被挂起的预期：结果在挂起期间丢失，宿主不知道写者是否已经停下。
  - 项目阶段仍是 READY，但之后的命令全部被拒（`REFUSED:WRITER_UNKNOWN`），92 次中 76 次失败。
  - 这是设计内的安全行为：写者未知不自动释放，见 [workspace-durability.md](../design/workspace-durability.md)。用户要在侧栏按“Release writer…”。
- **离开期间没有命令**（`background-idle`，在离开前后各留出空档，不发命令）：
  - 回来后 75 次全部 `COMPLETED`，VM 只启动过 1 次。
  - 最长的间隔是墙上时间 152.0 s，guest 的 uptime 增加了 151.9 s。也就是说 VM 在挂起后继续运行，guest 时钟跟上了墙上时间，没有落后。
- **兼容限制**：App 进入后台时如果有 Linux 命令在运行，项目会变成写者未知，需要用户手动释放。没有命令在运行时，2 分钟的后台不影响 Linux。
- 只测了约 2 分钟的后台。更长的后台、系统因内存回收结束进程，以及锁屏，都没有测。

第一次 `background-idle` 沿用了上一轮写者未知的项目，所有命令都被拒，不算数。后来改成每次运行新建自己的项目（r12），然后重测。

### watcher 与 HMR

冷启动阶段测了 watch 检测的前提和成本：

- guest 写入的文件，在命令结束时原生端立刻可见，不用等待。
- 原生写入的文件，guest 立刻能读到。
- 一次比对（stat 加读目录）用时 0–1 ms。

桥接的 watch 在每条 Linux 命令或 hook 结束后立即比对一次，另外每 2 s 轮询一次。所以模型命令造成的变化在命令结束时就能发现；guest 后台进程（例如开发服务器）写入的变化，最迟约 2 s 发现。

HMR 归 [#23](https://github.com/lvivvde/deepseek-harness-ipad/issues/23)，本票不测。

## 模型回合与 shell 工具端到端

2026-10-11，r12，用户在候选 App 内输入 Key，在 Gate1 项目里让模型用 bash 工具运行 `echo DSH-E2E-$(uname -m) > e2e.txt && cat e2e.txt`。私有脚本只核对固定标记和计数：

- 工具结果为 `DSH-E2E-aarch64`，模型原样回报；共两轮，每轮一次 shell 调用。
- 项目日志每次调用各有一次租约授予、`toolStart`、租约释放、`toolEnd`，没有写者未知。
- 工作区 `e2e.txt` 内容与标记一致。
- 会话检查点包含这两轮；强制结束后重开，会话只增不改，标记仍在。

过程中的两个发现：

- **缺 Key 显示成网络失败**：Key 只在内存里，App 重启后清空。此时原生网关返回 `MODEL_KEY_REQUIRED`，桥接把所有模型打开失败都转成 `TypeError`，官方 Worker 把它当传输错误重试 5 次，最后显示“DeepSeek Messages transport failed”。重新输入 Key 后正常。之后已修改：桥接对 `MODEL_KEY_REQUIRED` 返回 401 `authentication_error`；按官方适配层的错误分类，这是认证失败，只报一次、不重试。Key 输入框下注明 App 重启后要重新输入。桥接测试只核对 401 和错误类型；真机上还没有在缺 Key 时发过一轮。
- **导入的项目 Linux 起不来**：第一次是在合成导入的 `migrated-demo` 项目里运行的，两次 bash 都是 `LINUX_PREPARE_FAILED`（`MOUNT_CHECK_FAILED`），模型如实回报了错误。原因见下文迁移演练的“工作区根目录权限”一条，已修正；r12 是修正前的构建，r13 上新导入的两个项目 Linux 均就绪（见下文“旧导出器备份”）。`migrated-demo` 是 r12 时导入的；修正只作用于导入，按代码推断它的目录权限仍是旧的，设备上没有复查。

## 迁移演练（候选 App 实演）

候选 App 接入了 `UserDataMigrator`（[user-data-migration.md](../design/user-data-migration.md)），入口是 `BackupImport`。旧 App 的完整备份（`HarnessBackup.tar` 和 `.sha256`）导入后：

- 旧项目变成启用插件的候选项目；
- 旧的官方 home（会话已改键到 `/dsh/workspace/<名字>`）在 Worker 下次恢复时并入；
- 旧 App 和它的数据都不动，留作回退。

导入有两个入口：

- 设置页的“Import backup…”：用户在 iPad 的“文件”App 里同时选中 tar 和 `.sha256`，原地读取，不复制。
- 启动环境变量 `HARNESS_CANDIDATE_IMPORT=1`：读取数据根下 `incoming/` 里的备份，用于脚本演练。

规则：

- 迁移结果放在 `<数据根>/migrations/<摘要前 16 位>`。工作区以 rename 移入项目，最后才写项目记录。中途被杀时，下次导入会接着完成同一个项目，不会重复。完成后写 `.adopted`；同一份备份再导入，结果是 `alreadyImported`。
- 候选 App 已有同名项目时，整份备份拒绝导入（`PROJECT_NAME_TAKEN`），什么都不改。
- home 的并入记录放在 `home-imports/`，并入后 ID 写进 home 检查点的 `imports` 字段，每份只并一次。用户之后删掉的文件不会被再次并回。
- 路径相同时，候选 App 已有的文件优先。
- 工作区根目录统一设为 `0755`，与新建项目相同。guest 里不持租的读者（uid 65534，挂载检查就用它）必须能进入 `/workspace`；旧备份里项目目录的权限没有其他执行位时（例如 `0700`），挂载检查失败，这个进程里的 Linux 就起不来。真机脚本演练的合成备份把目录写成了 `0644`（迁移器补齐属主位后是 `0744`），用户在这个项目里实际使用时暴露了问题。导入代码和演练脚本都已修正，新增测试覆盖 `0700` 的旧项目目录。
- 凭据不迁移，由用户在候选 App 里重新输入。
- 并入记录读不到、损坏或与现有 home 冲突时，只记诊断（`IMPORT_READ_FAILED`、`IMPORT_CORRUPT`、`IMPORT_CONFLICT`），不阻止恢复。

真机脚本演练（合成备份，`passed`）：

- 备份约 17.4 MB：一个项目，400 个小文件加一个 16 MB 文件；一个旧会话（cwd 为 `/root/projects/…`），一个官方配置，一个凭据。
- 推入候选 App 的 `incoming/` 后，以 `HARNESS_CANDIDATE_IMPORT=1` 加打开该项目的方式启动。
- 导入用时 204 ms：403 个文件，约 17.0 MB；1 个会话改键；排除凭据 1 项；导入后的项目已启用插件。
- Worker 恢复后保存的 home 检查点里：
  - 有改键后的会话 `/dsh/home/sessions/--dsh-workspace-migrated-demo--/s-1/`，cwd 已改为 `/dsh/workspace/migrated-demo`；
  - 有官方配置，没有凭据；
  - `imports` 记录了这份备份；
  - Worker 还在该项目中新建了会话。

### 旧导出器备份（r13，假凭据，`passed`）

2026-10-11，r13（含工作区根目录权限修正）。备份由旧 App 自己的导出代码生成（关口 6 用的合成备份），不是正式 App 里的真实数据，里面的凭据都是假的。脚本推入备份，以 `HARNESS_CANDIDATE_IMPORT=1` 启动，再用探针阶段 `imported`（`HARNESS_CANDIDATE_MEASURE_PROJECT=<名字>`）逐个打开项目：

- 备份约 2.6 MB：两个项目 `demo` 和 `演示`，覆盖中文、emoji 加空格的文件名、六层长中文目录、硬链接、两个符号链接（一个悬空）、空目录、`0600` 与 `0755` 文件、源目录为 `0555` 的 `ro`（备份里记为 `0755`）；两个旧会话（一个 zstd 压缩、cwd 为 `/root/projects/demo`，一个没有 cwd）；导出器已排除 `node_modules`、`.cache`、`.git-credentials` 和回收站。
- 导入用时 83 ms：14 个文件，约 2.6 MB；2 个旧会话中，有 cwd 的 1 个改键，没有 cwd 的留在 `_no-cwd`；排除凭据 4 项、缓存 2 项；没有跳过特殊文件；两个项目都启用插件，ID 与按备份摘要和名字算出的一致。
- 探针：两个项目 Linux 均就绪（从打开到就绪约 9.7 s；两个项目在两次启动里分别探测，每个进程只启动一次 QEMU）；guest 中 `find` 的条目数与原生枚举一致（`demo` 17，`演示` 7，都含 `.plan500-identity`）；guest 写、读、删一个文件成功。
- 工作区逐文件比对导出器的清单：`demo` 6/6、`演示` 4/4，SHA256 全部一致；除 `.plan500-identity` 外没有多出的文件，工作区里没有凭据内容。这些是补拉后的结果，见下文。
- 重开打开 `demo` 后，Worker 保存的 home 检查点：`imports` 记录了这份备份；有官方配置 `settings.json`，没有凭据；压缩的旧会话已改键到 `--dsh-workspace-demo--`，cwd 改为 `/dsh/workspace/demo`；没有 cwd 的会话留在 `_no-cwd`。

比对时发现 devicectl 列目录不全。第一次比对 `demo` 只有 5/6，缺 `ro/inside.txt`。这个文件确实在设备上：

- 按路径直接复制，SHA256 与清单一致；
- 单独列 `ro` 能列出它；
- App 自己的原生枚举和 guest 中的 `find` 都数到了它。

漏掉它的是 `devicectl device info files --recurse`：从工作区根列两次，结果相同，都列出了 `ro` 目录本身（APFS 目录大小 96 字节，即有一个子项），但没有列出它的内容。其他目录的内容都列全了，包括六层深的目录。一个猜测是：按字母序，`ro` 排在符号链接 `readme-link` 后面；另一个排在符号链接后面的目录 `empty` 本来就是空的；`演示` 里没有符号链接，列得完整。但输出是按字母序排的，不一定是 devicectl 实际遍历的顺序。只有这一个样本，原因未查明。导入本身没有问题。

私有拉取脚本已改为每个目录单独列一次、不用 `--recurse`（工具注意事项见 [真机自动化](ipad-device-automation.md)“读取 App 容器”）。改后补拉两个项目，再按清单比对，得到上面的 6/6、4/4，并重查了多余文件和凭据内容。

### 真实备份演练（2026-10-13，候选 r16）

用户从正式 Harness 导出备份到“文件”App 的“我的 iPad”，在候选 App 里用“Import backup…”导入。tar 约 652 KB，`.sha256` 84 字节。正式 App 的覆盖安装和真实用户盘迁移不在本票内，另行授权。

**“文件”App 的重复编号。** 同名文件第二次保存时，“文件”App 会加编号：

- 已知类型，编号加在扩展名前：`HarnessBackup 2.tar`。
- 未知类型，编号加在名字末尾：`HarnessBackup.tar.sha256 2`。

r14 按文件名配对 tar 和 `.sha256`，这两个名字配不上，导入被拒（“Pick the backup .tar and its .sha256 together.”）。r15 改为按扩展名配对，但还不认末尾的编号。r16 先去掉末尾的“空格加数字”，再看扩展名：选中的文件里恰好一个 tar、一个 `.sha256` 就配成一对，是否属于同一份备份由校验和决定。单元测试覆盖了这两种编号和大小写。

**导入结果（r16）。** 一次成功，`.adopted` 中的计数：

| 项 | 值 |
| --- | --- |
| 项目 | 2 个：`Test`、`ipad-hello-plugin` |
| 迁移文件 | 73 个，约 494 KB |
| 会话 | 8 个，其中 3 个改键到 `/dsh/workspace/<名字>` |
| 排除的凭据 | 1 个 |
| 排除的缓存条目 | 10 个 |
| 跳过的特殊文件 / 符号链接 | 0 / 0 |
| home 文件 | 23 个；Linux home 条目 5 个 |

迁移目录下没有凭据类文件名。凭据内容没有打印或拷出设备，只核对了计数和名字规则。

**home 并入。** 用户打开 `Test` 后，Linux 显示 READY，Worker 保存了 home 检查点：

- 检查点的 `imports` 记下了这份备份的 ID。
- 23 个导入的 home 文件都在。21 个与备份逐字节相同。另 2 个（匿名用户 ID 和 `storages/workspace.json`）用候选 App 已有的版本，符合“路径相同时已有文件优先”。
- 8 个导入的会话都在，候选 App 现在共 19 个会话。

**会话在界面上的位置：**

- `Test` 下的“新会话”：备份里这个会话就是空的，没有消息。
- 另 7 个会话的工作目录不是这次导入的项目：2 个属于旧项目“啊啊”，5 个是旧的 `/root/...` 路径。它们在“未分组”里。
- `ipad-hello-plugin` 在备份里没有会话。

**小问题：**

- 导入的会话文件，修改时间变成了导入时间，没有保留原值。界面排序会受影响。
- 修复前有一次，界面一直显示“Importing…”。抓取的线程栈里没有线程在干活，导入队列空闲，磁盘上也没有写入。一个猜测是这次选中的是 10/8 那份已导入过的备份，但界面应显示“Already imported.”，与现象不符。原因未查明，r16 上没有复现。
- 用 lldb 直接 attach 设备上的 App，如果进程没停住就退出 lldb，App 会被杀掉。这次因此杀掉过一次卡住的导入（还在暂存前，没有写入）。私有抓栈脚本改为先停、等停稳、取栈、再 detach。

**回退：** 正式 Harness 由用户确认能否照常打开（待补）。
