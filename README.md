# DeepSeek Harness for iPad

目标：探索将 DeepSeek Harness 做成可在普通未越狱 iPad 上本地完成项目生产的应用，并最终提供可供使用者自行签名安装的 IPA。

当前状态（2026-10-03）：无 JIT 真机原型已跑通官方 Harness、模型调用、本地 Node 测试与持久化 HOME，原型票已关闭。原型代码在 `codex/ipad-linux-prototype` 分支；正式应用尚未实现。已开始 [官方 Harness 的 iPad App 适配 Spec](docs/design/ipad-app-spec.md) 与 [实现任务拆分](docs/design/ipad-app-implementation.md)，目标是安装后直接进入完整官方界面的自签 IPA。

架构与兼容范围的决策由 [本地生产路线地图](https://github.com/lvivvde/deepseek-harness-ipad/issues/1) 及其子议题追踪，研究笔记链接保存在相应研究票中。适配设计沿用官方界面作为整个 App 的主界面，项目放在设备内持久化用户盘；设计与实现任务不等于已经交付正式安装包。

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

执行层和界面桥接已由 [无 JIT 自签 IPA 原型](https://github.com/lvivvde/deepseek-harness-ipad/issues/11) 真机验证；实测范围和限制见 [阶段记录](docs/prototypes/linux-prototype-progress.md)。运行时随 IPA 交付、系统盘与用户盘分离的机制也已 [确认](https://github.com/lvivvde/deepseek-harness-ipad/issues/12)，仍待实现。Harness 是智能体运行框架；打包应用不等于将 DeepSeek 模型权重放进 iPad。

## 目录

- `ios/`：iPad 应用工程与代码。
- `upstream/`：预留给上游 Harness 源码。
- `docs/`：可行性分析、设计和调试记录。
- `scripts/`：构建与开发辅助脚本。

## 后续步骤

- 按适配 Spec 建立全屏官方主界面和应用级运行环境，去掉默认诊断外壳与主页面弹窗。
- 实现内置只读系统盘与独立用户盘，先交付无需手工导入 guest 的开发安装包。
- 结合首版范围与工作区决策，完成 Git 获取、模型修改、测试、提交与推送的本地开发闭环。
- 实现页面与前后台恢复、备份救援，实测资源与他人重签安装链；公开发布前完成执行器归档及对应源码/许可资料。

## 参考资料

- [DeepSeek Harness 官方源码](https://github.com/deepseek-ai/deepseek-harness)
- [Apple：iPadOS 运行时安全与沙盒](https://support.apple.com/guide/security/security-of-runtime-process-sec15bfe098e/web)
- [Apple：向注册设备分发应用](https://developer.apple.com/documentation/xcode/distributing-your-app-to-registered-devices)
