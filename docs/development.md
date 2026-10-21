# 开发环境

## 环境检查

在仓库根目录执行：

```sh
make doctor
make check
```

`doctor` 检查 Git、Swift、完整 Xcode、iOS SDK、模拟器工具、Node 和 Python 3，并提示 macOS 版要用的 Homebrew QEMU。缺少必需工具时以非零状态退出，不会安装软件或修改系统设置。`check` 检查脚本语法及暂存区、工作区的空白错误。

## 准备 Xcode

1. 安装完整 Xcode，首次打开并完成许可确认及组件安装。
2. 在 Xcode 设置中安装 iOS 平台。
3. 如果 `xcode-select -p` 仍指向 Command Line Tools，可只在当前终端指定 Xcode：

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
make doctor
```

Xcode 装在别处时调整路径。这个设置只影响当前终端；也可以在 Xcode 的 Locations 设置里选择完整 Xcode。

## 构建路径

只有一条：

1. 准备依赖、Linux guest（`build/guest`）和 QEMU 执行器（`build/executor`），见 [Linux 运行时与 App 构建输入](../runtime/README.md)。guest 要在 Linux 上构建。
2. `make web` 生成网页根目录 `build/app/Web`。
3. `make app` 构建 macOS 版，或 `make ipad` 构建 iPad 版。签名和安装见 [App 说明](../ios/HarnessApp/README.md)。

`make test` 不需要设备。其中的 Worker 恢复测试读 `build/app/Web`，所以先运行一次 `make web`。

## 凭据与签名

DeepSeek API Key 只在 App 里输入，只留在内存，App 重启后要重新输入。Git token 在 iPad 终端的 git 提示处输入。不要把 Key、token、签名团队、设备标识或描述文件写进仓库；私有签名文件、构建产物和设备证据都放在忽略的 `build/`。
