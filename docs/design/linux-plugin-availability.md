# Linux 插件可用性：私有接口检测（#39 关口 2）

ADR 0003 第 6 条：Darwin 9P backend 依赖私有 `pthread_fchdir_np`。本文件记录启动检测的实现合同、两分支行为、固定 QEMU 源码中该符号的全部调用点，以及由此得出的 ADR 修订提议。

## 合同

- **检测时机**：App 进程启动、任何 Linux 准备之前，检测一次。`LinuxAvailability.detect()` 用 `dlsym(RTLD_DEFAULT, "pthread_fchdir_np")`，与 QEMU framework 的 weak import 绑定方式一致。
- **缺失时**：`LinuxPlugin` 进入 `unavailable(LINUX_PRIVATE_SYMBOL_MISSING)`，QEMU 不启动。
  - 启用和未启用插件的项目都按原生方式打开。
  - linux 路径任务立即返回固定原因，不等待。这包括 shell、subprocess 和 hook 触发的命令。
  - 能力声明的 `plugin.state` 为 `UNAVAILABLE`，`reason` 为固定码，每个 linux 项都带同一原因。
  - native 项（会话、读写、编辑、搜索、Git 只读、review、草稿）不受影响。
- **存在时**：行为不变。
  - 启用插件的项目在打开时开始异步准备。
  - 排队的 linux 任务等待真实 ready 后执行，取消则不派发。
  - 准备失败后，同一进程内不重试。
- **未启用插件的项目**：两分支都立即拒绝 linux 任务，原因为 `LINUX_PLUGIN_NOT_ENABLED`，也不启动 QEMU。
- **执行路径**：在任务开始前按任务类型决定（`native` / `linux`），之后不切换。
- **注入**：缺失分支只能经测试注入进入。
  - 单元测试向 `detect` 传入解析器。
  - 独立研究 App（另一个 bundle ID）接受启动参数 `--inject-missing-private-symbol`。
  - 正式 App 没有任何开关能强制缺失分支。

实现在 `ios/HarnessApp/Sources/LinuxPlugin/`，研究 App 的 `WorkerCoordinator` 用它管理 QEMU 生命周期与任务准入。

## 证据（macOS）

- **单元测试**：`swift test --filter LinuxPluginTests`，共 13 项，两分支都覆盖：
  - 真实解析器在本机能找到该符号。
  - 未启用插件的项目、启用插件的项目、等待 Linux 的任务、hook 任务四种情况均显式返回，且启动次数为 0。
  - 存在分支只准备一次；取消时不派发；失败后不重启。
- **集成测试**（`run-worker.py`）：官方 Worker、Swift 网关与 macOS QEMU 一起运行。
  - **存在分支**：`none` 与 `mapped-xattr` 首次运行各 29 项、重启后各 10 项，全部通过。覆盖了未启用插件时的拒绝，以及排队的 hook 在 ready 后执行；QEMU 只启动 1 次。
  - **注入缺失分支**：15/15 通过。
    - 会话创建与重命名、原生读写、冲突草稿、home 检查点都正常。
    - linux 任务与 hook 分别在 2 ms 和 1 ms 内返回固定原因，没有留下文件。
    - 在同一次运行里，真实检测结果为 `available`。
    - QEMU 启动次数为 0，项目目录中也没有 QEMU 日志。
- **hook 路径说明**：官方 hook runner（`dsh-hook-protocol`）没有打包进 Worker 镜像。研究里用的是一个与 `ShellExecutor` 形状相同的适配器（`resolve`、`execute`、`result`），以 `trigger: "hook"` 走 linux 准入。它不是官方 runner 本身。

iPad 证据（真实检测加上注入缺失后的完整行为）见 #39 评论。

## 固定 QEMU 源码中的调用点

来源为 QEMU v10.0.12，提交 `0a6a1c7d02e1ce0d4b3cd9619df3e58bf065ce8a`。此前对正式 IPA 的静态检查显示其中的 QEMU 为 10.0.12，仓库内也没有修改 9P 的补丁。全树 `grep` 的结果如下：

| 位置 | 作用 |
| --- | --- |
| `meson.build:2365-2366` | macOS 上构建 virtfs 要求 `cc.has_function('pthread_fchdir_np')`，否则构建失败（构建期） |
| `meson.build:2655` | 设置 `CONFIG_PTHREAD_FCHDIR_NP`（构建期） |
| `hw/9pfs/9p-util.h:266` | 在 `CONFIG_DARWIN && CONFIG_PTHREAD_FCHDIR_NP` 下以 `weak_import` 声明；符号缺失时值为 NULL，不会导致加载失败 |
| `hw/9pfs/9p-util-darwin.c:113-145` `qemu_mknodat` | 唯一的运行期使用，见下文 |

`qemu_mknodat` 的逻辑：

- 普通文件或未带类型位（`S_ISREG(mode) || !(mode & S_IFMT)`）直接走 `openat_file(O_CREAT)`，**不触及该符号**。
- 其他类型先检查 `!pthread_fchdir_np`；若缺失，返回 `ENOTSUP` 并调用 `error_report_once`。
- 若存在，则执行 `pthread_fchdir_np(dirfd)`，再做 `mknod` 或 `bind`（socket），最后 `pthread_fchdir_np(-1)`。

`qemu_mknodat` 只有两个调用方：

- `hw/9pfs/9p-local.c:683`：`mapped`/`mapped-file` 模式，固定传入 `fmode | S_IFREG`，因此不会触及该符号。
- `hw/9pfs/9p-local.c:698`：`passthrough`/`none` 模式，传入 guest 请求的 `fc_mode`，即 FIFO、socket、字符设备或块设备节点。

## 影响范围与 ADR 修订提议

**结论**：符号缺失时，唯一受影响的是在共享工作区内**创建非普通文件节点**（FIFO、Unix socket、设备节点）。

- 这些请求会得到 `ENOTSUP`。
- QEMU 启动、9P 挂载、普通文件与目录的读写、rename、symlink、chmod 均不经过该符号。

在首个正式范围的 `none` 模式下，这类节点本来就不可用：iPad 上已观察到 FIFO/socket 失败，能力声明也已把它们列为 `unsupported`（原因 `SHARE_MODE_NONE`）。所以实际影响远小于“整个插件”。

**提议**：修订 ADR 0003 第 6 条。把“缺失即整个 Linux 插件不可用”收窄为“缺失时 `workspace.fifo`、`workspace.unix-socket` 与设备节点不可用（原因 `LINUX_PRIVATE_SYMBOL_MISSING`），插件其余部分照常”。前提条件如下：

1. 在符号缺失的 iPad 上，实测确认 QEMU 能启动、9P 能挂载、普通文件语义完整。目前无法在真实的缺失环境中验证，只有源码依据。
2. 每次升级 QEMU 时，重新列出调用点。

**这只是提议，未生效。** 修订属于架构决定，需用户确认。确认前，硬关口按 ADR 原文执行：缺失即整个插件不可用，本次实现即按此行为。
