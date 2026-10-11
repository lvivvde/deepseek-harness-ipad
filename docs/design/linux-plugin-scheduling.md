# Linux 插件调度与项目隔离边界（#17）

本文件是 [ADR 0003](../adr/0003-native-worker-with-project-linux.md) 在正式代码里的落地合同：Linux 兼容插件怎样按项目预热、任务怎样等待和取消、VM 退出与写者未知怎样处理，以及原生与 Linux 各能访问哪些数据。私有接口检测见 [linux-plugin-availability.md](linux-plugin-availability.md)；写租约和草稿的耐久协议见 [workspace-durability.md](workspace-durability.md)；各能力走哪条路径见 [capability-declaration.md](capability-declaration.md)。

代码：

- `ios/HarnessApp/Sources/LinuxPlugin/`：每个项目的阶段、准入和能力声明，不依赖其他模块。
- `ios/HarnessApp/Sources/Host/`（模块 `HarnessHost`）：
  - `ProjectGateway` 是一个项目的唯一权威，原生读写和 Linux 命令都经过它。
  - `LinuxBringUp` 是插件的启动器。
  - `ReadyProof` 校验 guest 的就绪证明。
  - `GuestRPC` 是与 guest agent 通信的接口。

## 阶段

每个项目各有一个阶段：`disabled → preparing → ready | failed(code) | unavailable(code)`。

| 阶段 | 何时 | Linux 任务 |
| --- | --- | --- |
| `disabled` | 项目未启用插件 | 立即拒绝，`LINUX_PLUGIN_NOT_ENABLED` |
| `preparing` | 已启用的项目打开后，guest 尚未通过就绪证明 | 等待 |
| `ready` | 就绪证明通过，且 guest 已绑定当前 epoch | 执行 |
| `failed(code)` | 准备失败（`LINUX_PREPARE_FAILED`）或 VM 退出（`LINUX_VM_EXITED`） | 立即拒绝，带该码 |
| `unavailable(code)` | 私有符号缺失（`LINUX_PRIVATE_SYMBOL_MISSING`），或 Linux 已绑定到别的项目（`LINUX_BOUND_TO_OTHER_PROJECT`） | 立即拒绝，带该码 |

`failed` 和 `unavailable` 在同一进程内都不会恢复。需要 Linux 时，界面提示关闭并重开 App。

## 一个进程只服务一个项目的 Linux

每个 App 进程最多启动一次 QEMU，所以 Linux 绑定到本进程里**第一个**打开、并已启用插件的项目（用户 2026-10-09 确认）。

- 绑定发生在打开时。之后打开的其他启用项目进入 `unavailable(LINUX_BOUND_TO_OTHER_PROJECT)`，原生功能照常；界面提示关闭并重开 App 后，先打开该项目。
- 关闭项目不会解除绑定，也不会停掉 QEMU。
- 未启用插件的项目不启动 VM，也不占用绑定。
- 私有符号缺失时，没有项目会绑定。

## 预热与等待

- 打开已启用的项目时，立即在后台队列开始准备，不阻塞打开。“后台准备”只指 App 在前台期间的异步准备。
- 准备由 `LinuxBringUp` 完成：
  1. 启动 QEMU 一次。启动失败时码为 `VM_START_FAILED`。
  2. 轮询 `/ready`，直到收到回答、VM 退出（`VM_EXIT_BEFORE_READY`）或超过期限（`READY_TIMEOUT`）。
  3. 用 `ReadyProof` 校验回答。依次检查：
     - 协议版本为 1（`READY_PROTOCOL_REFUSED`）
     - 项目身份一致（`READY_PROJECT_MISMATCH`）
     - 工作区是 9P 挂载，命令可见的视图是只读的（`READY_MOUNT_REFUSED`）
     - 有 `cgroup.kill`（`READY_CGROUP_KILL_MISSING`）
  4. 用 `/bind` 把耐久 epoch 告诉 guest（失败时码为 `BIND_REFUSED`）。绑定不授予写者。

  任何一步失败，项目都进入 `failed(LINUX_PREPARE_FAILED)`，失败步骤的码作为诊断原因保存。不重试。
- 只有走完这四步才算 `ready`。guest 进程只是活着不算。
- 同一项目的所有任务共用这一次准备。只有 `linux` 路径的任务等待；原生读写、会话和搜索在准备期间照常可用。
- 执行路径在任务开始前按任务类型确定，之后不再切换。

