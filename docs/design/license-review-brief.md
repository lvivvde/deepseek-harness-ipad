# 许可证审查简报

> 对应 [#14](https://github.com/lvivvde/deepseek-harness-ipad/issues/14)。**这是工程材料，不是法律意见。** 本文把需要有资格的人判断的问题整理出来，并附上判断时要用的技术事实。结论由审查人给出，见下面的“审查结果”。日期：2026-10-21，基于 iPad 候选构建 r28。

## 审查结果（2026-10-21）

用户请律师朋友看过本简报，并转述结论：

- 六个问题都没有问题。
- 建议**不发布 IPA**，只公开源码。

据此：

- 本仓库已经公开，且没有入库任何二进制（IPA、framework、系统盘、initramfs 都在忽略的 `build/` 里），所以公开源码这一步已经做到；根目录补上 MIT `LICENSE`（问题 6）。
- 不发布 IPA，也就不做“判断之后的工程工作”里为分发 IPA 准备的各项：对应源码包和收集脚本、App 内开源许可页、第三方许可证清单、自建 QEMU。以后如果改为发布 IPA，需要重新审查。
- 想自己用的人从源码构建并自签。构建要用 UTM SE 的 iOS sysroot（CI artifact `10845528675`），需要自己取得；该 artifact 在 2026-12-24 之后从 GitHub 消失，届时只能自己按 UTM 的固定提交构建（见[执行器构建来源](../prototypes/linux-executor-build-sources.md)）。

下文保留审查时的原始材料。

## 先读什么

1. [实际分发组件清单](distribution-components.md)：IPA 里到底有什么，各自的版本、许可证、改动和链接方式。
2. [运行时许可证核查](../research/runtime-licensing.md)：早期研究，提出了策略 A、MIT 外壳和风险 R1–R5。下文的问题 1–3 来自这里，4–6 是 r28 清单核对时新发现的。

## 分发方式（技术事实）

- 只做一种分发：在 GitHub 上公开 IPA，用户自己签名安装到自己的 iPad。没有 App Store，不收费。目前**还没有发布过**任何 IPA。
- 一个 IPA 约 1.1 GB，里面同时有：
  - Swift 写的 App 外壳（本项目自有代码）；
  - 通过 `dlopen` 载入**同一进程**的 QEMU 及 21 个依赖 framework（UTM SE 的预编译产物）；
  - Linux 内核、initramfs 和 Debian 13 系统盘（在 QEMU 虚拟机里运行）；
  - 在 WKWebView 里运行的官方 DeepSeek Harness Worker、前端及 318 个 npm 包，外加本项目的 22 项适配；
  - 在 App 的 JavaScriptCore 里运行的原生只读 Git（git 的 JavaScript 移植）。
- 插件由用户在 App 里自己从 npm 源下载，不在 IPA 里。

## 需要判断的问题

### 1. OpenSSL 1.1.1 和 Vulkan-Loader 与 GPLv2 的 QEMU 处于同一进程（R1）

- 事实：UTM SE 的 QEMU 为 SPICE（TLS）和 virgl（GPU）链接了 OpenSSL 1.1.1（OpenSSL/SSLeay 许可证，有广告条款）和 Vulkan-Loader（Apache-2.0）。本项目两项功能都不用，但这些库在 IPA 里，并且随 QEMU 一起载入。
- 问题：这样分发是否与 QEMU 的 GPLv2 冲突？
- 工程上的退路：自己构建一个不带 SPICE、不带 virgl 的 QEMU，把这两个库去掉。工作量较大，等判断结果再决定做不做。

### 2. LGPLv3 / GPLv3 的“安装信息”（R3）

- 事实：
  - Debian 系统盘里有 GPLv3 的程序（bash、coreutils、tar、gzip 等）。
  - npm 依赖里的 `@img/sharp-libvips-*` 含 LGPLv3 组件。
  - iPad 算 GPLv3 §6 所说的 User Product。用户本来就是自己签名安装，对应源码包里会有重建系统盘、重打 IPA 的完整脚本。
  - 系统盘和 initramfs 不能逐位重建，只能归档成品和构建收据。
- 问题：用户能自己替换组件、重建并重新签名，这是否已经满足“安装信息”的要求？构建不能逐位复现，是否有影响？

### 3. 策略 A 与 MIT 外壳

- 计划：每个 IPA 发布都在同一个 GitHub Release 里附带完整的对应源码包，另加 App 内“开源许可”页；Swift 外壳用 MIT 许可证并公开源码。
- 问题：
  - “同一 Release 里提供源码”是否足以满足 GPLv2 §3 和 LGPL-2.1 §6(d)？
  - MIT 外壳通过 `dlopen` 把 QEMU 载入同一进程，这样是否可行？

### 4. App 里的 GPLv2 / LGPL JavaScript（新增）

- 事实：原生只读 Git 由四个 JS 文件组成，作为 App 资源分发，在外壳管理的私有 JavaScriptCore 上下文里运行，只通过一个消息接口与 Swift 交换数据：
  - `native-git.js`、`native-git-match.js`：文件头声明派生自 git，GPLv2。
  - `native-git-xdiff.js`：LibXDiff 的移植，文件头为 LGPL-2.1-or-later。
  - `native-git-objects.js`：按 git 的对象和 pack 格式自己写的，文件头没有许可证声明。
- 问题：
  - 这些文件和 MIT 外壳是否构成一个组合作品？如果是，问题 3 的做法是否也覆盖它们？
  - `native-git-objects.js` 应该标什么许可证？只是按 git 的格式读写，是否就使它成为 git 的派生作品？

### 5. 官方 Harness 包的改动（新增）

- 事实：本项目在构建时改写官方 `@deepseek-ai/*` 包的副本（22 项适配，见清单第 3 节）。改动后的文件随 IPA 分发。这些包的 `package.json` 大多声明 MIT。
- 问题：除了保留原许可证文本，是否还要满足其他条件，例如标明改动、说明哪些文件改过？`@deepseek-ai/*` 包里如果另有使用条款，是否限制这种再分发？

### 6. 仓库没有 LICENSE 文件（新增）

- 事实：仓库根目录现在没有 `LICENSE`，所以“外壳用 MIT”还没有生效。仓库里的文件有几类：
  - 自有的 Swift、Python 和脚本；
  - 上面的 GPLv2 / LGPL JS；
  - 从上游复制或改写的片段。
- 问题：根目录放 MIT `LICENSE`，再在各个例外文件的文件头写明它们自己的许可证，这样是否可行？

## 判断之后的工程工作

下面这些等判断有了结果再做，现在都不做：

- 如果 R1 不能接受，就自建 QEMU。
- 写一个收集对应源码的脚本：按清单下载上游 tarball、Debian 源码包、补丁和构建脚本，放到被忽略的 `build/`。
- App 内“开源许可”页和第三方许可证清单。
- 添加根目录 `LICENSE`。
- 在 R2 期限之前把 UTM 的 artifact 归档好。
