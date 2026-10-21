# DeepSeek Harness for iPad

目标：探索将 DeepSeek Harness 做成可在普通未越狱 iPad 上本地完成项目生产的应用。本项目只公开源码，不发布 IPA；想用的人从源码自行构建、签名安装（见[许可证审查简报](docs/design/license-review-brief.md)）。

当前状态（2026-10-21）：只有一个 App，**DeepSeek Harness**。已在 iPad 上验收 Linux 项目、Git 开发闭环、插件安装、预览与 HMR、键盘和前后台恢复；未测项和已知缺口见 [开发交接](docs/agents/handoff.md)。旧的正式 App 和研究原型已退役，代码在 Git 历史里（[合并方案](docs/design/single-app-plan.md)）。

架构见 [ADR 0003](docs/adr/0003-native-worker-with-project-linux.md)：官方 Harness 的实验 Web Worker 在 WKWebView 里运行，沿用官方界面；Swift 原生层是项目文件、只读 Git 和模型请求的唯一权威；Linux 是项目级插件，在 App 进程内的 QEMU（无 JIT）里运行 shell、Git 写操作和开发服务器。Harness 是智能体运行框架，App 不包含 DeepSeek 模型权重，模型经网络调用。

## 从源码构建

需要 macOS、完整 Xcode 和 Node。先检查环境：

```sh
git clone https://github.com/lvivvde/deepseek-harness-ipad.git
cd deepseek-harness-ipad
make doctor
```

| 命令 | 作用 |
| --- | --- |
| `make web` | 从固定的官方包生成 App 的网页根目录 |
| `make app` | 构建未签名的 macOS App（用本机 Homebrew QEMU） |
| `make ipad` | 构建 iPad App，嵌入 QEMU 执行器 |
| `make test` | 运行全部无需设备的测试 |
| `make check` | 检查脚本语法和空白错误 |

`make web` 和 `make ipad` 需要先准备依赖、Linux guest 和 QEMU 执行器，步骤见 [Linux 运行时与 App 构建输入](runtime/README.md)；签名和安装见 [App 说明](ios/HarnessApp/README.md)。完整环境准备见 [开发环境说明](docs/development.md)。

## 约束

项目文件操作、Git、命令、验证和受支持插件都在 iPad 本地完成；只有模型请求联网。首版限定了项目类型和插件兼容范围，见 [能力声明](docs/design/capability-declaration.md)。

## 目录

- `ios/HarnessApp/`：Swift 包和 App 外壳。
- `runtime/`：网页根目录生成、App 构建、Linux guest 和执行器的构建脚本。
- `docs/`：架构决策、设计、验收记录和研究报告。
- `scripts/`：开发环境检查。

## 后续开发

新会话先读 [开发交接](docs/agents/handoff.md)。真机连接和容器读取见 [真机自动化工具](docs/validation/ipad-device-automation.md)，本机设备、签名和证据都放在忽略的 `build/`。

## 参考资料

- [DeepSeek Harness 官方源码](https://github.com/deepseek-ai/deepseek-harness)
- [Apple：iPadOS 运行时安全与沙盒](https://support.apple.com/guide/security/security-of-runtime-process-sec15bfe098e/web)
- [Apple：向注册设备分发应用](https://developer.apple.com/documentation/xcode/distributing-your-app-to-registered-devices)
