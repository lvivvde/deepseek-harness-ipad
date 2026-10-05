# 官方 Harness 与 Android 本地实现：iPad 移植研究

> 归档说明：本报告原在未合并分支 `research/upstream-android`（提交 `ad06a52`），2026-10-06 原样归档进 main，分支随后删除。属早期历史研究，当前架构以 [ADR 0003](../adr/0003-native-worker-with-project-linux.md) 为准。

研究日期：2026-10-02（Asia/Shanghai）。对应决策票：[研究：官方 Harness 与 Android 移植有哪些可复用部分？](https://github.com/lvivvde/deepseek-harness-ipad/issues/2)。

## 结论与使用边界

官方核心和 Web 界面值得作为复用起点；官方桌面版是 Electron 对同一 Web/Host 的包装，Android 两个实现则分别借助 Termux 和 Ubuntu 用户态环境提供本地工具执行。三者没有证明“把界面装进 IPA 就能保留全部执行能力”。iPad 的难点需要在运行时、文件系统、子进程、原生模块、沙箱与插件能力接口上逐一解决。下面的“移植含义”是依据已读源码的推断，尚不是选定的架构或真机结果。[官方架构][O-arch]、[桌面宿主启动][O-host]、[DSHA 容器运行时][D-runtime]、[Termux 安装器][T-install]。

约束：普通未越狱 iPad；项目、工具和插件执行均在本机；允许联网调用模型；首版可以只支持明确列出的项目类型，但要完成拉取、修改、测试、提交的本地闭环。本研究不做移植，不采用远程执行来绕过约束。

## 固定版本及来源身份

| 实现 | 本次固定版本 | 归属及证据范围 |
|---|---|---|
| 官方源码、Web 和桌面源码 | dsh-v0.2.0-rc.2，commit 639ed015397290b3745d163aafe02ffee4aa3f84；根包及桌面包版本均为 0.2.0-rc.2 | deepseek-ai/deepseek-harness；[固定 tag][O-release]、[根 manifest][O-root]、[桌面 manifest][O-desktop-package] |
| DSHA Android 应用 | 源码 commit 22ee68324110cf699e9a91f58cbc6d5ccd03688f；宿主版本 0.1.7-rc2、versionCode 147；内置 dsh 固定 0.1.7-rc.2 | DSH-APP/DSHA，独立维护者仓库；[Gradle][D-gradle]、[运行时 manifest][D-lock]。发布 v0.1.7-rc2 的 target commit 为 ac2767272d04da1d71b310137f1925e9e8950d53，源 HEAD 与发布 commit 分开记录，不视为相同构建 |
| Termux 移动分发 | commit 636f476fa19c7d5ae9ae0aa6abf910e596ef7d9f；安装器固定 CLI 0.1.0-rc.6，加 12 个本地 0.1.0-rc.7 tgz | ChongYep/Deepseek-harness-mobile，独立维护者仓库；[安装器][T-install]、[README][T-readme]。不是原生 APK，浏览器页面连接同设备 Termux Host |

官方 [Harness 官网](https://deepseek.com/harness/) 在研究时实际提供 macOS Apple Silicon DMG 和 Windows x64 EXE 下载，也链接官方源码与社区插件。2026-09-29 的 [dsh-v0.2.0-rc.2 GitHub release][O-release] 是预发行、API 所列 assets 为空；不能把 GitHub release 的 CLI 版本直接等同于官网 latest 二进制。本研究固定了桌面源码版本，未下载或解包官网安装包，因此没有核验官网安装包的实际版本、签名、字节数或与该 commit 的对应关系。官网 latest URL 会变化。

## 依赖与迁移风险矩阵

| 能力/层 | 官方 0.2.0-rc.2 的事实 | Android 对照事实 | 对 iPad 的含义（推断） |
|---|---|---|---|
| 主体语言与 UI | TypeScript/JavaScript 模块；桌面 Electron ^44.0.0，React/ReactDOM ^18.2.0；桌面加载完整 Web 应用 | DSHA Java 17 原生宿主，标准版系统 WebView、兼容版 GeckoView；Termux 版为浏览器移动 Web UI | Web 界面及业务层有复用机会；Java/Gecko/Electron 宿主层不是可直接重新签名的 iOS 代码。语言相同不等于运行环境相同。[O-desktop-package][O-desktop-package]、[D-gradle][D-gradle]、[T-readme][T-readme] |
| Node 与包管理 | 根 engines 为 ^22.19.0 或 >=24.0.0；根 pnpm@11.7.0；共享 primary-runtime lock 固定 Node 24.21.0、Python 3.12.14 | DSHA README 明述 Node 24、pnpm 10；其 notices 固定 pnpm-runtime 10.34.5；Termux 安装器主动检查 node:sqlite | Node 18 等移动嵌入库不能直接满足当前官方 engines；必须审查实际所需 API 并选择升级、适配或冻结上游版本。网页内 JavaScript 环境也不能自动替代 Node。[根 manifest][O-root]、[runtime lock][O-primary]、[DSHA notices][D-notices]、[Termux 安装器][T-install] |
| 桌面宿主与核心分层 | Electron Node mode 启动共享 CLI profile runner；桌面加载 dsh-app://app/；HTTP/WebSocket 到带鉴权本地 Host；Node IPC 承担启动、退出及账号私有信息 | DSHA 原生层负责安装、服务、WebView、工作区和插件管理，Ubuntu 内 Node 运行 Web Host；Termux 外部保活 | 可借鉴“宿主 + 共享 Harness + Web UI”分层；iPad 的宿主、启动和生命周期要另行设计。[桌面 README][O-desktop]、[宿主源码][O-host]、[DSHA README][D-readme] |
| 子进程与 PTY | spawnSubprocess 调用 node:child_process.spawn；local 依赖 koffi 3.1.1、node-pty 1.2.0-beta.15；PTY handle 管理输入、窗口与进程退出 | DSHA 的容器 prefix 执行 proot/proroot，并提供 Termux JNI 真 PTY；Termux rc.7 包把 node-pty 变成 optional，加载失败给 TerminalUnavailableError | 核心工具执行不是仅改文本；shell、Git、测试器和终端需要可用的执行世界。不能用“node-pty 可选”推导完整本地闭环已满足。[spawn 源码][O-spawn]、[subprocess manifest][O-subprocess-package]、[terminal 源码][O-terminal]、[DSHA Gradle][D-gradle]、[Termux tgz][T-subprocess] |
| 原生与文件能力 | fs-local 硬依赖 koffi；attachment-local 硬依赖 sharp；sandbox-local 依赖 @deepseek-ai/node-addon-system | DSHA 利用 Ubuntu/glibc 运行 Linux arm64 依赖；Termux 旧版本补丁将部分原生依赖可选化并提供硬链接失败回退 | ARM64 CPU 相同不使 ELF/glibc/native addon 自动变为 iOS 可用。需逐包区分必需能力、替换 provider 和功能降级，不能宣布 npm 插件普遍兼容。[fs manifest][O-fs]、[attachment manifest][O-attachment]、[sandbox manifest][O-sandbox-package]、[DSHA README][D-readme]、[Termux README][T-readme] |
| 沙箱 | sandbox-local 列出 Linux bwrap/Landlock、macOS Seatbelt、Windows ACL runner，功能探测失败时 fail-closed | DSHA 与 Termux 均承认 Android 执行沙箱不可用，默认 danger-full-access。DSHA 明述容器、插件、Node/Python 和终端在相同 Android UID 下运行 | 原生应用 OS 沙箱不等于项目间/插件间隔离。proot 路径重映射、权限档位、归档防逃逸和禁生命周期脚本不能宣称恶意插件已被安全隔离。[sandbox manifest][O-sandbox-package]、[sandbox provider][O-sandbox]、[DSHA security][D-security]、[Termux README][T-readme] |
| 安装与持续运行 | 桌面打包运行时并可用内置 pnpm 管理外部插件 | DSHA 安装流水线解压 rootfs、工具、Node、pnpm、dsh、补丁，失败项单独修复；原生前台服务与 watchdog。Termux 建议 wake-lock 与 tmux | 可以借鉴可诊断安装与修复、版本锁、插件回退；Android 前台服务、tmux 和可执行目录策略不是 iPad 后台保证。[DSHA pipeline][D-install]、[DSHA README][D-readme]、[Termux README][T-readme] |

没有跑完整应用、npm 安装、构建或模型请求；矩阵是固定源码和维护者声明核查，不是性能或兼容性验收。

## 复用接口与插件生态

官方架构将能力拆为服务定义、provider 和 consumer。具体可替换点包括 ctx.fs、ctx.subprocess、ctx.shell、ctx.terminals、ctx.sandbox；它特别要求文件系统和子进程 provider 共享同一执行世界。因此“保留核心、替换本机能力 provider”是源码允许讨论的方向，但并没有一个已核实可直接启用的 iPad provider。[能力 seams 与扩展表][O-arch]。

官方 README/官网指向 GitHub Discussions、Discord 与 GitHub dsh-plugin topic。该 topic 是发现入口，不是运行时兼容或安全认证。DSHA 另外接入 dsha.cc 目录和社区插件，支持链接、归档、本地导入和终端登记；它要求已构建入口、dsh.bundle.patch，依赖安装不跑 prepare/build/install 或 pnpmfile hooks；官方核心由整套 dsh 环境更新，而不是普通第三方插件覆盖。[官方 README][O-readme]、[官方社区 topic](https://github.com/topics/dsh-plugin)、[DSHA plugins][D-plugins]。

DSHA 的移动适配插件来自 mexiaosqwq/dsh-web-mobile，notices 固定 v2.1.1、MIT，并记录纯 DOM/CSS 改造与浏览器共享 React 依赖。它可以作为触屏布局调查对象，不能因此认为其它 host 插件也兼容。[DSHA notices][D-notices]。iPad 方案应产出兼容表，至少区分纯客户端 UI、宿主纯 JS、文件/执行 provider、原生 addon、外部二进制、设备 API 六种依赖；这是本研究的建议分类，不是已确定产品规范。

## 账号登录、模型 API Key 与本机 Web 鉴权

三件事应分开建模：

1. 官方账户模型 route 为 deepseek-account，解析 Host 的账号 grant，并向允许的推理 origin 发送 x-dsh-auth-token；API Key route 为 deepseek-official，读取 credentials/启动环境并发送 x-api-key。两条 route 在源码里明确分开，退出账户不应被等同为删除 API Key。[账号 adapter][O-account-llm]、[API Key adapter][O-key-llm]。
2. 官方账户 provider 使用系统浏览器、Host /oauth/callback、state 和 S256 PKCE；约束 platformOrigin 和 inferenceOrigin；当前文档只支持显式端口的 HTTP localhost/127.0.0.1/[::1] 及 SSH 本地转发。iPad 需要验证浏览器回调、凭据安全存储、发行客户端身份及官方服务是否接纳，源码存在登录实现不能证明第三方 IPA 登录已被平台授权或支持。[account provider 文档][O-account-platform]。
3. DSHA DshAuthSession.java 的本机鉴权是将启动 URL 换成 dsh-auth cookie、再请求本地页面验证 200；这是 Harness Web RPC 访问凭据，并非 DeepSeek 账户/模型登录。DSHA README 首次设置明确采用 API Key；运行时 manifest 含账号服务，但本研究未实际验证 DSHA 中官方账户模型登录流程。[DSHA AuthSession][D-auth]、[DSHA README][D-readme]、[运行时 manifest][D-lock]。

## 许可与复用边界

官方、DSHA、ChongYep 仓库各自 LICENSE 均是 MIT；可复用代码需保留对应版权及许可声明，第三方包继续遵循各自许可。不能以顶层 MIT 概括整个运行时。官方 THIRD_PARTY_NOTICES 明述只覆盖 workspace 直接依赖及特定 payload，完整 transitive closure 要查 lockfile；社区插件也要逐个核查。[官方 LICENSE][O-license]、[官方 notices][O-notices]、[DSHA LICENSE][D-license]、[Termux LICENSE][T-license]。

特别不能把 DSHA 默认 proroot 当成开源移植基础：DSHA notices 指定 proroot v1.2.8 为 Proprietary，声明允许使用但禁止分发修改二进制，且未公开源码；传统 Termux proot 为 GPL-2.0；Termux terminal JNI 是 Apache-2.0；GeckoView 是 MPL-2.0；Ubuntu rootfs 各包有各自许可。这里是维护者分发声明核查，不是完整合规审计；若复用实际二进制，应回到各组件发行许可、源码供给与修改条件逐项确认。[DSHA notices][D-notices]。

## 有证据的体量数字

[DSHA v0.1.7-rc2 release][D-release] 的 GitHub API 研究时返回：

| APK | 发布文件字节数 | 换算 MiB |
|---|---:|---:|
| dsha-0.1.7-rc2.apk | 273,621,504 | 260.95 |
| dsha-0.1.7-rc2low.apk | 349,864,634 | 333.66 |

这些是 Android 下载 APK 大小，包含其选定 Ubuntu/Node/toolchain/UI 资产，兼容版另外有 Gecko；不是安装后磁盘、峰值内存或 IPA 估算。ChongYep README 的 8 GB+ 是作者提出的设备条件，本研究未基准测量，不能视作 iPad 最低 RAM。没有可靠数字可给出 iPad 工期、IPA 大小或内存预算；要等架构、执行器和首版兼容集合确定后，在原型设备测量。[DSHA README][D-readme]、[Termux README][T-readme]。

## 未验证项与后续决策输入

- 官方官网 latest 二进制版本/签名/源码对应未解包验证；桌面源码 baseline 已固定。
- iPad 上何种运行时能满足 Node engines、SQLite、模块加载、原生库与生命周期；此票不判定。
- 自签名 IPA 的实际 entitlement、执行器能力、后台/挂起恢复与内存限额应由 iPad 平台票和后续真机验证处理。
- 第三方账号服务接入、费用/额度、插件下载来源与插件 ABI 的兼容承诺未验证。
- DSHA README 部分陈述较宽，但 security-model 明确缩小隔离边界；采用较窄的已披露保证。ChongYep 的补丁锁在旧 rc.6/rc.7，不可直接应用于最新 rc.2。
- 本地 Git、依赖解析、至少一种测试工具的端到端执行仍是首版架构必须给出证据的门槛。

## 证据方法与覆盖限制

采用 Verify Tier 2，任务定向核查；不做全仓审计。先 list_projects，确认父工作区图仅是无应用源码的骨架。外部官方 clone 网络未完成，改为通过 GitHub contents API 在固定 commit 下载上述准确路径；DSHA 和 Termux 来源也固定 commit。为结构发现创建精确文件快照图：wayfinder-official-exact（generation 2026-10-02T15:08:28Z）、wayfinder-dsha-exact（15:08:26Z），以及 Termux 完整小仓 wayfinder-upstream-termux（15:04:04Z）；这些是有意有限的快照，绝不代表完整上游仓库。

定向 search_graph 分别返回 official 16 项、DSHA 8 项、Termux 32 项，均 has_more=false。官方 spawnSubprocess 精确 snippet 确认子进程调用；both-direction depth 1 trace 返回四个快照内 callee、零 caller，零 caller 不能被用于“没有调用者”的全仓结论。DSHA ContainerRuntime 精确 snippet 核实 Linux路径、proot/proroot前缀与进程环境。

对所有证据路径调用 check_index_coverage。docs 与 LICENSE 被排除，直接阅读；DSHA Gradle parse_partial 为 75、165、219、228 行，已直接读相应范围及所引配置。后来补充的 manifest/account docs/notices 不在初始图中，coverage freshness=not_tracked，已直接阅读/按字面检索，未以图作完整性背书。Termux tgz 内 manifest 和编译 JS 通过 tar 精确读取，图不解析归档内容。没有记录缺口只是 best-effort 信号，不是完备性证明。

## 固定一手资料索引

[O-release]: https://github.com/deepseek-ai/deepseek-harness/releases/tag/dsh-v0.2.0-rc.2
[O-root]: https://github.com/deepseek-ai/deepseek-harness/blob/639ed015397290b3745d163aafe02ffee4aa3f84/package.json
[O-readme]: https://github.com/deepseek-ai/deepseek-harness/blob/639ed015397290b3745d163aafe02ffee4aa3f84/README.md
[O-desktop-package]: https://github.com/deepseek-ai/deepseek-harness/blob/639ed015397290b3745d163aafe02ffee4aa3f84/apps/desktop/package.json
[O-desktop]: https://github.com/deepseek-ai/deepseek-harness/blob/639ed015397290b3745d163aafe02ffee4aa3f84/apps/desktop/README.md
[O-host]: https://github.com/deepseek-ai/deepseek-harness/blob/639ed015397290b3745d163aafe02ffee4aa3f84/apps/desktop/src/host-process.ts#L183-L204
[O-arch]: https://github.com/deepseek-ai/deepseek-harness/blob/639ed015397290b3745d163aafe02ffee4aa3f84/docs/architecture.md
[O-primary]: https://github.com/deepseek-ai/deepseek-harness/blob/639ed015397290b3745d163aafe02ffee4aa3f84/scripts/primary-runtime/lock.json
[O-subprocess-package]: https://github.com/deepseek-ai/deepseek-harness/blob/639ed015397290b3745d163aafe02ffee4aa3f84/packages/subprocess/subprocess-local/package.json
[O-spawn]: https://github.com/deepseek-ai/deepseek-harness/blob/639ed015397290b3745d163aafe02ffee4aa3f84/packages/subprocess/subprocess-local/src/spawn.ts#L454-L492
[O-terminal]: https://github.com/deepseek-ai/deepseek-harness/blob/639ed015397290b3745d163aafe02ffee4aa3f84/packages/subprocess/subprocess-local/src/terminal.ts
[O-fs]: https://github.com/deepseek-ai/deepseek-harness/blob/639ed015397290b3745d163aafe02ffee4aa3f84/packages/fs/fs-local/package.json
[O-attachment]: https://github.com/deepseek-ai/deepseek-harness/blob/639ed015397290b3745d163aafe02ffee4aa3f84/packages/attachment/attachment-local/package.json
[O-sandbox-package]: https://github.com/deepseek-ai/deepseek-harness/blob/639ed015397290b3745d163aafe02ffee4aa3f84/packages/sandbox/sandbox-local/package.json
[O-sandbox]: https://github.com/deepseek-ai/deepseek-harness/blob/639ed015397290b3745d163aafe02ffee4aa3f84/packages/sandbox/sandbox-local/src/index.ts
[O-account-llm]: https://github.com/deepseek-ai/deepseek-harness/blob/639ed015397290b3745d163aafe02ffee4aa3f84/packages/llm/llm-deepseek-account/src/index.ts
[O-key-llm]: https://github.com/deepseek-ai/deepseek-harness/blob/639ed015397290b3745d163aafe02ffee4aa3f84/packages/llm/llm-deepseek-api-key/src/index.ts
[O-account-platform]: https://github.com/deepseek-ai/deepseek-harness/blob/639ed015397290b3745d163aafe02ffee4aa3f84/packages/credentials/deepseek-account-platform/README.md
[O-license]: https://github.com/deepseek-ai/deepseek-harness/blob/639ed015397290b3745d163aafe02ffee4aa3f84/LICENSE
[O-notices]: https://github.com/deepseek-ai/deepseek-harness/blob/639ed015397290b3745d163aafe02ffee4aa3f84/THIRD_PARTY_NOTICES.md
[D-readme]: https://github.com/DSH-APP/DSHA/blob/22ee68324110cf699e9a91f58cbc6d5ccd03688f/README.md
[D-gradle]: https://github.com/DSH-APP/DSHA/blob/22ee68324110cf699e9a91f58cbc6d5ccd03688f/app/build.gradle
[D-lock]: https://github.com/DSH-APP/DSHA/blob/22ee68324110cf699e9a91f58cbc6d5ccd03688f/tools/dsh-runtime/package.json
[D-runtime]: https://github.com/DSH-APP/DSHA/blob/22ee68324110cf699e9a91f58cbc6d5ccd03688f/app/src/main/java/com/deepseekharness/app/runtime/ContainerRuntime.java
[D-install]: https://github.com/DSH-APP/DSHA/blob/22ee68324110cf699e9a91f58cbc6d5ccd03688f/app/src/main/java/com/deepseekharness/app/runtime/InstallPipeline.java
[D-security]: https://github.com/DSH-APP/DSHA/blob/22ee68324110cf699e9a91f58cbc6d5ccd03688f/docs/security-model.md
[D-plugins]: https://github.com/DSH-APP/DSHA/blob/22ee68324110cf699e9a91f58cbc6d5ccd03688f/docs/plugins.md
[D-auth]: https://github.com/DSH-APP/DSHA/blob/22ee68324110cf699e9a91f58cbc6d5ccd03688f/app/src/main/java/com/deepseekharness/app/util/DshAuthSession.java
[D-release]: https://github.com/DSH-APP/DSHA/releases/tag/v0.1.7-rc2
[D-license]: https://github.com/DSH-APP/DSHA/blob/22ee68324110cf699e9a91f58cbc6d5ccd03688f/LICENSE
[D-notices]: https://github.com/DSH-APP/DSHA/blob/22ee68324110cf699e9a91f58cbc6d5ccd03688f/THIRD_PARTY_NOTICES.md
[T-readme]: https://github.com/ChongYep/Deepseek-harness-mobile/blob/636f476fa19c7d5ae9ae0aa6abf910e596ef7d9f/README.md
[T-install]: https://github.com/ChongYep/Deepseek-harness-mobile/blob/636f476fa19c7d5ae9ae0aa6abf910e596ef7d9f/install/install.sh
[T-subprocess]: https://github.com/ChongYep/Deepseek-harness-mobile/blob/636f476fa19c7d5ae9ae0aa6abf910e596ef7d9f/install/deepseek-ai-dsh-subprocess-local-0.1.0-rc.7.tgz
[T-license]: https://github.com/ChongYep/Deepseek-harness-mobile/blob/636f476fa19c7d5ae9ae0aa6abf910e596ef7d9f/LICENSE