## 取消

- **等待就绪时取消**：任务不会派发，没有副作用，也不占租约。
- **已获租约、尚未派发时取消**：释放租约（原因 `REFUSED`），工具调用记为 `CANCELLED`。
- **派发后取消**：只重试幂等的 `/cancel`，从不重发 `/execute`。
  - guest 确认取消后，任务按自己的结果结束：guest 杀掉 cgroup，回报 `writerQuiescent` 后释放租约。
  - 在取消窗口内（默认 35 秒）没能确认时，写者状态为**未知**。
- 每个操作 id 在一个网关里最多执行一次，取消之后也一样。重复提交返回 `DUPLICATE_OPERATION`。

## 写者未知

guest 断连、没回报 `writerQuiescent`，或者取消没能确认时，网关不知道写者是否已停：

- 租约保持占用，状态为 `WRITER_UNKNOWN`。此后的 Linux 任务被拒，码为 `WRITER_UNKNOWN`。
- 工具调用记为 `UNKNOWN`，不重放，也不换执行器重跑。
- 原生写继续保存为草稿。

租约只能按下表释放。只有写者停止得到证实时才释放，**从不凭超时或猜测释放**：

| 情形 | 释放方式 | 原因 | epoch |
| --- | --- | --- | --- |
| 取消超时后，同一条 `/execute` 迟到地回报 `writerQuiescent` | 该命令照常结束，由 guest 的回报证实写者已停 | `COMPLETED` | 不变 |
| 本进程派发的写者，本进程的 VM 已退出 | `guestExited` 释放，因为 VM 退出证实写者已停 | `GUEST_TERMINATED` | +1 |
| 本进程派发的写者，guest 仍在线 | 用户确认后调用 `releaseUnknownWriter`。只有 guest 的 `/revoke` 回答 `revoked: true` 才释放；guest 回答仍在运行或不可达时，租约保持 | `RECONCILED` | 不变 |
| 租约来自更早的 App 进程 | 用户确认后调用 `releaseUnknownWriter`。旧进程的 VM 已随进程消失 | `RECONCILED` | 不变 |

释放时，写者留在工作区里的内容按原样提交，并记入一个代际；被挡下的草稿按基线重放。`RECONCILED` 不改 epoch，因为新 guest 启动时已绑定当前 epoch，而 guest 不接受改绑到另一个 epoch（`EPOCH_CONFLICT`）。

这取代了研究 App 在就绪时自动对账租约的做法，与关口 1 “不自动释放”的规则一致。

## VM 退出

QEMU 退出后：

1. 先保存固定诊断：错误码、项目、阶段（`PREPARING` 或 `READY`）、退出状态，以及准备失败时的原因。保存完成后，阶段才变为 `failed`。只保存第一条：之后的失败、重复的退出和迟到的启动结果都被忽略。因此，准备已因 `READY_TIMEOUT` 或证明被拒而失败后，QEMU 再退出不会另存一条；此时仍在运行的 QEMU 由 App 接线负责停止，见文末“未完成”。
2. 阶段变为 `failed(LINUX_VM_EXITED)`，等待中的任务立即被拒。
3. 释放本进程派发的写者所持的租约（`GUEST_TERMINATED`）。更早进程留下的写者未知租约不受影响，仍等用户确认。
4. 同一进程内不重新初始化 QEMU。界面提示关闭并重开 App。

## 数据访问范围与项目隔离边界

所有项目共用一个 App 沙盒容器和同一个 uid。**这个容器不是项目隔离**，下面的边界才是。

**原生侧**

- 原生侧只通过本项目的 `ProjectGateway` 访问本项目的工作区。路径一律相对工作区根解析：父目录逐级用 `O_NOFOLLOW` 打开，符号链接越界被拒绝。
- 会话、草稿和日志各自存放在项目的状态目录中。
- 原生代码在技术上能读到容器里的其他项目，所以这道边界靠代码结构维持，内核不强制。

**Linux 侧**

