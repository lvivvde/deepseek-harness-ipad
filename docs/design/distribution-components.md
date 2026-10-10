# 分发组件清单（给 #14 的材料）

**状态：构建前清单。** 本文按 #17 当前源码和候选 App 的构建输入整理，列出候选 App 将随 IPA 分发的组件。候选 App 已构建 macOS 版（未签名）和 iPad 版（签名安装到用户设备，2026-10-10）。iPad `.app` 约 1.1 GB：Linux 输入约 1.0 GB，执行器约 100 MB。

- 组件集合与各文件 SHA256 以 iPad 构建收据（`build-safe.json` 的 `inputs`、`web`、`executor` 字段）为准。`executor` 记的是核对过的源闭包，即构建脚本剥离旧签名、重新签名之前的文件，所以与安装包内的二进制摘要不同。收据只留在忽略的 `build/`，公开时只记脱敏结果。
- 交给 #14 前，用收据核对本表，并补上 `system.raw` 的构建配方。
- 许可证结论属于 #14，不在 #17 范围内。本表只记来源和链接方式；已知的许可证事实只是供 #14 核对的线索，不是判断。

## 1. App 自有 Swift 代码

全部来自本仓库的 `ios/HarnessApp`（Swift Package `HarnessRuntime`），静态链接进 App 可执行文件。

| 模块 | 内容 |
| --- | --- |
| `HarnessHost` | 项目网关、Linux 启动器与就绪证明 |
| `NativeWorkspace` | 原生工作区耐久层 |
| `LinuxPlugin` | 私有接口检测、阶段与能力声明 |
| `ModelGateway` | 模型请求的增量流式网关 |
| `NativeTools` | 原生文件、搜索和图片工具，以及原生 Git 宿主 |
| `UserDataMigration` | 隔离副本的迁入与核验 |
| `HarnessCandidate` | 候选 App 的原生权威 `CandidateHost`、项目登记、VM 接口（iPad 上为进程内 `EmbeddedMachine`）与关口 1 探针 |

候选 App 外壳在 `ios/HarnessApp/CandidateApp/Sources`，包括 SwiftUI 界面、WKWebView 宿主和回环资源服务。工程由 `runtime/candidate/build.py` 生成。

仓库根目录目前没有 `LICENSE` 文件。[runtime-licensing.md](../research/runtime-licensing.md) 第 2 条的“MIT 并公开源码”仍只是计划。

## 2. 原生只读 Git（新增）

这些 JS 模块在 `NativeGitHost` 的私有 JSContext 中运行，随 App 资源分发。它们是 git v2.54.0 的移植，文件头自带版权与许可证声明：

| 文件 | 来源 | 文件头声明 |
| --- | --- | --- |
| `native-git.js` | 派生自 git | GPLv2 |
| `native-git-match.js` | git 的 `wildmatch.c`、`dir.c`、`attr.c`、`quote.c` | GPLv2 |
| `native-git-xdiff.js` | git 自带的 LibXDiff（`xdiffi.c`、`xprepare.c`、`xutils.c`） | LGPL（LibXDiff，Davide Libenzi） |
| `native-git-objects.js` | 按 git 的对象和 pack 格式自写 | 待 #14 核对 |

文件现在位于 `runtime/prototypes/plan500-ipad/web/`。候选 App 的网页根目录由 `runtime/candidate/prepare.mjs` 从这里复制，并按哈希收据核对。选型理由见 [native-read-only-git.md](native-read-only-git.md)。

## 3. 官方 Worker 及适配

| 组件 | 版本 | 说明 |
| --- | --- | --- |
| `@deepseek-ai/dsh-experimental-webworker-runtime` | `0.2.0-rc.2` | 官方 Worker 运行时，在 WKWebView 中运行 |
| `@deepseek-ai/dsh-experimental-webworker-packer` | `0.2.0-rc.2` | 构建期组装 web profile，本身不分发 |
| Zod | `4.6.5` | 改用其发布的 CJS 等价物 |
| 依赖树 | 见锁文件 | `runtime/prototypes/plan500-worker/dependencies/package-lock.json` |

适配逐项公开，实现在 `runtime/prototypes/plan500-worker/`：

1. **Zod CJS**（`pack.mjs`）：ESM 导出选择 Zod 发布的 CJS 等价物，避开模块 lowering 后循环引用的 TDZ。
2. **原生构造器比较**（`pack.mjs`）：把 `dsh-tools` 和 `dsh-cordis-host-runner` 中精确匹配 Chromium 原生函数字符串的检查，改为比较当前 realm 的原生 `Object`/`Array`。
3. **WebKit disposal**（`prepare-web.mjs`）：补齐缺失的 `Symbol.dispose` 和 `Symbol.asyncDispose`。

