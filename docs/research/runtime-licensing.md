# 运行时许可证核查：IPA 内置执行器、Linux 系统盘与 Harness 依赖

> 归档说明：本报告原在未合并分支 `research/runtime-licensing`（提交 `546b277`），2026-10-06 原样归档进 main，分支随后删除。属早期历史研究，当前架构以 [ADR 0003](../adr/0003-native-worker-with-project-linux.md) 为准。

> 归属：[决策：Linux 镜像、运行时与更新如何交付？](https://github.com/lvivvde/deepseek-harness-ipad/issues/12) 的研究资产（Q8）。
> 日期：2026-10-03。
> **这是工程核查，不是法律意见。** 发布闸门中标为“需法律判断”的条目，应在首个公开 IPA 发布前由具备资格的人确认。

## 结论

1. 采用**策略 A**：每个 IPA 发布都在同一个 GitHub Release 里附带完整的对应源码包，另加 App 内“开源许可”页。不使用书面要约（written offer），仅链接上游也不够。
   - 依据：GPLv2 §3 末段规定，从指定地点提供可执行文件时，“从同一地点提供源码的同等访问”即视为分发源码。
   - LGPL-2.1 §6(d) 有同样的结构。
2. Swift 外壳使用 **MIT** 许可证并公开源码。外壳通过 `dlopen` 把 GPLv2 的 QEMU 载入同一进程。MIT 与 GPLv2 兼容，源码公开后，“组合作品是否构成衍生作品”这个问题无论结论如何都能满足。
3. 两项**需法律判断**的风险：
   - OpenSSL 1.1.1 的广告条款，以及 Apache-2.0 的 Vulkan-Loader，与 GPLv2 的 QEMU 处于同一进程。
   - LGPLv3/GPLv3 对 User Product 的“安装信息”义务。

   两项都记为发布闸门，不阻塞实现。
4. UTM 官方 CI artifact **2026-12-24 过期**，必须自行归档其二进制和对应源码。

## 1. 执行器：UTM SE 的 22 个 framework

来源：UTM 固定提交 `7eadb056ae0f91d979059544d0ddcd2d5a40be92` 的 `patches/sources` 给出各依赖版本，官方 CI artifact `10845528675`（`Sysroot-ios-tci-arm64`）提供实物。链接关系用 `otool -L` 在本地 `.runtime/Frameworks` 上核对。

| Framework | 上游源码 | 许可证（主要来源） |
|---|---|---|
| qemu-aarch64-softmmu | utmapp/qemu `v10.0.12-utm` | 整体 GPLv2；未带声明的文件为 GPLv2+（仓库 `LICENSE`） |
| glib-2.0、gobject-2.0、gio-2.0、gmodule-2.0 | GLib 2.83.0 | LGPL-2.1-or-later（`COPYING`） |
| intl.8 | gettext 0.22.5 libintl | LGPL-2.1-or-later（`gettext-runtime/intl/gettext.c` 文件头） |
| iconv.2 | libiconv 1.16 | 库：LGPL v2（`COPYING.LIB` 为 GNU Library GPL v2）；`iconv` 程序为 GPL，不随包分发（`README`） |
| ffi.8 | libffi 3.5.0 | MIT |
| pixman-1.0 | pixman 0.38.0 | MIT（`COPYING`） |
| ssl.1.1、crypto.1.1 | OpenSSL 1.1.1b | OpenSSL + SSLeay 双许可证，**含广告条款** |
| spice-server.1 | spice 0.14.3 | LGPL-2.1（`COPYING`） |
| gstreamer-1.0、gstbase-1.0、gstapp-1.0 | GStreamer、gst-plugins-base 1.19.1 | LGPL v2（Library GPL） |
| opus.0 | opus 1.3 | BSD |
| zstd.1 | zstd 1.5.2 | BSD 或 GPLv2 二选一 |
| jpeg.62 | libjpeg-turbo 1.5.3 | IJG + BSD-3 + zlib |
| slirp.0 | libslirp 4.9.1 | BSD 风格（`COPYRIGHT`） |
| epoxy.0 | utmapp/libepoxy `bf98587` | MIT |
| virglrenderer.1 | utmapp/virglrenderer `5d26f60` | MIT |
| vulkan.1 | osy/Vulkan-Loader `6df8690` | Apache-2.0 |

链接图：

- qemu 链接 pixman、jpeg、epoxy、gio、gobject、glib、zstd、slirp、spice-server、virglrenderer、gmodule。
- spice-server 链接 ssl、crypto、opus、jpeg、gstreamer、gstapp、glib、gio、gobject、pixman。
- virglrenderer 链接 epoxy、vulkan。

**风险 R1（需法律判断）。** OpenSSL 1.1.1 的广告条款与 GPLv2 不兼容，Apache-2.0 与 GPLv2-only 也不兼容。它们进入 QEMU 进程，**只**因为 SPICE（TLS）和 virgl（GPU）支持，而本项目两者都不使用。

- 彻底的缓解办法：自建一个不带 SPICE 和 virgl 的 QEMU。但这与“最快跑通”的决策冲突，所以首版不做，作为发布闸门记录。
- OpenSSL 1.1.1b 已经 EOL，不过只被 SPICE TLS 使用，本项目不启用那条路径。

**风险 R2：artifact 过期。** CI artifact `10845528675` 在 **2026-12-24** 过期。发布流程必须：

- 把 artifact 本体（内层 `sysroot.tgz`，SHA256 `eed7cbea…7c56`）归档到 Release 资产或项目自有存储；
- 同时归档上表全部源码 tarball，以及 UTM 在 `patches/` 下的补丁。

**外壳与执行器的边界。** 原型的 `QemuBridge.m` 是自写代码（只用 `dlopen`、`task_info` 等系统 API），没有 UTM 的版权头，不需要 UTM 的 Apache-2.0 NOTICE。如果实现时引入任何 UTM 源码，需要保留其 `LICENSE` 和 NOTICE。

## 2. Linux 内核与 initramfs

- **内核**：Alpine 3.23.6 `linux-lts` 6.18.52-0。
  - aports `v3.23.6:main/linux-lts/APKBUILD` 声明 `license="GPL-2.0-only"`。
  - 源码为 `cdn.kernel.org` 的 `linux-6.18.tar.xz`，加上 `patch-6.18.52.xz`，再加 aports 中的补丁和 `virt` config。
  - 对应源码包需包含这四样，以及模块签名以外的构建说明。
  - 已核对 config 的 SHA256（`18bb325d…`）与研究收据一致。
- **BusyBox**（如果 initramfs 的 init 继续使用）：采用 Debian 的静态 BusyBox，GPLv2，需附 Debian 源码包（`.dsc`、`.orig`、`.debian.tar`）。
- **init 脚本**、构建脚本：项目自有代码，MIT。

## 3. Debian 13 系统盘

系统盘由 snapshot.debian.org 固定时间戳的 trixie arm64 `.deb` 组成。规则：

1. **版权文件随盘保留**：Debian Policy 12.5 要求每个包在 `/usr/share/doc/<pkg>/copyright` 放版权文件。构建系统盘时**禁止**用 `dpkg --path-exclude` 或任何瘦身步骤删除这些文件。这条规则本身就满足“随二进制附许可证文本”的要求。
2. **源码自动收集**：构建时用 `dpkg-query -W -f='${source:Package} ${source:Version}\n'` 列出源码包，从同一个 snapshot 时间戳下载 `.dsc`、`.orig.tar.*`、`.debian.tar.*`，校验 `.dsc` 签名和哈希后放入对应源码包，并写进构建清单。
3. **GPLv3 / LGPLv3 包**（bash、coreutils、tar、gzip 等）：见 §5 的 R3。

## 4. Node 与 Harness（npm 依赖树）

- **Node v24.21.0**：本体 MIT。它的 `LICENSE` 列出了内置组件（V8、ICU、OpenSSL 3.x（Apache-2.0）、libuv、c-ares、zlib、brotli、zstd、nghttp2/3、ngtcp2、undici、npm 等），整份 `LICENSE` 需原样随附。Node 官方二进制通过 SHASUMS256 校验。
- **dsh `@deepseek-ai/dsh` 0.2.0-rc.2** 依赖树：lockfile 共 608 个条目（跨所有平台），其中 MIT 482、Apache-2.0 74、BSD-3 18、LGPL-3.0-or-later 10、ISC 8、MPL-2.0 6，其余为少数许可证。实际安装（linux-arm64）后约 509 MB。dsh、node-pty、koffi 均为 MIT。需要注意的有两项：

  | 包 | 许可证 | 义务 |
  |---|---|---|
  | `@img/sharp-libvips-linux-arm64` | LGPL-3.0-or-later | 单个 `libvips-cpp.so.8.18.7` 内含 glib 2.90、fribidi、libexif、libheif、librsvg（LGPLv3）、cairo（MPL-1.1）、aom（BSD + 专利许可）等，见其 README 组件表和 `versions.json`。需附 libvips 及各组件的对应源码，并满足 LGPLv3 §4（可替换库、安装信息）。 |
  | `@deepseek-ai/libreoffice-kit-wasm` 0.1.5 | MPL-2.0 | 体积 152 MB。包内已自带 `licenses/`（LICENSE、NOTICE、DeepSeek-Harness-MIT.txt）和 `sources/`（`core-source.json`、`source-changes.patch`）。按 MPL-2.0 §3.2，可执行形式需告知源码获取方式；原样保留这两个目录，并在源码包中收录其指向的源码。 |

- **收集规则**：构建时从安装后的 `node_modules` 遍历每个包的 `package.json` `license` 字段和 `LICENSE*`、`NOTICE*` 文件，生成第三方许可证清单。Apache-2.0 包的 NOTICE 必须进入 App 内许可页。

## 5. 发布闸门风险

| 编号 | 风险 | 状态 |
|---|---|---|
| R1 | OpenSSL 1.1.1（广告条款）和 Apache-2.0 Vulkan-Loader 与 GPLv2 QEMU 处于同一进程 | 需法律判断；缓解路径是自建无 SPICE、无 virgl 的 QEMU |
| R2 | UTM CI artifact 2026-12-24 过期 | 工程项：首个发布前完成归档 |
| R3 | LGPLv3 §4(e) / GPLv3 §6 “安装信息”适用于 iPad 这类 User Product（sharp-libvips 组件、Debian 的 GPLv3 包） | 需法律判断；预期可以满足：用户本来就自签安装，且拿得到完整镜像构建脚本，能自行替换组件并重建、重签。对应源码包须包含重建系统盘、重打 IPA 的完整脚本和说明 |
| R4 | MPL-2.0 libreoffice-kit-wasm 的源码指引 | 工程项：保留其 `licenses/` 和 `sources/` |
| R5 | Swift 外壳与 GPLv2 QEMU 构成组合作品的问题 | 已用 MIT + 公开源码消解 |

## 6. 发布清单（每个 IPA 发布）

同一个 GitHub Release 内必须包含：

1. **IPA**；
2. **对应源码包**，包括：
   - UTM 固定提交的源码，及 §1 表中全部上游 tarball 和补丁；
   - 内核 tarball、增量补丁、aports 补丁和 config；
   - BusyBox 和全部 Debian 源码包（按 §3 自动收集）；
   - Node 源码 tarball；
   - npm 依赖中 LGPL 和 MPL 组件的源码（至少包括 libvips 及其内含组件、LibreOffice 核心源码与补丁）；
   - 本项目全部构建脚本（系统盘、initramfs、用户盘种子、IPA 打包）；
3. **构建清单**：所有输入和最终系统盘的 SHA256（与 Q6 的清单为同一份）；
4. **第三方许可证清单**：每个组件的名称、版本、许可证和源码位置。

IPA 内：

- App 内“开源许可”页：包含全部许可证文本、Apache NOTICE、OpenSSL 广告条款要求的致谢语、Node 的 `LICENSE`，以及对应源码包在 Release 中的位置。
- 系统盘保留 `/usr/share/doc/*/copyright`。

## 来源

- GPLv2 §3：<https://www.gnu.org/licenses/old-licenses/gpl-2.0.html#section3>
- LGPL-2.1 §6：<https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html#SEC4>
- GPLv3 §6 / LGPLv3 §4：<https://www.gnu.org/licenses/gpl-3.0.html#section6>、<https://www.gnu.org/licenses/lgpl-3.0.html>
- MPL-2.0 §3.2：<https://www.mozilla.org/en-US/MPL/2.0/>
- Debian Policy 12.5：<https://www.debian.org/doc/debian-policy/ch-docs.html#copyright-information>
- UTM `patches/sources`：<https://github.com/utmapp/UTM/blob/7eadb056ae0f91d979059544d0ddcd2d5a40be92/patches/sources>
- utmapp/qemu `LICENSE`：<https://github.com/utmapp/qemu/blob/v10.0.12-utm/LICENSE>
- Alpine linux-lts APKBUILD：<https://gitlab.alpinelinux.org/alpine/aports/-/blob/v3.23.6/main/linux-lts/APKBUILD>
- libiconv 1.16 `README`、`COPYING.LIB`；gettext 0.22.5 `gettext.c`：<https://ftp.gnu.org/gnu/libiconv/libiconv-1.16.tar.gz>、<https://ftp.gnu.org/gnu/gettext/gettext-0.22.5.tar.gz>
- Node v24.21.0 `LICENSE`：<https://github.com/nodejs/node/blob/v24.21.0/LICENSE>
- sharp-libvips 组件表：<https://github.com/lovell/sharp-libvips>
- 原型构建来源与收据：`origin/codex/ipad-linux-prototype` 上的 `docs/prototypes/linux-executor-build-sources.md`、`docs/prototypes/linux-prototype-progress.md`
- 本地核查对象（不入库）：原型 `.runtime/Frameworks`（`otool -L`），以及 Harness `package-lock.json` 和 `node_modules`（各包 `package.json`、`LICENSE`）