- guest 只挂载一个工作区：本进程绑定的那个项目，经 9P 挂载，共享模式为 `none`。其他项目的工作区、会话、草稿、日志和 App 状态都不进入 guest。
- 命令看到的 `/workspace` 是只读 bind。只有持有租约的命令才进入私有 mount namespace，并只把自己的视图改为可写；不持租约的命令以 reader uid 运行。
- 每个命令有自己的 cgroup。结束、超时或取消时，guest 先杀掉整个 cgroup，再回报 `writerQuiescent`。

**已知缺口**

以下缺口保留，作为后续加固项：

- 持租命令与 guest 内其他同 uid 进程之间，可以经 `/proc/<pid>/cwd` 写入或经 `SCM_RIGHTS` 传递文件描述符。
- 写租约的 CAS 存在 TOCTOU 窗口。

这类写入不会被实时阻止，而是**事后检测并转为冲突**：

- 原生写之前，先核对磁盘指纹。
- 租约释放时，扫描工作区。

差异记为 `external` 代际，受影响的原生修改保存为冲突草稿。独立 uid 或更强的隔离不在 #17 范围内。

## 验证

macOS 单元测试：`swift test --package-path ios/HarnessApp --filter 'LinuxPluginTests|HarnessHostTests|HarnessCandidateTests'`，以及 `make test-candidate`（Worker 桥接、官方锚点与构建闸门）。

- `LinuxPluginTests`：阶段、准入、首个项目绑定、VM 退出诊断、准备失败原因，以及缺失与存在两个分支。
- `ReadyProofTests`：就绪证明的四项检查。
- `LinuxBringUpTests`：只启动一次、轮询直到证明、VM 提前退出、超时、证明被拒和绑定失败。
- `ProjectGatewayTests`：
  - 持租执行，期间的原生写变成草稿
  - guest 拒绝后释放租约
  - 断连和未确认的结束时写者未知，并跨重开耐久保存
  - 等待中取消与派发后取消
  - VM 退出时释放（`GUEST_TERMINATED`）
  - 重启后和在线 guest 撤销 fence 后的显式释放

guest agent 本身（`/bind`、`/execute`、`/cancel`、`/revoke`）用的是写租约研究中的 `runtime/prototypes/plan500-lease/agent.cjs`，这里只测网关对它的调用合同。

## 候选 App（macOS 与 iPad）

正式候选 App 的 bundle ID 为 `org.lvivvde.harness.candidate`，与正式 App 分开。代码在正式源码树中：

- `ios/HarnessApp/Sources/Candidate`（模块 `HarnessCandidate`）：`CandidateHost` 是 Worker 唯一的原生权威，负责项目、文件、子进程、Linux 执行与取消、模型流和 Worker home 检查点。VM 接口 `GuestMachine` 有两个实现：macOS 上的 `QemuMachine` 是子进程；iPad 上的 `EmbeddedMachine` 把随包的 QEMU framework 载入 App 进程，在单独线程上运行。两者共用同一组 guest 参数（`GuestArguments`）。
- `ios/HarnessApp/CandidateApp/Sources`：SwiftUI 外壳，以及装载官方页面的 WKWebView 与回环资源服务。
- `runtime/candidate`：`prepare.mjs` 从固定官方包生成网页根目录，在副本中给官方 Worker 加挂接点；`candidate-bridge.js` 把官方服务接到原生调用；`build.py` 核对输入后生成独立 Xcode 工程（`--sdk macosx` 或 `iphoneos`）。iPad 构建先按 `frameworks.json` 核对执行器闭包的集合与 SHA256，再嵌入 `Frameworks/`；只有提供私有 `--signing-file` 时才签名，签名设置只接受开发团队、签名方式和描述文件三项。正式 App 的工程不改。

接线行为：

