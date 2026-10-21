# DeepSeek Harness for iPad

目标：探索将 DeepSeek Harness 做成可在普通未越狱 iPad 上本地完成项目生产的应用。本项目只公开源码，不发布 IPA；想用的人从源码自行构建、签名安装（见[许可证审查简报](docs/design/license-review-brief.md)）。

当前状态（2026-10-21）：完整功能在独立的候选 App（Harness Candidate，`make candidate-app`）里，已在 iPad 上验收 Linux 项目、Git 开发闭环、插件安装、预览与 HMR、键盘和前后台恢复。正式 App 仍停在基线 `7956e8c`，没有用上新架构。未测项和已知缺口见 [开发交接](docs/agents/handoff.md)。

当前路线图由 [iPad 原生基础能力与 Linux 兼容插件 #15](https://github.com/lvivvde/deepseek-harness-ipad/issues/15) 承载；#1 是历史规划归档。现有应用沿用官方界面，项目放在设备内持久化用户盘。新的“原生优先”候选仍处于方案500研究阶段，正式架构以现有 ADR 为准。

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

执行层和界面桥接已由 [无 JIT 自签 IPA 原型](https://github.com/lvivvde/deepseek-harness-ipad/issues/11) 真机验证；正式入口、内置运行时、独立用户盘及核心恢复已进入 main。代码完成与真实验收分开记录，最新状态见 [开发交接](docs/agents/handoff.md)。Harness 是智能体运行框架；打包应用不等于将 DeepSeek 模型权重放进 iPad。

## 目录

- `ios/`：iPad 应用工程与代码。
- `upstream/`：预留给上游 Harness 源码。
- `docs/`：可行性分析、设计和调试记录。
- `scripts/`：构建与开发辅助脚本。

## 后续步骤

新会话先读 [开发交接](docs/agents/handoff.md)，其中列出主干/已安装包差异、开放任务、已验证和未完成项。真机连接、独立 runner 构建和页面检查使用 [真机自动化工具](docs/validation/ipad-device-automation.md)，本机设备/签名与证据保存在忽略的 `build/`。

架构以 [ADR 0003](docs/adr/0003-native-worker-with-project-linux.md) 为准：官方实验 Worker + Swift 原生权威 + 项目级 Linux。路线图 #15 的 #39、#17、#18、#23 已完成，许可证审查 #14 已有结果。用户取消的锁屏/8 小时测试继续取消。

## 参考资料

- [DeepSeek Harness 官方源码](https://github.com/deepseek-ai/deepseek-harness)
- [Apple：iPadOS 运行时安全与沙盒](https://support.apple.com/guide/security/security-of-runtime-process-sec15bfe098e/web)
- [Apple：向注册设备分发应用](https://developer.apple.com/documentation/xcode/distributing-your-app-to-registered-devices)
