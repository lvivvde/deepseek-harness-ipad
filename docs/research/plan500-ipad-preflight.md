# 方案500：iPad 研究 App 的安装前预检

2026-10-06，北京时间。继续 [Issue32](https://github.com/lvivvde/deepseek-harness-ipad/issues/32)、研究分支和 draft [PR36](https://github.com/lvivvde/deepseek-harness-ipad/pull/36)。用户要求“继续执行”，按 [Darwin 报告](plan500-darwin.md)下一关口准备独立研究 App；[源码与复跑入口](../../runtime/prototypes/plan500-ipad/README.md)。

## 当前结论

**独立研究 App 已完成 iPhoneOS Release 构建及真实签名核验；同一份 15 项检查在 macOS 真实 QEMU 两种 9P 模式下均通过。用户已授权签名安装，但安装被免费开发 App 名额限制拒绝；尚未安装或在 iPad 上执行。**

Swift 连接闸门已从 Python 中继移入 `GatedTransport`。它在同一 TCP 连接上完成未认证的 403 往返并读完响应，确认 libslirp 已 accept 后释放连接锁。后续 `/execute`、`/cancel`、`/notify` 可以并发，丢失回复保留不确定状态，不自动重跑。

研究 App bundle ID 为 `org.lvivvde.harness.plan500.research`，显示名 `Plan500 Research`，与正式 Harness 和旧 LinuxPrototype 不同。使用自己的 Documents 合成目录、只读系统盘与 RAM overlay，没有用户盘。未改变正式应用、ADR/CONTEXT 或 #17 的依赖条件。

## 已执行验证

| 检查 | 结果与范围 |
| --- | --- |
| 只读设备 probe | 已连接、已配对、已解锁，正式 Harness 已安装；不启动或安装应用 |
| Swift 网关测试 | 15/15：原有 11 项及 4 项真实 socket 测试；backlog 1 / 分段 chunked 403 / 12 路并发、长请求期间取消、断连不重试且保持租约、409 与畸形 proof |
| 构建输入拒绝测试 | 4/4：拒绝 user.raw 字段、变更系统盘、过期 agent 源码、篡改执行器/额外 framework |
| 同一检查逻辑，macOS QEMU `none` | 15/15；原生与 Linux 双向文件、版本冲突、真实只读/uid/cgroup、generation、旧 fd、草稿、超时、取消、并发、断连保租和重连释放 |
| 同一检查逻辑，macOS QEMU `mapped-xattr` | 15/15；与上行相同，直接使用 Swift gate，不经过 Python 中继 |
| 完整 device App | iPhoneOS Release 编译通过，最终 bundle ID、guest 输入集合/摘要核验；App 和复制后的 frameworks 均无签名 |

未签名 App 的逻辑文件约 1.190 GB（十进制），不是 IPA 压缩体积或设备安装占用。guest 输入固定为既有 Darwin inputs；执行器固定为 UTM 构建的 QEMU 10.0.12 iOS framework 闭包。macOS 运行仍使用 Homebrew QEMU 11.1.2，不能代替 iOS 执行。

## 兼容性观察

macOS 默认卷上仍复现此前发现：只差大小写的名字合并；`none` 保留普通 host chmod/symlink，但不能在共享工作区创建 FIFO/socket；`mapped-xattr` 能在 guest 内创建 FIFO/socket，但宿主权限/链接类型不普通。这些观察不计入 15 项必需检查通过数。

本轮 App 检查是有界子集，不是旧 26 项合同的完整重跑：尚未覆盖真机 VM 退出、网关 SIGKILL、同 uid `/proc` 绕过、SCM_RIGHTS、完整 Git/hook 或 watch 行为。已知 CAS TOCTOU、同 uid 绕过等缺口仍存在。网关未接官方 Worker；模型、网络、性能与内存占用也未验证。

## 当前关口与下一步

1. 用户已同意独立研究 App 的签名、安装与隔离检查。签名/profile 已核验，当前待解决免费开发 App 名额；卸载独立验收 runner 仍需明确同意，不能自动卸载现有 App 或替换正式 Harness。
2. 在 iPad 前台分别运行两种模式，每种只启动一次 QEMU；换模式时只结束研究 App 进程。读取此独立容器的脱敏收据，单列沙箱与私有符号行为。
3. 完成 iPad 证据后继续官方 Worker 的 Swift 网关接入及模型/网络，随后在 #32 形成用户架构决定。

G3/G4 与完整 G0–G7 未通过；#32 OPEN、#17 保持依赖。正式安装代码仍为 `7956e8c`，签名截止仍为 2026-10-12 15:49:52（北京时间）；取消的锁屏/8 小时测试继续取消。

私有资产：`build/prototypes/plan500-ipad/unsigned-final/`（构建与摘要收据）、`host-none-final/`、`host-mapped-final/`（各随机子目录中的 result-safe.json、串口、QEMU 日志）；网关测试日志在 `build/prototypes/plan500-darwin/gated-tests-private.log`。不发布 profile、设备标识、token 或原始日志。

## 2026-10-06 已授权签名与安装尝试

用户明确同意使用本机现有开发团队为独立研究 App 签名、安装并运行隔离检查。

- 命令行 Xcode 报 `No Accounts` 与缺少新 bundle ID 的 profile；独立私有工程在 Xcode GUI 中 Build 成功，生成了研究 App 专属 profile。没有启动或构建正式 App 目标。
- 已验证 `codesign --verify --deep --strict`、App bundle ID、签名团队与 profile、证书包含关系、钥匙串组和当前 iPad 的设备授权；权限仅为普通开发签名，没有共享 App group 或额外运行时能力。最终五项 ProbeInputs 集合及三个 guest 文件摘要与锁定输入一致。
- 实际研究 App 的较早签名截止：**2026-10-13 01:02:35（北京时间）**。此日期只属于研究 App；正式 Harness 仍为 2026-10-12 15:49:52。
- CoreDevice 安装命令失败，明确为“免费开发签名 App 数量上限”。只读应用清单确认正式 Harness、LinuxPrototype、独立 DeviceAcceptance runner 均已安装，研究 bundle ID 未安装。
- 没有卸载、替换、启动现有 App，也没有运行研究 guest 或复制正式数据。建议在明确获准后仅卸载 `org.lvivvde.harness.acceptance.xctrunner` 以腾出名额，再安装已校验研究 App；这会删除 runner 自己的测试容器，并暂时移除 UI 验收工具，正式 Harness 与 LinuxPrototype 保留。

签名、profile、设备、Xcode 与安装原始日志留在忽略的 `build/prototypes/plan500-ipad/device-r1/`；从 `signing-safe.json`、`slot-audit-safe.json` 开始接手。签名 App 在 `gui-products/Release-iphoneos/Plan500Research.app`。安装与真机检查仍未通过，#32 OPEN、#17 保持依赖。
