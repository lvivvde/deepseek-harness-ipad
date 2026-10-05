# DeepSeek Harness for iPad

目标：探索将 DeepSeek Harness 做成可在普通未越狱 iPad 上本地完成项目生产的应用，并最终提供可供使用者自行签名安装的 IPA。

当前状态（2026-10-05）：正式 Harness App 的入口、内置 Linux 运行时、独立用户盘、备份恢复和存储工具已进入 main。最近验证的 iPad 安装基线为 `7956e8c`，包含导出中断修复；覆盖安装前后的 83 个文件一致，冷启动及重启后的首次导出复测通过。签名截止为 2026-10-12 15:49:52（北京时间），后续须按实际签名检查维护。完整开发闭环及未完成的真机验收见 [开发交接](docs/agents/handoff.md)。

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

当前先推进现有版本维护 #19 与[方案500架构研究 #32](https://github.com/lvivvde/deepseek-harness-ipad/issues/32)。研究候选为官方实验 Worker + Swift 工作区桥 + Linux 能力网关：macOS Worker 持久化探针已通过，真实 Linux 的两种共享模式各通过 23 项协议检查，但跨域锁和文件通知等共享语义仍有缺口。详细结果见[可行性研究](docs/research/plan500-feasibility.md)与[共享工作区/RPC 报告](docs/research/plan500-sharing-rpc.md)，代码保存在[草稿 PR36](https://github.com/lvivvde/deepseek-harness-ipad/pull/36)。

下一研究关口是统一写租约、版本冲突与变更通知/轮询，然后补 Darwin/iPad 和真实模型路径。#17 实现仍等待 #32 的架构决定；开发闭环 #18、交互验收 #23 和发布审查 #14 按依赖推进。用户取消的锁屏/8 小时测试继续取消，公开发布仍待对应源码与许可证审查。

## 参考资料

- [DeepSeek Harness 官方源码](https://github.com/deepseek-ai/deepseek-harness)
- [Apple：iPadOS 运行时安全与沙盒](https://support.apple.com/guide/security/security-of-runtime-process-sec15bfe098e/web)
- [Apple：向注册设备分发应用](https://developer.apple.com/documentation/xcode/distributing-your-app-to-registered-devices)
