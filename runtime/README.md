# 内置运行时与开发 IPA

实现 [内置运行时任务](https://github.com/lvivvde/deepseek-harness-ipad/issues/17)。采用已确认的 [运行时交付决策](https://github.com/lvivvde/deepseek-harness-ipad/issues/12)：Debian 13 arm64 固定快照、Alpine 6.18.52-0-virt、Node 24.21.0、官方 dsh 0.2.0-rc.2；小 initramfs、只读 ext4 系统盘、独立 ext4 `/root` 用户盘。首次启动不下载运行时。

## 固定输入

`inputs.lock.json` 固定 Debian 快照 `20261003T000000Z` 的 135 个软件包和内核/Node 输入，列出 URL、版本、来源包与 SHA256。二进制收据用于固定输入一致性，不宣称替代上游签名验证。`harness-package-lock.json` 保留官方 npm 依赖与 integrity；通过 npm ci 重建，禁止用 npm update 替代。

下载与 npm 准备在构建机器上执行，设备不执行这些步骤：

```sh
python3 runtime/prepare-inputs.py /path/to/inputs
mkdir -p /path/to/harness
cp runtime/harness-package.json /path/to/harness/package.json
cp runtime/harness-package-lock.json /path/to/harness/package-lock.json
npm ci --ignore-scripts --os=linux --cpu=arm64 --libc=glibc --prefix /path/to/harness
```

Debian 包提取 data.tar，不运行维护脚本；镜像构建显式生成 root 用户条目、CA bundle 和 DHCP hook。保留包内 `/usr/share/doc/*/copyright` 与 npm 许可证/源码资料。guest 使用 C.UTF-8；仅省去 `/usr/share/locale` 中未使用的命令消息翻译，保留终端定义和时区。系统按整版镜像升级，不在设备运行 apt upgrade。

## 构建镜像

需要 Python 3.11+、ar、mke2fs、unsquashfs；zstd 压缩模块另需 zstd。完整工具集合包含大小写不同的 Linux 文件名，需在大小写敏感的文件系统上构建；本次使用既有隔离 Linux VM。macOS 默认大小写不敏感目录不适合作为完整 sysroot 的暂存目录。若 `/tmp` 为小容量 tmpfs，设置 `TMPDIR` 到有足够空间的构建磁盘。输出目录必须不存在；中途失败的目录保留，不自动删盘，重试用新目录。

```sh
python3 runtime/build-runtime.py \
  --inputs /path/to/inputs --lock runtime/inputs.lock.json \
  --harness /path/to/harness --output /path/to/new-guest \
  --mke2fs /path/to/mke2fs --unsquashfs /path/to/unsquashfs \
  --system-mib 1024 --user-mib 8 --memory-mib 2048
```

容量与工具集合按 [首版范围决策](https://github.com/lvivvde/deepseek-harness-ipad/issues/6) 固定。系统盘包括：Node/npm/corepack、固定 dsh、Bash、CA、tzdata、xdg-user-dirs、e2fsprogs；GNU coreutils/findutils/grep/sed/gawk/diffutils/patch、procps、util-linux/bsdutils 常用工具、less、file；tar/gzip/xz/zstd/zip/unzip；Git/OpenSSH client/curl；ripgrep/jq/nano。ncurses-base 提供 xterm-256color 的终端定义。Python、编译工具和系统包安装仍不支持。种子用户盘默认 8 MiB；`--user-disk-mib`（默认 8192）写入 `runtime.json`，App 首次或升级时把 `user.raw` 稀疏扩展到该容量（只增不减，目录排除 iCloud 备份），guest 挂载后在线 `resize2fs`。用户可从悬浮按钮 →“iPad 应用设置…”手动在线增大至 64 GiB；同容量可重试，不支持缩小，不自动增长。运行中扩容通过 QMP 修改唯一 raw 盘，并持有 supervisor 租约完成文件系统扩展；与备份冻结互斥，失败不缩回原盘。

Git 预置 `/etc/gitconfig`：credential store 写入 `/root/.git-credentials`（0600）、`user.useConfigOnly`、默认分支 main、pager 为 cat。项目放在 `/root/projects/<名称>`；全局 `/root/.dsh/AGENTS.md` 由镜像管理（带标记行时每次启动刷新，删除标记即由用户接管）。

单项目导出/导入由 guest `transfer.cjs`（npm 自带 node-tar）提供：仅监听 guest 网卡 3002，App 经 `127.0.0.1:28083` 转发，每个 App 进程随机 token 通过内核参数 `harness.transfer=` 传入，并以 `X-Harness-Transfer` 头校验。导出跳过 `node_modules` 与 `.cache`；导入只接受单个顶层目录，解压到临时目录后改名，重名追加 `-2`、`-3`，从不覆盖。项目名可含中文、空格与符号，只排除隐藏名、斜杠和控制字符。删除先移入同盘 `/root/.trash/<id>/`（含 `meta.json` 与原目录），彻底删除先改名为 `.purging-<id>` 再后台删除，服务启动时清理残留。

项目删除通过 `project-lifecycle.mjs` host 插件的 `/run/harness-workspaces.sock`（0600）协调官方 `workspaceRegistry`：先停止并持久归档项目会话，再删除工作区登记，最后允许传输服务移动文件。只调用官方 API，不从另一进程改写官方存储或上游包。旧版回收站清空时用删除时间筛选旧工作区和会话；即使重启后目录已不存在，也通过官方持久会话头找回应归档的会话。同名新工作区保留。插件不可用则返回 `WORKSPACE_UNAVAILABLE`，不移动项目文件。

`make test-runtime` 包含真实官方注册表、JSON 持久化和传输 HTTP 接口的项目删除回归。需要先按上文准备固定 Harness 依赖，并设置 `HARNESS_TEST_MODULES=/path/to/harness/node_modules`（本机默认 `/private/tmp/ipad-runtime-harness/node_modules`）；缺少依赖时这些集成测试明确跳过。测试使用自己的临时目录、socket 与测试令牌，不读取设备或用户配置。

输出 `Image`、`initramfs.gz`、`system.raw`、`user-seed.raw`、`runtime.json` 与 `build-receipt.json`。App bundle 只嵌入前五项；收据作为构建资料单独交付，包含输入清单与最终资源 SHA256。App、运行时版本和协议在构建时检查一致。

小 initramfs 只保留静态 BusyBox、启动脚本和匹配内核的必要模块。系统盘以 `ro,noload` 挂载后 switch_root；`/tmp`、`/run`、`/var` 为临时文件系统，项目、会话、配置和 Node 编译缓存都在持久化 `/root`。

用户盘先用默认只读的 debugfs 检查布局，再在未挂载状态运行 e2fsck -p；只有 clean/repaired 状态继续挂载。布局不是 v1 或无法读取时先保留原盘，避免对未知/未来格式修复写入。错误进入串口救援并向原生层发出固定故障码，不回退到 RAM home。镜像构建与设备启动都不格式化已有用户盘。

陈旧锁清理仅在新 VM 冷启动、官方 dsh 尚未启动时执行，显式要求 `--cold-boot`。仅清除官方 `~/.dsh` 内严格 PID 加换行格式的 `.lock` 文件，不以新进程中的同号 PID 判断旧锁仍有效；其他锁、会话日志和尾部 NUL 不修改。完整 tar+SHA256 备份/恢复及停止 QEMU 后的 raw 救援入口已实现，见 [恢复与备份验证](../docs/validation/ipad-recovery-backup.md)。

## 构建与打包

QEMU 执行器复用已验证输入；正式 App 的页面/项目传输分别使用独立 28080/28083 回环端口；串口与 QMP 使用 Unix socketpair，与原型分开。Swift 端口集中在 `RuntimePorts`；guest 内仍为官方 loopback 3001 与网卡 2999 relay，官方 trusted-host 为 127.0.0.1:28080，鉴权不变。修改端口时必须同步 guest trusted-host 并重建运行时；这项跨语言契约仍是非阻塞的维护限制。

```sh
xcodebuild -project ios/HarnessApp/HarnessApp.xcodeproj -scheme HarnessApp \
  -sdk iphoneos -configuration Release -derivedDataPath /path/to/app-build \
  HARNESS_EXECUTOR_DIR=/path/to/prepared-executor \
  HARNESS_GUEST_DIR=/path/to/new-guest -allowProvisioningUpdates build
python3 runtime/package-ipa.py \
  /path/to/app-build/Build/Products/Release-iphoneos/HarnessApp.app \
  /path/to/HarnessApp-0.1.0-dev.ipa
```

签名配置仍在忽略的 `ios/HarnessApp/Signing.local.xcconfig`，不要提交签名身份、描述文件或设备标识。打包器检查资源完整性、开发描述文件和签名；拒绝覆盖已有 IPA，保留符号链接。当前个人开发签名只覆盖配置中的设备，其他用户的重签安装链路尚未验收。

此前 M1 本地 IPA 实测约 **311 MB**，最终字节数和 SHA256 随本机包的 sidecar 记录；该旧版未压缩的两个 raw 文件分别为 1 GiB 和 512 MiB（本轮新种子缩为 8 MiB，首次启动仍扩到 8 GiB；不会更改已有用户盘），内核 10,387,968 字节、小 initramfs 1,673,827 字节。App bundle 的本机磁盘占用约 1.5 GiB，不等于设备安装占用；设备实际占用、冷启动和内存需要真机另测。构建默认不能当作之前包体/性能估计的验收结果。

个人开发包在本机保留；没有公开发布二进制 Release。正式发布前仍需完成执行器归档、完整对应源码包和许可证发布条件。

## 验收与限制

`make test-runtime` 检查锁定输入损坏和既有输出/种子盘保留。Swift 状态测试覆盖磁盘故障不得被旧 ready 事件或重试变成成功。`runtime/guest/runtime-check.cjs` 在真实 guest 验证只读系统盘、可写用户盘、npm test、Git 本地提交、SQLite 和计数持久化；第一次参数 0，成功后第二次应传 1，不能重置计数让测试通过。

Linux 测试 VM 中真实 QEMU 已启动新镜像，按官方 token/cookie 流程获得 HTTP 200 和 `__DSH_BOOT__`；Node/npm/Git/SQLite 与只读检查已通过，重启后 Git 和 SQLite 保留、计数由 1 继续到 2。这不代替 iPad 上的无 JIT 性能与界面验收。

故障验收可在 Linux 执行 `python3 runtime/check-boot.py /path/to/new-guest`，需要 QEMU、mke2fs、debugfs。它只创建自有临时盘：未来布局 v2 必须进入 USER_LAYOUT 救援且完整 raw 哈希不变；数据块满但 inode/目录尚可用时，必须进入 USER_SPACE 救援，不能尝试启动 Harness。两项真实 QEMU 验收已通过。正常启动还执行非空同步写入探测，空间不足或 I/O 失败有明确故障码。

正式 M1–M3 已合入 main，并生成过一次 main IPA；设备仍是旧 dev9，新包未安装。工具与存储补齐分支本轮不打包、不安装。S 仓库、模型/插件调用、键盘、长后台、重签、存储与性能仍需集中真机验收；相关 issue 保持开放。

原生仅把固定阶段和启动时长写到自己的 `Library/Application Support/HarnessRuntime/RuntimeStatus.json`，页面绘制打印固定标记。原始串口、完整启动 URL、凭据和设备标识不写入该记录或公开收据。

## 用户级包、网络与空间

全局 npm 前缀固定为 `/root/.local`，其 `bin` 在 PATH 中；不写只读系统盘。官方插件机制使用固定 pnpm 11.28.4，`corepack pnpm` 与 `yarn` 可按项目需求下载到用户盘的 `/root/.cache/corepack`；首版包管理承诺仍以 npm 为准，不自动升级项目版本。

默认 npm registry 为 npmjs.org。用户可自行在用户盘 `~/.npmrc` 配置镜像，在 `git config --global http.proxy` 和 `HTTP_PROXY`/`HTTPS_PROXY` 配置代理。不会读取 iPadOS 系统代理/PAC；iPad VPN 是否覆盖 guest 流量仍需真机确认。离线可以继续本地编辑、测试、构建、预览和 commit，模型 API、未缓存依赖、clone/push 需要网络。请勿把代理凭据或 token 写进共享命令/日志。

用户盘稀疏上限与 iPad 实际余量不同。设置先显示宿主余量，前台每 15 秒检查低于 2 GiB 的情况并提醒；此时拒绝继续扩容。运行时仍可能因真实写入空间不足进入救援，不能把更大的稀疏上限当作更多物理空间。

删除文件的 discard/打洞能力仍待真机验证。本轮不提供自动压缩原盘；完整备份恢复会保留旧数据目录，也不能保证释放 iPad 空间。需要回收时应先保留并校验备份，再规划到新容器的迁移，不自动删除当前数据盘。

本轮最终 guest 的隔离 QEMU 验收与体积测量见 [存储与工具补齐验收](../docs/validation/ipad-storage-tools.md)。最终无签名 App 逻辑文件总量约 1.199 GB（1.117 GiB）；未测新 IPA 或设备安装占用，不能据此登记预算通过。
