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

启动时安装 BusyBox 的独立 applet 命令入口到 `/bin`，补齐 `ls` 等最小工具；这不是 GNU 工具链兼容承诺。实际探测 koffi、sharp、flock、Landlock 和 node-pty，再运行原版 `dsh --profile web --patch /opt/harness/ipad.patch.yml --no-open --port 3001 --trusted-host 127.0.0.1:18080`。patch 只给官方 `workspace-controller` 设置 `documentsDirectory: /root/Documents`，该目录在 init 中创建；避免最小 Linux 缺少 `xdg-user-dir` 导致默认工作区初始化失败。已有目录也可以通过官方“添加工作区”界面登记。Harness 保留 guest loopback 监听；guest 内 TCP relay 从 SLIRP 网卡端口 3000 转接到 3001。设备侧端口仍只绑定 loopback。外壳从完整串口行读取官方启动 URL，只替换转发端口，保留官方 token 交换与 cookie 鉴权。

这是带 RAM-only 文件系统的兼容实验。原始启动 URL、token、cookie 和可能包含配置的日志只留本地；不会发布。本探针不等于已验证插件、模型调用、Git 或持久化项目闭环。

Harness 探针使用 2048 MiB guest RAM。首次 1536 MiB 配置在 initramfs 解包时触及临时根文件系统容量，出现 `Initramfs unpacking failed: write error` / `No space left on device`；缺失模块不能视作兼容性结论。镜像的未压缩归档合计约 679 MiB，还有文件页和目录开销。正式运行时需使用持久化 POSIX 根文件系统，避免以大 initramfs 装载整套 npm 树。

可选磁盘恢复探针：准备一个全新的 64 MiB 空白文件 `persistence-probe.raw`，用 macOS `newfs_msdos -F 16 -S 512 -s 131072 -h 16 -u 63 -b 4096 -o 0 -v PROBE` 格式化此文件，放入下载目录。构造脚本在输出目录首次复制为 `persistence.raw`，以后不覆盖。guest 挂载它并写入 `proof.txt`，后续应用重启应输出 `PERSISTENCE_RESTORED:persistence-file-ok`。此 FAT 磁盘只验证持久化 I/O，不是 POSIX 工程工作区；重启测试不要重新覆盖设备上的磁盘。

仅 `--prototype-autostart` 诊断模式启用命令信箱：向应用的 `Documents/PrototypeCommand.txt` 写入不超过 16 KiB 的 UTF-8 命令，原型在真实串口连接且 guest 初始化标记出现后读取一次、删除文件并发送到 guest。结果留在串口日志。它用于真机探针，不是正式应用接口。

WebView 的原型 popup delegate 在应用内创建授权子窗口，保持 Linux 回调仍在前台；官方 OAuth URL、PKCE、回调和 token 交换都由上游执行。返回按钮只关闭浏览器子窗口，取消授权仍由官方页面处理。

冷启动时，外壳轮询启动 URL，直到官方页面返回 200 且含 `__DSH_BOOT__` 才自动打开 WebView；等待期间显示阶段和按上次实测时长估算的剩余时间。WebView 打开后，原生遮罩保持到官方 `#root` 出现文字并经过两帧绘制。外壳把各阶段耗时、串口启动标记首次出现时间和一次截图像素检查写入 `PrototypeMetrics.json`，只含数字。官方停止按钮在 mousedown 时把焦点移回输入框，iPad 上会弹出键盘并丢掉这次点击。外壳注入一段只匹配官方停止按钮标签（“停止生成”/“Stop generating”）的触摸脚本：不移动的单击直接触发按钮 `click()`，不修改上游代码。上游改标签后该脚本会失效，这是候选上游问题。

基础 Harness guest 的 home 在 RAM 中；以下状态盘实验用于验证重启持久化。

## 持久化 HOME 实验

`build-state-guest.py` 在 Harness guest 上追加与 Linux `6.18.52-0-virt` 匹配的 ext4、jbd2、mbcache 和 crc16 模块；runtime 根文件系统仍在 RAM 中，新增 ext4 磁盘仅挂载到 `/root`。它保留第一块 `persistence.raw` FAT 盘作为迁移备份，`boot.json` 的 `stateDisk` 指定第二块 raw 磁盘。普通签名外壳支持这一可选字段，不申请额外权限。

