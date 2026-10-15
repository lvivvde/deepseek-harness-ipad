# 开发交接

最后更新：2026-10-14，北京时间。此文件是接手入口，只记当前状态、约束和资产入口；GitHub Issues 是任务状态源，过往过程以 git 历史、研究报告和验收记录为准。

## 开始工作

1. 读根 `CONTEXT.md`、相关 `docs/adr/`，检查 `git status --short`、当前分支和最新提交。保留已有未提交改动。
2. 查 `gh pr list --state open` 和下表涉及的 Issues。已有待合并分支时先继续该分支，避免重新实现；每个新 PR 合并都另获用户同意。
3. 真机任务读 [真机自动化](../validation/ipad-device-automation.md)；其他任务读对应验收记录。先用只读 `probe` 确认连接，按明确缺项推进，减少用户交互。
4. 完成后更新本文件的状态、验证和下一步；原始日志/设备/签名参数保存到忽略的 `build/`，公开文档只记脱敏结果。

## 当前状态

架构第二项在独立分支 `codex/linux-execution` 实现（基线 `c81f9dc`，终端 PR #53 已合并，开工时恢复 PR #54 仍开放）。用户已确认原生侧范围及[执行与写租约结算设计](../design/linux-execution-lifecycle.md)。LinuxExecution 集中操作 ID、取消、终端归属及写租约结算；未派发租约清理、提前取消 ID 再提交、命令/终端授予期间 VM 退出均已由行为测试覆盖。代码提交 `b64e6be` 已完成验证：Swift 全量测试与 `make check` 通过、无警告（网关 35、候选宿主 16 项）；`make test-candidate` 桥接 15、构建闸门 15 项通过、无跳过。macOS/iPad 候选 App 未签名构建成功，脱敏收据在本项 worktree 的忽略目录 `build/candidate/linux-execution-{mac,ipad}-reviewed/build-safe.json`。规范审查无发现；规格审查三项（旧终端登记竞争、拒绝后的存储错误被吞、Gateway 兼容入口归属绕过）均修复并复核通过。图工具不可用，审查为有界源码核查。未安装、未上真机。用户已授权推送及创建草稿，分支已推送并创建 [PR #56](https://github.com/lvivvde/deepseek-harness-ipad/pull/56)，base 为 main；已同步包含 PR #54 的 main（`021959c`），冲突仅交接文档且已保留双方记录；组合后的 `make test-app`、`make check` 与 `make test-candidate` 全通过（网关 35、候选宿主 20、恢复合同 9、桥接 20、构建闸门 15 项），无跳过。macOS/iPad 未签名构建复验通过，脱敏收据在 `build/candidate/linux-execution-{mac,ipad}-integrated/build-safe.json`；两轴组合审查无新发现。PR #56 已以 merge commit 合入 main。

