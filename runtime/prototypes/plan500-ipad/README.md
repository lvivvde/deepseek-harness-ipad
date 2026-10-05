# 方案500：独立 iPad 研究 App

研究资产，继续 [Issue32](https://github.com/lvivvde/deepseek-harness-ipad/issues/32) 与 [PR36](https://github.com/lvivvde/deepseek-harness-ipad/pull/36)。
问题：正式 IPA 所用的 iOS QEMU 10.0.12 能否在独立 iPad 沙箱内挂载 9P 工作区，并通过 Swift 连接闸门运行写租约合同的有界子集？[本轮预检结果](../../../docs/research/plan500-ipad-preflight.md)只覆盖 macOS 与设备编译，真机尚未执行。

## 边界

- Bundle ID 固定为 `org.lvivvde.harness.plan500.research`；显示名 `Plan500 Research`。不依赖正式 Harness 或 LinuxPrototype target，不使用共享容器或特殊 entitlement。
- 原生工作区位于此研究 App 的 `Documents/Plan500Research/<随机值>/workspace`，仅含合成文件。guest 只挂载只读 `system.raw`，其系统写入落在 RAM overlay；没有 `user.raw` / `user-seed.raw` / 状态盘输入。
- 使用已有、摘要核验的 lease guest 与 device executor，复用 Swift 网关库和仅重命名的 QEMU 桥。每个 App 进程只调用一次 QEMU。换模式需结束研究 App 进程再打开，不能同进程重启。
- 只绑定 loopback `29450` → guest `4500`。准备好的 token 只留私有 bundle/日志，不显示或提交。Swift `GatedTransport` 在同一实例上串行建立连接并完成一次未认证 403 往返，随后释放闸门，让长命令、取消与通知并发；不自动重试副作用请求。
- build 脚本只生成**未签名 `.app`**，不申请 profile、不签名、不安装、不启动 App。安装前按交接要求另获用户同意；不得为腾出签名名额自动卸载任何现有 App。
- 没有官方 Worker、模型请求、产品 UI 或正式数据迁移。通过这里的检查不等于完整 G3/G4 或 G0–G7 通过。

## 一条命令构建

先使用 [Darwin 探针](../plan500-darwin/README.md)已有的独立 inputs 和 executor；新机器需自行准备同一锁定输入。输出目录必须不存在，且位于本仓库忽略的 `build/`。

```sh
python3 runtime/prototypes/plan500-ipad/build.py \
  --inputs build/prototypes/plan500-darwin/inputs \
  --executor ios/LinuxPrototype/.runtime \
  --output build/prototypes/plan500-ipad/unsigned-new
```

脚本在输出目录生成独立 Xcode 工程、复制公开源码、编译 Release，并核验最终 bundle ID 与输入摘要/文件集合。`ProbeInputs` 只含 Image、initramfs.gz、system.raw、inputs.json、token-private；framework 闭包按现有收据核验，移除继承签名后复制进 App。私有 `build-private.log` 和脱敏 `build-safe.json` 都在同一目录，App 在 `derived/Build/Products/Release-iphoneos/Plan500Research.app`。

模拟器编译可加 `--sdk iphonesimulator`，不带 device QEMU；这不是沙箱文件行为或 Linux 检查。

## 检查与收据

点击“运行隔离检查”，或在**另获安装/启动授权后**使用启动参数 `--plan500-probe --model none`（另一模式为 `mapped-xattr`）。最多等待真实 RPC ready 600 秒；错误时保存已有结果，不登记通过。

15 项必需检查：实际 9P/身份/只读挂载、cgroup/uid/userns 条件、中文双向文件、无租写入拒绝、原生版本冲突、generation、rename/旧 fd、租约期间草稿冲突、超时、取消、12 路并发，以及断连后保留租约、重连确认写者结束后释放。大小写、普通宿主 chmod/symlink、FIFO/socket 和私有符号存在性单列为观察，不计入协议通过数。

`Documents/Plan500Research/<随机值>/result-safe.json` 保存布尔结果与固定名称；`serial-private.log`、`error-private.log` 留在此研究容器。只读取本研究 App 的收据，不从正式 App 复制项目/用户盘。Files 共享只开放研究容器本身，外部修改仍存在既有 CAS TOCTOU 限制。

## macOS 预检同一份检查逻辑

它使用 Homebrew QEMU 进程，不加载 iOS framework，也不声称 iPad 已验。端口 29450 必须空闲；只清理本次启动的 QEMU。

```sh
swiftc runtime/prototypes/plan500-ipad/Sources/HostMain.swift \
  runtime/prototypes/plan500-ipad/Sources/ResearchApp.swift \
  runtime/prototypes/plan500-darwin/gateway/Sources/Plan500Gateway/*.swift \
  -o build/prototypes/plan500-ipad/host-probe
build/prototypes/plan500-ipad/host-probe \
  build/prototypes/plan500-darwin/inputs build/prototypes/plan500-ipad/host-none none
build/prototypes/plan500-ipad/host-probe \
  build/prototypes/plan500-darwin/inputs build/prototypes/plan500-ipad/host-mapped mapped-xattr
swift test --package-path runtime/prototypes/plan500-darwin/gateway
python3 -m unittest discover -s runtime/prototypes/plan500-ipad -p test_build.py
```

两模式必须串行运行。主程序把原始错误留私有文件；完成/失败后均停止自己启动的 QEMU。CLI 收据明确 `physicalDevice=false`。
