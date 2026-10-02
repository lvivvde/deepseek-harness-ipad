# DeepSeek Harness for iPad

目标：探索将 DeepSeek Harness 做成可在普通未越狱 iPad 上本地完成项目生产的应用，并最终提供可供使用者自行签名安装的 IPA。

当前状态：已初始化仓库基础配置、开发环境检查脚本和 CI；尚未下载上游源码、创建 Xcode 工程或构建 IPA。

当前先规划移植方案。架构与兼容范围的决策由 [本地生产路线地图](https://github.com/lvivvde/deepseek-harness-ipad/issues/1) 及其子议题追踪，研究笔记链接保存在相应研究票中。

## 开始开发

```sh
git clone https://github.com/lvivvde/deepseek-harness-ipad.git
cd deepseek-harness-ipad
make doctor
make check
```

完整环境准备步骤见 [开发环境说明](docs/development.md)。仅安装 Command Line Tools 时，`make doctor` 会提示补齐完整 Xcode。

## 移植约束与待验证路线

2026-10-02 已确认：项目文件操作、Git、命令、验证和受支持插件执行均须在 iPad 本地完成；允许联网调用模型。首版可以限定项目类型与插件兼容范围，但必须完成项目获取、修改、验证与提交的本地开发闭环。

已选完整 Linux 系统软件模拟作为原型验证方向，保留官方 Harness 运行方式与 Web 界面；分层、语言及验证门槛见 [架构基线](docs/design/architecture-candidates.md)。远端执行客户端不满足当前约束。

架构基线已选定，尚未构建或真机验收；下一步由 [无 JIT 自签 IPA 原型](https://github.com/lvivvde/deepseek-harness-ipad/issues/11) 核实执行层和界面桥接。Harness 是智能体运行框架；打包应用不等于将 DeepSeek 模型权重放进 iPad。

## 目录

- `ios/`：iPad 应用工程与代码。
- `upstream/`：预留给上游 Harness 源码。
- `docs/`：可行性分析、设计和调试记录。
- `scripts/`：构建与开发辅助脚本。

## 后续步骤

- 先验证已选本地执行架构，再通过路线地图明确首版兼容范围及保留的工具能力。
- 获取上游源码并记录具体版本，核查依赖和前后端接口。
- 准备完整 Xcode 和 iPad 测试环境；当前检查到的开发工具路径为 `/Library/Developer/CommandLineTools`。
- 方案明确后，按决策票中的验证门槛开展技术原型，再进入应用实现。
- IPA 真机安装需要适合所选分发方式的签名与描述文件。

## 参考资料

- [DeepSeek Harness 官方源码](https://github.com/deepseek-ai/deepseek-harness)
- [Apple：iPadOS 运行时安全与沙盒](https://support.apple.com/guide/security/security-of-runtime-process-sec15bfe098e/web)
- [Apple：向注册设备分发应用](https://developer.apple.com/documentation/xcode/distributing-your-app-to-registered-devices)