模块输入来自[固定 Alpine 3.23.6 modloop](https://dl-cdn.alpinelinux.org/alpine/v3.23/releases/aarch64/netboot-3.23.6/modloop-virt)，SHA256 `e96d6f26f7bc7ce64946deb60dae5e3728d73ecd4f37bc59d974a2027cba825b` 是本次 HTTPS 下载的内容收据，不冒充上游签名校验。脚本读取 `modules.dep` 的依赖闭包并逐个核对 vermagic；用 `unsquashfs -cat` 读取目标条目，避免 macOS 常见大小写不敏感文件系统解包整棵 Linux 模块树时产生名称冲突。格式化与挂载方式参考[Linux ext4 文档](https://www.kernel.org/doc/html/latest/admin-guide/ext4.html)。

先在 guest 正常停止 Harness，使用 BusyBox tar 将 `/root` 归档为 `/persist/root-backup.tgz`，检查归档后 sync 并卸载 `/persist`。备份包含登录配置，只保存在设备的应用数据容器，不复制到仓库或构建目录。

在全新的输出目录准备 512 MiB 的空白普通文件，使用 `mke2fs -t ext4 -F -b 4096 -m 0 -E lazy_itable_init=0,lazy_journal_init=0 -d SEED_DIRECTORY STATE_IMAGE` 格式化；seed 目录只含 `.prototype-state-version`，正文 `v1\n`。本次 Mac 临时工具为 e2fsprogs 1.47.4、unsquashfs 4.7.5；它们仅解包使用，未安装到系统。新文件用 exclusive-create 创建，已有文件不得重格式化。随后运行：

```sh
python3 ios/LinuxPrototype/scripts/build-state-guest.py \
  /下载目录 /HarnessGuest目录 /全新StateGuest目录 /unsquashfs可执行文件
```

生成 `initramfs-state.cpio.gz`、`boot.json` 和模块/镜像收据。部署时只新增 initramfs 和首次使用的 `state.raw`，更新 boot.json；不要复制或覆盖设备已有的 `persistence.raw` 或已经使用的 `state.raw`。首次挂载核对版本标记并从设备备份恢复 `/root`，恢复成功后才写 `.state-restored-v1`；后续启动直接沿用状态盘。挂载、版本或恢复失败时保留救援串口，不启动 Harness，避免以 RAM 状态误报持久化成功。

`state-probe.cjs WORKSPACE EXPECTED_COUNT` 用原有加法模块与测试复核工作区，检查 ext4 上的权限、符号链接、硬链接和 SQLite WAL，写入可跨重启核对的计数。探针源码在宿主仓库，由诊断 mailbox 送入真实 guest 后运行；这是集成实验，不是正式迁移工具。

`stop-harness.cjs` 查找官方 CLI，发送 SIGTERM 并等待退出，再 sync；串口中确认 `HARNESS_STOPPED` 后才卸载 `/root` 和 `/persist`。它不是 VM 电源管理或异常断电恢复机制。

外壳每秒读取自身 `task_info(TASK_VM_INFO)`，在 `PrototypeMetrics.json` 保存当前 phys_footprint、采样峰值及内核报告的峰值，记录从 QEMU 调用到官方启动 URL/HTTP 就绪的耗时及前后台事件。HTTP 探测使用无缓存的 ephemeral session，只有带 token 的启动入口得到 200 且正文含官方 `__DSH_BOOT__` 时才计为就绪，避免同一 loopback 地址以前的 BusyBox 页面缓存误报。范围仅为宿主应用进程，不含 WKWebView 独立辅助进程；采样峰值也不能代替完整生产工作负载预算。

## 异常退出探针

先在 Harness 停止时把当前 `/root` 归档为 FAT 盘上的新文件（不覆盖原 `root-backup.tgz`），`gzip -t` 并核对关键条目后 sync；随后重启 Harness，卸载 `/persist`，避免强杀时备份盘处于挂载写状态。`abnormal-writer.cjs` 在 `/root/.abnormal-exit` 每 100 ms 追加一行序号、一个 64 KiB 定值块和一条 `synchronous=FULL` 的 SQLite WAL 记录，每 10 次 fsync 并原子更新 `last-fsynced.txt`。写入进行中用 `devicectl device process terminate --kill` 向宿主应用发 SIGKILL，再以 `--prototype-autostart` 重启。`abnormal-verify.cjs` 只输出计数：fsync 检查点之前的行和块必须完整、SQLite `integrity_check` 为 ok；检查点之后未同步的追加允许丢失，也可能留下 NUL 尾部，单独计数。`writer.log` 已存在时写入器拒绝运行，避免混淆两次实验。

这模拟宿主进程被杀，不模拟 iPad 断电：QEMU 未指定 `cache=`，已交给宿主的写入在 iOS 页缓存中仍会落盘。
