# 开发交接

最后更新：2026-10-11，北京时间。此文件是接手入口，只记当前状态、约束和资产入口；GitHub Issues 是任务状态源，过往过程以 git 历史、研究报告和验收记录为准。

## 开始工作

1. 读根 `CONTEXT.md`、相关 `docs/adr/`，检查 `git status --short`、当前分支和最新提交。保留已有未提交改动。
2. 查 `gh pr list --state open` 和下表涉及的 Issues。已有待合并分支时先继续该分支，避免重新实现；每个新 PR 合并都另获用户同意。
3. 真机任务读 [真机自动化](../validation/ipad-device-automation.md)；其他任务读对应验收记录。先用只读 `probe` 确认连接，按明确缺项推进，减少用户交互。
4. 完成后更新本文件的状态、验证和下一步；原始日志/设备/签名参数保存到忽略的 `build/`，公开文档只记脱敏结果。

## 当前状态

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
- 未验：模型回合和 shell 工具的端到端，需要用户在 App 内输入 Key。
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
- 交互式终端在分支 `feat/issue17-candidate-terminal`（2026-10-11，租约规则由用户确认：空闲不占写租约，运行时模型 shell 命令并入）：
  - guest 代理新增 `/terminal/*`：pty 上的 `/bin/bash -i`，独立挂载命名空间，默认只读；运行键取租约后改为可写，回到空闲提示符且并入的命令结束后改回只读并释放。
  - `ProjectGateway` 终端 API 和并入路径（结果 `.joined`）；`CandidateHost` 的 `terminal-*` 原生调用，新 Worker 安装时 `terminals-reset` 关闭旧终端；声明里 `terminal` 随 `shell`，可用时附 `WRITE_LEASE_WHILE_BUSY`。
  - 桥接 `spawnTerminal` 返回官方终端控制器所需的句柄（输出流用 Worker 自己的 `PassThrough`）。
  - 两轴审查后修正：重复关闭时 guest 按宿主发来的 fence 报告已释放，宿主对关闭后未确认的租约记写者未知，不再留下活动租约；shell 未退出时 guest 关闭失败、不释放；`/terminal/unlease` 返回后先核对租约仍是同一个；宿主只开 `/bin/bash -i`（`/bin/sh` 报告不了空闲提示符，租约会一直占着）。`CONTEXT.md` 新增术语“并入”。
  - 保留未改：`inspectForeground`/`signalForeground` 和 guest 的 `inputWaiting` 目前只有被拒的常驻 bash 会用，作为官方终端句柄接口的完整实现保留；hook 也会并入终端租约，文档已写明。
  - 缺口：minimal 预设的常驻 bash 被 guest 拒绝（`ARGV_REFUSED`）；iPad 上官方终端面板未验。
  - 已验证（macOS）：真实 QEMU guest 的 `run.py` 探针（含终端 18 项）通过；`make test-app`（网关 25、候选宿主 15）、`make check`、`make test-candidate`（桥接 15、构建 15）、`make test-plan500-ipad` 通过。

**下一步：**

1. iPad 上验交互式终端（不需要 Key）：在启用插件的项目中打开终端，运行 `echo hi > f`，文件面板应看到 `f`。
2. 模型回合与 shell 工具端到端：用户在 iPad 候选 App 内输入 Key 后验证。
3. #17 要求的测量和迁移演练。
4. 用 iPad 候选构建收据补全 #14 清单，包括 `system.raw` 的构建配方。

## 开放任务