已验证（真机，2026-10-13，签名 r14，[PR #57](https://github.com/lvivvde/deepseek-harness-ipad/pull/57) 已合并）：内置探针新阶段 `execution`、`execution-hold`、`execution-stale` 自动完成，无需用户操作和 Key，均 `passed`。先到取消与重复 ID、运行中取消、终端租约的取得、释放与并入、关闭的终端 ID、命令期间 VM 退出、上一进程留下的写者跨本进程 VM 退出保持未知直到显式释放，都符合设计。冷启动、G4 调度、G6 生命周期回归通过。存储失败注入、VM 退出的确定时序、断连与迟到停止证明、释放中等待、显式 revoke，以及终端只允许 `/bin/bash -i` 和空闲终端在第一行前只读，真机未验证，只有 macOS 测试。详见 [Linux 执行生命周期验收](../validation/ipad-linux-execution.md)。`make test-app` 237 项、`make check` 通过。

架构基线为 [ADR 0003](../adr/0003-native-worker-with-project-linux.md)（2026-10-06 用户确认，accepted）：官方 Worker 在 WKWebView 中运行，Swift 网关与原生工作区为唯一权威；Linux 是项目级兼容插件，启用后异步预热；9P 共享模式 `none`；耐久写租约与草稿；隔离语义为事后检测并转为冲突；工具按能力声明走 `native` / `linux` / `unsupported`。[ADR 0001](../adr/0001-local-linux-emulation.md) 中“Harness 在 Linux 内运行”的部分被取代。

正式实现 #17 的 [#39 六项前置关口](https://github.com/lvivvde/deepseek-harness-ipad/issues/39)已全部完成，#39 于 2026-10-09 关闭，#17 解除阻塞。各关口的脱敏证据在 #39 评论中：

| 关口 | 内容 | 类型 | 先后 |
| --- | --- | --- | --- |
| 1 | G2 原生工作区、会话与草稿的崩溃耐久 | 硬关口 | 可立即开始 |
| 2 | `pthread_fchdir_np` 启动检测与 Linux 插件不可用 | 硬关口 | 可立即开始 |
| 3 | 官方 fs、编辑、搜索与原生只读 Git 接入原生工作区 | 可收紧 | 等关口 1 |
| 4 | G1 模型回复增量流式、取消、认证与网络错误 | 可收紧 | 可立即开始；需用户输入 Key 并切一次飞行模式 |
| 5 | G3/G5 Git 写操作与 hook 的一致性和提交前拦截 | 可收紧 | 等关口 2、3 |
| 6 | G7 从隔离备份迁入、逐文件核验与回退旧包 | 硬关口 | 等关口 1 |

用户确认的关口决定（已写入 #39）：

- 真机证据只来自独立 bundle ID 的候选 App。G7 用专用测试 bundle ID 演练旧包→新包→回旧包，数据为合成数据加一份由用户在 iPad“文件”App 导出的真实备份副本（不经 Mac）。正式 App 升级与真实数据迁移不属 #17，须另获授权。凭据不迁移。
- 崩溃恢复以工作区为准、不回滚：会话回到最后完整检查点，未记录完成的工具调用标“结果未知”且不重放，草稿保留，change generation 不一致在会话中标出。
- 原生 Git 只读；所有修改仓库的 Git 操作和全部 hook 走 `linux` 路径，原生不写 `.git/index`。
- 硬关口不通过即停；可收紧的关口不通过时收紧兼容范围，每次须用户确认，必要时修订 ADR。关口之后的集成实现暂留 #17 正文，不预先拆票。

拆票规则（用户定）：开放 Issue 尽量少；有阻塞关系的不合并，同一层级、无相互阻塞的细项写成任务清单。

#39 进展（脱敏证据见 #39 各条评论）：

- 六项关口全部勾选。关口 1、2、3、4、6 的代码在 [PR46](https://github.com/lvivvde/deepseek-harness-ipad/pull/46)，已合并。设计与限制见 [工作区耐久](../design/workspace-durability.md)、[Linux 插件可用性](../design/linux-plugin-availability.md)、[原生官方工具](../design/native-official-tools.md)（含用户确认的 4 项收紧）、[原生只读 Git](../design/native-read-only-git.md)、[模型网关](../design/model-gateway.md)、[用户数据迁移](../design/user-data-migration.md)。
- 关口 5 的代码在 [PR47](https://github.com/lvivvde/deepseek-harness-ipad/pull/47)，设计与限制见 [Git 写操作与 hook](../design/git-writes-and-hooks.md)。Git 写操作和 hook 走项目 Linux，原生只读复核。授权推送用的是本仓库的专用分支 `gate5-push-test`，token 由用户在 iPad 上输入；核对后该分支已删除。
- 遗留限制：系统崩溃和断电未验；关口 1 真机写租约中的 Linux 写者是模拟的，真实 VM 补测记在 #17；快照或日志中段损坏时会丢草稿和租约记录；生成中切后台未在真机运行；hook 的 `workdir` 被忽略（候选 App 已修正）；shell 工具能直接 `git commit --no-verify`，同 uid 代码能从 `/proc` 读到 Git 令牌；iPad 上完整 clone 本仓库超过单条命令 60 s 的上限，大项目的 clone 时长留给 #18。

#17 进展：

- 核心切片已在 [PR49](https://github.com/lvivvde/deepseek-harness-ipad/pull/49) 合并，范围由用户 2026-10-09 确认。
  - `LinuxPlugin`：每个项目的阶段、准入和 VM 退出诊断。
  - `HarnessHost`：`ProjectGateway`、`LinuxBringUp`、`ReadyProof`。
  - `WorkspaceStore`：新增释放原因 `RECONCILED`。
  - 多项目时，Linux 绑定到本进程第一个打开的启用项目。
- 候选 App 的 macOS 竖切已在 [PR50](https://github.com/lvivvde/deepseek-harness-ipad/pull/50) 合并（2026-10-10）。范围由用户 2026-10-10 确认：
  - 代码放在正式源码树：`Sources/Candidate`、`CandidateApp/`、`runtime/candidate/`。
  - 由脚本生成独立工程，bundle ID 为 `org.lvivvde.harness.candidate`，不加研究仪器。
  - 先打通 macOS，iPad 安装与验收放到下一个 PR。
  - 设计、实测与缺口见 [调度与隔离边界](../design/linux-plugin-scheduling.md)“候选 App”一节；组件变化已写入 [分发组件清单](../design/distribution-components.md)。
- 宿主新增 `GatedGuestRPC`、`MountCheck`（宿主直接写保留名哨兵文件，再由 guest 读回），`LinuxBringUp` 在准备失败时停止 QEMU。
- 已做两轴代码审查（标准、规格），并按结论修正：
  - 网页只能停留在本地资源源，消息处理器核对帧来源，外链交给系统浏览器；资源服务解析符号链接。
  - 登记记录与项目身份文件改走工作区存储的耐久替换（`durableReplace`）。
  - 能力声明显示候选 App 与正式范围的差距：`hook.command` 为 `CANDIDATE_NOT_WIRED`，`git.write` 为 `SHELL_ONLY`，`subprocess` 为 `BASH_C_ONLY`，另加不支持的 `terminal` 行。
  - 写者未知时，侧栏提示并提供需确认的“Release writer…”；VM 退出后提示关闭并重开 App。
  - 网页收据的 `adaptations` 列全 10 项改动；文档写明 guest 用 `/bin/sh -c`。
  - 未改并说明理由：操作记录不修剪（每条命令很小，且网关保留已结束 id 以回答迟到的取消）、原型 `GatedTransport` 重复与 `plan500` 命名（留给 #14 的构建输入整理）。
- 已验证（macOS，审查修正后）：
  - `make test-app`（含候选宿主 13 项）、`make check`、`make test-plan500-ipad` 通过，无警告；`make test-candidate` 中桥接 10 项、构建闸门 9 项通过。
  - 用真实 Homebrew QEMU 跑了 `make candidate-web` 和 `make candidate-app`，得到未签名 `.app`。
  - 界面操作：项目进入 READY，官方前端在导航锁定下正常加载，原生工作区文件可列出和读取，终端显示 `TERMINAL_UNSUPPORTED`。能力差距行由单元测试覆盖，侧栏未在界面上滚动核对。
  - 退出后没有残留 QEMU。
  - 运行数据在 `build/candidate/run`（启动时设 `HARNESS_CANDIDATE_ROOT`）。
- 已验证（真机，2026-10-11，r12）：模型回合和 shell 工具端到端。用户输入 Key，在 Gate1 让模型用 bash 写读 `e2e.txt`，工具结果、项目日志、工作区文件和重开后的会话均核对通过，见测量文档。
- iPad 构建与真机验收已由 PR #51 合入 main（2026-10-11），关口 1 脱敏结果已发到 #17：
  - `build.py --sdk iphoneos` 核对并嵌入 QEMU framework 闭包（22 个，按 `frameworks.json` 核 SHA256）；签名只用私有 `--signing-file`。`make candidate-ipad` 构建未签名版。
  - `EmbeddedMachine` 在 App 进程内运行 QEMU，串口与 QMP 用 socketpair，`stop` 走 QMP `quit`；进程内只启动一次。
  - 真机：签名安装到用户 iPad，项目 READY，官方页面正常（用户确认）。`.app` 约 1.1 GB。
  - 关口 1 用真实 VM 写者补测通过，由内置 `Gate1Probe`（启动环境变量 `HARNESS_CANDIDATE_GATE1=hold|check`）自动完成，无需用户操作：强制结束后写者未知、不自动释放、新命令被拒、命令不重放、草稿逐字节一致。探针每阶段自判 `passed`；修正 QEMU 入口签名后的 r5 构建复测两阶段均 `passed`。细节见 [调度与隔离边界](../design/linux-plugin-scheduling.md)“候选 App”一节。
  - 新 bundle ID 首次签名须在 Xcode 界面运行一次生成描述文件，之后命令行可复用。
  - 已验证：`make check`、`make test-app`（候选 23 项）、`make test-candidate`（桥接 10、构建 15）、`make test-plan500-ipad` 通过、无警告；`make candidate-app` 与 `make candidate-ipad` 构建完成。
- 候选缺口第一批已由 [PR52](https://github.com/lvivvde/deepseek-harness-ipad/pull/52) 合入 main（2026-10-11）：
  - 项目内 hook 作为独立 Linux 任务运行（触发方式 `hook`），在 `workdir` 中运行，payload 中的项目路径换成 `/workspace`；没跑完的一律阻止（退出码 2，`DSH_HOOK_NOT_RUN <原因>`）。官方网页版不加载 hook 插件，只由桥接测试（用官方 `runHook`）覆盖；声明里 `hook.command` 由 `CANDIDATE_NOT_WIRED` 改为可用并附 `NO_OFFICIAL_CALLER`。
  - 项目 `watch` 每 2 秒比对原生存储，Linux 命令或 hook 结束后立即再比对。
  - 官方网页版没有发起仓库写操作的 Git 调用方，只改文档；`git.write` 保留 `SHELL_ONLY`。
  - 顺带修正：发出前就被拒的 RPC 请求（超过 128 KiB 或路由非法）以前记为写者未知，会锁住项目；现在记为拒绝并释放租约。
  - 已验证：`make test-app`、`make check`、`make test-candidate`（桥接 13 项）通过。这一批未上真机，只有单元测试覆盖。
- 交互式终端在 [PR53](https://github.com/lvivvde/deepseek-harness-ipad/pull/53)，已合并（2026-10-11，租约规则由用户确认：空闲不占写租约，运行时模型 shell 命令并入）：
  - guest 代理新增 `/terminal/*`：pty 上的 `/bin/bash -i`，独立挂载命名空间，默认只读；运行键取租约后改为可写，回到空闲提示符且并入的命令结束后改回只读并释放。
  - `ProjectGateway` 终端 API 和并入路径（结果 `.joined`）；`CandidateHost` 的 `terminal-*` 原生调用，新 Worker 安装时 `terminals-reset` 关闭旧终端；声明里 `terminal` 随 `shell`，可用时附 `WRITE_LEASE_WHILE_BUSY`。
  - 桥接 `spawnTerminal` 返回官方终端控制器所需的句柄（输出流用 Worker 自己的 `PassThrough`）。
  - 两轴审查后修正：重复关闭时 guest 按宿主发来的 fence 报告已释放，宿主对关闭后未确认的租约记写者未知，不再留下活动租约；shell 未退出时 guest 关闭失败、不释放；`/terminal/unlease` 返回后先核对租约仍是同一个；宿主只开 `/bin/bash -i`（`/bin/sh` 报告不了空闲提示符，租约会一直占着）。`CONTEXT.md` 新增术语“并入”。
  - 保留未改：`inspectForeground`/`signalForeground` 和 guest 的 `inputWaiting` 目前只有被拒的常驻 bash 会用，作为官方终端句柄接口的完整实现保留；hook 也会并入终端租约，文档已写明。
  - 真机修正：打包器的清扫看不到控制器经 `createLazyRequire` 加载的 `@xterm/headless`、`@xterm/addon-serialize`，iPad 上打开终端报 `cannot resolve "@xterm/headless"`；`prepare.mjs` 把两者列入打包入口，构建时核对其主文件在镜像内，并核对打包器未导出的默认种子仍与副本一致；设计文档第 6 条和收据 `adaptations`（增为 11 项）列出这项适配。
  - 缺口：minimal 预设的常驻 bash 被 guest 拒绝（`ARGV_REFUSED`）。iPad 文件面板显示终端新建的文件，2026-10-14 已由用户确认（r16）。
  - 已验证（macOS）：真实 QEMU guest 的 `run.py` 探针（含终端 18 项）通过；`make test-app`（网关 25、候选宿主 15）、`make check`、`make test-candidate`（桥接 15、构建 15）、`make test-plan500-ipad` 通过。
  - 已验证（真机，2026-10-11，签名 r7）：iPad 上终端打开，用户运行两次命令，项目日志各有一次终端租约授予并以 `COMPLETED` 释放，工作区出现 `f`。`echo hi > f` 本身无输出，所以界面上只是换出新提示符。macOS 候选 App 上同样验证并在文件面板看到 `f`。

2026-10-11 架构扫描选定会话检查点与恢复，用户已确认设计并在 [PR54](https://github.com/lvivvde/deepseek-harness-ipad/pull/54) 的 `codex/session-recovery` 实现（终端 PR53 与会话恢复 PR54 均已合入 main）。详见 [会话恢复](../design/session-recovery.md)。Worker 与 Swift 共同收拢恢复、采集前项目基线、home 完整验证及耐久确认；保留当前/上一份和初始化身份，损坏隔离后可回退，无可用副本则阻止恢复。新建须明确确认并保留诊断与旧字节；失败持续显示未保存，自动和手动重试。项目提示读取正常打开后的状态，不清理调用账本，不预热其他项目，不回滚工作区或释放未知租约。

- 审查：规范轴无发现；规格轴的首次保存被空标记忽略、新建后诊断丢失两项已修复并复核。另补上无新事件时手动保存失败仍自动重试，并由真实 VFS 往返核对目录时间在恢复后保持。
- 验证（macOS）：真实 Worker VFS/官方 JSONL flush→Swift handler→新 Worker 往返；恢复合同 9 项，包含已有副本 15 种及首次/新建 30 种 SIGKILL 组合；桥接 20 项无跳过；构建闸门 15 项。工作区 27、宿主 44、候选 28 项回归通过；审查修正后候选宿主 19 项复测通过；`make check` 通过。
- 已有 QEMU 进程测试在与 App 编译同时运行的一次回归中读取到未完整写入的参数文件，单独及随后完整回归通过；测试自身的读文件时序窗口仍在。本次没有改它。
- 未签名 macOS 与 iPad App 均已构建；最终收据在 `build/candidate/{app,ipad}/build-safe.json`。Xcode 保留已有 Gate1 `Phase` Sendable、传统 headermap 与 AppIntents 元数据提示，不登记为无警告。
- 已验证（真机，2026-10-11，签名 r9）：无需用户操作的自动脚本（忽略的 `build/candidate/device/recovery-auto-private.py`）经启动环境变量 `HARNESS_CANDIDATE_OPEN=Gate1` 打开项目，只比对检查点内的会话文件：
  - 覆盖安装后恢复（序号 14→16）、切到“文件”App 后台立即保存（16→18）、强制结束后重开恢复（20→22），会话文件均逐字节一致，无诊断。
  - 推入校验和损坏的当前副本：回退到上一份，会话一致，诊断 `CHECKPOINT_FALLBACK`，损坏副本进入隔离区。
  - 两份都损坏：没有新保存、不自动新建，两份进入隔离区；用户确认界面显示橙色 `Recovery blocked` 和 `Start a new session…`（未点）。推回完好副本后重开恢复，会话一致（23→25）。
  - 设备上的候选 App 因此保留 `CHECKPOINT_FALLBACK` 提示（按设计持续显示，直到明确新建）和 3 个隔离文件。Worker 日志里启动早期的 `checkpoint-failed SESSION_NOT_READY` 是会话就绪前的保存请求，无害，未改。
- 未验：断电/系统崩溃；有新模型回合的会话（需 Key）。HTML 扫描报告只在临时目录；知识图谱工具不可用，使用限定源码证据。Linux 执行生命周期在 PR #56 实现，原生工具适配留待探索。

2026-10-11 #17 测量与迁移演练（分支 `feat/issue17-measure-migrate`，r10–r13 真机，结果见 [iPad 候选 App 的 #17 测量与迁移演练](../validation/ipad-candidate-measurements.md)）：

- 内置 `MeasureProbe`（启动环境变量 `HARNESS_CANDIDATE_MEASURE=cold|scheduling|lifecycle|background|background-idle`）自动完成，无需 Key：冷启动 3 次、预热调度 G4、插件生命周期 G6、后台两种均 `passed`；内存、存储、watch 延迟已记。
- 两项兼容限制：同项目 Linux 命令不排队（并行 shell 调用只有一条运行，其余 `LEASE_BUSY`，能力声明 `shell` 附 `ONE_COMMAND_AT_A_TIME`）；命令运行中进入后台会变成写者未知，需用户手动释放。
- 候选 App 接入 `UserDataMigrator`（`BackupImport`、设置页“Import backup…”、`HARNESS_CANDIDATE_IMPORT=1`）；合成备份真机导入 `passed`，旧 home 经 Worker 恢复并入一次。
- 已验证（macOS，最后一次代码改动 `1bf5b71` 之后，2026-10-11）：`make test-app` 全量 8 个测试包共 224 项，无失败、跳过或警告（候选宿主 19、导入 7、测量 6 项）；`make check`、`make test-candidate`（恢复 9、桥接 20、构建 15）通过。
- 顺带修正 `QemuMachineTests` 读取未写完参数文件的时序窗口（替身脚本改为写临时文件后 rename）。
- #14 组件清单已按 iPad r9 收据核对并记下 `system.raw` 构建配方，见 [分发组件](../design/distribution-components.md)。
- 缺 Key 改为 401 `authentication_error`（官方归为 AUTH，不重试；桥接测试已过，真机未在缺 Key 时发过一轮）；新增探针阶段 `imported`（`HARNESS_CANDIDATE_MEASURE=imported` + `HARNESS_CANDIDATE_MEASURE_PROJECT=<名字>`）。
- 已验证（真机，2026-10-11，签名 r13，`build/candidate/ipad-signed-r13/`）：旧导出器生成的假凭据备份（`device/oldexport-fake/`，两个项目）经 `measure-auto-private.py import-old` 导入 `passed`。两个项目 Linux 就绪，guest 与原生条目数一致；工作区逐文件 `demo` 6/6、`演示` 4/4；home 并入一次、会话改键、无凭据。证据 `device/measure-auto-165653`，补查在 `device/ro-check-183446`。
- 工具约束：`devicectl device info files --recurse` 会漏掉某个目录的内容（这次漏了 `demo/ro/inside.txt`，文件本身在设备上）。私有 `device-private.py pull` 已改为逐个目录列出（旧版为 `device-private.py.bak-*`），见 [真机自动化](../validation/ipad-device-automation.md)“读取 App 容器”。
- 模型回合与 shell 工具端到端已在 Gate1 通过（`e2e-auto-private.py`，证据 `device/e2e-check-163231`）。顺带发现的工作区根目录权限问题已修正；r12 时导入的 `migrated-demo` 按代码推断仍不可用 Linux（未复查），用 Gate1 或新导入的项目。

2026-10-13 真实备份演练（分支 `fix/import-pairing-suffix`，候选 r16，结果见测量文档“真实备份演练”）：

- PR #58 已合并。正式 Harness 用同一签名身份重签覆盖安装（r3，`build/maintenance19/r3-7956e8c-resign/`），数据保留。
- 用户从正式 Harness 导出备份，在候选 App 导入。“文件”App 给重复保存的文件加了编号（`HarnessBackup 2.tar`、`HarnessBackup.tar.sha256 2`），r14 配不上对。r15 改为按扩展名配对，r16 再去掉末尾编号；r16 导入成功。
- 已验证（真机，r16）：2 个项目、73 个文件、8 个会话（3 个改键），凭据 1 个和缓存 10 条被排除。打开 `Test` 后 Linux READY，home 检查点记下这份导入，23 个 home 文件、8 个会话都在。
- 回退通过：用户确认正式 Harness 页面正常、项目和会话都在。它在后台约 80 分钟后第一次恢复失败（修复页面端口转发未成，“页面连接暂不可用”），同一进程再次恢复后 `ready`，原因未查明，状态文件只记阶段。
- PR #59 已合并（`fb34cfa`）。
- 未查明：修复前有一次一直显示“Importing…”，线程栈无活动、无写入。导入的会话文件修改时间变成了导入时间。
- 已验证（macOS，`01a7f7c` 之后）：`make test-app` 全量 239 项，无失败或警告；`make check` 通过。第一次全量时 `EmbeddedMachineTests` 有 1 项在 5 秒内没读到串口日志而失败，单独跑 3 次和随后全量都通过，按时序抖动记，没有改它。
- 工具：lldb attach 设备 App 后，进程未停住就退出会杀掉 App。私有 `build/candidate/device/stack-private.py` 用 Python API 停住、取栈、detach，不杀进程。

#17 已于 2026-10-14 关闭。[完成条件核对](../validation/issue17-closeout.md) 由 PR #60 合入（`cf28b7c`），用户同意缺口按核对表放行。iPad 文件面板能显示终端新建的文件，用户已确认（r16）。文件面板在右侧栏 ＋ 里的“工作区文件”，不是中间的会话列表。

#18 进行中，分支 `feat/issue18-git-loop`。范围由用户 2026-10-14 确认，已写进 #18 评论和 [#18 验收记录](../validation/issue18-git-loop.md)：私有测试仓库 `lvivvde/harness-acceptance-ts`（种子提交 `afdb093`），用户在 iPad 的 git 提示处输入 fine-grained token；guest 放开出站；固定项目是 `runtime/acceptance/ts-git-loop`；`git fetch`、`npm ci`、`git push` 由用户在终端手动运行。

- 已改：QEMU 网络放开出站；探针阶段 `network`、`git-fetch`、`git-push`、`git-keep`。`git-fetch` 失败带原因码，遇 `TERMINAL_NOT_FOUND` 重开终端；`git-push` 的提交改在终端运行（shell 工具 60 s 上限放不下 hook）；`git-keep` 核对 Git 历史、凭据配置并扫描 App 容器里的 token 前缀。候选 App 的 Key 输入去掉首尾空白，并显示末 4 位和长度。
- 已验证（iPad，2026-10-15，r19–r23）：验收表 6 步全部填写，1–5 通过，6 通过附发现。远端 `main` 为 `f4386365`，父提交 `afdb093`。重开、r22→r23 覆盖升级、合成备份迁移后 Git 历史、会话、配置都保留；App 容器无 token 命中。macOS 上 `MeasureProbeTests` 14 项通过。
- 发现（未修，建议另开 issue）：guest 的 `/etc/gitconfig` 带 `credential.helper = store`，`HOME=/tmp`，输入的 token 留在 guest 内存直到 VM 退出，hook 和模型命令都能读到；迁移或用户自建的仓库里，App 保留文件 `.plan500-identity` 显示为未跟踪。修前者要改候选镜像配置或 agent 环境（`agent.cjs` 的摘要固定在 `runtime/candidate/build.py`，改后须重新准备输入）。
- 设备上现装 r23（`build/candidate/ipad-signed-r23/`）。候选 App 里有 Acc-ts（测试仓库的克隆）和迁移演练项目 `migrated-git`，都可随卸载一并清除。私有驱动 `measure-auto-private.py` 新增 `git-fetch`、`git-push`、`keep-baseline`、`git-keep`、`home-check`、`import-git`；证据：push `device/measure-auto-231526`，升级后 `232857`、`233224`，重开 `233105`，迁移 `234434`。

**下一步：**

1. #18：开 PR 合入验收记录和探针改动（合并需用户同意）；为上面两条发现开 issue 或在本分支修复后复测 `git-keep`；然后按用户意见关闭 #18，转 #23。测试仓库是否删除由用户决定。#14 也可以开始，依据是 #17 的组件清单。
2. 可选后续：导入时保留会话文件的修改时间；查清修复前那次一直显示“Importing…”的原因（r16 上未复现）。
3. 可选后续：桥接对 shell 执行也重试 `LEASE_BUSY`。

## 开放任务

| Issue | 依赖与边界 |
| --- | --- |
| [#15 路线图](https://github.com/lvivvde/deepseek-harness-ipad/issues/15) | 总入口；执行顺序 39→17→18→23→14。#1、#16、#17、#19、#32、#39 已关闭，作为历史保留。 |
| [#18 Git 开发闭环验收](https://github.com/lvivvde/deepseek-harness-ipad/issues/18) | 当前任务。iPad 验收 6 步已填，1–5 通过，6 附两条发现待处理。推送只用用户授权的测试远端。 |
| [#23 插件/预览/键盘/前后台验收](https://github.com/lvivvde/deepseek-harness-ipad/issues/23) | 被 #18 阻塞。“重试”是重提任务，同进程不重启 QEMU；dev server 默认 `linux`；阈值在开工前提出并经用户确认。仍带 `needs-triage`。 |
| [#14 许可证与对应源码审查](https://github.com/lvivvde/deepseek-harness-ipad/issues/14) | #17 已关闭，组件清单见[分发组件](../design/distribution-components.md)，可与交互验收并行准备；含 Worker bundle、适配补丁、原生只读 Git 与原生搜索。不发布 GitHub Release。仍带 `needs-triage`。 |

## 已交付基线

- 正式 iPad 安装代码基线 `7956e8c`（含导出中断修复），同身份覆盖安装前后真实备份 83 个文件一致。main 另含研究原型与 ADR 0003，正式 App 尚未包含。
- 已有实现：完整 Linux 原型、正式全屏入口、持久用户盘、恢复诊断、备份/存储工具、签名预检 `runtime/check-signing.py`、真机 runner、原生菜单标签与示例插件声明。既有用户项目不会因示例更新被覆盖。
- 独立研究 App（`org.lvivvde.harness.plan500.research`）在 iPad 上有界通过：`none` / `mapped-xattr` 各 15/15 必需检查、23 项 Worker/Swift/Linux 协作 + 9 项进程恢复；真实模型小闭环在 `none` 模式 8/8 通过。这些不是完整 G0–G7。

## 已知缺口与技术约束

- `none` 模式不能建 FIFO/socket；`mapped-xattr` 宿主 mode/symlink 不普通。
- iPad 容器样本保留大小写不同的名称，但大小写不敏感卷会合并同名；工作区须显式处理。
- libslirp `listen(s,1)` 在 XNU 下积压溢出会 RST。
- 私有 `pthread_fchdir_np` 符号存在且 9P backend 可运行，但完整语义与私有接口条件未解决；关口 2 只做了启动检测，符号缺失时 Linux 插件不可用。
- 同 uid 经 /proc、SCM_RIGHTS、写租约 CAS TOCTOU 的隔离缺口保留，独立 uid 加固留作后续。
- 研究中的 SSE 缓冲交付已由关口 4 改为增量流式；`mapped-xattr` 未跑模型。
- 旧 Linux 路径：guest Vite production build 超时；删除/trim 后未观察到宿主 raw 占用下降。不要猜测根因或承诺原盘压缩。
- 历史恢复、实际时差、救援盘仍未验；物理锁屏与 8 小时验收已取消，不登记通过。

## 文档入口

- 研究：[Worker/Swift/Linux 接缝](../research/plan500-worker-gateway.md)、[iPad 研究 App](../research/plan500-ipad-preflight.md)、[Darwin](../research/plan500-darwin.md)、[写租约](../research/plan500-write-lease.md)、[共享/RPC](../research/plan500-sharing-rpc.md)、[候选研究](../research/plan500-feasibility.md)；原型在 `runtime/prototypes/plan500-*/README.md`。早期研究报告已归档在 `docs/research/`，文首注明原分支。
- 验收：[非锁屏](../validation/ipad-non-lock-acceptance.md)、[后台恢复](../validation/ipad-background-recovery.md)、[备份恢复](../validation/ipad-recovery-backup.md)、[存储工具](../validation/ipad-storage-tools.md)、[签名维护](../validation/ipad-signing-maintenance.md)、[Linux 执行生命周期](../validation/ipad-linux-execution.md)、[插件预览](../validation/ipad-plugins-preview.md)。

## 本机接手资产

全部在忽略的 `build/`，路径相对仓库根；其他机器可从源码重建工具，但需重新配对、签名和准备本机资源。原始证据不可贴聊天、提交或公开。

- `build/device-acceptance/local-settings.json`：本机 runner 签名设置（权限 600）；多设备时用 `selected-device-private.json`。runner xctestrun 在 `build/device-acceptance/portable-signed-final/derived/Build/Products/`，测试源码变更后按真机工具说明重建。
- `build/test-dependencies/harness/`：固定官方 `@deepseek-ai/dsh@0.2.0-rc.2`、pnpm 11.28.4 的宿主测试依赖和 lock。设置 `HARNESS_TEST_MODULES="$PWD/build/test-dependencies/harness/node_modules"` 后运行 `make test-runtime`，核对无跳过。依赖丢失时用保留的 lock 重装。
- Lima `ubuntu` 内 `/var/tmp/ipad-bundled-guest-storage-v6` 可跑 Linux 验收，使用新临时盘；`/Users/edwin` 只读挂载，`/private/tmp` 不挂载。Linux/QEMU 只用隔离盘，不读 iPad 原盘。
- 正式包：`build/maintenance19/r2-7956e8c/`，现装重签版在 `r3-7956e8c-resign/`。研究 App 与收据：`build/prototypes/plan500-ipad/`（`device-r1/` 签名与两模式收据，`worker-device-r1/`、`r2/`、`r4/` 协作与模型收据）；macOS 原型收据在 `build/prototypes/plan500-{worker,sharing,lease,darwin}/`。
- #39 关口：`build/issue39-gate1/`（从 `device/durability-safe.json` 看起）；`build/issue39-gate3/device/`（关口 2、3、4 的收据与 `device-private.py`）；`build/issue39-gate6/`（合成矩阵，`device/gate6-private.py` 与收据）；`build/issue39-gate5/`（`device/device-private.py`，步骤为 sign、install、launch、wait；收据在 `device/*-safe.json`，macOS 运行在 `mac-3/` 和 `mac-push-dry/`）。研究 App 已于 2026-10-10 卸载以腾出名额，演练 App `g6drill` 已卸载；iPad 上现装候选 App `org.lvivvde.harness.candidate`（现为 r14 构建；内有用户建的项目 Gate1、探针项目 gate1-probe-2 至 4 和 `measure-*` 测量项目，部分保持写者未知，可随时整体卸载）。
- #17 候选 App：`build/candidate/CandidateWeb`（网页根目录与 `candidate-receipt.json`）；`build/candidate/app/`（生成的工程、`build-private.log`、`build-safe.json` 和 `.app`）；`build/candidate/run/`（macOS 实测的数据根，含私有日志和测试项目 `demo`）。
- #17 iPad 候选：`build/candidate/ipad-signed-r16/`（现装签名构建与收据，r10–r15 为旧版）；`build/candidate/ipad-signed/project` 是注入团队后供 Xcode 界面首次运行的工程；`build/candidate/device/device-private.py`（步骤 free-slot、install、launch、gate1 hold|check、running、terminate、pull SUBDIR DEST）。一键复测：`python3 build/candidate/device/gate1-auto-private.py <.app> <上次 hold.json 相对 device/ 的路径>`，安装、hold、强制结束、check 全自动，只打印 `HOLD_PASSED`/`CHECK_PASSED`。关口 1 证据：最新 `device/gate1-auto-204420/`（`hold.json`、`check.json`）；首次手动版在 `device/gate1-killed/` 与 `device/gate1-checked/`。#17 测量：`device/measure-auto-private.py`（install APP、cold N、scheduling、lifecycle、background、background-idle、import、import-old、execution、execution-stale），证据在 `device/measure-auto-154040`（冷启动）、`154144`（调度）、`154203`（生命周期）、`154227`（后台）、`155655`（空闲后台）、`160243`（导入与 home 检查点）、`165653`（旧导出器备份导入）；PR #56 验收在 `223332`（`execution`）、`223410`（hold 与 stale），r14 回归在 `223459`、`223523`、`223541`。端到端复核：`device/e2e-auto-private.py`。
- 历史归档：`build/acceptance-archive/2026-10-05/`（旧日志、xcresult、截图、脱敏结果与 SHA256 清单）；Issue 正文备份与草稿在 `build/issue-drafts/`。
- `harness-30` 锁屏提醒已暂停，保持取消。

## 持续约束

- 保护正式 Harness 数据、草稿、Git 历史和有效备份；覆盖升级只用同签名身份，保留原盘；原盘迁移只经校验副本。设备备份不导出到 Mac 或仓库。
- 免费开发团队的 App 名额有限。用户已授权按需卸载本项目占位 App（Harness、LinuxPrototype、DeviceAcceptance runner）及后续项目 IPA，不再重复询问；不扩展为其他 App 或无关数据。研究 App 同团队签名安装已获授权。
- 每进程 QEMU 最多启动一次；VM 真退出时保存固定诊断，明确关闭重开。
- 设备标识、签名身份、凭据和原始日志只留 `build/`；Key 由用户在设备入口自行输入，不从聊天取值、不替用户输入。
- API 及 Token 消耗无需另问；外部 Git push 只用用户授权的测试远端。当前不发布 GitHub Release。
- 文档与代码改动走分支和 PR，不直接推 main；每个 PR 合并另获用户同意。
