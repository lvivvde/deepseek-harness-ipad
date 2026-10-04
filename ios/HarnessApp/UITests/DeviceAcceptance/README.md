# 独立真机 UI runner

接手和执行步骤见 [真机自动化](../../../../docs/validation/ipad-device-automation.md)。默认 `page` 只检查已运行的正式 Harness；CLI 仅选择一个方法。工程没有正式 App target/dependency，App 已退出则保留证据，不自动重开。

项目不含团队、设备或 profile 设置。把本机设置、签名产物和 XCTest 日志放到仓库忽略的 `build/`。不要将 runner 的 bundle ID 改为正式 Harness 或 LinuxPrototype。

Home 切换和已有会话请求是显式选择；在普通 Xcode 全测试中会跳过。当前后续锁屏已被用户取消。测试不读取用户 raw 盘、不替用户输入 token、不清理现有草稿。
