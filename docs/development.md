# 开发环境

当前仓库是 iPad 应用的起始骨架，尚未包含 Xcode 工程或上游 Harness 源码。

## 环境检查

在仓库根目录执行：

```sh
make doctor
make check
```

`doctor` 检查 Git、Swift、完整 Xcode、iOS SDK 和模拟器工具；缺少必需工具时以非零状态退出，不会安装软件或修改系统设置。`check` 检查辅助脚本语法及暂存区、工作区的空白错误，可在 macOS 和 Linux 运行。

## 准备 Xcode

1. 安装完整 Xcode，首次打开并完成许可确认及组件安装。
2. 在 Xcode 设置中安装需要的 iOS 平台和模拟器运行时。
3. 如果 `xcode-select -p` 仍指向 Command Line Tools，可仅在当前终端指定 Xcode 路径：

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
make doctor
```

如果 Xcode 安装在其他位置，请调整路径。此设置只影响当前终端；后续终端需重新设置，或在 Xcode 的 Locations 设置中选择 Command Line Tools 对应的完整 Xcode。

## 项目与依赖

- `ios/` 预留给应用工程，待确认客户端路线后创建。
- `upstream/` 预留给上游源码；可将独立源码检出放到 `upstream/deepseek-harness/`，该路径不会纳入本仓库。
- 上游依赖和版本应在获取源码、确认实现路线后记录；当前不安装 Node、Python 等尚未确定的运行时依赖。
- 当前 CI 只验证仓库基础配置和脚本，尚不能验证 iPad 应用编译。

## 凭据与签名

DeepSeek API Key 等凭据只保存在本机或后续约定的安全存储中。`.env`、签名私钥、描述文件和构建产物已加入忽略规则。未来如果需要环境变量，应提供不含真实密钥的 `.env.example` 并说明用途。

真机安装和 IPA 导出还需要配置 Apple 开发账户、签名团队及适合分发方式的描述文件。不要将这些凭据提交到公开仓库。
