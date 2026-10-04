# 原生项目菜单截图回归

从 `ProjectTransferView.swift` 提取实际 `ProjectRowMenu` 和 UIKit 适配器，编译到独立 Simulator 夹具。夹具没有 QEMU、用户盘、网络或正式 App 启动代码，测试不需要签名账号。

启动一个 iPad Simulator 后，从仓库根执行：

```sh
python3 ios/HarnessApp/scripts/test-native-menu.py \
  --simulator <booted-iPad-Simulator-UUID> --output /tmp/harness-native-menu-new
```

输出目录必须不存在。构建和测试日志、`menus.xcresult` 保存在该目录，命令只打印固定结果。工具不选择真机，也不启动或终止正式 Harness App。

测试分别打开浅色、深色的项目和回收站菜单，确认菜单项存在，并用 Vision OCR 检查菜单打开后的屏幕仍实际绘制对应行标题。仅检查 `XCUIElement.exists` 不够：修复前的 UIButton 标签被菜单隐藏，但辅助功能节点仍存在，旧检查会误判通过。截图附在 xcresult 内。

本回归验证原生行文字的呈现，不代替真机操作、官方侧栏同步、菜单动作的数据集成或实际恢复验收。