| Issue | 依赖与边界 |
| --- | --- |
| [#15 路线图](https://github.com/lvivvde/deepseek-harness-ipad/issues/15) | 总入口；执行顺序 39→17→18→23→14。#1、#16、#19、#32、#39 已关闭，作为历史保留。 |
| [#17 实现](https://github.com/lvivvde/deepseek-harness-ipad/issues/17) | 当前任务，进度见上文“#17 进展”。实现原生 Harness 宿主、同一项目工作区、Linux 预热及准备/就绪/取消/失败调度；保留旧 Linux 和用户盘保护。资源、低空间、删除回收等未验项转兼容插件技术债，不标记通过。 |
| [#18 Git 开发闭环验收](https://github.com/lvivvde/deepseek-harness-ipad/issues/18) | 被 #17 阻塞。按能力声明区分路径；Git 写与 hook 走 `linux`；推送只用用户授权的测试远端。仍带 `needs-triage`。 |
| [#23 插件/预览/键盘/前后台验收](https://github.com/lvivvde/deepseek-harness-ipad/issues/23) | 被 #18 阻塞。“重试”是重提任务，同进程不重启 QEMU；dev server 默认 `linux`；阈值在开工前提出并经用户确认。仍带 `needs-triage`。 |
| [#14 许可证与对应源码审查](https://github.com/lvivvde/deepseek-harness-ipad/issues/14) | 被 #17 的实际组件清单阻塞，可与交互验收并行准备；含 Worker bundle、适配补丁、原生只读 Git 与原生搜索。不发布 GitHub Release。仍带 `needs-triage`。 |

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
- 验收：[非锁屏](../validation/ipad-non-lock-acceptance.md)、[后台恢复](../validation/ipad-background-recovery.md)、[备份恢复](../validation/ipad-recovery-backup.md)、[存储工具](../validation/ipad-storage-tools.md)、[签名维护](../validation/ipad-signing-maintenance.md)、[插件预览](../validation/ipad-plugins-preview.md)。

## 本机接手资产

全部在忽略的 `build/`，路径相对仓库根；其他机器可从源码重建工具，但需重新配对、签名和准备本机资源。原始证据不可贴聊天、提交或公开。

- `build/device-acceptance/local-settings.json`：本机 runner 签名设置（权限 600）；多设备时用 `selected-device-private.json`。runner xctestrun 在 `build/device-acceptance/portable-signed-final/derived/Build/Products/`，测试源码变更后按真机工具说明重建。
- `build/test-dependencies/harness/`：固定官方 `@deepseek-ai/dsh@0.2.0-rc.2`、pnpm 11.28.4 的宿主测试依赖和 lock。设置 `HARNESS_TEST_MODULES="$PWD/build/test-dependencies/harness/node_modules"` 后运行 `make test-runtime`，核对无跳过。依赖丢失时用保留的 lock 重装。
- Lima `ubuntu` 内 `/var/tmp/ipad-bundled-guest-storage-v6` 可跑 Linux 验收，使用新临时盘；`/Users/edwin` 只读挂载，`/private/tmp` 不挂载。Linux/QEMU 只用隔离盘，不读 iPad 原盘。
- 正式包：`build/maintenance19/r2-7956e8c/`。研究 App 与收据：`build/prototypes/plan500-ipad/`（`device-r1/` 签名与两模式收据，`worker-device-r1/`、`r2/`、`r4/` 协作与模型收据）；macOS 原型收据在 `build/prototypes/plan500-{worker,sharing,lease,darwin}/`。
- #39 关口：`build/issue39-gate1/`（从 `device/durability-safe.json` 看起）；`build/issue39-gate3/device/`（关口 2、3、4 的收据与 `device-private.py`）；`build/issue39-gate6/`（合成矩阵，`device/gate6-private.py` 与收据）；`build/issue39-gate5/`（`device/device-private.py`，步骤为 sign、install、launch、wait；收据在 `device/*-safe.json`，macOS 运行在 `mac-3/` 和 `mac-push-dry/`）。研究 App 已于 2026-10-10 卸载以腾出名额，演练 App `g6drill` 已卸载；iPad 上现装候选 App `org.lvivvde.harness.candidate`（现为 r5 构建；内有用户建的项目 Gate1 和探针项目 gate1-probe-2 至 4，均保持写者未知，可随时整体卸载）。
- #17 候选 App：`build/candidate/CandidateWeb`（网页根目录与 `candidate-receipt.json`）；`build/candidate/app/`（生成的工程、`build-private.log`、`build-safe.json` 和 `.app`）；`build/candidate/run/`（macOS 实测的数据根，含私有日志和测试项目 `demo`）。
- #17 iPad 候选：`build/candidate/ipad-signed-r5/`（现装签名构建与收据）；`build/candidate/ipad-signed/project` 是注入团队后供 Xcode 界面首次运行的工程；`build/candidate/device/device-private.py`（步骤 free-slot、install、launch、gate1 hold|check、running、terminate、pull SUBDIR DEST）。一键复测：`python3 build/candidate/device/gate1-auto-private.py <.app> <上次 hold.json 相对 device/ 的路径>`，安装、hold、强制结束、check 全自动，只打印 `HOLD_PASSED`/`CHECK_PASSED`。关口 1 证据：最新 `device/gate1-auto-204420/`（`hold.json`、`check.json`）；首次手动版在 `device/gate1-killed/` 与 `device/gate1-checked/`。
- 历史归档：`build/acceptance-archive/2026-10-05/`（旧日志、xcresult、截图、脱敏结果与 SHA256 清单）；Issue 正文备份与草稿在 `build/issue-drafts/`。
- `harness-30` 锁屏提醒已暂停，保持取消。

## 持续约束

- 保护正式 Harness 数据、草稿、Git 历史和有效备份；覆盖升级只用同签名身份，保留原盘；原盘迁移只经校验副本。设备备份不导出到 Mac 或仓库。
- 免费开发团队的 App 名额有限。用户已授权按需卸载本项目占位 App（Harness、LinuxPrototype、DeviceAcceptance runner）及后续项目 IPA，不再重复询问；不扩展为其他 App 或无关数据。研究 App 同团队签名安装已获授权。
- 每进程 QEMU 最多启动一次；VM 真退出时保存固定诊断，明确关闭重开。
- 设备标识、签名身份、凭据和原始日志只留 `build/`；Key 由用户在设备入口自行输入，不从聊天取值、不替用户输入。
- API 及 Token 消耗无需另问；外部 Git push 只用用户授权的测试远端。当前不发布 GitHub Release。
- 文档与代码改动走分支和 PR，不直接推 main；每个 PR 合并另获用户同意。
