# Linux 执行可行性原型（可丢弃）

问题：普通签名的自有 iPad 应用，能否通过固定 UTM SE/QEMU 无 JIT 解释器运行 aarch64 Linux，再让官方 Harness 与 WKWebView 通过本机端口桥交互？对应[原型验证票](https://github.com/lvivvde/deepseek-harness-ipad/issues/11)。

这是技术验证资产。外壳可编译不等于 Linux 已运行；Linux 启动也不等于 Node、Harness、PTY、sandbox 或生产性能已通过。界面不会生成假的 guest 输出。

## 构建外壳

从仓库根目录执行：

```sh
xcodebuild -project ios/LinuxPrototype/LinuxPrototype.xcodeproj \
  -scheme LinuxPrototype -sdk iphoneos \
  -derivedDataPath ios/LinuxPrototype/build CODE_SIGNING_ALLOWED=NO build
```

普通签名安装：用 Xcode 打开此工程，target → Signing & Capabilities → Add Account，自己登录 Apple ID 并选择 Team，再选择连接的 iPad 运行。个人签名资料和设备日志不提交到公开仓库；本地 `Signing.local.xcconfig` 已忽略，可写入 `DEVELOPMENT_TEAM = 你的团队标识`。发布工程前，应将 Xcode 写入 project.pbxproj 的个人 Team 设置移到此本地配置。原型未申请 JIT、hypervisor、额外内存或共享 app group 权限。

## 固定执行器

官方构建 run `36090554968` / artifact `10845528675` 的 `Sysroot-ios-tci-arm64` 对应 UTM `7eadb056ae0f91d979059544d0ddcd2d5a40be92`，QEMU `v10.0.12-utm`。解包后在本目录执行：

```sh
python3 scripts/prepare-runtime.py /实际路径/sysroot-iOS-TCI-arm64
```

脚本核对 iOS 平台、三个共享库入口，记录每个二进制摘要并提取静态链接依赖闭包。它不下载组件，也不证明这些二进制的來源或许可合规；下载时需核对官方 artifact 元数据和摘要。产物位于忽略的 `.runtime/`，Xcode 构建阶段复制并用本次身份签名。设备框架不用于模拟器；模拟器只能检查外壳。

## 测试 guest

导入目录包括 `boot.json` 和其中指定的镜像文件。最小 kernel 模式示例：

```json
{"mode":"kernel","kernel":"Image","initrd":"initramfs.cpio.gz","append":"console=ttyAMA0 rdinit=/init","memoryMiB":512}
```

initramfs 必须明确提供可执行 `/init` 和适配 virt 机器的驱动；任意发行版 installer initrd 不保证直接出现 shell。应用将文件复制到自己的测试目录，启动单 CPU / 512 MiB 配置；这是引导实验参数，不是 Harness 内存预算。可选 `disk` 指定同目录 qcow2；UEFI 模式使用同产物 `edk2-aarch64-code.fd` 和 qcow2 根磁盘。

真实 guest 救援串口：设备 `127.0.0.1:18081`；QMP：`127.0.0.1:18082`。网页：设备 `127.0.0.1:18080` → guest 网卡端口 `3000`；guest 服务须监听其可达网卡。不能把 guest loopback 当作设备 loopback。串口视图是简易文本收发器，不能替代 Harness PTY 验收。

首次原型仅前台、单 VM、每个应用进程启动一次。需要重新启动时关闭应用再打开；没有实现后台运行、暂停/恢复、完整终端、项目工作区或镜像更新。QEMU 的致命退出仍可能终止宿主，错误日志由 Xcode 捕获。

所有 native frameworks、guest 镜像、签名资料和构建日志只留本地。将来分发含这些组件的 IPA 前，应按实际组件准备对应源码、补丁、构建及所需重链接资料；本分支不发布二进制。

## Node 运行时探针

`build-node-guest.py` 在已生成的最小 guest 上追加官方 Node 24.21.0 Linux arm64 发行包、Debian glibc 2.41、GCC 14 运行库。脚本核对固定摘要，复制 tar 条目到 cpio，不在 Mac 上运行 Linux 二进制。

```sh
python3 ios/LinuxPrototype/scripts/build-node-guest.py \
  /下载目录 /最小guest目录 /NodeGuest输出目录
```

下载目录的文件名和来源：

- `node-v24.21.0-linux-arm64.tar.xz`：[Node 官方发行目录](https://nodejs.org/dist/v24.21.0/)，摘要由该目录 `SHASUMS256.txt` 核对。
- `libc6.deb`：[Debian libc6 2.41-12+deb13u4 arm64](https://packages.debian.org/trixie/arm64/libc6/download)。
- `libgcc-s1.deb`：[Debian libgcc-s1 14.2.0-19 arm64](https://packages.debian.org/trixie/arm64/libgcc-s1/download)。
- `libstdcpp.deb`：[Debian libstdc++6 14.2.0-19 arm64](https://packages.debian.org/trixie/arm64/libstdc%2B%2B6/download)。

镜像启动后自动执行 Node 的子进程、文件、SQLite、worker 和 guest HTTP 探针，输出串口和 `/www/node.txt`。配置使用 1536 MiB guest RAM，仅是这次实验参数。镜像仍无持久化 rootfs、完整工具链或 Harness；不能作为完整发行版验收。

## 官方 Harness 启动探针

在临时目录下载固定官方 CLI 及 Linux ARM64 依赖，禁用包生命周期脚本：

```sh
npm install --prefix /临时Harness目录 --ignore-scripts \
  --os=linux --cpu=arm64 --libc=glibc --no-audit --no-fund \
  --save-exact @deepseek-ai/dsh@0.2.0-rc.2
python3 ios/LinuxPrototype/scripts/build-harness-guest.py \
  /下载目录 /NodeGuest目录 /临时Harness目录 /HarnessGuest输出目录
```

另外下载 `bash.deb`（[Debian bash 5.2.37-2+b10 arm64](https://packages.debian.org/trixie/arm64/bash/download)）和 `libtinfo6.deb`（[Debian libtinfo6 6.5+20250216-2 arm64](https://packages.debian.org/trixie/arm64/libtinfo6/download)）。脚本检查摘要，保存本次依赖锁及其摘要；CLI 版本固定，传递依赖以该次锁文件为准。

启动时实际探测 koffi、sharp、flock、Landlock 和 node-pty，再运行原版 `dsh web --no-open --port 3001 --trusted-host 127.0.0.1:18080`。Harness 保留 guest loopback 监听；guest 内 TCP relay 从 SLIRP 网卡端口 3000 转接到 3001。设备侧端口仍只绑定 loopback。外壳从完整串口行读取官方启动 URL，只替换转发端口，保留官方 token 交换与 cookie 鉴权。

这是带 RAM-only 文件系统的兼容实验。原始启动 URL、token、cookie 和可能包含配置的日志只留本地；不会发布。本探针不等于已验证插件、模型调用、Git 或持久化项目闭环。

Harness 探针使用 2048 MiB guest RAM。首次 1536 MiB 配置在 initramfs 解包时触及临时根文件系统容量，出现 `Initramfs unpacking failed: write error` / `No space left on device`；缺失模块不能视作兼容性结论。镜像的未压缩归档合计约 679 MiB，还有文件页和目录开销。正式运行时需使用持久化 POSIX 根文件系统，避免以大 initramfs 装载整套 npm 树。

可选磁盘恢复探针：准备一个全新的 64 MiB 空白文件 `persistence-probe.raw`，用 macOS `newfs_msdos -F 16 -S 512 -s 131072 -h 16 -u 63 -b 4096 -o 0 -v PROBE` 格式化此文件，放入下载目录。构造脚本在输出目录首次复制为 `persistence.raw`，以后不覆盖。guest 挂载它并写入 `proof.txt`，后续应用重启应输出 `PERSISTENCE_RESTORED:persistence-file-ok`。此 FAT 磁盘只验证持久化 I/O，不是 POSIX 工程工作区；重启测试不要重新覆盖设备上的磁盘。
