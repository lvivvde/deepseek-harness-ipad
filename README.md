# DeepSeek Harness for iPad

目标：探索将 DeepSeek Harness 做成可在 iPad 上安装和使用的应用，并最终导出签名 IPA。

当前状态：已初始化仓库基础配置、开发环境检查脚本和 CI；尚未下载上游源码、创建 Xcode 工程或构建 IPA。

## 开始开发

```sh
git clone https://github.com/lvivvde/deepseek-harness-ipad.git
cd deepseek-harness-ipad
make doctor
make check
```

完整环境准备步骤见 [开发环境说明](docs/development.md)。仅安装 Command Line Tools 时，`make doctor` 会提示补齐完整 Xcode。

## 待验证的实现路线

1. iPad 客户端：使用 SwiftUI + WKWebView 或原生界面，连接运行在 Mac / 服务器上的 Harness。建议先验证此路线；Harness 执行环境仍在远端。
2. iPad 本机运行：评估嵌入运行时、插件兼容性、文件访问、工具执行以及后台运行限制。需要独立技术验证，不能通过直接打包保证可用。

最终路线尚未确定。Harness 是智能体运行框架；打包应用不等于将 DeepSeek 模型权重放进 iPad。

## 目录

- `ios/`：iPad 应用工程与代码。
- `upstream/`：预留给上游 Harness 源码。
- `docs/`：可行性分析、设计和调试记录。
- `scripts/`：构建与开发辅助脚本。

## 后续步骤

- 确认目标是远端客户端还是本机运行，以及需要保留哪些工具能力。
- 获取上游源码并记录具体版本，核查依赖和前后端接口。
- 准备完整 Xcode 和 iPad 测试环境；当前检查到的开发工具路径为 `/Library/Developer/CommandLineTools`。
- 创建最小应用，先验证连接、会话和流式响应，再验证真机安装与 IPA 导出。
- IPA 真机安装需要适合所选分发方式的签名与描述文件。

## 参考资料

- [DeepSeek Harness 官方源码](https://github.com/deepseek-ai/deepseek-harness)
- [Apple：iPadOS 运行时安全与沙盒](https://support.apple.com/guide/security/security-of-runtime-process-sec15bfe098e/web)
- [Apple：向注册设备分发应用](https://developer.apple.com/documentation/xcode/distributing-your-app-to-registered-devices)
