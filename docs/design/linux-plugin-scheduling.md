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

macOS 单元测试：`swift test --package-path ios/HarnessApp --filter 'LinuxPluginTests|HarnessHostTests'`。

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

**未完成**（不算通过，见[开发交接](../agents/handoff.md)）：

- 正式候选 App 的接线：固定官方 Worker 与适配接入、QEMU 生命周期，以及准备失败后停止仍在运行的 QEMU。
- 就绪证明目前是 guest 的自报。接线时由宿主侧核对挂载的确实是本项目的原生工作区，例如经网关写一个哨兵文件，再由 guest 读回。
- iPad 真机验证，以及关口 1 用真实 VM 写者补测写租约（#17 的 2026-10-05 评论）。
- #17 要求的测量。
- 迁移演练：只用 #39 关口 6 核验过的隔离副本。
