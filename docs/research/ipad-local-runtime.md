# 普通 iPad 的本地开发执行环境：架构选择证据

日期：2026-10-02。研究票：[研究：普通 iPad 能支持怎样的本地开发执行环境？](https://github.com/lvivvde/deepseek-harness-ipad/issues/3)。分支：`research/ipad-local-runtime`。

约束：普通未越狱 iPad；使用者重签 IPA；Harness、文件、Git、包管理、工具与测试均在本地执行；允许联网调用模型、下载依赖、访问 Git 远端；首版可限定项目和插件，但要完成拉取、修改、测试、提交的闭环。本研究不构建产品、不实际签名、不进行真机性能测量。

## 结论和决策边界

**事实支持“有限兼容范围内的本地开发环境”存在可复用路线；不支持“把桌面包或 Android Linux 环境原样装进 IPA 就能工作”。** iPad 的项目目录不是阻断；执行宿主、子进程语义、原生依赖、隔离与中断恢复才是选择架构的关键。强芯片和总 RAM 不能代替这些能力的证据。[Apple 运行时安全][apple-runtime]、[a-Shell][ashell]、[nodejs-mobile 构建脚本][node-build]、[iSH][ish]。

**建议作为下一张人机决策票的候选，而非本票替用户锁定：**

1. **宿主适配路线**：原生 iPad UI/目录与任务宿主，嵌入无需 JIT 的 JS/Node 类运行时；把 Harness 文件、Git、执行工具接到明确的宿主接口。受控命令借鉴 `ios_system`，扩展插件优先解释器或 WASM。优点是首版范围可控；代价是上游进程依赖须修改，Node 版本匹配未解决。
2. **用户态 Linux 模拟路线**：借鉴 iSH 保留 guest shell、fork/exec、PTY 和 guest 包生态；用桥接连接项目、UI 与 Harness。优点是较接近 Linux 工具语义；代价是 i386、syscall/指令兼容和性能，现代 Harness/Node 必须实测。
3. **无 JIT 全系统模拟**：UTM SE 证明普通侧载 app 可用解释器模拟 32/64 位系统；可能容纳更现代 Linux 工具链，但多出完整 guest OS、磁盘和桥接层。保留为比较候选，不能凭来源将它认定为生产首选。[UTM SE 固定源码][utm]

目前不能给可信 IPA 大小、内存上限、工程规模或速度数字；这些取决于选择的运行时、工具链、签名构建和真实设备。不得把上游描述的解释器相对速度当作本产品性能。

## 操作系统条件：事实

- 第三方 app 在 sandbox 内运行；访问其他数据需系统提供的接口；entitlements 被签入并受验证。普通重签不是提权机制。Apple 对可写且可执行内存有严格条件，不能将无越狱侧载等同于通用 JIT 权限。[Apple 运行时安全][apple-runtime]
- iOS/iPadOS 可执行代码需要 Apple 证书签名；嵌入 framework 可用；动态库链接有代码签名与 Team ID 条件。因此基础方案应把原生工具编译为随 IPA 一起签名的库。下载 JS/Python/WASM 数据交给已签解释器执行，与把下载的 arm64 二进制变成可执行进程是不同路径；前者有下列成熟项目证据。新增原生模块通常意味着重新构建/组装和重签，不能许诺任意下载 `.node`/`.dylib` 即用。[Apple 代码签名][apple-signing]
- iOS 13 起 `UIDocumentPickerViewController` 可授权一个目录及其子目录、新增文件；可保存 bookmark 供重启后使用。必须配合 security-scoped resource 生命周期及文件协调，且用户可撤销授权。可建立 app 内项目库，也可让用户选 Files 目录；不能声称任意读全盘。[Apple 目录访问][apple-files]
- 普通后台模式会暂停 app，短暂 `beginBackgroundTask` 和系统调度 `BGProcessingTask` 不是无限终端守护进程。[Apple 后台策略][apple-background]
- **不要遗漏 iPadOS 26**：`BGContinuedProcessingTask` 支持由用户在前台发起、进入后台后继续的 CPU/网络工作；提供进度、取消和排队策略。仍可能因资源条件终止，不能许诺永久驻留。最低系统版本和是否采用此能力尚待方案决定。[Apple 持续任务][apple-continued]、[终止与进度条件][apple-continued-class]、[WWDC25 系统版本说明][apple-wwdc]

## 已固定的一手实现证据

### 嵌入 JS/Node 与进程内命令

`nodejs-mobile` 的 arm64 device 构建明确 `--dest-os=ios --enable-static --v8-options=--jitless`；同一 commit 的 `src/node_version.h` 是 **Node 18.20**，不可直接视为满足现代上游要求。并行研究票已读取 DeepSeek Harness 固定 `dsh-v0.2.0-rc.2`（commit `639ed015397290b3745d163aafe02ffee4aa3f84`），其根 `engines.node` 为 `^22.19.0 || >=24.0.0`、`packageManager` 为 `pnpm@11.7.0`；这使此 Node 18 候选存在已知版本缺口，而非仅理论风险。[上游固定 package.json][upstream-package][构建脚本 L60–73][node-build]、[版本头 L25–27][node-version]

项目 FAQ 明确：`child_process.spawn/fork` 等创建进程的 API 会遇到权限问题；runtime 预期每进程单实例，在专用线程运行而非 WebView 内。原生模块需要目标平台交叉编译和适配。FAQ 只承诺 npm 模块在 app 开发时安装，**没有证明 iPad 内任意 `npm install` 闭环**。运行时线程不是后台执行授权。[FAQ][node-faq]

`--jitless` 是解释运行 JS 的路线，不代表完整桌面 V8 性能和功能。V8 2019 一手说明在当时 jitless 模式不支持 WebAssembly；这不是当前所有 V8 版本的普遍断言。选定 runtime 必须探测 `WebAssembly` 实际能力，不能据 Node 存在就许诺 `esbuild-wasm`；独立 WASM 解释器可避开这个假设。[V8 说明][v8]

`ios_system` 用命令字典选已嵌入的 framework，`dlopen/dlsym` 定位入口，以 `pthread_create(run_function, …)` 执行命令。其 `ios_execv` 不具有真实 exec 终止/替换进程语义；stdio、退出和全局变量要适配。这证明命令能移植，不证明任意 Unix 二进制能启动。[命令加载 L3810–3833][ios-load]、[线程执行 L3898–3949][ios-thread]、[集成及语义说明][ios-readme]

`ios_setMiniRoot` 与 `__allowed_cd_to_path` 是宿主目录规则。已读范围只证明目录切换限制，**不能据这个名字宣称每个插件拥有 OS 级 sandbox**。[范围 L992–1067][ios-miniroot] 同进程原生代码共享 app 权限/内存的隔离风险是架构推断；需用受限宿主 API、WASM capability、独立 guest 根等设计，并验证逃逸路径。

### WASM/WASI 与本地编译

WAMR 有 iOS 构建目录；固定 `CMakeLists.txt` 明确 `INTERP=1`、`AOT=0`、WASI libc 开启，JIT 与 fast JIT 默认关闭。这是可嵌入解释器的源码起点，**不是已成功构建、通过签名和真机验证的产品证据**；脚本/linker/SDK 条件仍需实验。[WAMR iOS 配置][wamr-ios]

a-Shell 自述并包含这些功能：嵌入 Python/Lua/JS；本地 clang 将 C/C++ 编译为 WebAssembly；运行 WASM、下载其特定命令包；pip 安装纯 Python 包。其 WASM 宿主明确没有 fork、socket，原生 Python 扩展不能任意现场构建后装载。**这些是 a-Shell 此实现的边界，不是所有 WASI 版本永久没有 socket**。[固定 README 的 Programming 段][ashell]

WASI 是有版本差异的系统接口；宿主显式授予能力的设计适合受限插件，但不能把“WASI”当作完整 POSIX、任意 Node API 或已有 Docker sandbox。选用版本、导入函数、文件 preopen、网络 broker、执行时间/内存限额须成为插件 ABI 的组成部分。[WASI 一手概览][wasi]

### Linux 用户态和全系统模拟

iSH 使用 x86 用户态模拟和 syscall 翻译；执行文件检查限定 32 位 little-endian x86 ELF。guest `sys_fork/sys_vfork` 进入 `sys_clone`，并有 guest PTY/termios 实现和 app PTY 桥接。其 fork/exec 是模拟层行为，不是 iPad 新获原生 Linux 子进程权利；也不是 Docker/真实 Linux 内核。[README][ish]、[ELF 检查 L37–52][ish-exec]、[clone/fork L143–208][ish-fork]、[guest tty][ish-tty]、[app PTY][ish-pty]

因此 guest shell、Git、Python、包安装和部分编译工具具有路线；具体 Alpine 版本、仓库、包架构、syscall 和指令兼容必须逐个验证。**未证明现代 Node/Harness 可运行**，也未证明其速度/多工程稳定性；不得用“能装 Alpine”替代这些验证。

UTM SE 在固定 README 中明确用 threaded interpreter，普通侧载无需越狱或 JIT workaround，含 32/64 位 ARM/PPC/RISC-V/x86。它说明更完整 guest OS 并非理论上完全不可能；没有说明任何 iPad 跑 Node 24/Harness 都足够快。[UTM README][utm]

### Git、预览和 MCP

`isomorphic-git` 是纯 JS 实现，可读写 `.git`，fetch/push，提供 `clone/add/commit` 等 API，允许自行提供 fs/HTTP adapter。它可作为本地 Git 候选；浏览器环境 CORS 是实在约束，iPad 宿主网络桥可作为替代路线，但还需验证认证、仓库操作和磁盘持久性，不能把 README 当完整 git CLI 保证。[固定 README][isogit]

本地 HTTP/预览不是从 shell 子进程必然推出的能力。可由 app 内嵌网络宿主提供，或 guest 端口桥接；普通 app 的接收 TCP 与本地网络权限不是同一条件，Apple 对方向及 WebView 有明确规则。具体 loopback/ATS/WebView/CSP、端口、后台切换和热更新仍须实验。[Apple TN3179][apple-network]

MCP 标准 stdio transport 规定 client 启动 server 子进程。可在 guest 模拟的进程层实现，或将精选 server 适配到宿主；协议允许 custom transport，但进程内 JSON-RPC 适配必须说明连接和生命周期，不能宣称无修改兼容任意 `npx ...`。HTTP transport 在本票约束内仅接受**设备本地**工具服务；远端工具执行不满足用户要求。[MCP transports][mcp]

## 能力矩阵

“候选”表示文档/源码支持路线，未完成真机验收；“适配”表示必须实现接口或改变上游。

| 能力 | 嵌入解释器/进程内宿主 | WASM/WASI 解释器 | iSH 用户态 Linux | UTM SE 全系统模拟 |
|---|---|---|---|---|
| Harness 逻辑、联网模型 | 候选；匹配语言/API/Node 版本 | JS 核心须额外解释器/移植 | 需验证具体 Node/Harness | guest 内候选，版本与性能未知 |
| JS/TS 项目 | JS 候选；TS 需本地 transpile/typecheck API；不是原生执行 TS | 可装移植工具；与 Node 不等价 | i386 工具兼容待测 | 完整 guest 工具候选，待测 |
| shell/管道/退出码 | ios_system 类适配，限定命令 | 宿主约定；无自动 POSIX | guest shell/syscalls 已实现 | guest OS 提供 |
| fork/exec/PTY | 普通 Node spawn/fork 非即用；交互终端需适配 | 无默认真实子进程；PTY 需宿主 | guest fork/exec/PTY 源码存在 | guest 层提供 |
| Git 拉取/提交/推送 | Git 库/API 候选，认证待测 | 需移植或宿主 broker | guest 包候选，待测 | guest 包候选，待测 |
| 依赖安装 | 纯解释包候选；lifecycle/spawn/native addon 逐项限定 | WASM 包/ABI 可限定下载 | guest 包仓库与 ABI 限定 | guest 包安装候选 |
| 测试/编译 | 可执行受支持解释器/库测试；native编译产物不自动可执行 | a-Shell 已证明本地 C/C++→WASM | 指令/syscall/内存约束待测 | 兼容范围和耗时待测 |
| 本地网页预览 | app 内 server 或文件宿主适配 | 网络通过宿主授予，因 ABI 而异 | socket/端口桥实测 | guest 网络/端口转发实测 |
| MCP/DIY 插件 | 解释插件/受限 API；stdio server 需适配 | capability 插件候选 | guest stdio server 候选，runtime待测 | guest server 候选 |
| 原生扩展 | 预编译、签名并随 IPA 打包；不是任意下载即用 | `.wasm` 不是任意 `.node` 替代品 | guest ELF 为模拟数据，ABI限定 | guest原生为模拟数据，ABI限定 |
| 工具隔离 | app sandbox 只隔离app与系统；内部权限须设计 | 取决于导入/预开目录与runtime实现 | guest根/资源限制需验证 | guest/共享目录边界需验证 |
| Files 工作区 | Apple目录授权/协调/bookmark | 需 fs bridge | 需 guest fs bridge | 需共享目录/同步 bridge |
| 后台/重启恢复 | 均服从 iPad宿主生命周期 | 同左 | 同左 | 同左；guest存档不是永不终止 |

本矩阵为上文证据的架构推断集合，不能作为通过测试的兼容承诺。

## 下一次真机原型的最小实验

每个候选使用普通签名、不开 debugger/JIT helper 的真实 iPad；记录型号、系统、签名途径、固定运行时与工具版本。失败留下准确错误与阶段，不能改为远端执行来使闭环表面通过。

1. **匹配上游**：读取准确 Harness 版本的 `engines`、启动方式、Native依赖与 spawn 调用。对候选执行对应版本的 JS 测试、TLS/streaming模型调用；Node 18 不作为 Node 24 的验证替代。
2. **最小闭环**：选一个小纯 JS/TS 或纯 Python仓库，从 HTTPS clone 到本地磁盘；安装明确依赖；修改文件；运行会因修改成败而改变结果的真实测试；本地提交并推送。模型可联网，但所有执行都在设备。
3. **危险依赖探针**：分别测纯包、install/postinstall脚本、原生 addon、子进程工具和 WASM 工具；确认失败是版本、ABI、签名、权限还是宿主功能缺失。为每种路线输出明确支持列表。
4. **执行接口/插件**：命令输出、stderr、非零退出、取消、管道、交互输入；一个本地 MCP server 完成 initialize/tools/list/tools/call；一种DIY解释或WASM插件完成安装/更新/禁用。测试越界路径、符号链接、未授权网络和资源限额；不能只展示终端 UI。
5. **项目目录与预览**：app内目录+Files授权目录各跑闭环；撤销权限、重启bookmark、离线文件provider、项目重命名；loopback预览刷新、端口占用、WebView请求，确认无需远端服务。
6. **中断恢复和规模**：任务进行中切后台、锁屏、取消及杀 app；iPadOS26持续任务记录排队/终止，重启不能重复写文件或重复提交。测实际IPA、磁盘、峰值内存、耗时、温度及可用工程规模，再据测量设置边界。

尚未决定：首版项目语言和依赖白名单、Node升级维护责任、插件ABI与信任模型、是否要求完整guest shell、目录读写模式、最低iPadOS和设备范围。上述选择是后续决策票；本票只清除了“有无本地路线”及关键技术边界的事实迷雾。

## 证据范围与限制

父代理提供本仓 Verify Tier 2 证据：骨架尚未引入上游/Xcode工程；generation `2026-10-02T14:57:20Z`、相关文档无记录缺口，这不代表完整证明。本人调用 graph `list_projects`，未发现上述外部仓库在图中，故外部调查直接读取固定 commit README、配置及精确源码范围；未对其全仓调用链或安全性做穷尽审计。Apple/规范网页在研究日读取，未来可改变。iSH/a-Shell/WAMR/UTM仅源码阅读，没有编译、设备运行或性能结果。上游 engines 事实由父代理转发并行票的固定源码核实结果；本票不重复上游调用链审计。现成移动运行时升级能否满足该要求仍未知。

[apple-runtime]: https://support.apple.com/en-ie/guide/security-pdf/sec15bfe098e/1/web/1
[apple-signing]: https://support.apple.com/guide/security-pdf/app-code-signing-process-sec7c917bf14/web
[apple-files]: https://developer.apple.com/documentation/uikit/providing-access-to-directories
[apple-background]: https://developer.apple.com/documentation/backgroundtasks/choosing-background-strategies-for-your-app
[apple-continued]: https://developer.apple.com/documentation/backgroundtasks/performing-long-running-tasks-on-ios-and-ipados
[apple-continued-class]: https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtask
[apple-wwdc]: https://developer.apple.com/videos/play/wwdc2025/227/
[apple-network]: https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy
[node-build]: https://github.com/nodejs-mobile/nodejs-mobile/blob/d9552e0e01ed5bdbe12a31d1ce6c0877a4f39580/tools/ios_framework_prepare.sh#L60-L73
[node-version]: https://github.com/nodejs-mobile/nodejs-mobile/blob/d9552e0e01ed5bdbe12a31d1ce6c0877a4f39580/src/node_version.h#L25-L27
[node-faq]: https://github.com/nodejs-mobile/nodejs-mobile/blob/d9552e0e01ed5bdbe12a31d1ce6c0877a4f39580/doc_mobile/FAQ.md
[v8]: https://v8.dev/blog/jitless
[ios-load]: https://github.com/holzschu/ios_system/blob/ebc045299e56edaf3509144d43a7f7348af400a7/ios_system.m#L3810-L3833
[ios-thread]: https://github.com/holzschu/ios_system/blob/ebc045299e56edaf3509144d43a7f7348af400a7/ios_system.m#L3898-L3949
[ios-miniroot]: https://github.com/holzschu/ios_system/blob/ebc045299e56edaf3509144d43a7f7348af400a7/ios_system.m#L992-L1067
[ios-readme]: https://github.com/holzschu/ios_system/blob/ebc045299e56edaf3509144d43a7f7348af400a7/README.md
[ashell]: https://github.com/holzschu/a-shell/blob/fb5c04f40140b30b9815545cc8ebf84c3e03a7e2/README.md
[wamr-ios]: https://github.com/bytecodealliance/wasm-micro-runtime/blob/f5f57c09aee623436f5fb87a90798fdd2cdf39fd/product-mini/platforms/ios/CMakeLists.txt
[wasi]: https://wasi.dev/
[ish]: https://github.com/ish-app/ish/blob/83348361fe65311f6e87ad2e1cbb0ac38d123f69/README.md
[ish-exec]: https://github.com/ish-app/ish/blob/83348361fe65311f6e87ad2e1cbb0ac38d123f69/kernel/exec.c#L37-L52
[ish-fork]: https://github.com/ish-app/ish/blob/83348361fe65311f6e87ad2e1cbb0ac38d123f69/kernel/fork.c#L143-L208
[ish-tty]: https://github.com/ish-app/ish/blob/83348361fe65311f6e87ad2e1cbb0ac38d123f69/fs/tty.c#L682-L704
[ish-pty]: https://github.com/ish-app/ish/blob/83348361fe65311f6e87ad2e1cbb0ac38d123f69/app/LinuxPTY.c
[utm]: https://github.com/utmapp/UTM/blob/7eadb056ae0f91d979059544d0ddcd2d5a40be92/README.md
[isogit]: https://github.com/isomorphic-git/isomorphic-git/blob/431453fbe9350537b404769204b92f479e427c27/README.md
[mcp]: https://modelcontextprotocol.io/specification/2025-06-18/basic/transports

[upstream-package]: https://github.com/deepseek-ai/deepseek-harness/blob/639ed015397290b3745d163aafe02ffee4aa3f84/package.json
