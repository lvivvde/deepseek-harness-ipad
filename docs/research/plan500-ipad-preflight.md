# 方案500：iPad 研究 App 的安装前预检

2026-10-06，北京时间。继续 [Issue32](https://github.com/lvivvde/deepseek-harness-ipad/issues/32)、研究分支和 draft [PR36](https://github.com/lvivvde/deepseek-harness-ipad/pull/36)。用户要求“继续执行”，按 [Darwin 报告](plan500-darwin.md)下一关口准备独立研究 App；[源码与复跑入口](../../runtime/prototypes/plan500-ipad/README.md)。

## 当前结论

**独立研究 App 已完成未签名的 iPhoneOS Release 构建；同一份 15 项检查在 macOS 真实 QEMU 两种 9P 模式下均通过。没有签名、安装或在 iPad 上执行。**

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

1. 安装前另获用户同意，确认独立 bundle ID 的签名/profile 和研究 App 安装；没有授权自动卸载现有 App 或替换正式 Harness。
2. 在 iPad 前台分别运行两种模式，每种只启动一次 QEMU；换模式时只结束研究 App 进程。读取此独立容器的脱敏收据，单列沙箱与私有符号行为。
3. 完成 iPad 证据后继续官方 Worker 的 Swift 网关接入及模型/网络，随后在 #32 形成用户架构决定。

G3/G4 与完整 G0–G7 未通过；#32 OPEN、#17 保持依赖。正式安装代码仍为 `7956e8c`，签名截止仍为 2026-10-12 15:49:52（北京时间）；取消的锁屏/8 小时测试继续取消。

私有资产：`build/prototypes/plan500-ipad/unsigned-final/`（构建与摘要收据）、`host-none-final/`、`host-mapped-final/`（各随机子目录中的 result-safe.json、串口、QEMU 日志）；网关测试日志在 `build/prototypes/plan500-darwin/gated-tests-private.log`。不发布 profile、设备标识、token 或原始日志。
