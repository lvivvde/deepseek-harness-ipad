# 分发组件清单（给 #14 的材料）

**状态：已按 iPad 候选构建收据核对（2026-10-11）。** 本文列出候选 App 随 IPA 分发的组件。核对用的是当前装在用户 iPad 上的签名构建 r9（与 main `021959c` 的源码一致）。iPad `.app` 约 1.1 GB：Linux 输入约 1.0 GB，执行器约 100 MB。

- 组件集合与各文件 SHA256 以 iPad 构建收据（`build-safe.json` 的 `inputs`、`web`、`executor` 字段）为准。`executor` 记的是核对过的源闭包，即构建脚本剥离旧签名、重新签名之前的文件，所以与安装包内的二进制摘要不同。收据只留在忽略的 `build/`，公开时只记脱敏结果。
- r9 收据与本表一致：22 个 framework（第 4 节），3 个 guest 输入（第 5 节），网页根目录 139 个文件，其中有 4 个原生 Git 脚本（第 2 节）、318 个 npm 包（第 3 节），以及 12 项适配。
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
| 依赖树 | 见两个锁文件 | 见下文 |

候选网页根目录的内容来自两棵依赖树：

- `runtime/harness-package-lock.json`（SHA256 `1a60fdd7…`，与收据 `harnessLockSha256` 一致）是固定的官方 `@deepseek-ai/dsh@0.2.0-rc.2` 树。Worker 的 VFS 镜像 `vfs-image.tar.gz` 和官方前端 `dsh-web-frontend/dist` 都来自这棵树。镜像中有 318 个 npm 包，其中 250 个是 `@deepseek-ai/*`。各包 `package.json` 里的 `license` 字段：MIT 300 个；Apache-2.0 10 个（`@opentelemetry/*`）；ISC 3 个（`picocolors`、`semver`、`yaml`）；BSD-3-Clause 3 个（`@deepseek-ai/node-addon-system`、`diff`、`fast-uri`）；BSD-2-Clause 1 个（`@mixmark-io/domino`）；Python-2.0 1 个（`argparse`）。这些只是包自己声明的字段，没有逐个核对 LICENSE 文件。前端 `dist` 是打包好的产物，里面打进的第三方代码和字体（如 KaTeX）不按包列出。
- `runtime/prototypes/plan500-worker/dependencies/package-lock.json` 提供 `dsh-experimental-webworker-runtime`（`worker.js`、`client.js`）、`dsh-client-web`（`apply-injections.js`）和构建期的打包器。这三个包都是 `0.2.0-rc.2`，声明 MIT。

同一棵官方树的 Node 版本还装在 `system.raw` 的 `/opt/harness` 中，见第 5 节。

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
6. **VFS 镜像入口**（`prepare.mjs`）：官方终端控制器经 `createLazyRequire` 加载 `@xterm/headless`、`@xterm/addon-serialize`，打包器的清扫看不到。所以打包入口在打包器自己的种子之外加上这两个包，镜像随之带上 `@xterm/headless` 6.0.0 和 `@xterm/addon-serialize` 0.14.0。打包器的种子未导出，构建时核对其副本与 `prepare.mjs` 里的一致，并核对两个包的主文件在镜像内。
7. **官方页面**（`prepare.mjs`）：在官方 `index.html` 中加 importmap 和 `connector.js`，让传输层先于入口建立。
8. **候选桥接**（`candidate-bridge.js`、`session-recovery.js`、`connector.js`）：
   - 项目内的文件、搜索、只读 Git、图片编解码和模型请求走原生网关。
   - 项目内的 shell 命令走 Linux。官方 bash 工具在项目内跳过 Worker 的虚拟沙箱启动器，因为 VM 本身就是隔离；结果里的 `sandbox.denied` 固定为 `false`。
   - 命令在 guest 中以 `/bin/sh -c` 运行；`system.raw` 里的 `/bin/sh` 指向 bash，所以实际是 bash 的 POSIX 模式。
   - 项目内的交互式终端在 guest 的 pty 上运行 `/bin/bash -i`，输出经长轮询读回，交给官方终端控制器。只接受 `/bin/bash -i`。

   - 会话恢复 module 等官方 flush 后采集 home，并等待原生耐久确认；新增保存帧用于手动重试和前后台保存尝试。恢复受阻时不启动官方树。

网页收据 `candidate-receipt.json` 的 `adaptations` 字段逐项列出上述改动。

## 4. Linux 执行器（插件）

执行器是 UTM SE 构建的 QEMU 10.0.12 iOS framework 闭包，共 22 个 framework，随 IPA 的 `Frameworks/` 分发，由 App 进程载入。候选构建按 `ios/LinuxPrototype/.runtime/frameworks.json` 核对集合和 SHA256，嵌入时去掉原签名和调试符号后用 App 的身份重签；QEMU 数据目录（`-L`）为空的 `qemu/`。逐个 framework 的上游、版本和链接图见 [runtime-licensing.md](../research/runtime-licensing.md) 第 1 节。

[runtime-licensing.md](../research/runtime-licensing.md) 中的风险 R1（OpenSSL 与 Vulkan-Loader 跟 GPLv2 的 QEMU 处于同一进程）仍未处理，由 #14 判断。

## 5. Linux guest 输入

