# Harness iPad 正式应用入口

对应 [正式应用实现任务](https://github.com/lvivvde/deepseek-harness-ipad/issues/16) 与 [适配 Spec](../../docs/design/ipad-app-spec.md)。当前包含独立 Xcode 工程、应用级运行环境、真实 QEMU 桥接和全屏官方页面宿主；完整 guest 的构建、打包和验收记录见 [内置运行时](../../runtime/README.md)。

Bundle ID 为 `org.lvivvde.harness.ipad`，与技术原型不同。项目和凭据只属于此 App 自己的用户盘；不读取或升级原型 App 数据。

## 构建与测试

在仓库根目录执行：

```sh
xcodebuild -project ios/HarnessApp/HarnessApp.xcodeproj \
  -scheme HarnessApp -sdk iphoneos \
  -derivedDataPath /tmp/harness-app-build CODE_SIGNING_ALLOWED=NO build
make test-app
```

Debug 缺少完整运行时输入时允许编译，App 显示明确的缺少运行时状态。设备 Release 构建缺少任一输入会失败，避免把不含运行时的包当作可用产品。模拟器只可检查原生状态界面，不能运行 iOS device QEMU。

个人签名身份写入忽略的 `Signing.local.xcconfig`，或在 Xcode 中配置。不要提交 Team、设备标识、描述文件或 Key。带完整运行时的本地开发签名 IPA 已生成；真机各项验收与未完成项目见运行时记录。

## 给运行时构建的接入契约

执行器与 guest 分开准备，通过 Xcode build setting 传入目录，不需要把机器路径写入工程：

```sh
xcodebuild -project ios/HarnessApp/HarnessApp.xcodeproj \
  -scheme HarnessApp -sdk iphoneos \
  -derivedDataPath /tmp/harness-app-build CODE_SIGNING_ALLOWED=NO \
  HARNESS_EXECUTOR_DIR=/path/to/prepared-executor \
  HARNESS_GUEST_DIR=/path/to/bundled-guest build
```

默认目录分别是本工程的 `.runtime/` 和 `.runtime/Guest/`，均已忽略。

执行器输入沿用原型 `prepare-runtime.py` 输出布局：

```text
prepared-executor/
  Frameworks/qemu-aarch64-softmmu.framework/qemu-aarch64-softmmu
  Frameworks/<实际依赖闭包>.framework/
  qemu/<执行器提供的支持文件；virt 直接启动无需嵌入固件>
```

新的自建执行器也应提供相同共享库入口 `qemu_init`、`qemu_main_loop`、`qemu_cleanup` 与框架依赖闭包。应用代码不负责下载或重新编译 UTM。

Guest 输入目录放 `runtime.json` 与四个命名资源。格式见 [runtime.example.json](runtime.example.json)；文件名必须是单个安全文件名，版本为 1，内存范围 128–2048 MiB。构建只复制清单中这四个文件和清单本身，额外日志、备份或状态文件不进入 bundle。

- `kernel`：aarch64 virt 内核，串口 `ttyAMA0`。
- `initramfs`：含 `/init`，启动参数 `console=ttyAMA0 rdinit=/init`。
- `systemDisk`：第一张 virtio raw ext4 盘，QEMU 以只读方式打开；guest init 完成系统挂载与运行目录准备。
- `userDiskSeed`：第二张 virtio raw ext4 盘的全新种子。原生首次复制到应用的 `Application Support/HarnessRuntime/user.raw`；后续沿用，不替换。guest init 必须完成 `/root` 挂载、布局版本检查与异常盘救援，不能在失败时退回 RAM home 冒充持久化成功。

Guest 保留原型已验证的网络关系：官方 dsh 监听 guest loopback `3001`，guest relay 从网卡端口 `2999` 转接；设备 `127.0.0.1:28080` 转发到 guest `2999`。官方完整启动行 `dsh web: http://127.0.0.1:3001/?token=…` 从串口发出，应用只替换端口，不重写官方鉴权。init 可打印 `HARNESS_INIT_READY` 更新启动阶段。

## 生命周期与诊断

App 持有唯一运行环境，页面和授权子窗口不控制 VM 启停。主页面作为根视图；辅助窗口用于设置、项目、导入/导出和诊断，关闭它们不移除主页面或停止 VM。

启动与恢复使用无缓存、本机限定的 HTTP 探测，只有 200 且包含 `__DSH_BOOT__` 才判定官方页面就绪。WebView 等真实 `#root` 文本绘制后显示；导航失败/绘制超时有重试状态，不无期限展示白屏。

页面进程退出时重连已有环境；回前台检查 HTTP，正常页面不主动重载。QEMU 退出是终止状态，旧桥接不得在同进程内再次调用。后台只尝试有限时间的 guest sync，不承诺后台永久执行。

串口和 QMP 使用预创建的 Unix socketpair；有限时的前台恢复先检查 VM、guest 时间和用户盘，再按层修复 Harness 或页面转发。长后台真机恢复仍待验收。诊断只含固定阶段事件，不保存串口原文、启动 URL、网页正文或网络错误文本。

## 项目管理、回收站与导出/导入

官方界面就绪后，屏幕边缘的悬浮按钮（可上下拖动、吸附左右两侧）提供项目管理、导入、回收站、端口预览、iPad 应用设置与诊断；外接键盘时菜单栏“项目”另有 ⌘⇧E（项目管理）/ ⌘⇧I（导入）。

- 项目管理列出 `/root/projects` 下的目录（中文、空格均可，隐藏目录除外）。点项目可导出或移到回收站，也可左滑删除。项目与回收站行使用 UIKit 按钮承载文字和菜单，菜单锚定当前行。
- 导出生成 `<名称>-<时间>.tar` 与 `sha256sum` 格式的 `.sha256`，经“文件”App 存储；不含 `node_modules` 与 `.cache`，Git 凭据不在项目目录内。导入可同时选择校验文件，不一致时不上传。
- 回收站在同一用户盘的 `/root/.trash`，移入与恢复都是改名，不复制数据；恢复时原名被占用则追加 `-2`。彻底删除与清空需再次确认，先从列表移除，磁盘删除在后台完成，中断后下次启动继续。回收站不会自动清空。
- 移到回收站前，通过官方注册表停止并归档该项目的会话、移除对应工作区（包括子目录工作区），侧栏收到官方变更通知；旧会话不能再继续模型步骤并重建目录。归档保留会话历史。官方同步失败时不移动文件，显示明确错误。
- 清空和彻底删除还会清理旧版回收站遗留的工作区登记；以删除时间为界，不移除后来新建的同名工作区。恢复项目后需在官方侧栏重新登记；旧会话保留在归档中，不自动重新启动。

## 验收状态

核心状态与文件契约由 Swift 测试覆盖；Xcode 编译验证原生代码的类型与链接。真机全屏交互、官方鉴权、键盘/触控、后台恢复和新运行时磁盘启动，必须在完整运行时接入后单独验收。相关实现任务保持开放，直到有真实设备证据。

## 用户盘容量与空间提醒

悬浮工具按钮 →“iPad 应用设置…”可查看用户盘上限、实际占用和 iPad 剩余空间，手动增大至 16、32 或 64 GB；不自动扩容、不支持缩小。当前容量可再次确认，用于完成上次中断的扩容。

确认框先说明空间与不可缩小的约束；iPad 剩余空间低于 2 GiB 时显示提醒并阻止扩容。前台每 15 秒检查一次空间，低空间横幅可打开设置。扩容只增加稀疏尾部，后续真实写入仍需要 iPad 空间。

运行中由 QMP `block_resize` 增大唯一用户盘，再通过认证服务协调在线 `resize2fs`，不重启 Harness。与备份/恢复冻结共享互斥租约，文件系统扩容进程退出前不释放锁。QMP/网络失败不缩回原盘，重试当前容量或重开 App 可完成文件系统扩容。设置与空间横幅仍需新包真机确认，详见 [存储与工具验证](../../docs/validation/ipad-storage-tools.md)。

Release 构建仅对复制到 App 的 framework 去掉本地/调试符号，保留动态导出；原始执行器输入不修改。aarch64 virt 直接启动 Linux 内核，网卡显式禁用 PXE ROM，不嵌入其他架构的 BIOS/UEFI 固件。这些体积调整仍需新包真机回归。
