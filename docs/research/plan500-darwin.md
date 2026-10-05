# 方案500：Darwin 宿主 9P 与 Swift 网关验证

2026-10-05，北京时间。用户要求“继续下一步”，按[写租约报告](plan500-write-lease.md)记录的下一关口执行：Darwin 文件行为与 9P backend，以及 Swift 网关。继续 [Issue32](https://github.com/lvivvde/deepseek-harness-ipad/issues/32)、[PR36](https://github.com/lvivvde/deepseek-harness-ipad/pull/36)。源码与复跑入口见 [Darwin 探针](../../runtime/prototypes/plan500-darwin/README.md)。

## 结论

**macOS 宿主上，QEMU 的 Darwin local fsdev 能承载未修改的写租约合同，Swift 网关可以替换 Python 网关。** 两种卷（区分大小写的 APFS 稀疏镜像、默认卷）× 两种网关（Python、Swift）× 两种 9P 模式（`none`、`mapped-xattr`）都运行了原样的 26 项必需检查。加连接闸门后共 48 个模型运行，47 个 26/26 通过，1 次失败疑为检查自身的时序竞争，见[实测](#实测)。

本轮还发现三项 Darwin 特有的约束，产品设计必须先处理：

1. **`none` 模式下，共享工作区里无法创建 FIFO 和 Unix socket。** guest 的 `mkfifo` 得到 ENXIO，`listen()` 得到 ENOTSUP。原因在 QEMU 的 Darwin backend 源码，正式 IPA 内嵌的 UTM 10.0.12 使用同一份代码，因此 iPad 上预计行为相同（尚未在真机执行）。`mapped-xattr` 能创建这两种文件，但它们在宿主上只是普通文件加 `user.virtfs.*` xattr；guest 的 chmod 与 symlink 在宿主上也不再是普通 mode 与 symlink。
2. **hostfwd RPC 在 Darwin 宿主上会随机被重置。** libslirp 对 hostfwd 监听使用 `listen(s, 1)`。XNU 对超出 accept 队列的连接回 RST，Linux 则让连接继续等待。并发 RPC 因此偶发 `ConnectionResetError`。正式 IPA 内嵌的 libslirp 4.9.1 使用同一行代码。在探针前加“一次只建立一个上游连接”的闸门后，48 个模型运行中不再出现重置。
3. **大小写不敏感的卷上，只差大小写的两个文件名会静默合并。** guest 第二次创建返回成功，实际打开的是已有文件。

**仍未通过 G3，也没有在 iPad 上运行。** QEMU 是 Homebrew 11.1.2 在 macOS 上运行，不是 IPA 内的 10.0.12 iOS 构建。Swift 网关只是研究 harness 的子进程，没有进入 App 进程、QemuBridge 生命周期或官方 Worker 的原生写入路径。同 uid 经 `/proc` 的绕过仍然存在。本结果不能用于关闭 #32、启动 #17 或改选 ADR。

## 输入和隔离边界

Linux 端（既有 Lima）用 `run.py prepare` 复用写租约探针的 guest 打包，再把输出复制到 Mac 的忽略目录。Mac 端用 Homebrew QEMU 11.1.2（TCG、aarch64、1 CPU、1GiB）启动，9P 共享 macOS 目录，`writeout=immediate`。区分大小写的卷用 `hdiutil` 临时创建并在结束时 detach 删除。

| 输入 | SHA256 / 版本 |
| --- | --- |
| kernel `6.18.52-0-virt` / Image | `06196d2cf51e9a2bac421564bb64c63a8b7146c9a22755dd22a713e337023013` |
| 只读 system.raw | `a1a33f394f393bb408cabec3b92a186de88e6125d83a8e9591b2506cb1b91d5f` |
| 锁定 modloop-virt | `e96d6f26f7bc7ce64946deb60dae5e3728d73ecd4f37bc59d974a2027cba825b` |
| 探针 initramfs | `5e46d3ce0cb4a1155e08764200da55741038dafa50ac997270d25c033588f191` |
| plan500-lease run.py / init.sh / agent.cjs（未修改） | `d58ddefd…d579`、`2cf2658d…589a`、`e219a850…c0fc`，与[写租约报告](plan500-write-lease.md)一致 |
| plan500-sharing/run.py（未修改） | `81c4a8613baeda2a3a3e0e6c905a00112e0506f43f3b8b4350f950353f4516e6` |
| plan500-darwin/run.py | `53cd9d6dca86399eef649394023825cbbdcf17ae9472b3d79f99932206914580` |
| plan500-darwin/backlog.py | `18d0231bdd6312eb27781729453425cb861441fae93132e3fdc0804054d11ce5` |
| Swift 网关 release 二进制 | `b42a35445e02e1d36eba519f0c0a12c8c7bed0dbd420913fba41d55a6fd411a0` |
| 宿主 | macOS 27.0.1 arm64，Swift 工具链见收据 |

Swift 源文件：Package.swift `534b6f76…`，Gateway.swift `ba851614…`，Transport.swift `6dfc969c…`，Workspace.swift `3f9d2054…`，main.swift `88741ae6…`，GatewayTests.swift `3122b473…`（完整值在收据中）。

没有读取 user.raw/user-seed.raw 或 iPad 原盘：inputs.json 只从内置运行时清单抄录这些文件的 SHA256。没有接触设备、签名、安装、外部模型或项目远端。token、串口、QEMU 日志和 traceback 只留在忽略的 `build/` 下。

## 正式 IPA 的静态证据

只读检查当前正式包 `7956e8c` 中的 `qemu-aarch64-softmmu.framework`：

- 平台 iOS，minos 15.0，SDK 27.0；版本字符串 `QEMU emulator version 10.0.12`。
- 包含 `virtio-9p-pci`、`local`、`security_model`、`passthrough`、`mapped-xattr`、`mapped-file` 字符串。
- 导入 `_fgetxattr`、`_flistxattr`、`_fremovexattr`、`_fsetxattr`、`_mknod`、`_bind`、`_socket`，以及 **weak import** 的 `_pthread_fchdir_np`。
- 同包 `slirp.0.framework` 版本字符串为 4.9.1，导入 `_listen`、`_accept`。

因此 IPA 已编入 Darwin 9P backend，并在运行时依赖私有 `pthread_fchdir_np`。若系统缺少此符号，QEMU 只会报告 `pthread_fchdir_np() not available on this version of macOS`，mknod/socket 操作失败。这些都是静态证据，不证明 iPad 运行时行为或 App Review 可接受性。

## QEMU 源码中的 FIFO/socket 原因

上游 v10.0.12、v11.1.2 与 UTM 的 `utm-edition` 分支（VERSION 10.0.12，提交 `b795d6de88fc52cb6ff061e0e034be51d8e9c474`）中，相关代码相同。v10.0.12 文件 SHA256：`hw/9pfs/9p-util.h` `03c235f5…172`、`9p-local.c` `703d461c…4a6`、`9p-util-darwin.c` `aaf52b51…91d`。

- `none`/`passthrough` 的 `local_mknod` 先调用 `qemu_mknodat`：`pthread_fchdir_np(dirfd)` 后执行 `mknod`，socket 则通过 `create_socket_file_at_cwd` 执行 `bind`。随后 `local_set_cred_passthrough` 调用 `fchownat`（`none` 忽略其失败）和 `fchmodat_nofollow`。
- Darwin 没有 `O_PATH`（`O_PATH_9P_UTIL` 为 0），`fchmodat_nofollow` 必须真正打开文件。`openat_file` 遇到 FIFO 时由 `close_if_special_file` 返回 ENXIO（CVE-2023-2861 的修复），socket 则无法打开（EOPNOTSUPP，guest 中表现为 ENOTSUP）。失败后 `unlinkat_preserve_errno` 删除刚创建的节点。
- `mapped-xattr`/`mapped-file` 不创建真实节点，而是创建普通文件并把类型与 mode 写进 `user.virtfs.*`，所以 guest 内“成功”。

在 macOS 上用 C 程序复现了同一系统调用序列：`pthread_fchdir_np`、`mknod` FIFO、`bind` socket 和 `fchownat` 都成功；FIFO 以 `O_RDONLY|O_NONBLOCK` 打开并 `fchmod` 成功；socket 打开失败（Operation not supported on socket）。这说明失败来自 QEMU 选择的打开方式，而不是 Darwin 不支持这些文件类型。

## 实测

### 必需检查

加连接闸门（见下节）后先运行一轮四种组合，再连续重复 5 轮，共 24 次探针、48 个模型运行，每个模型运行 26 项必需检查：

| 卷 | 网关 | `none` | `mapped-xattr` |
| --- | --- | --- | --- |
| 区分大小写 APFS | Python | 6/6 次 26/26 | 6/6 次 26/26 |
| 区分大小写 APFS | Swift | 6/6 次 26/26 | 6/6 次 26/26 |
| 默认（不区分大小写） | Python | 5/6 次 26/26 | 6/6 次 26/26 |
| 默认（不区分大小写） | Swift | 6/6 次 26/26 | 6/6 次 26/26 |

48 个模型运行中 47 个通过，加闸门后没有任何一次连接重置。唯一的失败发生在第一轮的默认卷 + Python + `none`，前 24 项通过，“只有 VM 退出才能释放不可达写者”一项断言失败。收据中 release 的 reason（GUEST_TERMINATED）与 changed（crash-effect）都正确，未记录的条件是 lost 状态、epoch 递增和 `crash-effect` 内容是否为 `partial`。该检查在文件出现时就杀 VM，而 9P 上创建与 `printf` 写入是两个操作，杀进程可能落在两者之间。这是最可能的原因，但未经证实；后续 20 次同类运行都通过。

最终收据都记录了相同的 lease 源码 SHA256 与 `run.py` `53cd9d6d…4580`。最终 generation 19、epoch 2、fence 15，与 Linux 轮次一致。

### Darwin 文件行为（观察项，不计入通过数）

两种网关结果一致；只有大小写一项随卷变化：

| 观察项 | `none` | `mapped-xattr` |
| --- | --- | --- |
| 只差大小写的文件名 | 区分大小写的卷：两个文件；默认卷：只剩一个，guest 未报错 | 同左 |
| NFC 与 NFD 文件名 | 保持两个文件，宿主字节不变 | 同左 |
| guest chmod/symlink 在宿主 | 普通 0755 与真实 symlink | 宿主为 0600 普通文件，mode/类型存在 `user.virtfs.*` |
| 宿主 mode/symlink 在 guest | 可见、可执行 | 可见、可执行 |
| FIFO | `mkfifo` 失败，ENXIO | guest 内成功；宿主为普通文件 |
| Unix socket | `listen` 失败，ENOTSUP | guest 内成功；宿主为普通文件 |
| rename 覆盖已打开文件 | 旧 fd 仍读旧 inode | 同左 |
| 400 个小文件写入 | 释放后宿主全部可见，扫描约 1ms | 同左 |

写租约合同自带的两项观察与 Linux 相同：只读视图中 `git status` 可用；同 uid 无租进程经 `/proc/<leased>/cwd` 写入**未被阻止**。guest 轮询看到原生写入约 33–118ms。

### Swift 网关

- `Plan500Gateway` 是 Python 网关的移植。路径按字节比较（Swift `String` 相等会把 NFC/NFD 合并），目录遍历用 `openat` + `O_NOFOLLOW`，原子写入用 `O_EXCL` 临时文件、`F_FULLFSYNC`、`renameat` 并同步目录。
- 合同中的“网关崩溃”对 Swift 进程发送真实 SIGKILL。被杀的 Python 网关线程仍会等到 guest 命令结束，Swift 进程做不到，所以代理在返回 CRASHED 前等满该命令的 agent 侧超时再加 2 秒，不改动状态。首轮的 restarted-gateway 检查曾因代理立即返回而失败，修正后通过。VM 是否已退出由 harness 告诉 `reconcile`，在 iPad 上对应 QemuBridge 的职责。
- 单元测试：macOS `swift test` 11/11；iOS 模拟器（iPad Pro 13-inch (M5)）`xcodebuild test` 11/11。模拟器使用 Mac 文件系统，不代表 iPad 沙箱容器。

## hostfwd 连接重置

修正前的首批完整运行中，8 个模型运行（2 卷 × 2 网关 × 2 模式）里有 5 个在合同中途出现 `ConnectionResetError: [Errno 54]`；在 Linux 宿主上的写租约轮次从未出现。

- 在 QEMU netdev 上加 `filter-dump` 抓 guest 侧报文：guest **没有**发出 RST，slirp 也没有为被重置的连接向 guest 转发 SYN。抓包止于 consumer 的 `/execute` 请求被确认，约 0.3 秒后客户端收到重置。说明重置发生在宿主侧，guest agent 从未见到该连接。
- libslirp v4.9.5 与 v4.9.1（IPA 所用版本）的 `tcpx_listen` 都调用 `listen(s, 1)`（v4.9.1 `src/socket.c` SHA256 `bf883af1390b9297b3fd3c948b33c9d899d86281d227d50b54919489b6de7294`，第 871 行）。QEMU 主循环忙于 TCG 时，第二个连接在第一个被 accept 前到达。
- `backlog.py` 在不启动 VM 的情况下复现：backlog 1 的监听暂停 0.5 秒再 accept，2/3/4/6 个客户端并发连接并发送。macOS 27.0 上只有 1 个成功，其余全部 `ConnectionResetError`；Lima 中 Linux 7.0 上全部成功。

在 macOS 上用户态 harness 无法改变 slirp 的 backlog，因此 `run.py` 在 hostfwd 前加了一个中继：一次只建立一个上游连接，并在连接上先做一次未认证往返（agent 回 403，keep-alive）证明 slirp 已 accept，之后才释放闸门、原样转发客户端字节。往返前的失败和之后的重置都以重置交给客户端，断连仍然可观察。加闸门后的 48 个模型运行中未再出现重置。

对产品的含义：RPC 丢失时，合同把租约保持为 WRITER_UNKNOWN/HELD，因此重置不会破坏正确性，但会降低可靠性。iPad 上的 App 需要相同的连接闸门、单个长连接复用，或改用不经 accept 队列的通道（管道、预建 socketpair）。agent 已按操作 id 加相同签名对 `/execute` 去重，可以安全重试。正式 App 现有的页面、传输与预览目录也通过 hostfwd，可能受同一问题影响，尚未验证。

## 缺口与限制

- 没有 iPad 运行：QEMU 版本（11.1.2 对 10.0.12）、平台（macOS 对 iOS）、沙箱容器、iPadOS 数据卷是否区分大小写，以及 iOS 上 `pthread_fchdir_np` 是否存在、能否通过审核，都未验证。
- `none` 不能在工作区里放 FIFO/socket，依赖它们的工具（部分 dev server、语言服务器、Git fsmonitor）须把这类文件放在 guest 本地目录；`mapped-xattr` 则让宿主看到非普通的 mode/symlink。两者都不是完整的共享语义，需要用户在架构决定中选择或收窄兼容范围。
- 同 uid 经 `/proc` 的写入仍只能在释放时检测；SCM_RIGHTS 未直接构造；原生 CAS 存在 TOCTOU。
- Swift 网关没有接入官方 Worker 的原生写入，也没有进入 App 进程或 QemuBridge 生命周期；连接闸门只在 Python harness 中实现。
- 模型、网络、性能与资源占用均未验证。

## 关口状态与下一步

- **G3**：Darwin 宿主上合同成立，Swift 网关可替换；但 FIFO/socket、大小写合并、同 uid 绕过和 iPad 未验，**未通过**。
- **G4**：hostfwd 重置是新发现的可靠性风险，已有可行的缓解方式，iPad 上未验证。
- G0–G7 均未完整通过。

下一步：在 iPad 上用独立 bundle ID、独立容器、合成工作区与 guest 的研究 App 验证 9P backend 与连接闸门（需另获用户同意并确认签名与安装细节），把 Swift 网关接入官方 Worker 的原生写入，再做模型/网络路径，之后在 #32 形成用户的架构决定。ADR/CONTEXT 未改选，#32 保持 OPEN，#17 继续依赖。正式 App 仍为 `7956e8c`，签名截止 2026-10-12 15:49:52 北京时间；锁屏/8 小时测试保持取消。

本地收据：忽略的 `build/prototypes/plan500-darwin/runs/` 与 `repeat/`。公共交付只包含复跑源码和上述脱敏结论。