| 文件 | 内容 | 来源 |
| --- | --- | --- |
| `Image` | 内核 Alpine `6.18.52-0-virt` | Alpine 3.23 netboot，见 [miniguest-build-sources.md](../prototypes/miniguest-build-sources.md) |
| `initramfs.gz` | 写租约 initramfs：BusyBox、补入的 9P 等模块、租约 `/init` 和 guest agent | 见下文“initramfs” |
| `system.raw` | 1 GiB 只读 ext4 系统盘，含 Debian 13 用户态、Node `24.21.0` 和 Git `2.47.3` | 见下文“system.raw” |
| guest agent | 租约、取消和撤销协议 | `runtime/prototypes/plan500-lease/agent.cjs`，打进 initramfs |

各输入的 SHA256 记在 [plan500-darwin.md](../research/plan500-darwin.md) 的输入表里。

研究 App 和候选 App 构建时都会逐个核对这些文件的 SHA256，见 `runtime/prototypes/plan500-ipad/build.py` 和 `runtime/candidate/build.py`。候选构建还要求 initramfs 中的 guest agent 与已提交的 `agent.cjs`、`init.sh` 一致。用户盘不随 IPA 分发，也不会被覆盖。

### system.raw

`system.raw` 由 `runtime/build-runtime.py` 生成。该脚本自 `3235e01` 起未改动，与正式 IPA 用的是同一份系统盘。

- **构建环境**：2026-10-04，隔离的 Lima Ubuntu arm64 虚拟机，工作目录在区分大小写的 ext4 上。
- **参数**：`--lock runtime/inputs.lock.json --harness <目录> --system-mib 1024 --user-mib 8 --memory-mib 2048`，另给出 `--inputs`、`--output`、`--mke2fs`、`--unsquashfs`。`--harness` 是按 `runtime/harness-package-lock.json` 执行 `npm ci` 得到的目录。
- **收据**：脚本写出 `build-receipt.json`。其中 `inputManifestSHA256`（`21ec2367…`）与已提交的 `runtime/inputs.lock.json` 一致，`harnessLockSHA256`（`1a60fdd7…`）与 `runtime/harness-package-lock.json` 一致。

所有下载输入都由 `runtime/inputs.lock.json` 锁定 URL 和 SHA256：

- **Debian 13 arm64**：135 个 `.deb`，对应 93 个源码包，取自 snapshot.debian.org 的 `20261003T000000Z` 快照。脚本只解出 `data.tar`，不运行维护者脚本，去掉 `/usr/share/locale`，保留 `/usr/share/doc/*/copyright`。`/usr/bin/sh` 链接到 bash。
- **Node**：官方 `node-v24.21.0-linux-arm64`，装在 `/opt/node`。
- **内核模块**：Alpine `6.18.52-0-virt` 的 modloop，与 `Image` 同一版本。
- **`/opt/harness`**（约 537 MB）：上面那棵官方 `@deepseek-ai/dsh@0.2.0-rc.2` npm 树，加上 `runtime/guest` 的脚本和示例。脚本改了其中两个官方客户端文件（`patch_client_bridges`）。候选 App 的 shell 只用 guest 里的 Debian 用户态和 Node，不运行 `/opt/harness`，但它在系统盘里，所以随 IPA 分发。

`mke2fs` 没有固定 UUID、hash seed 和时间戳，所以重跑同样的配方得不到逐位相同的镜像。分发用的镜像必须连同 `build-receipt.json` 原样归档；私有副本目前在 Lima 虚拟机和忽略的 `build/` 中。

### initramfs

候选用的 `initramfs.gz` 由 `runtime/prototypes/plan500-darwin/run.py prepare` 在 Linux 上生成，构建逻辑在 `plan500-sharing/run.py` 的 `build()`：

1. 核对 `build-runtime.py` 产出的 `Image`、`initramfs.gz`、`system.raw` 与其收据一致，核对 modloop 与锁文件一致。
2. 解开正式 initramfs（BusyBox），从 modloop 补入 `virtio_blk`、`virtio_net`、`ext4`、`overlay`、`9p`、`9pnet_virtio` 及其依赖，共 13 个模块。
3. 放入 `plan500-lease/init.sh` 作为 `/init`、`agent.cjs`，以及一个每次构建随机生成的 token。
4. 用 `cpio newc` 打包，gzip 的 mtime 固定为 0。

因为 token 每次随机，initramfs 也不能逐位重现，需要与 `inputs.json` 一起归档。`/init` 以只读方式挂载 `system.raw`，叠一层 overlay，挂上 9P 工作区，再 chroot 进去运行 guest agent。

macOS 候选 App 使用本机 Homebrew 的 `qemu-system-aarch64`，不随包分发，因此不属于本清单。

## 6. 可重建的构建输入

- **Swift**：`ios/HarnessApp/Package.swift`。没有外部 Swift 包依赖。
- **Worker**：上面的锁文件、`pack.mjs` 和 `prepare-web.mjs`；候选 App 另用 `runtime/candidate/prepare.mjs`。
- **执行器**：[linux-executor-build-sources.md](../prototypes/linux-executor-build-sources.md)。UTM 官方 CI artifact 会过期，二进制和对应源码需要自行归档（[runtime-licensing.md](../research/runtime-licensing.md)）。
- **guest**：`runtime/inputs.lock.json`、`runtime/harness-package-lock.json`、`runtime/build-runtime.py`，以及 `plan500-sharing`、`plan500-lease`、`plan500-darwin` 下的脚本。`system.raw` 和 initramfs 不能逐位重建，需归档成品和收据（第 5 节）。随 GPL 组件提供源码时，Debian 源码包按同一快照取得。
