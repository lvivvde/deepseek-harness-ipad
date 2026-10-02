# UTM SE 嵌入自有 IPA：完整 Linux 执行层候选

研究日期：2026-10-02。对应议题：[研究：UTM SE 能否嵌入自有 IPA 并承载上游 Harness？](https://github.com/lvivvde/deepseek-harness-ipad/issues/10)。范围：普通未越狱 iPad，使用者重签 IPA，无必须前置的 JIT helper，无远端工具执行；允许联网模型。只读文档与少量源码，没有构建、镜像下载、模拟器或真机测试。

## 结论与决策边界

**有足够一手依据把 UTM SE/QEMU 完整系统模拟定为优先验证路线，但没有证据把它定为已可生产的 Harness 运行环境。** 官方将 SE 定义为无需越狱和 JIT 变通的解释执行版本；这直接符合设备与签名约束。性能明显弱于 JIT，芯片强、物理内存大不能替代实测。[UTM SE 官方说明](https://github.com/utmapp/UTM/blob/7eadb056ae0f91d979059544d0ddcd2d5a40be92/README.md#utm-se)、[iOS 安装矩阵](https://docs.getutm.app/installation/ios/)

**首个 guest 候选可明确选择 aarch64 Linux，x86_64 保留为兼容备选；这不是性能比较结论。** 固定构建脚本包含 `aarch64-softmmu` 与 `x86_64-softmmu`，参数生成也有 aarch64 CPU/virt machine 支持；因此不是把 i386 用户态模拟误作现代 ARM64 Linux。aarch64 与 iPad 同架构并不会在 SE 中自动获得硬件虚拟化。选择 aarch64 的理由是有可核查的实现入口及与现代 Linux ARM64 工具生态的候选匹配，速度优劣尚未测试。[固定构建参数](https://github.com/utmapp/UTM/blob/7eadb056ae0f91d979059544d0ddcd2d5a40be92/scripts/build_dependencies.sh#L1047-L1061)、[aarch64 参数生成](https://github.com/utmapp/UTM/blob/7eadb056ae0f91d979059544d0ddcd2d5a40be92/Configuration/UTMQemuConfiguration%2BArguments.swift#L413-L550)、[官方架构说明](https://docs.getutm.app/settings-qemu/system/)

本路线的工程推断是：Linux 内核承担 shell、fork/exec、管道、PTY、包管理和文件权限，Harness 留在 guest 运行；iPad app 提供 VM 与界面桥。这保留了上游使用 Linux 系统接口的机会，**没有证明固定 Harness 所需 Node 22/24、koffi、sharp、PTY 或完整插件可用**。guest 中 Node 的 JIT 生成的是 guest 指令，由模拟器执行，不能把它等同于 app 在 iPadOS 申请原生 JIT；具体 CPU、原子操作、线程、V8 和负载兼容仍需验证。

## 固定证据与可复用层

UTM 固定版本为 `7eadb056ae0f91d979059544d0ddcd2d5a40be92`，不称其为最新稳定版。该提交的 `patches/sources` 指向 UTM 修改的 QEMU `v10.0.12-utm`。iOS `*-tci`、arm64 host 构建启用 `--enable-tcg-threaded-interpreter` 和 `--enable-shared-lib`；非 arm64 host 分支使用传统 `--enable-tcg-interpreter`。所以本候选是 UTM 修改后的依赖组合，不能直接用未经适配的桌面 QEMU 替代。[依赖来源](https://github.com/utmapp/UTM/blob/7eadb056ae0f91d979059544d0ddcd2d5a40be92/patches/sources)、[构建脚本](https://github.com/utmapp/UTM/blob/7eadb056ae0f91d979059544d0ddcd2d5a40be92/scripts/build_dependencies.sh#L1023-L1061)

| 层 | 固定源码的正面证据 | 对自有应用的含义 |
|---|---|---|
| Swift 配置与 VM 管理 | `UTMQemuVirtualMachine` 管理配置、状态、QEMU launcher、QMP monitor、guest agent | 可研究提取/裁剪为 Swift 原生外壳的执行管理；不是公开稳定 SDK |
| Objective-C 桥 | `UTMQemuSystem` 动态解析 `qemu_init/main_loop/cleanup`；`UTMProcess` iOS 默认加载 app Frameworks 中的库并创建 pthread | VM 在 app 内线程运行；guest 子进程与 iPadOS 原生子进程是两层概念 |
| 修改后的 QEMU/C 依赖 | TCTI 解释器、softmmu target、slirp、SPICE 等构建组合 | 需随 app 构建、封装和签名所需 framework，不靠下载后执行任意 iOS native 插件 |
| guest Linux 与 Harness | 上述完整系统模拟提供承载入口 | Linux 发行版、Node、Harness 安装与依赖版本仍是原型对象 |

来源：[Swift 管理层](https://github.com/utmapp/UTM/blob/7eadb056ae0f91d979059544d0ddcd2d5a40be92/Services/UTMQemuVirtualMachine.swift#L27-L151)、[QEMU 入口桥](https://github.com/utmapp/UTM/blob/7eadb056ae0f91d979059544d0ddcd2d5a40be92/Services/UTMQemuSystem.m#L246-L287)、[iOS 内线程启动](https://github.com/utmapp/UTM/blob/7eadb056ae0f91d979059544d0ddcd2d5a40be92/Services/UTMProcess.m#L157-L245)。需要自己的模块边界、错误恢复、更新与构建维护；本研究没有确认可独立 drop-in 的现成库。

## Web、终端、工作区与生命周期

**Web 桥候选：** guest 中 Harness WebHost 监听可由虚拟网卡到达的地址；QEMU user-mode VLAN `hostfwd` 显式绑定 iPad host `127.0.0.1:端口`；Swift 外壳中 WKWebView 加载该 loopback URL。官方有 TCP/UDP 端口映射，固定源码在 iOS 生成 `user` 网络后端与 `hostfwd`。这是端口桥存在的证据；**WKWebView、WebSocket/RPC、登录跳转、cookie、ATS 配置与官方 UI 尚未跑通**。guest `127.0.0.1` 与 iPad `127.0.0.1` 不是同一网络空间，不能只把前者 URL 交给 WebView；原型需检查 WebHost bind 地址，不能为了省事对外网卡公开 host 端口。[官方端口配置](https://docs.getutm.app/settings-qemu/devices/network/port-forwarding/)、[固定 networkArguments](https://github.com/utmapp/UTM/blob/7eadb056ae0f91d979059544d0ddcd2d5a40be92/Configuration/UTMQemuConfiguration%2BArguments.swift#L1090-L1168)

**控制与终端：** QMP 是 VM 管理接口，SPICE 负责端口/显示等通信；built-in terminal 使用 SPICE serial channel，也可用 TCP serial 仅监听 host loopback。guest serial console 和 Harness 自己的 PTY 工具不应混同：前者足以做引导/救援，后者必须在 Linux guest 单独验收。首次候选用 headless Linux 加 serial console，官方 Web UI 作为工作界面，避免引入 guest 桌面。[serial 接口](https://docs.getutm.app/settings-qemu/devices/serial/)、[固定 serial/QMP 参数](https://github.com/utmapp/UTM/blob/7eadb056ae0f91d979059544d0ddcd2d5a40be92/Configuration/UTMQemuConfiguration%2BArguments.swift#L219-L399)

**工作区：** 固定代码支持虚拟磁盘、VirtIO block、9p/VirtFS `share` 和 SPICE WebDAV；WebDAV 会持有 security-scoped directory access。建议首次验证把 Git checkout、`node_modules`、Linux 权限/符号链接放 guest 磁盘，Files 先作为导入/导出通道；这是一项待人类确认的工程建议，并非已经锁定的工作区产品方案。共享目录需验证 symlink、xattr、文件监视、原子 rename、大小写、离线文件提供者及权限恢复；存在共享接口不能证明 Files provider 可作为可靠 Linux 工程根目录。[共享后端](https://docs.getutm.app/settings-qemu/sharing/)、[磁盘与 9p 参数](https://github.com/utmapp/UTM/blob/7eadb056ae0f91d979059544d0ddcd2d5a40be92/Configuration/UTMQemuConfiguration%2BArguments.swift#L751-L969)、[共享路径授权](https://github.com/utmapp/UTM/blob/7eadb056ae0f91d979059544d0ddcd2d5a40be92/Services/UTMSpiceIO.m#L311-L330)

**生命周期与内存：** Swift 层有 QMP pause/saveSnapshot/powerDown，但 UTM 文档明确部分设备不能挂起，不能直接承诺切后台保持编译或无损恢复。iPadOS 普通后台执行时间受限；应验证前台运行、主动暂停/保存、超时与被系统终止后的磁盘恢复。固定 iOS entitlements 包含 increased-memory-limit 与 extended-virtual-addressing，它们是申请项，不是所有重签用户都能保留或得到无限内存的保证；要测试目标签名方式的实际 entitlement 和 jetsam 边界。[挂起限制](https://docs.getutm.app/basics/controls/)、[snapshot 实现](https://github.com/utmapp/UTM/blob/7eadb056ae0f91d979059544d0ddcd2d5a40be92/Services/UTMQemuVirtualMachine.swift#L591-L630)、[Apple 后台执行](https://developer.apple.com/documentation/uikit/extending-your-app-s-background-execution-time)、[固定 entitlement 文件](https://github.com/utmapp/UTM/blob/7eadb056ae0f91d979059544d0ddcd2d5a40be92/Platform/iOS/iOS.entitlements)

## 修改和分发的许可证条件

UTM 自身声明 Apache-2.0，同时明确使用 (L)GPL 组件、静态链接的 gstreamer plugins 和取自 QEMU 的代码。Apache 授权允许修改和分发源码/二进制，但要求随附许可、保留适用通知、标注修改及处理 NOTICE；不授予上游品牌使用许可。这支持开发独立品牌的修改应用，不等于整个 IPA 的每个组件都只有 Apache 条件。[固定 UTM 许可声明](https://github.com/utmapp/UTM/blob/7eadb056ae0f91d979059544d0ddcd2d5a40be92/README.md#license)、[Apache 条款 4/6](https://www.apache.org/licenses/LICENSE-2.0)

QEMU 官方声明 GPLv2，个别文件另有许可。复用和修改后再分发其二进制必须按适用 GPL 提供对应源码途径；对应源码包括修改和必要构建/安装脚本，单贴 upstream 仓库链接不等于提供实际发布版本源码。该规则针对相关 GPL covered work；**本研究没有判定自有 Swift 外壳是否属于特定 GPL derivative/combined work，也不替用户选择全 app 的 GPL 版本**。动态链接不是自动豁免；需按实际边界、取用文件及版本做判断。[QEMU 官方许可](https://www.qemu.org/docs/master/about/license.html)、[固定 UTM 随附 GPLv2 条文（第 2/3 节）](https://github.com/utmapp/UTM/blob/7eadb056ae0f91d979059544d0ddcd2d5a40be92/Platform/iOS/Settings.bundle/License.plist#L619-L724)

LGPL 组件的二进制分发同样需要许可、适用通知、修改库源码与满足替换/重新链接条件；静态链接时尤其要保存足够的对象文件/源码和构建方式以满足适用版本要求，不能仅提供库源码就宣布完结。iOS framework 签名、用户替换与重签路径需要纳入实际分发审查。[UTM 随附 LGPL2.1 第 4/6 节](https://github.com/utmapp/UTM/blob/7eadb056ae0f91d979059544d0ddcd2d5a40be92/Platform/iOS/Settings.bundle/License.plist#L249-L370)

**重要证据限制：** UTM `License.plist` 的组件列举引用 QEMU4.2、旧 gstreamer 等，和当前 `patches/sources` 不一致，不能当完整准确 SBOM。例如 GStreamer 官方称核心为 LGPL，而 plist 有较宽泛 GPL 分组。因此这里只用其中原文理解许可条款；实际发布必须从保留组件的固定源码 LICENSE/COPYING、选用 plugins 和 link map 重建清单（QEMU、GLib、SPICE、libslirp、SwiftTerm 等），记录 patches、编译参数与源码包。不要为了简化先把所有组件标同一许可。[旧清单](https://github.com/utmapp/UTM/blob/7eadb056ae0f91d979059544d0ddcd2d5a40be92/Platform/iOS/Settings.bundle/License.plist)、[实际依赖版本](https://github.com/utmapp/UTM/blob/7eadb056ae0f91d979059544d0ddcd2d5a40be92/patches/sources)、[GStreamer 官方许可说明](https://gstreamer.freedesktop.org/documentation/frequently-asked-questions/licensing.html)

用户重签解决安装身份问题，不改变再分发人对实际 IPA/组件的源码、通知或重新链接义务。仅改名重签上游发行包也不能证明自有架构已经实现。Linux rootfs 和其中软件如果一并发布，也需分别清点。上述是文档事实和后续核查对象，不是法律结论。

## 最小验证顺序与阻断条件

1. **许可/构建入口：** 固定 UTM/QEMU/patches，裁剪无关图形、音频、USB与 target；生成实际组件清单、link map、来源与对应源码/重建计划。若选定分发方式无法履行组件义务，暂停发布方案，不能以重签绕过。
2. **最小 IPA 真机：** 原生外壳加载已签名 SE framework，无 JIT/helper/hypervisor，启动 headless aarch64 Linux；serial 中执行 shell、fork/exec、文件写入与重启。若必须特殊权限才能运行，违反约束，停止此候选。
3. **运行时：** 固定现代 Linux libc/Node 22.19 或所选 24 版本；核查 Node、child_process、worker threads、PTY、koffi、sharp/node addon system及信号。原生 addons 预编译可用性和从源码编译耗时分别记录。若固定上游依赖不能运行，不得宣称“上游兼容”。
4. **Web 桥：** guest HTTP → hostfwd → app WKWebView，再验 WebSocket/RPC、登录、模型请求、触控 UI 和端口只在 loopback 暴露。接口存在不代表这一步已通过。
5. **完整一项目本地闭环：** Git 拉取→安装支持的依赖→Harness 修改→shell 测试→提交；量测冷启动、token交互以外的命令延迟、RSS/磁盘增长、功耗/温度与连贯工作体验。未设具体秒数/包体/内存承诺；先由产品决策给可接受阈值，再决定能否成为首版。
6. **生命周期与工作区：** 前后台、主动挂起、异常终止、重签更新、磁盘恢复、导入/导出和权限失效。Files 活目录及更多插件在基本闭环后验证，不能默认 POSIX 完全等价。

性能越不过事先约定门槛、常见内存压力反复杀进程、最低设备无法稳定跑闭环，是重新选型或缩小兼容范围的触发条件。无论 guest 多完整，不能从本研究推出 Docker、任意桌面工程、无限插件、持续后台服务或任意设备硬件访问已经支持。

## 证据覆盖说明

父代理提供项目图上下文（Verify Tier2），根项目为文档骨架。本研究首次 `list_projects` 全 8 项，无 UTM 图，随后只取 14 个固定源码/文档文件的故意有限快照并索引为 `wayfinder-utm-se-exact`，generation `2026-10-02T15:29:42Z`；不是完整 UTM 仓库。一次 graph search 返回 31 项、`has_more=false`，随后对全部引用路径核查 coverage。Arguments.swift 的 23–1066、1293、1296、1319 与 VM.swift 的 27–164、196、313、336–350、371、374–376、544–550、660、710–712、756 有 parse partial，已对实质相关范围直接读源码；scripts、LICENSE excluded；补取的 Process/source manifest/App 文件为 not_tracked，直接准确源码核查。所有引用是正面候选证据，没有作全仓完整性或“无其他依赖”声明。未克隆全仓，未验证构建产物、运行时、签名、WebView或设备性能。
