# 内置运行时与开发 IPA

实现 [内置运行时任务](https://github.com/lvivvde/deepseek-harness-ipad/issues/17)。采用已确认的 [运行时交付决策](https://github.com/lvivvde/deepseek-harness-ipad/issues/12)：Debian 13 arm64 固定快照、Alpine 6.18.52-0-virt、Node 24.21.0、官方 dsh 0.2.0-rc.2；小 initramfs、只读 ext4 系统盘、独立 ext4 `/root` 用户盘。首次启动不下载运行时。

## 固定输入

`inputs.lock.json` 固定 Debian 快照 `20261003T000000Z` 的 66 个软件包和内核/Node 输入，列出 URL、版本、来源包与 SHA256。二进制收据用于固定输入一致性，不宣称替代上游签名验证。`harness-package-lock.json` 保留官方 npm 依赖与 integrity；通过 npm ci 重建，禁止用 npm update 替代。

下载与 npm 准备在构建机器上执行，设备不执行这些步骤：

```sh
python3 runtime/prepare-inputs.py /path/to/inputs
mkdir -p /path/to/harness
cp runtime/harness-package.json /path/to/harness/package.json
cp runtime/harness-package-lock.json /path/to/harness/package-lock.json
npm ci --ignore-scripts --os=linux --cpu=arm64 --libc=glibc --prefix /path/to/harness
```

Debian 包提取 data.tar，不运行维护脚本；镜像构建显式生成 root 用户条目、CA bundle 和 DHCP hook。保留包内 `/usr/share/doc/*/copyright` 与 npm 许可证/源码资料。系统按整版镜像升级，不在设备运行 apt upgrade。

## 构建镜像

需要 Python 3.11+、ar、mke2fs、unsquashfs；zstd 压缩模块另需 zstd。可在 Linux 构建，或使用 macOS 的同名工具。输出目录必须不存在；中途失败的目录保留，不自动删盘，重试用新目录。

```sh
python3 runtime/build-runtime.py \
  --inputs /path/to/inputs --lock runtime/inputs.lock.json \
  --harness /path/to/harness --output /path/to/new-guest \
  --mke2fs /path/to/mke2fs --unsquashfs /path/to/unsquashfs \
  --system-mib 1024 --user-mib 512 --memory-mib 2048
```

上述容量和工具集合仅为本次开发验收输入，正式预算继续由首版范围任务确定。工具包括 Node/npm、Bash、Git、curl、CA、e2fsprogs 和 BusyBox；不是对所有项目类型的兼容承诺。种子用户盘为 512 MiB；`--user-disk-mib`（默认 8192）写入 `runtime.json`，App 首次或升级时把 `user.raw` 稀疏扩展到该容量（只增不减，目录排除 iCloud 备份），guest 挂载后在线 `resize2fs`。

Git 预置 `/etc/gitconfig`：credential store 写入 `/root/.git-credentials`（0600）、`user.useConfigOnly`、默认分支 main、pager 为 cat。项目放在 `/root/projects/<名称>`；全局 `/root/.dsh/AGENTS.md` 由镜像管理（带标记行时每次启动刷新，删除标记即由用户接管）。

单项目导出/导入由 guest `transfer.cjs`（npm 自带 node-tar）提供：仅监听 guest 网卡 3002，App 经 `127.0.0.1:28083` 转发，每个 App 进程随机 token 通过内核参数 `harness.transfer=` 传入，并以 `X-Harness-Transfer` 头校验。导出跳过 `node_modules` 与 `.cache`；导入只接受单个顶层目录，解压到临时目录后改名，重名追加 `-2`、`-3`，从不覆盖。

输出 `Image`、`initramfs.gz`、`system.raw`、`user-seed.raw`、`runtime.json` 与 `build-receipt.json`。App bundle 只嵌入前五项；收据作为构建资料单独交付，包含输入清单与最终资源 SHA256。App、运行时版本和协议在构建时检查一致。

小 initramfs 只保留静态 BusyBox、启动脚本和匹配内核的必要模块。系统盘以 `ro,noload` 挂载后 switch_root；`/tmp`、`/run`、`/var` 为临时文件系统，项目、会话、配置和 Node 编译缓存都在持久化 `/root`。

用户盘先用默认只读的 debugfs 检查布局，再在未挂载状态运行 e2fsck -p；只有 clean/repaired 状态继续挂载。布局不是 v1 或无法读取时先保留原盘，避免对未知/未来格式修复写入。错误进入串口救援并向原生层发出固定故障码，不回退到 RAM home。镜像构建与设备启动都不格式化已有用户盘。

陈旧锁清理仅在新 VM 冷启动、官方 dsh 尚未启动时执行，显式要求 `--cold-boot`。仅清除官方 `~/.dsh` 内严格 PID 加换行格式的 `.lock` 文件，不以新进程中的同号 PID 判断旧锁仍有效；其他锁、会话日志和尾部 NUL 不修改。尚不提供完整的原生备份/恢复 UI，继续由恢复任务处理。

## 构建与打包

QEMU 执行器复用已验证输入；正式 App 使用独立 28080/28081/28082/28083（页面/串口/QMP/项目传输）端口，与原型 18080/18081/18082 分开。Swift 端口集中在 `RuntimePorts`；guest 内仍为官方 loopback 3001 与原有网卡 3000 relay，官方 trusted-host 为 127.0.0.1:28080，鉴权不变。修改端口时必须同步 guest trusted-host 并重建运行时；这项跨语言契约仍是非阻塞的维护限制。

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

本次本地 IPA 实测约 **311 MB**，最终字节数和 SHA256 随本机包的 sidecar 记录；未压缩的两个 raw 文件分别为 1 GiB 和 512 MiB，内核 10,387,968 字节、小 initramfs 1,673,827 字节。App bundle 的本机磁盘占用约 1.5 GiB，不等于设备安装占用；设备实际占用、冷启动和内存需要真机另测。构建默认不能当作之前包体/性能估计的验收结果。

个人开发包在本机保留；没有公开发布二进制 Release。正式发布前仍需完成执行器归档、完整对应源码包和许可证发布条件。

## 验收与限制

`make test-runtime` 检查锁定输入损坏和既有输出/种子盘保留。Swift 状态测试覆盖磁盘故障不得被旧 ready 事件或重试变成成功。`runtime/guest/runtime-check.cjs` 在真实 guest 验证只读系统盘、可写用户盘、npm test、Git 本地提交、SQLite 和计数持久化；第一次参数 0，成功后第二次应传 1，不能重置计数让测试通过。

Linux 测试 VM 中真实 QEMU 已启动新镜像，按官方 token/cookie 流程获得 HTTP 200 和 `__DSH_BOOT__`；Node/npm/Git/SQLite 与只读检查已通过，重启后 Git 和 SQLite 保留、计数由 1 继续到 2。这不代替 iPad 上的无 JIT 性能与界面验收。

故障验收可在 Linux 执行 `python3 runtime/check-boot.py /path/to/new-guest`，需要 QEMU、mke2fs、debugfs。它只创建自有临时盘：未来布局 v2 必须进入 USER_LAYOUT 救援且完整 raw 哈希不变；数据块满但 inode/目录尚可用时，必须进入 USER_SPACE 救援，不能尝试启动 Harness。两项真实 QEMU 验收已通过。正常启动还执行非空同步写入探测，空间不足或 I/O 失败有明确故障码。

签名 App 已安装到独立 `org.lvivvde.harness.ipad` 容器；首次启动请求被设备锁屏拒绝，等待解锁后继续真机验收。新容器没有复制原型配置，API Key/模型操作需在新 App 独立验收。键盘/触控、工作区操作、后台恢复与备份尚未完整验收；相关 issue 保持开放。

原生仅把固定阶段和启动时长写到自己的 `Library/Application Support/HarnessRuntime/RuntimeStatus.json`，页面绘制打印固定标记。原始串口、完整启动 URL、凭据和设备标识不写入该记录或公开收据。
