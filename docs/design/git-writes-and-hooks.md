# Git 写操作与 hook

依据：[ADR 0003](../adr/0003-native-worker-with-project-linux.md)，[#39](https://github.com/lvivvde/deepseek-harness-ipad/issues/39) 关口 5，原生只读 Git 见 [native-read-only-git.md](native-read-only-git.md)。2026-10-08 创建。

## 要回答的问题

原生 Worker 只能读 Git（八种只读调用）。凡是可能改动仓库的操作，包括 commit、checkout、merge、push 以及仓库自己的 hook，都要交给项目 Linux。这要求：

1. 写操作只在持有写租约时运行，原生复核不会读到它写了一半的状态。
2. 仓库的 hook 照常运行，不能被跳过。宿主要能确切知道哪些 hook 跑了、按什么顺序、退出码是多少。
3. hook 没能在 Linux 上运行时（Linux 没就绪、准备失败、开始前就被取消、写入方未知），动作必须被阻止，而不是放行。
4. 网络操作所需的令牌不落进工作区、9P 共享、`.git/config` 或日志。

## 设计

### 写入只在 Linux，原生只读复核

- 每个 Git 写操作是一条 `/bin/sh` 事务，由 `web/git-write.js` 的 `plan` 生成，经 `WorkerCoordinator.execute(trigger: git)` 在写租约下运行。Linux agent 以共享目录属主的 uid 运行命令，所以 Git 的属主检查能通过。命令跑在 cgroup 里，留下的后台进程会被清掉。单条命令的时长上限原来是 15 s（agent）和 30 s（原生协调器），现在统一为 60 s，给 hook 和 push 留出余量；shell 工具也共用这个上限。
- 原生侧的复核由 `Gate5Review` 负责，只用原生只读子集：
  - 先复制一份索引到自己的临时目录；
  - 再执行 `add --all --ignore-errors`、`write-tree`、`rev-parse -q --verify HEAD`、`diff-tree -r -M -z --numstat`。

  每次回答都带上 `.git` 复核前后的摘要。摘要变了即视为失败。
- 显式结果，不读半写状态：
  - Linux 命令持有租约时，原生复核返回 `WORKSPACE_LEASE_BUSY`；
  - `.git/index.lock` 存在时返回 `GIT_INDEX_LOCKED`；
  - Linux 上的 Git 遇到锁时以 128 退出，事件只有 `start git` 和 `end git 128`。
- 索引里的 stat 缓存是 Linux 经 9P 写入的。原生 lstat 看到的 dev、ino 和时间通常对不上。原生复核只读索引的一份副本，所以：
  - 这种差异不会被报告成改动；
  - 原生也不会把刷新后的 stat 写回 `.git/index`。

### 事务、shim 与事件顺序

- 事务把 `core.hooksPath` 指向一个私有目录。真实 hooks 目录（尊重仓库原有的 `core.hooksPath`）里每个可执行文件，在私有目录里都对应一个 shim。
- shim 用同样的参数、stdin 和环境调用真实 hook，前后分别记录 `start <hook>` 和 `end <hook> <code>`。Git 本身由 `start git` 和 `end git <code>` 包住。
- 事件写在一条带随机 nonce 的尾部标记之后，命令输出无法冒充事件。
- 以下选项在派发前就以 `GIT_HOOK_BYPASS_REFUSED` 拒绝：
  - `--no-verify`，以及 Git 会展开成它的缩写（从 `--no-v` 起）；
  - commit 的含 `n` 的短选项簇。
- 阻断型 hook（pre-commit、commit-msg、pre-push 等）以非零退出时，操作结束，不写入任何东西。post-commit 这类事后 hook 失败时，提交照常完成，失败记在 `postHookFailures` 里。
- `init` 和 `clone` 要创建的仓库还不存在，没有 hook 可包装。这两个操作不改 `core.hooksPath`：Git 照常运行新仓库自己的 hook，只是事件里只有 Git 本身。

### 官方 runHook 的阻断语义

官方 `dsh-hook-protocol` 的 `runHook` 遇到执行器抛错时，会当作“没有决定”而放行。`web/hook-shell.js` 的执行器从不抛错。凡是没有跑完的命令都返回退出码 2，包括：

- `LINUX_UNAVAILABLE`、`LINUX_PREPARE_FAILED`；
- 开始前取消、`WRITER_UNKNOWN`、桥接错误；
- 已派发但因超时或取消而没有退出码（`HOOK_TIMEOUT`、`HOOK_CANCELLED`）。上游对缺失的退出码按非阻塞错误处理，所以这些情况也要拦下。

这时 stderr 固定为 `DSH_HOOK_NOT_RUN <CODE>`。`runHook` 会把它解析成 `decision: "block"`，原因就是这个代码。

Linux 正在启动时，hook 排队等待就绪。等待中被取消的 hook 不会再运行。就绪后，排队的 hook 只运行一次。

### 令牌的存放

令牌只在下面这条链上经过，每一段都不持久化：

1. **Swift 进程内存。** `WorkerCoordinator` 的 `SecretBox` 持有令牌，只在构造请求时读取。
2. **单条命令的 Linux 环境变量。** 只有 `trigger: git` 且是网络操作（push、fetch、pull、clone、ls-remote）时，令牌才作为 `DSH_GIT_TOKEN` 放进那一条请求的 `secretEnv`。它从不出现在命令文本里。Linux agent 只接受白名单里的密钥名。它不回显、不记录这些值，只保留摘要，用来校验重试时携带的是同一个令牌。
3. **credential helper。** 事务为网络操作加一个 helper。它只回答 `get`，而且只对 https 或发往回环地址的 http 回答，数据取自 `DSH_GIT_TOKEN`。所以即使仓库改了远程 URL，也不能让令牌以明文发往别的主机。远程 URL 里带用户信息（`https://user:pass@…`）的请求一律以 `GIT_URL_USERINFO_REFUSED` 拒绝，所以 `.git/config` 里不会存凭据。
4. **hook 的环境里没有令牌。** shim 在运行任何 hook 之前都会 `unset DSH_GIT_TOKEN`。

研究 App 每次运行都生成一个随机令牌（系统 CSPRNG）。运行结束时，它扫描整个项目根下的所有文件，包括工作区、网关状态、日志和回执。只要有一处含有令牌，`gitTokenPersisted` 就为真，这次运行判为失败。这条链挡住的是落盘和日志，挡不住同一个 uid 下的代码：

- hook 与 Git 以同一个 uid 运行，仍然可以从 `/proc/<祖先进程>/environ` 读到令牌；
- 仓库配置的 filter、`core.sshCommand` 等子进程会继承这个环境变量。

所以令牌只应交给用户信任其 hook 和配置的仓库。正式 App 的计划是：由用户在设备上输入令牌，存进 Keychain，运行时读进同一个 `SecretBox`。这一步不在本关口内。

## 已知限制

- **只有 Git 工具受 hook 保护。** 经事务和 runHook 的 Git 操作不能跳过 hook。模型的 shell 工具在 Linux 上执行的是任意命令，它直接运行的 `git commit --no-verify` 或对 `.git` 的改写不受这层保护。这与桌面上的 shell 工具相同：shell 有用户本人的权限。
- **hook 的工作目录被忽略。** `runHook` 请求里的 `workdir` 不生效，hook 命令一律在 `/workspace` 运行。
- **macOS 宿主上锁定 `core.ignorecase`。** 宿主的共享目录在 APFS 上，大小写不敏感。Linux git 在 `init` 时会写 `core.ignorecase=true`，而原生子集拒绝这种仓库（见 `native-git.js`）。关口 5 的仓库先记录检测到的值，再设成 `false`。iPad 上检测结果是未设置，说明那里的卷大小写敏感。
- **iPad 上 60 s 内做不完完整 clone。** iPad 的 guest 是单核解释执行（TCG）。完整 clone 本仓库 main（约 2.2 MB）并检出全部文件，超过单条命令 60 s 的上限，结果是写者未知。授权推送因此改用 `--depth 1 --filter=blob:none --no-checkout`：只取 main 的提交和目录树，再用 `git read-tree HEAD` 建索引。完整 clone 大一些的项目，需要另定时长或分步方案，留给 #18。

## 代码与验证

- JS：
  - `runtime/prototypes/plan500-ipad/web/git-write.js`：事务、shim 和拒绝规则；
  - `web/hook-shell.js`：runHook 执行器。
- Swift：
  - `runtime/prototypes/plan500-ipad/Sources/Gate5Review.swift`：原生复核与 stat 缓存比对；
  - `WorkerBridge.swift`：`SecretBox`、`execute`、令牌扫描。
- Linux：`runtime/prototypes/plan500-lease/agent.cjs`（`secretEnv`、以属主 uid 运行）。
- 单元：`runtime/prototypes/plan500-ipad/test_git_write.mjs`，macOS 16/16。
- 授权推送：`integration.html` 的 `plan500RunGate5Push`。研究 App 带 `--gate5-push` 启动时，显示 GitHub token 输入框和推送按钮；token 只放进 `SecretBox`，写收据前会扫描收据里有没有它，写完即清掉。macOS 上的 `run-worker.py --only gate5-push-dry` 不带 token 跑同一流程，要求两次推送都停在认证、早于 pre-push，并且远端什么也没收到。
- 集成：`run-worker.py --only gate5` 依次运行三段：gate5、gate5-unavailable、gate5-prepare-failed。gate5 除 hook 矩阵外，还在预热时排队一条 `git init`，并在 push 之后依次运行 stash push、stash pop、checkout -b、commit、checkout、merge --no-ff、reset --hard。每一步之后，Linux 的 status 与 numstat 都要和原生复核一致。

2026-10-08 的结果：

| | macOS 宿主 | iPad 真机 |
| --- | --- | --- |
| gate5 | 35/35 | 35/35 |
| Linux 不可用 | 5/5，10 ms 内阻断 | 5/5，11 ms |
| 准备失败 | 5/5，10 ms 内阻断，没有启动 VM | 5/5，10 ms，没有启动 VM |
| 令牌落盘 | 否 | 否 |
| 检测到的 ignorecase | true（已锁定为 false） | 未设置 |
| stat 缓存 | 4 条目的 dev 和 ino 均不同，不报告改动、不写回 | 同左 |
| 预热时排队的 hook 与 `git init` | 各运行一次 | 各运行一次，hook 等待约 12 s |
| stash 到 reset 共 6 步 | 每步两侧一致 | 每步两侧一致 |

hook 矩阵的事件顺序（两端相同）：

- pre-commit 失败：`start git, start pre-commit, end pre-commit 1, end git 1`
- commit-msg 失败：`… end pre-commit 0, start commit-msg, end commit-msg 1, end git 1`
- 会改动内容的 hook：pre-commit、commit-msg、post-commit 依次 `0`，`end git 0`
- post-commit 失败：提交完成，`postHookFailures` 为 `[post-commit 1]`
- push：`start git, start pre-push, end pre-push 0, end git 0`
  - 远端统计：认证 2 次，推送 1 次
- pre-push 失败：推送 0 次，远端 HEAD 不变

### 授权远端推送（2026-10-09）

用户授权的测试远端是本仓库的专用分支 `gate5-push-test`。它不存在于远端，推送时从当前 main 新建，验证后删除，main 不动。token 由用户在 iPad 上输入（fine-grained，只限本仓库，Contents 读写，1 天有效期）。

- 流程：Linux git 部分 clone main，然后在 main 上做一次只新增 `gate5-push-test.md` 的提交，再推送两次。仓库的 pre-push hook 只放行 `refs/heads/gate5-push-test`。
- iPad 真机 7/7：
  - 推到 `gate5-push-refused`：`start git, start pre-push, end pre-push 1, end git 1`，被 pre-push 阻断，远端没有这个分支；
  - 推到 `gate5-push-test`：`start git, start pre-push, end pre-push 0, end git 0`，远端分支指向本次提交，其父提交就是 main；
  - main 不变；`.git/config` 里只有不带凭据的远端 URL；token 没有落盘。
  - 耗时：clone 7.9 s，add 5.8 s，commit 9.1 s，两次 push 6.1 s 和 8.0 s。
- macOS 无 token 试跑 7/7：两次推送都以 128 结束，事件只有 `start git, end git 128`，Git 报告读不到用户名；远端没有收到任何东西。
- 之后从 Mac 核对了远端提交（只新增一个文件、父提交是 main），随后删除了 `gate5-push-test`。
- merge --no-ff：`start git, start commit-msg, end commit-msg 0, end git 0`；stash、checkout、reset 只有 `start git, end git 0`
