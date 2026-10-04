# 真机连接与 UI 自动化

工具入口：`python3 ios/HarnessApp/scripts/device-acceptance.py --help`。项目是独立 UI-testing runner，不依赖、构建或安装正式 Harness。CLI 日志、设备 JSON、xcresult 只保存到本地私有输出目录，终端只报告固定结果。

## 先只读连接

```sh
python3 ios/HarnessApp/scripts/device-acceptance.py probe
```

工具自动选唯一已连接、已配对的物理 iPad，读取锁定状态和正式 Harness 的安装状态。无设备、未配对或多设备会报固定阻塞；多设备用 `--device-file build/device-acceptance/selected-device-private.json` 指定本地 JSON 的 `identifier`，不要打印其值。不会自动配对、索要密码、安装或启动 App。

`status` 仅复制正式 App 的固定 `RuntimeStatus.json`，不访问用户盘文件：

```sh
python3 ios/HarnessApp/scripts/device-acceptance.py status
```

锁定或未安装时停止。状态文件可能来自旧启动，不能独自证明当前进程存活或恢复完成；累计启动耗时不是恢复时间。输出的未知阶段会变为 `UNRECOGNIZED_STAGE`，原文件留私有目录。

## 构建独立 runner

无设备、无账号也能做编译检查：

```sh
python3 ios/HarnessApp/scripts/device-acceptance.py build \
  --output build/device-acceptance/unsigned-new
```

真机运行必须有匹配本 runner 的签名。把本机设置放在忽略的 `build/device-acceptance/local-settings.json`，例如：

```json
{"DEVELOPMENT_TEAM": "YOUR_LOCAL_TEAM"}
```

只接受 `DEVELOPMENT_TEAM`、`CODE_SIGN_STYLE`、`PROVISIONING_PROFILE_SPECIFIER`。它是私有配置，不进入命令输出、源码或 PR；CLI 不自动申请在线 provisioning。

```sh
python3 ios/HarnessApp/scripts/device-acceptance.py build \
  --signing-file build/device-acceptance/local-settings.json \
  --output build/device-acceptance/signed-new
```

输出目录必须不存在；xctestrun 在 `signed-new/derived/Build/Products/`。每次改测试源码后重建 runner；不需要重打正式 IPA。

CLI 报 `No Accounts` 不等于 Xcode GUI 没登录。曾通过 GUI Personal Team 的 Build For Testing 创建匹配 profile，再由 CLI 复用缓存签名。若仍缺 profile：把 `UITests/DeviceAcceptance/` 复制到忽略的 `build/device-acceptance/gui-runner/`，在 Xcode 打开该副本并选择本机团队，对 **DeviceAcceptance** 执行 Product → Build For → Testing。私有团队设置只改副本。可用下面的辅助功能脚本触发该独立窗口构建/读取固定状态；它需要本机辅助功能权限：

```sh
swift ios/HarnessApp/scripts/xcode-ui/xcode-build-runner.swift
swift ios/HarnessApp/scripts/xcode-ui/xcode-test-status.swift
```

GUI helper 不能确认目标签名成功，最终以构建产物/CLI 结果为准。保留 GUI 辅助构建，不保留旧的 GUI“运行全部测试”脚本，避免不经选择就发请求。

## 运行一个明确检查

把实际生成的 xctestrun 路径传给 CLI，输出目录可省略或使用新的目录：

```sh
python3 ios/HarnessApp/scripts/device-acceptance.py run \
  --xctestrun <signed-build/derived/Build/Products/file.xctestrun> \
  --check page
```

工具先检查连接/锁定/安装，拒绝带正式 App 依赖的 xctestrun，保留独立 runner 自身的两个产品依赖；移动配置时解析 `__TESTROOT__`。只执行所选测试，设置 `UseUITargetAppProvidedByTests=true`。

| check | 操作与结果边界 |
| --- | --- |
| `page`（默认） | 只激活已经运行的正式 App，检查遮罩/失败文字/WebView/可用输入；不输入、不发送。App 不运行或状态未知则失败，不自动冷启动。 |
| `settings` | 打开/关闭原生设置，确认容量/备份/恢复入口；不扩容、备份、恢复或修改输入。 |
| `short-background` | 显式 Home 3 秒再返回，并断言原输入值相同；不是物理锁屏。当前用户已取消后续此类恢复安排，接手时不默认运行。 |
| `session-reply` | 显式在空输入的已有会话发一次固定请求，观察生成控件与 `RECOVERY_OK`；非空草稿、已存在标记或未识别 Send 则跳过。需要当前任务授权，API Key 使用已有设备配置，不输入 token。 |

后两项还在测试内部要求显式环境选择，误点 Xcode 的全部测试时会跳过。没有删除草稿、卸载 App、清空数据、强杀正式 App或物理锁屏测试。`CHECK_COMPLETE` 必须伴随对应完成标记；跳过返回退出码 2，不能记为通过。失败码 1，原始细节留 `*-private.log`；退出码 0 才是命令完成。

免费个人团队可能只有少量签名 App 名额。`RUNNER_APP_SLOT_FULL` 时明确报告阻塞；任何指定 App 卸载及其数据删除需要用户明确授权，不能自动卸载 Harness/LinuxPrototype。过去只在授权后卸载了 Breeze，这不构成后续卸载授权。

`UI_AUTOMATION_AUTHORIZATION_TIMEOUT` 表示测试初始化未完成；需要设备端授权或解锁时，给用户一次简短步骤。不把安装、编译、初始化超时登记为恢复失败或测试通过。当前连接 probe 已实际成功；锁屏后的 UI 测试必须等到用户自行正常解锁，不主动催促已取消的验收。

## 验证和隐私

```sh
make test-device-tools
make check
```

无设备测试覆盖多设备歧义、断开/模拟器拒绝、旧/新 Xcode JSON、正式 App 依赖拒绝、移动 runner 配置、固定阶段/错误脱敏。原始日志、签名配置和截图均不公开；对外仅给出结论、范围、耗时与固定阶段。跨机器需要新的配对/权限和该机器的签名条件，已有开发授权不是可搬迁的文件。