- 打开启用插件的项目后异步预热。每个进程只启动一次 QEMU，挂载项目工作区（9P，`none`）。
- 就绪后由宿主核对挂载（`MountCheck`）：宿主直接在原生工作区写入保留名哨兵文件 `.dsh-mount-check`，不经网关和耐久层，再由 guest 读回。哨兵名是保留名，工具看不到。核对失败视为准备失败，并停止仍在运行的 QEMU。
- macOS 上 App 退出时停止 QEMU，这次退出不记为 Linux 失败。iPad 上 QEMU 随进程结束；`EmbeddedMachine.stop` 经 QMP 发 `quit`，串口和 QMP 都用 socketpair，不监听路径或额外端口。载入的 QEMU 不能在进程内重启，第二次启动直接拒绝。
- VM 意外退出时，先保存固定诊断，再在侧栏提示关闭并重开 App。本进程内 Linux 不再恢复。
- 写者未知时，项目侧栏显示提示和"Release writer…"按钮。用户确认后才调用 `writer-release`：命令留在工作区的内容按原样保留，暂存的草稿在其上变基。
- shell 命令在 guest 中以 `/bin/sh -c` 运行（Alpine 的 BusyBox ash），不是 bash。官方工具发出的 `bash -c` 只取命令文本，依赖 bash 语法的命令可能失败。
- 网页只能停留在回环资源服务的源上，原生调用和日志也只接受这个源的主框架。用户点击的外部链接交给系统浏览器打开。
- 侧栏显示每个项目的能力声明（`native` / `linux` / `unsupported` 及原因），其中候选 App 的缺口也逐项列出，见 [capability-declaration.md](capability-declaration.md)。
- Key 只在内存中，由用户在 App 内输入。

macOS 实测（2026-10-10，Homebrew QEMU，数据根指向忽略的 `build/candidate/run`）：

- 新建启用插件的项目并打开，阶段由 PREPARING 进入 READY，guest 输出就绪标记。
- 官方前端完整加载。工作区文件面板经原生网关列出并读取了项目文件。
- 官方终端显示固定错误 `TERMINAL_UNSUPPORTED`（当时终端尚未接入，见下文交互式终端）。
- 正常退出后不残留 QEMU，重开后没有遗留诊断。

iPad 实测（2026-10-10，签名安装到用户的 iPad；设备验收部分完成，模型与 shell 端到端见下文缺口）：

- `.app` 约 1.1 GB，其中 Linux 输入约 1.0 GB、执行器 22 个 framework 约 100 MB。
- 进程内 QEMU 启动 guest，项目进入 READY，官方页面正常加载（用户在设备上确认）。
- 关口 1 用真实 VM 写者补测通过。候选 App 内置 `Gate1Probe`，只在设置启动环境变量 `HARNESS_CANDIDATE_GATE1=hold|check` 时运行，走 Worker 桥接相同的操作，不需要模型或 Key。每个阶段自己判定，全部条件成立才记 `passed`；`check` 还把草稿摘要与 `hold` 的记录比对：
  - `hold`：新建启用插件的项目，在 guest 中经 9P 运行 `echo run >> runs.txt; sleep 300`。命令持有写租约期间，原生写 `draft.txt` 返回 `WORKSPACE_DRAFT_HELD`，存为草稿，工作区里没有这个文件。随后从 Mac 强制结束 App（`devicectl process terminate --kill`）。从设备拉回的日志中有 `leaseGrant`、`toolStart`、`draftAdd`，没有释放记录（人工核对）。
  - `check`（重新启动后）：项目一打开就是写者未知，30 s 后仍未自动释放；新命令被拒绝（`WRITER_UNKNOWN`）；`runs.txt` 仍只有一行，命令没有重放；草稿与强制结束前逐字节一致。拉回的日志新增 `leaseUnknown` 和结果未知的 `toolEnd`（人工核对）。被拒绝的命令不进入 guest，由单元测试覆盖，真机上没有单独观测。
  - 每个阶段只写固定字段到数据根下的 `probe/gate1-<阶段>.json`。

iPad 签名的注意事项：新 bundle ID 第一次用命令行签名会报 "No Accounts"。需要先在 Xcode 界面中对生成的工程运行一次，生成描述文件，之后命令行带 `-allowProvisioningUpdates` 即可复用。免费团队的 App 名额有限；需要腾名额时，只卸载用户授权过的本项目占位 App（Harness 占位版、DeviceAcceptance 运行器）或本项目旧的候选 IPA，不动 LinuxPrototype 和正式 Harness 的数据。

**hook 与项目文件监听：**

