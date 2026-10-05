# 方案500：Darwin 宿主 9P 与 Swift 网关探针

研究原型，关联 [Issue32](https://github.com/lvivvde/deepseek-harness-ipad/issues/32) 和 [研究结论](../../../docs/research/plan500-darwin.md)。不进入正式 App，不打开 user.raw / user-seed.raw 或 iPad 原盘。

## 组成

- `run.py prepare`（Linux）：复用 [写租约探针](../plan500-lease/README.md) 的 guest（`init.sh` / `agent.cjs`，经 `../plan500-sharing/run.py` 打包 initramfs），输出 Image、system.raw、initramfs.gz、`inputs.json`（含各文件与 guest 源码 SHA256）和 0600 的 `token-private`。macOS 缺 `unsquashfs`，所以在 Linux 构建后复制到 Mac。
- `run.py probe`（macOS）：用 Homebrew `qemu-system-aarch64`（TCG）启动同一 guest，9P 共享 macOS 宿主目录。`--volume case-sensitive`（默认）先用 `hdiutil` 建并挂载区分大小写的 APFS 稀疏镜像，模拟 iPadOS 数据卷；`--volume default` 直接用 scratch 所在卷（Mac 默认不区分大小写）。每种 9P 安全模型跑两段：
  - `contract`：原样运行 `plan500-lease` 的 26 项必需检查；
  - `darwin`：只记录观察项，包括只差大小写的文件名、NFC/NFD 文件名、guest chmod/symlink 与宿主互见、FIFO、Unix socket（两项分开记录）、rename 覆盖已打开文件、400 个小文件写入。
- 连接闸门：libslirp 的 hostfwd 用 `listen(s, 1)`，XNU 对溢出 accept 队列的连接回 RST（Linux 让连接等待），并发 RPC 会随机重置。`GatedGuest` 在 hostfwd 前放一个本机中继：一次只建立一个上游连接，先做一次未认证往返（agent 回 403，keep-alive）证明 slirp 已 accept，再释放闸门并原样转发；往返前失败或之后的重置都以重置交给客户端。
- `backlog.py`：不启动 VM，复现同一内核行为（backlog 1、暂停 accept、多个客户端并发连接），可在 macOS 与 Linux 上分别运行对比。
- `--gateway swift`：先 `swift build -c release` 编译 `gateway/`，再把 `lease.Gateway` 换成 `SwiftGateway` 代理，同一组检查改由 Swift 进程执行。`crashed = True` 对 Swift 进程发送真实 SIGKILL。被杀的 Python 网关线程仍会等到 guest 命令结束，Swift 进程做不到，所以代理在返回 CRASHED 前等满该命令的 agent 侧超时再加 2 秒（agent 不依赖连接也会执行超时），不改动任何状态；VM 是否已退出由本 harness 告诉 `reconcile`，在 iPad 上对应 QemuBridge 的职责。
- `gateway/`：Swift package（macOS 13 / iOS 16）。
  - `Plan500Gateway` 库是 Python 网关的移植。路径按字节比较，因为 Swift `String` 的相等性按规范等价判断，NFC/NFD 会合并。目录遍历用 `openat` + `O_NOFOLLOW`，拒绝符号链接父目录；特殊文件只取 lstat、不打开。原子写入使用 `O_EXCL` 临时文件、`F_FULLFSYNC`、`renameat` 并同步目录。状态 JSON 中按路径索引的表存为数组。
  - `plan500-gateway` 是只供研究 harness 使用的 JSON-lines stdin/stdout 服务，不是产品接口。

## 复跑

```sh
# Linux：构建 guest 输入
python3 runtime/prototypes/plan500-darwin/run.py prepare \
  --runtime /path/to/bundled-runtime --modloop /path/to/locked/modloop-virt --out /path/to/inputs
# macOS：brew install qemu；把 inputs 目录复制到 build/ 下
python3 runtime/prototypes/plan500-darwin/run.py probe --inputs build/prototypes/plan500-darwin/inputs \
  --scratch build/prototypes/plan500-darwin --volume case-sensitive --gateway swift
# 内核 accept 队列行为对比（macOS 与 Linux 各跑一次）
python3 runtime/prototypes/plan500-darwin/backlog.py
# Swift 单元测试
swift test --package-path runtime/prototypes/plan500-darwin/gateway
```

iOS 模拟器上运行单元测试：在 `gateway/` 中执行 `xcodebuild test -scheme Plan500Gateway-Package -only-testing:Plan500GatewayTests -destination 'platform=iOS Simulator,name=…'`。

收据写入 `<scratch>/plan500-darwin-<volume>-<gateway>-result-safe.json`。token、串口、QEMU 日志（按模型和阶段分别命名）、Python traceback 和 Swift stderr 只留在本次临时目录，结束时删除。加 `--keep` 时保留：`--volume default` 原地保留；稀疏镜像总会 detach 并删除，所以 `case-sensitive` 会先把临时目录复制到 `<scratch>/<目录名>-kept`。

## 边界

- Mac 上的 QEMU 是 Homebrew 版本，跑在 macOS 上。正式 App 内嵌的是 UTM 构建的 QEMU 10.0.12（iOS 平台）。两者共用 9P Darwin backend 源码，但这里**不**证明 iPad 上的运行时行为。
- 模拟器单元测试用的是 Mac 文件系统，不是 iPad 沙箱容器。
- 连接闸门只在 Python harness 中实现，App 内的等价机制尚未实现。
- Swift 网关尚未接入官方 Worker 的原生写入路径，也未进入 App 进程或 QemuBridge 生命周期。
