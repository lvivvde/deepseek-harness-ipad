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

上述容量和工具集合仅为本次开发验收输入，正式预算继续由首版范围任务确定。工具包括 Node/npm、Bash、Git、curl、CA、e2fsprogs 和 BusyBox；不是对所有项目类型的兼容承诺。当前用户盘为固定容量，在线扩容尚未实现。

输出 `Image`、`initramfs.gz`、`system.raw`、`user-seed.raw`、`runtime.json` 与 `build-receipt.json`。App bundle 只嵌入前五项；收据作为构建资料单独交付，包含输入清单与最终资源 SHA256。App、运行时版本和协议在构建时检查一致。

小 initramfs 只保留静态 BusyBox、启动脚本和匹配内核的必要模块。系统盘以 `ro,noload` 挂载后 switch_root；`/tmp`、`/run`、`/var` 为临时文件系统，项目、会话、配置和 Node 编译缓存都在持久化 `/root`。

用户盘先用默认只读的 debugfs 检查布局，再在未挂载状态运行 e2fsck -p；只有 clean/repaired 状态继续挂载。布局不是 v1 或无法读取时先保留原盘，避免对未知/未来格式修复写入。错误进入串口救援并向原生层发出固定故障码，不回退到 RAM home。镜像构建与设备启动都不格式化已有用户盘。

陈旧锁清理仅限官方 `~/.dsh` 内 `.lock` 文件，必须是 PID 加换行且进程已不存在；其他锁、会话日志和尾部 NUL 不修改。尚不提供完整的原生备份/恢复 UI，继续由恢复任务处理。

## 构建与打包

QEMU 执行器复用已验证输入；正式 App 使用独立 28080/28081/28082 端口，与原型 18080/18081/18082 分开。guest 内仍为官方 loopback 3001 与原有网卡 3000 relay，官方 trusted-host 为 127.0.0.1:28080，鉴权不变。

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

本次本地 IPA 实测 **311,340,361 字节**；未压缩的两个 raw 文件分别为 1 GiB 和 512 MiB，内核 10,387,968 字节、小 initramfs 1,673,827 字节。App bundle 的本机磁盘占用约 1.5 GiB，不等于设备安装占用；设备实际占用、冷启动和内存需要真机另测。构建默认不能当作之前包体/性能估计的验收结果。

个人开发包在本机保留；没有公开发布二进制 Release。正式发布前仍需完成执行器归档、完整对应源码包和许可证发布条件。

## 验收与限制

`make test-runtime` 检查锁定输入损坏和既有输出/种子盘保留。Swift 状态测试覆盖磁盘故障不得被旧 ready 事件或重试变成成功。`runtime/guest/runtime-check.cjs` 在真实 guest 验证只读系统盘、可写用户盘、npm test、Git 本地提交、SQLite 和计数持久化；第一次参数 0，成功后第二次应传 1，不能重置计数让测试通过。

Linux 测试 VM 中真实 QEMU 已启动新镜像，按官方 token/cookie 流程获得 HTTP 200 和 `__DSH_BOOT__`；Node/npm/Git/SQLite 与只读检查已通过。这不代替 iPad 上的无 JIT 性能与界面验收。

签名 App 已安装到独立 `org.lvivvde.harness.ipad` 容器，启动验证正在进行。新容器没有复制原型配置，API Key/模型操作需在新 App 独立验收。键盘/触控、工作区操作、后台恢复与备份尚未完整验收；相关 issue 保持开放。

原生仅把固定阶段和启动时长写到自己的 `Library/Application Support/HarnessRuntime/RuntimeStatus.json`，页面绘制打印固定标记。原始串口、完整启动 URL、凭据和设备标识不写入该记录或公开收据。