- 项目内的 hook（官方 `runHook` 带 stdin 调用 shell 的 `execute`）作为独立的 Linux 任务运行，触发方式 `hook`。在 hook 的 `workdir` 中运行；环境变量先导出，环境变量和 JSON payload 中的项目路径换成 guest 的 `/workspace`，payload 经 `printf` 回放到命令的 stdin。整条请求超过 128 KiB 时，宿主在发出前拒绝（`BODY_TOO_LARGE`），写租约随即释放，hook 按阻止处理。没有跑完的 hook 一律按阻止处理：退出码 2，stderr 为 `DSH_HOOK_NOT_RUN <原因>`，原因包括 `REFUSED` 的具体原因（如 `WRITER_UNKNOWN`）、`HOOK_TIMEOUT`、`HOOK_CANCELLED` 和 `CANCELLED_BEFORE_DISPATCH`。官方网页版目前不加载 hook 插件，所以这条路径只由桥接测试（使用官方 `runHook`）覆盖，真机上没有调用方。
- 项目内的 `watch` 每 2 秒经网关比对原生存储：文件比对类型、版本和大小，目录比对直接子项。每条 Linux 命令或 hook 结束后立即再比对一次。有变化就通知订阅方；比对进行中又有命令结束时，再比对一轮。读取失败也算一次变化，只通知一次、不带错误，订阅方重读时会看到错误。取消订阅后不再轮询。

**交互式终端：**

- 项目内的官方终端在 guest 的 pty 上运行 `/bin/bash -i`，输出由桥接长轮询读回（每次最多等 20 s），交给官方终端控制器。宿主只接受 `/bin/bash -i`，因为只有它能报告空闲提示符，而释放租约靠的就是这个；环境变量只接受 `DSH_` 开头的名字，同时最多 16 个终端。
- 终端有自己的挂载命名空间，工作区默认只读。空闲时不占写租约，模型和文件面板照常工作。
- 输入里含运行键（Enter、Ctrl-J、Ctrl-O、Ctrl-X）时，先取写租约，再把这个终端的视图改成可写。租约被占用时，桥接每 250 ms 重试，最长 70 s，之后返回 `LEASE_BUSY`；写者未知时返回 `WRITER_UNKNOWN`。
- 命令运行期间，其他 Linux 命令（模型的 shell 命令、hook）并入终端的租约（同一 fence），不另取租约；原生写入照常存为草稿。
- shell 回到空闲提示符、并入的命令都已结束后，guest 把视图改回只读，宿主释放租约。在读输出时释放的，随即比对一次项目文件监听；其他情况由 2 秒一次的比对发现。仍有文件以写方式打开时改回只读会失败，租约保留到下一次空闲。
- 空闲要等 bash 打印新的提示符才算。停在续行提示符（PS2）、按了 Ctrl-X 组合键但没有运行，或者 `~/.bashrc` 设了 `trap`（这时活动状态始终为 `unknown`），都不算空闲，租约保留到下一个提示符或关闭终端。
- 关闭终端时先向 shell 发 SIGHUP，再结束终端 cgroup 中剩下的进程，然后释放租约。shell 没有退出时不释放，关闭失败（`TERMINAL_BUSY`），可以再关。
- 终端的写者未知时（如写入的应答丢失），按"Release writer…"会结束这个终端。新 Worker 安装时（如刷新页面）宿主关闭上一个 Worker 留下的终端；VM 退出时全部终端作废。

**候选 App 已知缺口：**

- 常驻 bash（`dsh-terminal-bash`，只在非默认的 minimal 预设中启用）：它的 argv 由 Worker 的沙箱启动器生成，guest 拒绝（`ARGV_REFUSED`），不能用。默认预设的 bash 工具走 `bash -c`，不受影响。
- 交互式终端只在 Mac 上的 QEMU guest 中逐项验证（pty、运行键取租约、并入、空闲释放、关闭），iPad 上的官方终端面板端到端未验。macOS 候选 App 中 Linux 不可用（私有符号缺失），只能在 iPad 上验。
- 官方 Worker 发起的 Git 写操作：官方网页版没有这样的调用方。Worker 自己调用的 git（变更审阅）解析到原生只读 Git，超出子集以退出码 128 拒绝；会修改仓库的 git 命令在 shell 工具里运行，走 Linux。
- 模型回合和 shell 工具的端到端，需要用户在 App 内输入 Key 后验证（macOS 和 iPad 都未验）。
- App 崩溃或被强制结束时，macOS 上的 QEMU 子进程仍可能残留；iPad 上 VM 在进程内运行，不存在这一问题。

**未完成**（不算通过，见[开发交接](../agents/handoff.md)）：

- #17 要求的测量。
- 迁移演练：只用 #39 关口 6 核验过的隔离副本。
