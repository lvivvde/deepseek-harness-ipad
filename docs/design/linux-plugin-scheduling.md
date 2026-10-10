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
- `runtime/candidate`：`prepare.mjs` 从固定官方包生成网页根目录，在副本中给官方 Worker 加挂接点；`candidate-bridge.js` 把官方服务接到原生调用；`build.py` 核对输入后生成独立 Xcode 工程（`--sdk macosx` 或 `iphoneos`）。iPad 构建先按 `frameworks.json` 核对执行器闭包的集合与 SHA256，再嵌入 `Frameworks/`；只有提供私有 `--signing-file` 时才签名，签名设置只接受开发团队和描述文件两项。正式 App 的工程不改。

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
- 官方终端显示固定错误 `TERMINAL_UNSUPPORTED`，见下文缺口。
- 正常退出后不残留 QEMU，重开后没有遗留诊断。

iPad 实测（2026-10-10，签名安装到用户的 iPad）：

- `.app` 约 1.1 GB，其中 Linux 输入约 1.0 GB、执行器 22 个 framework 约 100 MB。
- 进程内 QEMU 启动 guest，项目进入 READY，官方页面正常加载（用户在设备上确认）。
- 关口 1 用真实 VM 写者补测通过。候选 App 内置 `Gate1Probe`，只在设置启动环境变量 `HARNESS_CANDIDATE_GATE1=hold|check` 时运行，走 Worker 桥接相同的操作，不需要模型或 Key：
  - `hold`：新建启用插件的项目，在 guest 中经 9P 运行 `echo run >> runs.txt; sleep 300`。命令持有写租约期间，原生写 `draft.txt` 返回 `WORKSPACE_DRAFT_HELD`，存为草稿，工作区里没有这个文件。随后从 Mac 强制结束 App（`devicectl process terminate --kill`）。此时日志中有 `leaseGrant`、`toolStart`、`draftAdd`，没有释放记录。
  - `check`（重新启动后）：项目一打开就是写者未知，30 s 后仍未自动释放；新命令被拒绝（`WRITER_UNKNOWN`），guest 没有收到；`runs.txt` 仍只有一行，命令没有重放；草稿与强制结束前逐字节一致。日志新增 `leaseUnknown` 和结果未知的 `toolEnd`。
  - 每个阶段只写固定字段到数据根下的 `probe/gate1-<阶段>.json`。

iPad 签名的注意事项：新 bundle ID 第一次用命令行签名会报 "No Accounts"。需要先在 Xcode 界面中对生成的工程运行一次，生成描述文件，之后命令行带 `-allowProvisioningUpdates` 即可复用。免费团队的 App 名额有限，安装前可能要先卸载本项目的其他 App。

**候选 App 已知缺口：**

- 交互式终端：需要 PTY 流，而 guest 协议只返回执行完的命令结果。
- 官方 Worker 自己发起的 hook 执行和 Git 写操作还没有接到 Linux。在 shell 工具里运行的 git 命令照常走 Linux。
- 项目文件监听：原生工作区还没有变更通知，`watch` 不会触发。
- 模型回合和 shell 工具的端到端，需要用户在 App 内输入 Key 后验证（macOS 和 iPad 都未验）。
- App 崩溃或被强制结束时，macOS 上的 QEMU 子进程仍可能残留；iPad 上 VM 在进程内运行，不存在这一问题。

**未完成**（不算通过，见[开发交接](../agents/handoff.md)）：

- #17 要求的测量。
- 迁移演练：只用 #39 关口 6 核验过的隔离副本。
