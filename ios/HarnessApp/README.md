# DeepSeek Harness App

Swift 包 `DeepSeekHarness` 和 App 外壳。架构见 [ADR 0003](../../docs/adr/0003-native-worker-with-project-linux.md)：官方 Harness 的实验 Web Worker 在 WKWebView 里运行，Swift 是项目文件、只读 Git 和模型请求的唯一权威，Linux 是项目级插件。

## 结构

| 位置 | 内容 |
| --- | --- |
| `App/Sources` | SwiftUI 界面、WKWebView 宿主（`WebHost`）、回环资源服务（`AssetServer`）、终端辅助键排（`TerminalKeyRow`） |
| `Sources/Core`（`HarnessCore`） | 原生权威 `AppHost`、项目登记、VM 接口（iPad 上是进程内 `EmbeddedMachine`，macOS 上是 Homebrew QEMU 子进程 `QemuMachine`）、插件存储 `PackageStore`、内置验收探针 |
| `Sources/Host`（`HarnessHost`） | 项目网关、Linux 启动与就绪证明、Linux 执行与写租约结算 |
| `Sources/Workspace`（`NativeWorkspace`） | 原生工作区的耐久存储 |
| `Sources/LinuxPlugin` | 私有接口检测、插件阶段和能力声明 |
| `Sources/ModelGateway` | 模型请求的增量流式网关 |
| `Sources/NativeTools` | 原生文件、搜索、图片工具和原生只读 Git 宿主 |
| `Tools/` | 测试用的崩溃和恢复探针 |

没有提交的 Xcode 工程。`runtime/app/build.py` 在 `build/app/<输出>/` 下生成工程，链接这个 Swift 包，并把网页根目录、Linux guest 输入（和 iPad 上的 QEMU 执行器）逐个核对哈希后嵌入。

## 构建

先按 [runtime/README.md](../../runtime/README.md) 准备输入，再在仓库根目录：

```sh
make web
make app     # macOS，未签名，输出 build/app/app/
make ipad    # iPad，未签名，输出 build/app/ipad/
make test
```

macOS 版用本机的 `/opt/homebrew/bin/qemu-system-aarch64` 跑 Linux，不随包分发。iPad 版约 1.1 GB，其中 Linux 输入约 1.0 GB。

## 签名并安装到 iPad

签名只用一个私有 JSON 文件，放在忽略的 `build/` 里：

```json
{"DEVELOPMENT_TEAM": "你的团队 ID", "PRODUCT_BUNDLE_IDENTIFIER": "com.example.harness"}
```

- `DEVELOPMENT_TEAM` 必填；`CODE_SIGN_STYLE`、`PROVISIONING_PROFILE_SPECIFIER` 可选。
- `PRODUCT_BUNDLE_IDENTIFIER` 可选，默认 `org.lvivvde.harness.candidate`。同一个 bundle ID 只能属于一个开发者账号，所以自己构建时换成自己的。
- 其他键一律拒绝。

```sh
python3 runtime/app/build.py --sdk iphoneos --signing-file build/my-signing.json --output build/app/ipad-signed
xcrun devicectl device install app --device <设备> build/app/ipad-signed/derived/Build/Products/Release-iphoneos/DeepSeekHarness.app
```

签名的 iPad 构建还会写出 `build/app/ipad-signed/DeepSeekHarness.ipa`，只给自己装（比如用 Xcode 的 Devices 窗口拖进去），不要公开发布。

新 bundle ID 第一次用命令行签名会报 "No Accounts"：先用 Xcode 打开生成的 `build/app/ipad-signed/project/DeepSeekHarness.xcodeproj`，选上团队运行一次，生成描述文件，之后命令行就能复用。构建收据在输出目录的 `build-safe.json`。

## 使用

- 整个窗口就是官方 Harness 界面：左侧栏有新会话、插件和工作区列表，下方输入框选模型和工作区内修改；终端、文件面板和插件管理也都在里面。
- 第一次启动自动建好“默认工作区”（启用 Linux 插件）。在工作区选择器里点“新建文件夹”再打开，就是一个新项目。
- API Key 在官方的首次提示或“设置 → 模型”里输入。Key 只交给 Swift、只留在内存，App 重启后重新输入。
- 右下角的小圆按钮（macOS 也可以用菜单“运行状态…”，⌘⇧I）打开运行状态：会话保存、Linux 状态、开发服务器预览和每个项目的能力声明。需要处理时按钮变成橙色警示。
- 数据在 App 自己的 Application Support 下；`HARNESS_CANDIDATE_ROOT` 启动环境变量可以把数据根指到别处（只用于验证）。

已验证和未验证的项目见 [开发交接](../../docs/agents/handoff.md)。
