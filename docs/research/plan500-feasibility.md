# 方案500：原生 Harness 与项目级 Linux 插件的可行性研究

日期：2026-10-05，北京时间。任务：[Issue #32](https://github.com/lvivvde/deepseek-harness-ipad/issues/32)。用户已明确解除人工阻塞，授权可行性研究和架构决策准备；本报告不表示 #17 实现或正式数据迁移已经获准开始。

## 结论与待决策项

**当前研究候选为“官方实验 Web Worker Harness + iPad 宿主工作区桥 + Linux 能力网关”。** macOS Worker 与真实 Linux 共享/RPC 隔离原型已有部分证据，但共享语义关口未通过；**下一步验证统一写租约、版本冲突与变更通知/轮询**，最新结果见[共享/RPC 报告](plan500-sharing-rpc.md)。固定上游已经实现无需 Node Host 的 Worker 组装、模块兼容层和 HTTP 消息隧道，目前定位为浏览器预览；持久化、任意插件和 iPad 生命周期仍没有生产保证。[Worker 入口与定位][worker-package]、[Worker 组装][worker-host]

这里的“原生优先”指 Harness 核心在 iPad 的 WKWebView/Web Worker 中执行，启动核心不依赖 Linux VM；Swift 负责文件、凭据与运行时管理。它不是把上游全部改写成 Swift，也不是把 Web UI 连回 Linux 后就称为原生 Harness。候选的必要新增工作是持久工作区、工具边界、可信网络与恢复协议，尚未实现。

现成 nodejs-mobile 仍为 Node 18.20.4，不满足固定上游的现代 Node 要求；自维护 Node 22/24 iOS 无 JIT 移植可以保留更多 Node 语义，但属于另一项明显更大的运行时工程。直接用 JavaScriptCore/Swift 重新补齐 Node 和官方插件所需 API，复用率与语义风险更难控制。[上游 engines][root-package]、[移动 Node 版本][mobile-version]、[移动 Node FAQ][mobile-faq]

**2026-10-05 用户已接受此候选并授权隔离原型验证；下节补充实际结果。正式架构是否改选，仍要通过下文完整门槛并记录决策。** 若要求必须使用未经浏览器兼容层处理的官方 Node Host，则优先项应改为现代 mobile Node 移植。现有 [ADR 0001](../adr/0001-local-linux-emulation.md)、[ADR 0002](../adr/0002-runtime-ships-inside-ipa.md) 和根 CONTEXT 继续有效；研究文档不自动改选它们。

## 证据范围与固定基线

| 项目 | 本轮使用的证据 |
| --- | --- |
| 官方 Harness | `@deepseek-ai/dsh@0.2.0-rc.2`；源码固定 `639ed015397290b3745d163aafe02ffee4aa3f84` |
| 本机依赖 | 忽略的 `build/test-dependencies/harness/` 中已安装包、manifest、实际 `lib/*.js`；源码研究阶段只读核对；随后仅在独立 build 目录安装固定 Worker/packer 依赖，未升级既有依赖 |
| 安装工具 | 本仓库 `runtime/harness-package.json` 固定 pnpm `11.28.4`；官方源码根 manifest 的构建工具是 pnpm `11.7.0`，两者不混称 |
| Node 要求 | 源码根 `engines.node = ^22.19.0 || >=24.0.0`；不能因 CLI 发布包未重复 engines 就认定 Node 18 获支持 |
| nodejs-mobile | 固定 `d9552e0e01ed5bdbe12a31d1ce6c0877a4f39580`，`node_version.h` 为 `18.20.4`；只读官方 API 核查当日 main 仍是此提交，latest release 为 `v18.20.4`，发布于 2024-10-07 |
| UTM/QEMU | 固定 UTM `7eadb056ae0f91d979059544d0ddcd2d5a40be92`；本项目现有交付 IPA 中 QEMU 二进制的只读结构证据 |

官方源码通过 GitHub 只读 API 获取上述不可变提交的树和相关文件；树响应 `truncated=false`，本轮只阅读与候选相关的文件，未进行整个依赖树穷举。源码缓存与私有收据在忽略的 `build/` 或临时目录。本报告区分 **事实**（源码/manifest/结构检查）、**推断**（据此提出的设计）和 **未知**（需要运行验证）。[官方根 manifest][root-package]、[移动 Node 发布][mobile-release]

本仓库结构使用 Tier 2 Verify：graph project `Users-edwin-Projects-deepseek-harness-ipad`，父任务最新 generation `2026-10-05T11:32:19Z`；相关 RuntimeConfiguration/EmbeddedRuntime/QemuBridge/transfer 证据路径覆盖为 metadata_match、无已记录缺口，不等于全集完备。上游和忽略的依赖目录未纳入该图，使用精确源文件回退，不把图结果当作其覆盖证据。

源码研究阶段没有运行宿主探针；随后用户授权的 macOS WebKit 隔离原型见下节，实际 Linux 共享/RPC 见[追加报告](plan500-sharing-rpc.md)。均未运行真实模型请求、读取凭据、连接设备、构建/签名/安装正式 App，也没有迁移或替换正式用户盘。宿主结果不是 iPad 验收。

## 实际上游运行要求

| 能力 | 固定源码/发布包事实 | 对原生候选的影响 |
| --- | --- | --- |
| 默认插件组合 | base patch 装配会话、JSONL 持久化、工具、subprocess-local、sandbox-local、配置和插件管理；Cordis 以服务可用性激活，不以 YAML 行顺序激活。[base patch][base-patch] | 要固定一个候选 profile 和完整模块可达清单；“核心都是 JS”不能证明整个 Web profile 可运行 |
| 子进程与终端 | subprocess-local 使用 `node:child_process`、POSIX 进程信号和 terminal provider；已安装依赖 `node-pty@1.2.0-beta.15`、`koffi@3.1.1`。[provider][subprocess]、[PTY 实现][terminal] | 普通移动 Node 的进程限制仍存在；原生 addon/PTY 不能靠 bundling 消除，Linux 需提供真实 process/PTY 生命周期 |
| Shell 与 Hooks | bash-local 实现官方 shell seam，hook-protocol 通过 `ctx.shell.resolve/execute` 执行 command hook。[bash provider][bash]、[hook runner][hook-runner] | 可以在服务边界接 Linux，但 cwd、环境、stdin、退出码、取消与超时都属于协议，不是只转发一段字符串 |
| 插件包管理 | plugin-manager 的 operations 直接调用 `execa` 启动 `pnpm view/install`，并处理锁、脚本、取消和失败恢复。[包操作][plugin-operations] | 仅换 subprocess provider 不会接管全部进程路径；必须禁用原生侧不支持的操作或另设明确 Linux 服务 |
| MCP | `stdio` 用 MCP SDK 自己创建子进程，源码明确它不走 subprocess seam；`streamable-http` 则连接 URL。[transport][mcp-transport] | stdio 也需单独代理/兼容路径；HTTP 适配可独立验证，不默认宣传所有 MCP 可用 |
| JSONL 持久化 | 默认 backend 用 `@deepseek-ai/node-addon-system/flock` 获写所有权，并用 `node:worker_threads` 做文件 generation 验证。[写租约][session-lease]、[验证线程][session-verifier] | modern Node 路线还须解决 addon 和线程；Worker 路线必须明确单写者与恢复语义 |
| SQLite | session-query-sqlite 只在打开索引时动态 `import('node:sqlite')`；base/Web 默认 `openAt: never`，搜索索引禁用但精确会话查询仍可用。[SQLite schema][sqlite-schema]、[Web patch][web-patch] | SQLite **不是默认启动必经硬阻塞**；启用全文搜索后才要实现兼容数据库或明确禁用功能 |
| 文件系统 | fs-local 有真实 `fs/promises`、open/link/rename/lstat/realpath 与文件身份语义。[fsio][fsio] | 桥接需保留原子替换、路径约束和文件身份，不能用定期覆盖同步模拟同一目录 |
| Web/API | 原生 Node Web Host 用 `node:http`；Worker 有独立消息隧道，映射不同。[Worker HTTP][worker-http] | 需保留官方认证、请求、流式结果、取消与错误协议；UI 可沿用，不代表 Host API 已兼容 |

以上是有界实际依赖核查，不能声明所有第三方插件已被枚举或测试。已安装 `@deepseek-ai/node-addon-system@0.1.2` manifest 声明 Node `>=20`，预构建组合列出 darwin/linux，不能把 macOS arm64 产物当作 iOS 产物。[native system manifest][system-package]

## 已有官方 Worker 接缝：可复用什么，缺什么

事实：固定 `webworker-runtime/package.json` 声明版本 `0.2.0-rc.2`，公开 `.` → `lib/index.js`、`./worker` → `lib/worker.js`、`./client` → `lib/client.js`；源码入口导出 `createWorkerHost`、MemoryVfs、loader、module proxy table 和 tunnel。另有官方 packer 为模块转换和可达包组装 VFS 产物。源码存在这些入口，不证明对应已发布包在本机或 iPad 上已经构建运行。[manifest][worker-package]、[exports][worker-index]、[packer][packer]

事实：`MODULE_PROXIES` 有实际 Node fs/stream/http/async-context 兼容实现，并替换 `execa`、`node-pty`、koffi、flock 等平台包；`node:sqlite`、`node:net`、`node:vm`、`node:worker_threads` 指向拒绝调用的结构 stub。这是既有官方兼容边界，适合复用并逐项扩展。[proxy table][worker-proxies]、[SQLite stub][worker-sqlite]

事实：Worker 的 `child_process.spawn` 使用另一 Web Worker 加命令表，而不是操作系统 fork。它不等价于 Linux bash；README 明确没有 Git/网络工具与 bash 的完整语法，`execSync/fork` 仍拒绝。直接让真实测试、npm 生命周期脚本和 Git hooks 留在此命令表中不能完成本地开发闭环。[child_process 实现][worker-process]

事实：`flock` 替身立即成功，理由是单 Worker 内已有写所有权；这只能用于该单写者假设。增加 guest 或宿主外部写者后，不能继续把它解释为跨运行时互斥。[flock 替身][worker-flock]

未知：持久 profile/会话与项目的耐久存储、外部写入和 symlink、WKWebView 的 Worker/Blob/流传输支持、前后台销毁与恢复、真实模型网络请求均未验。官方预览验收以 Chromium 与 fixture 为主，文档明确其中历史读取链不发模型请求；不能借它证明真实推理或 iPad 可靠性。[官方验收说明][worker-readme]

事实：同一固定提交的 module-proxies 注释写 zlib 为真实 zstd codec，但目标 zlib 实现的压缩/解压函数都调用拒绝替身；worker-host 的 profile 组装明确强制 `compression: 'none'`。应以实现为准：此候选预览组合写明文 JSONL，不能直接读写旧压缩日志。数据迁移需明确格式转换与验证，而非照搬注释宣称已有 codec。[proxy table][worker-proxies]、[zlib 实现][worker-zlib]、[profile 组装][worker-host]

推断：先用固定官方 Worker 产物作为候选内核，Swift 提供耐久存储/工作区与网络桥，真实 Linux 命令通过明确能力协议执行，比从零补齐 JSC/Node API 更有可检验的复用基础。浏览器 VFS 必须变成同一权威工作区的桥接视图，或有可证明的一致写协议；不能与 host/guest 各自维护一份可写副本。

## 候选比较与兼容范围

| 候选 | 当前事实 | 建议 |
| --- | --- | --- |
| A：官方实验 Worker + Swift 桥 + Linux 网关 | 上游已有模块兼容/组装接缝；关键持久化和外部文件语义缺验证 | **第一个有界可行性候选**；门槛失败时保留错误，决定缩小范围或转 B |
| B：现代 mobile Node + providers | 可最大化复用 Node Host；现成 mobile Node 是 18.20.4，进程 API 受限 | 若必须保留完整 Node Host，单独评估 Node 22/24 iOS 维护成本；禁止修改 engines 假装满足要求 |
| C：JSC/Swift 大量重写 Host | Apple JSC 提供 JS 执行与原生交互，不能据此推导 Node API/plugin 等价 | 仅针对明确模块的合同适配；不作为整个官方树的默认可行性结论。[Apple JSC][jsc] |
| D：全部继续 Linux | 现有已交付路线，维护记录可复用 | 研究失败或升级未完成时保留；不会满足“核心不等 VM”的新目标 |

建议首个兼容表按 **功能和固定插件版本** 列出：原生侧候选为会话/模型编排/审阅、受支持文件操作、配置；Linux 侧为 Git CLI、bash/PTY、项目 Node/包管理/测试、command hook 和 stdio MCP。HTTP MCP 单独验。不能把任意 Cordis 插件简单搬到另一个进程：插件可能持有 ctx/service/内存对象，只能通过已定义 RPC/tool seam 暴露能力。

上游 plugin compatibility 主要比较 dsh peers 与精确版本豁免，**不是 iOS/Linux/权限能力声明**。方案500需另有 `native/linux/unsupported` 能力清单与错误说明；Linux 插件启用也不代表其前端或原生模块可自动在 Worker 中加载。[兼容预检源码][plugin-compatibility]

## 同一工作区与预热边界

事实：当前本仓库 `RuntimeConfiguration.qemuArguments` 的有界参数数组装配只读 system.raw、可写 user.raw 和端口转发，没有加入 live sharing；prepare 将 user.raw 放在 App Support/HarnessRuntime，保留既有用户盘。`transfer.cjs` 的项目导出是 portable tar，排除依赖/缓存，并非实时共享目录。[运行参数][local-runtime]、[项目导出][local-transfer]

事实：固定 UTM 参数生成器提供 local fsdev + `virtio-9p-pci`，使用 `mapped-xattr`。当前正式 IPA 内 QEMU Mach-O 的只读字节检查发现 `virtio-9p-pci`、`virtio-9p-device`、`mapped-xattr`、`mapped-file` 字符串；这是优先做 9P 探针的结构证据，不能证明 backend 已启用、guest 可挂载、权限或设备性能。[固定 UTM 参数][utm-sharing]

事实：QEMU 文档描述 `mapped-xattr` 用 xattr 编码 guest uid/gid/mode/symlink；mapped-file 用隐蔽元数据目录且不兼容普通 Unix 工具直接交互。UTM Linux 说明还要求 guest 9P 支持并提醒 uid/gid 与 xattr 差异。故 **host 与 guest 看到同一路径不保证 mode/symlink 等语义一致**。[QEMU fsdev][qemu-fsdev]、[UTM Linux VirtFS][utm-linux]

推断：权威项目目录设在 App Support；9P 作为首选 guest 接入探针，工作区网关统一路径身份、授权和写调度。每个项目用固定身份/根目录，拒绝越界路径和符号链接逃逸。先串行化写操作和 `.git` 更新，只有证明互斥和可见性后才放开并发。native/Linux 的 node_modules 与二进制工具分开保存；共享源码不能推导共享依赖。

后续实测：固定 initramfs 需从锁定 modloop 补入 9P/overlay 模块；Linux 双向文件操作与命名 index.lock 成功，但实测跨域 flock 未互斥、guest watcher 未收到目标宿主写入，详见[共享/RPC 报告](plan500-sharing-rpc.md)。Darwin/iPad 共享仍未知。宿主 fs watcher 或 NSFileCoordinator 不能在设计上被假定自动协调任意 guest POSIX 写。标准桌面 virtiofsd 需要 daemon/namespace 等宿主能力，不直接套用到普通 iPad；另行移植的可能性也不被本报告排除。[virtiofsd 文档][virtiofsd]

建议状态合同：`disabled → preparing → ready`，preparing 可取消/失败；打开已启用项目立即异步预热；原生操作独立继续，Linux 操作等待 ready 后自动续执行。ready 必须验证工作区身份/挂载、工具版本和 RPC，而非只看 guest 进程活着。请求固定 operation ID、cwd、能力、deadline、signal；队列取消后 ready 不能重新执行它。VM 失败后有界失败/重试且保留草稿，不在未验证条件下同进程重新初始化 QEMU。

## Git 与 Hook 顺序

先分清两层：Harness `PreToolUse/PostToolUse` 等拦截事件是 agent/tool 协议；Git `pre-commit/prepare-commit-msg/commit-msg/post-commit/pre-push` 是 Git 命令内部语义。它们不能互相替代。[Harness hook 接入][claude-hooks]、[Git hooks][git-hooks]

建议首个兼容路径把有 hooks 的 **整个 Git CLI 操作放在 Linux 内**，由 Git 保证顺序：准备并确认同一工作区 → 执行 Harness 前置门禁 → 调用 Git → `pre-commit` → `prepare-commit-msg` → `commit-msg` → 写 commit/ref → `post-commit` → 命令退出 → Harness 后置事件。前置 Git hook 非零须阻止提交；post-commit 已发生在提交之后，失败不能虚报提交不存在。Push 的 pre-push 在发送更新前执行，非零阻止推送；远端接收 hooks 属于远端，不由 iPad伪造。[Git hooks][git-hooks]

若未来改用原生 Git 库，必须另做 Hook orchestration 合同；本轮没有选择/验证该库或声称它自动执行 Git hooks。还要处理 `core.hooksPath`、可执行位、stdin/argv/env、修改后的 index 与提交信息、失败及取消；不得为避免等 Linux 默认添加 `--no-verify`。

可在后续单独验证无 hook、行为受支持的原生 Git 操作。初始路由规则应在产生副作用之前检查能力：发现已配置 shell hook 或不支持的 Git 行为，整次事务等待 Linux ready 后执行；不能先原生提交，再补跑 Linux hooks。若将来选择跨两种实现的事务，须另证明 index 写租约及 hook 修改后重新检查，当前候选不依赖此复杂路径。

**必须规避的真实上游行为：** hook-protocol 的 `runHook` 捕获缺 shell/不可用目录等基础设施拒绝，解析为没有 exitCode 的 non-blocking error；不能让 Linux 未就绪的 hook 进入此分支后继续副作用。产品调度应在调用 runner 前等待 ready；必需 hook 的准备失败/取消须阻止对应工具/Git操作并返回明确结果。这是产品适配要求，不能冒称上游已保证。[runner 的 catch 分支][hook-runner]

## 最小可证伪门槛与下一步

以下是完整验收合同，本轮没有一项完整通过；Worker 原型提供 G0/G1/G2 部分主机证据和 G4 注入模型证据，后续共享/RPC 原型追加 G3/G4/G5 的真实 Linux 部分证据，并发现明确语义缺口，详见后节和[追加报告](plan500-sharing-rpc.md)。仍需统一写者合同及 iPad 探针，不关闭 #32 或解除 #17 的技术依赖。

| 门槛 | 最小证据与失败判据 |
| --- | --- |
| G0 固定候选可构建 | 固定提交、lock、packer/profile、模块替身列表和 SHA256；启动官方 agent/session/tool 树而非静态 UI。缺依赖/拒绝模块须明确错误 |
| G1 原生核心独立 | Linux 不启动时能恢复会话、读取修改隔离文件、保存配置/草稿；一次真实模型工具调用后可审阅变更。实际 API 流式传输、认证、取消和网络错误分别验；不以 fixture/伪回复替代 |
| G2 耐久数据 | Worker/App 有界重建后会话/草稿/文件一致；注入未完成写入、并发写、损坏日志，证明只提交完成的记录且保留可恢复副本；flock 单 Worker 替身不能覆盖外部写者 |
| G3 同一工作区 | 双向 create/write/rename/delete、中文名、symlink、mode/xattr、原子替换、锁争用、`.git/index.lock` 与 watcher/HMR；host/guest 内容/身份一致，任何一项不成立就收紧范围或否决共享方案 |
| G4 预热调度 | preparing 时排队，ready 自动继续一次；取消不重放；启动失败、项目关闭/切换、后台恢复、RPC断连有界返回。独立测核心 ready、Linux ready、首命令、内存/存储，不承诺毫秒/秒数 |
| G5 Hook/Git | 注入失败的前置 hook、修改 index/message 的 hook、post失败、pre-push失败；事件有序，前置失败无 commit/远端副作用。固定授权测试远端完成 push；不绕过 hooks |
| G6 插件能力 | 固定至少一个纯原生功能、一个 Linux command/hook、stdio与HTTP MCP路径及不支持插件；实测激活、调用、错误和取消。pnpm/安装脚本操作明确放在哪个环境 |
| G7 数据与回退 | 从隔离备份迁入新候选工作区，逐文件核验并保留原盘；候选失败回旧交付包。正式迁移与安装另按授权执行；原盘不能同时被两个执行器写 |

本轮已完成源码研究、Worker 持久化及真实 Linux 共享/RPC 的有界隔离探针，详见后节；未进行设备或真实模型运行验证。下一步针对已发现的共享缺口验证写租约、版本冲突和变更通知/轮询，再验证 Darwin/iPad 与模型路径，并在 #32 记录最终架构决定；门槛未过保持 #17 受技术关口约束。现有维护 #19 与 2026-10-12 签名截止独立继续，不重启已经取消的锁屏测试。


## 用户授权的隔离原型结果（2026-10-05）

**结论：候选值得继续验证，但尚不支持改选正式架构。** macOS WKWebView 中无需启动 Linux，真实官方 Worker 可启动、创建会话、保存中文标题；Swift 检查点确认后，销毁 Worker、重建官方树并重开会话，JSONL 标题和中文文件可恢复。代码与复跑入口见 [隔离探针](../../runtime/prototypes/plan500-worker/README.md)。以下是本地实测，不由上游文档推断。

| 项目 | 实际结果与边界 |
| --- | --- |
| 固定输入 | Harness/Worker/packer `0.2.0-rc.2`，本机 Node `24.20.0`、Zod `4.6.5`；两个 npm lock 已随原型提交，不执行 install scripts |
| 组装 | 官方 `dsh-worker-transform/1`，318 包、1,325 JS 条目、175 roster；缺包清单为空，但另有 62 项 unresolved external requests，不能据此宣称全部插件兼容 |
| 产物 | 干净安装复跑的 gzip 镜像 13,706,164 字节，SHA256 `886a6d8ab5929d693e9256650c432c3bb35e3046f75cd1fa006e91ec7ee82915`；镜像、原始日志不提交 |
| 官方核心 | 真实加载 860 个模块；通过官方 WorkerTunnel 调用 session/list、session/create、session/rename，再重开持久会话；没有 fixture 响应或模型调用 |
| 存储 | 官方会话 flush → 抓取受限 VFS → Swift 原子检查点写入/文件同步/读回 → 明确确认 → Worker 终止 → boot 前恢复；仅内存写入显式不算 saved |
| 失败注入 | 在持久写入前拒绝一次检查点，调用方得到错误；随后重建仍读到上一有效文件。没有真实掉电、进程写中途崩溃或磁盘满注入 |
| 计数 | 既有测试依赖和从两个 lock 全新安装的独立依赖树均 WebKit 14/14（含拒绝无效 schema）、调度模型 7/7；模型中的准备器/执行器均为注入，未启动真实 Linux 或执行真实 Git/hook |
| 时间与资源 | 第一次 session/list 的主机样本约 0.3–0.5 秒；不作 iPad 启动/恢复承诺。VFS 内容约 42.7 MB，不是实际 RSS/峰值内存测量 |

### 三项必要兼容适配

未经 Zod/schema 适配的负对照稳定返回 boot HTTP 503，27 个插件失败、19 个等待。模块级诊断定位到 Zod ESM 循环引用：`Cannot access 'globalConfig' before initialization`。原型只在 scratch 中选择同一已发布版本的 CJS 导出，原安装树不变；这表明官方 packer 对这组固定依赖不能直接作为即插即用方案。

随后真实 session/create 触发 `Symbol.dispose is not defined`。Worker 副本补齐缺失的 disposal 符号，保留上游释放 helper 的执行。继续调用仍因工具 schema 被拒绝而失败：固定 `dsh-tools` 和 `dsh-cordis-host-runner` 把原生构造器字符串精确写成单行；实际 WebKit 返回带换行的 `function Object() {\n    [native code]\n}`。scratch 适配改为比较当前 realm 的原生 Object/Array，保留构造器名、prototype 身份和其余严格校验，并实测普通 schema 被接受、Date/类实例/无效 type 被拒绝。正式移植须维护这些适配或推动上游修正，不应隐藏它们。[工具 schema 源码](https://github.com/deepseek-ai/deepseek-harness/blob/639ed015397290b3745d163aafe02ffee4aa3f84/packages/core/tools/src/json-schema.ts)

原型还暴露两个恢复顺序问题：rename 接口接受事件后，JSONL 批次可能仍未写入 VFS，必须先等待官方 sessionPersistence.flush；flush 完成也只到内存 VFS，仍需 Swift 确认。持久列表 projection cache 可能只有 seq 2，JSONL 已到 seq 3；本轮以官方重开后权威投影中的标题为准，没有把旧缓存当成数据丢失或恢复成功。

### 已通过部分与下一关口

本节 Worker 阶段的 G0 仅证明经上述适配的固定 web 组合可组装并加载；G1 仅证明无 VM 的会话/文件路径，模型、网络流、取消、认证与完整 UI 未验；G2 仅证明 Worker 重建与有界检查点失败，App/系统崩溃、损坏日志、并发写和原有压缩会话迁移未验。该阶段 G4 是模型行为检查，G3/G5 无运行证据；后续真实 Linux 结果见下节，G6/G7 仍未通过。

本节提出的下一步共享/RPC 探针现已完成，见下节。检查点不是实时共享目录，也不保留 hardlink/symlink 文件身份；base64 全量快照和 Swift 主线程写入不能直接用于大型工程。iPad 生命周期、真实模型工具和网络路径是正式架构决策前的独立关口。ADR/CONTEXT 未改选，#32 OPEN、#17 继续等待；正式安装/原盘迁移未开始。

私有收据：`build/prototypes/plan500-worker/run-safe.json`；负对照为 `unadapted-run-safe.json`，原始日志只留忽略目录。Harness lock SHA256 `1a60fdd7b3dd0501993f8848be11301c0fc1423268ff2fc02aeab39298559a19`；Worker/packer lock SHA256 `02472f491b41be7cfb3bafcb3a1301d868cf10b72cb328e11934956ee1b6e01c`。

## 用户授权的共享工作区与真实 RPC 结果（2026-10-05）

真实 Linux QEMU 中 `mapped-xattr`、`none` 各 23/23 必需协议检查通过：双向中文文件操作、原子替换、Git index.lock、真实 boot/ready、排队/去重/取消/超时/项目关闭、RPC 断连门禁。另有 8 项兼容性观察；两种模式均未通过全部共享语义。`mapped-xattr` 的宿主普通 mode/symlink 不等价；`none` 在本 Linux 样本保留二者，但两者均未协调被测跨域锁、guest watcher 未收到目标宿主写入，显式轮询成功。真实 pre-commit 非零阻止提交仅是一个 G5 用例。

Darwin SDK 小探针证实显式声明私有 `pthread_fchdir_np` 后可链接，macOS 隔离运行成功；公开头文件编译失败，iOS 未执行，QEMU backend 未验。完整结论、输入 SHA256、限制和复跑代码见[追加报告](plan500-sharing-rpc.md)。**下一步是统一写租约与变更通知/轮询合同，再做 Darwin/iPad 及模型路径**；不能直接把 9P 挂载视为共享工作区完成。原型仍未接入产品，G0–G7 均未完整通过。

[root-package]: https://github.com/deepseek-ai/deepseek-harness/blob/639ed015397290b3745d163aafe02ffee4aa3f84/package.json
[base-patch]: https://github.com/deepseek-ai/deepseek-harness/blob/639ed015397290b3745d163aafe02ffee4aa3f84/packages/bundle/base/cordis.patch.yml
[web-patch]: https://github.com/deepseek-ai/deepseek-harness/blob/639ed015397290b3745d163aafe02ffee4aa3f84/packages/bundle/web-app/cordis.patch.yml
[subprocess]: https://github.com/deepseek-ai/deepseek-harness/blob/639ed015397290b3745d163aafe02ffee4aa3f84/packages/subprocess/subprocess-local/src/index.ts
[terminal]: https://github.com/deepseek-ai/deepseek-harness/blob/639ed015397290b3745d163aafe02ffee4aa3f84/packages/subprocess/subprocess-local/src/terminal.ts
[bash]: https://github.com/deepseek-ai/deepseek-harness/blob/639ed015397290b3745d163aafe02ffee4aa3f84/packages/shell/bash-local/src/index.ts
[hook-runner]: https://github.com/deepseek-ai/deepseek-harness/blob/639ed015397290b3745d163aafe02ffee4aa3f84/packages/hooks/hook-protocol/src/runner.ts
[claude-hooks]: https://github.com/deepseek-ai/deepseek-harness/blob/639ed015397290b3745d163aafe02ffee4aa3f84/packages/hooks/hooks-claude-code/src/index.ts
[plugin-operations]: https://github.com/deepseek-ai/deepseek-harness/blob/639ed015397290b3745d163aafe02ffee4aa3f84/packages/boot/plugin-manager/src/operations.ts
[plugin-compatibility]: https://github.com/deepseek-ai/deepseek-harness/blob/639ed015397290b3745d163aafe02ffee4aa3f84/packages/boot/app-boot/src/plugin-compatibility.ts
[mcp-transport]: https://github.com/deepseek-ai/deepseek-harness/blob/639ed015397290b3745d163aafe02ffee4aa3f84/packages/mcp/mcp-client/src/transport.ts
[session-lease]: https://github.com/deepseek-ai/deepseek-harness/blob/639ed015397290b3745d163aafe02ffee4aa3f84/packages/session/session-persistence-jsonl/src/lease.ts
[session-verifier]: https://github.com/deepseek-ai/deepseek-harness/blob/639ed015397290b3745d163aafe02ffee4aa3f84/packages/session/session-persistence-jsonl/src/migration-verifier.ts
[sqlite-schema]: https://github.com/deepseek-ai/deepseek-harness/blob/639ed015397290b3745d163aafe02ffee4aa3f84/packages/session-query/session-query-sqlite/src/schema.ts
[fsio]: https://github.com/deepseek-ai/deepseek-harness/blob/639ed015397290b3745d163aafe02ffee4aa3f84/packages/fs/fs-local/src/fsio.ts
[system-package]: https://github.com/deepseek-ai/deepseek-harness/blob/639ed015397290b3745d163aafe02ffee4aa3f84/native/system/packages/entry/package.json
[worker-readme]: https://github.com/deepseek-ai/deepseek-harness/blob/639ed015397290b3745d163aafe02ffee4aa3f84/packages/experimental/webworker-runtime/README.md
[worker-package]: https://github.com/deepseek-ai/deepseek-harness/blob/639ed015397290b3745d163aafe02ffee4aa3f84/packages/experimental/webworker-runtime/package.json
[worker-index]: https://github.com/deepseek-ai/deepseek-harness/blob/639ed015397290b3745d163aafe02ffee4aa3f84/packages/experimental/webworker-runtime/src/index.ts
[worker-host]: https://github.com/deepseek-ai/deepseek-harness/blob/639ed015397290b3745d163aafe02ffee4aa3f84/packages/experimental/webworker-runtime/src/worker-host.ts
[worker-proxies]: https://github.com/deepseek-ai/deepseek-harness/blob/639ed015397290b3745d163aafe02ffee4aa3f84/packages/experimental/webworker-runtime/src/module-proxies.ts
[worker-flock]: https://github.com/deepseek-ai/deepseek-harness/blob/639ed015397290b3745d163aafe02ffee4aa3f84/packages/experimental/webworker-runtime/src/node/external_packages/node-addon-system-flock.ts
[worker-sqlite]: https://github.com/deepseek-ai/deepseek-harness/blob/639ed015397290b3745d163aafe02ffee4aa3f84/packages/experimental/webworker-runtime/src/node/builtin_modules/mock/sqlite.ts
[worker-process]: https://github.com/deepseek-ai/deepseek-harness/blob/639ed015397290b3745d163aafe02ffee4aa3f84/packages/experimental/webworker-runtime/src/node/builtin_modules/implemented/child_process.ts
[worker-http]: https://github.com/deepseek-ai/deepseek-harness/blob/639ed015397290b3745d163aafe02ffee4aa3f84/packages/experimental/webworker-runtime/src/node/builtin_modules/implemented/http.ts
[worker-zlib]: https://github.com/deepseek-ai/deepseek-harness/blob/639ed015397290b3745d163aafe02ffee4aa3f84/packages/experimental/webworker-runtime/src/node/builtin_modules/implemented/zlib.ts
[packer]: https://github.com/deepseek-ai/deepseek-harness/blob/639ed015397290b3745d163aafe02ffee4aa3f84/packages/experimental/webworker-packer/README.md
[mobile-version]: https://github.com/nodejs-mobile/nodejs-mobile/blob/d9552e0e01ed5bdbe12a31d1ce6c0877a4f39580/src/node_version.h
[mobile-faq]: https://github.com/nodejs-mobile/nodejs-mobile/blob/d9552e0e01ed5bdbe12a31d1ce6c0877a4f39580/doc_mobile/FAQ.md
[mobile-release]: https://github.com/nodejs-mobile/nodejs-mobile/releases/tag/v18.20.4
[jsc]: https://developer.apple.com/documentation/javascriptcore
[local-runtime]: https://github.com/lvivvde/deepseek-harness-ipad/blob/7956e8c/ios/HarnessApp/Sources/Core/RuntimeConfiguration.swift
[local-transfer]: https://github.com/lvivvde/deepseek-harness-ipad/blob/7956e8c/runtime/guest/transfer.cjs
[utm-sharing]: https://github.com/utmapp/UTM/blob/7eadb056ae0f91d979059544d0ddcd2d5a40be92/Configuration/UTMQemuConfiguration%2BArguments.swift#L1211-L1235
[qemu-fsdev]: https://www.qemu.org/docs/master/system/qemu-manpage.html
[utm-linux]: https://docs.getutm.app/guest-support/linux/#virtfs
[virtiofsd]: https://virtio-fs.gitlab.io/qemu/tools/virtiofsd.html
[git-hooks]: https://git-scm.com/docs/githooks