研究阶段的诊断和调试仪器不进入正式 App。

候选 App 另有以下适配，实现在 `runtime/candidate/`：

4. **Worker 挂接点**（`prepare.mjs`）：在官方 Worker 的副本中加三处挂接，每处锚点必须恰好出现一次。分别用于恢复 Worker home、装入候选桥接，以及让 `node:fs/promises` 先走候选路由。已安装的官方包不修改。
5. **Worker 补充**（`prepare.mjs`）：
   - 补上 Worker 没有的 `fs/promises.copyFile`，供快照插件复制 VFS 字节。
   - 在 Worker 开头过滤候选消息帧，避免官方隧道因未知帧失败。
   - 补齐 WebKit 缺少的 `Symbol.dispose` 和 `Symbol.asyncDispose`（同第 3 条）。
6. **官方页面**（`prepare.mjs`）：在官方 `index.html` 中加 importmap 和 `connector.js`，让传输层先于入口建立。
7. **候选桥接**（`candidate-bridge.js`、`connector.js`）：
   - 项目内的文件、搜索、只读 Git、图片编解码和模型请求走原生网关。
   - 项目内的 shell 命令走 Linux。官方 bash 工具在项目内跳过 Worker 的虚拟沙箱启动器，因为 VM 本身就是隔离；结果里的 `sandbox.denied` 固定为 `false`。
   - 命令在 guest 中以 `/bin/sh -c` 运行，不是 bash。
   - 交互式终端返回 `TERMINAL_UNSUPPORTED`。

网页收据 `candidate-receipt.json` 的 `adaptations` 字段逐项列出上述改动。

## 4. Linux 执行器（插件）

执行器是 UTM SE 构建的 QEMU 10.0.12 iOS framework 闭包，共 22 个 framework，随 IPA 的 `Frameworks/` 分发，由 App 进程载入。候选构建按 `ios/LinuxPrototype/.runtime/frameworks.json` 核对集合和 SHA256，嵌入时去掉原签名和调试符号后用 App 的身份重签；QEMU 数据目录（`-L`）为空的 `qemu/`。逐个 framework 的上游、版本和链接图见 [runtime-licensing.md](../research/runtime-licensing.md) 第 1 节。

[runtime-licensing.md](../research/runtime-licensing.md) 中的风险 R1（OpenSSL 与 Vulkan-Loader 跟 GPLv2 的 QEMU 处于同一进程）仍未处理，由 #14 判断。

## 5. Linux guest 输入

| 文件 | 内容 | 来源 |
| --- | --- | --- |
| `Image` | 内核 Alpine `6.18.52-0-virt` | Alpine 3.23 netboot，见 [miniguest-build-sources.md](../prototypes/miniguest-build-sources.md) |
| `initramfs.gz` | 写租约探针的 initramfs，含从锁定 modloop 补入的 9P 等模块 | `runtime/prototypes/plan500-lease/run.py prepare` 与 `init.sh` |
| `system.raw` | 只读系统盘，含 Node `24.21.0` 和 Git `2.47.3` | 沿用既有 Linux 原型；构建配方仍待补入本表（交给 #14 前） |
| guest agent | 租约、取消和撤销协议 | `runtime/prototypes/plan500-lease/agent.cjs` |

各输入的 SHA256 记在 [plan500-darwin.md](../research/plan500-darwin.md) 的输入表里。

研究 App 和候选 App 构建时都会逐个核对这些文件的 SHA256，见 `runtime/prototypes/plan500-ipad/build.py` 和 `runtime/candidate/build.py`。候选构建还要求 initramfs 中的 guest agent 与已提交的 `agent.cjs`、`init.sh` 一致。用户盘不随 IPA 分发，也不会被覆盖。

macOS 候选 App 使用本机 Homebrew 的 `qemu-system-aarch64`，不随包分发，因此不属于本清单。

## 6. 可重建的构建输入

- **Swift**：`ios/HarnessApp/Package.swift`。没有外部 Swift 包依赖。
- **Worker**：上面的锁文件、`pack.mjs` 和 `prepare-web.mjs`；候选 App 另用 `runtime/candidate/prepare.mjs`。
- **执行器**：[linux-executor-build-sources.md](../prototypes/linux-executor-build-sources.md)。**guest**：上表各行的来源。UTM 官方 CI artifact 会过期，二进制和对应源码需要自行归档（[runtime-licensing.md](../research/runtime-licensing.md)）。
