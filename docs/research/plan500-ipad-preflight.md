# 方案500：iPad 研究 App 构建、签名与真机检查

2026-10-06，北京时间。继续 [Issue32](https://github.com/lvivvde/deepseek-harness-ipad/issues/32)、研究分支和 draft [PR36](https://github.com/lvivvde/deepseek-harness-ipad/pull/36)。用户要求“继续执行”，按 [Darwin 报告](plan500-darwin.md)下一关口准备独立研究 App；[源码与复跑入口](../../runtime/prototypes/plan500-ipad/README.md)。

## 当前结论

**独立研究 App 已签名并安装到 iPad；真实 iOS QEMU 10.0.12 的 `none` 与 `mapped-xattr` 两种模式均通过 15/15 项必需检查。** 免费开发 App 名额问题已在用户授权后仅卸载独立验收 runner 解决。两份设备收据明确 `physicalDevice=true`，已核验输入、编译源码与签名包来源。

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
| 完整 device App | iPhoneOS Release 编译、输入与最终 bundle 核验通过；独立 GUI Build 后深度严格签名及当前设备 profile 授权核验通过，已安装 |
| iPad QEMU `none` | 15/15，真实 9P 与 Swift gate；RPC ready 单次样本 8.241 秒 |
| iPad QEMU `mapped-xattr` | 15/15，每种模式使用独立 App 进程；RPC ready 单次样本 8.179 秒 |

未签名 App 的逻辑文件约 1.190 GB（十进制），不是 IPA 压缩体积或设备安装占用。guest 输入固定为既有 Darwin inputs；执行器固定为 UTM 构建的 QEMU 10.0.12 iOS framework 闭包。macOS 运行仍使用 Homebrew QEMU 11.1.2，不能代替 iOS 执行。

## 兼容性观察

macOS 默认卷上只差大小写的名字合并；**本次 iPad 研究容器样本中两种模式均保留两个不同大小写名称**，不能将 macOS 默认卷结果泛化到 iPad。其余限制在真机复现：`none` 保留普通宿主 chmod/symlink，但不能创建 FIFO/socket；`mapped-xattr` 能在 guest 内创建它们，但宿主权限/链接类型不普通。

| iPad 观察（不计入 15 项协议检查） | `none` | `mapped-xattr` |
| --- | --- | --- |
| 私有 `pthread_fchdir_np` 符号存在 | 是 | 是 |
| 只差大小写的文件名保留两个条目 | 是 | 是 |
| 普通宿主 chmod 与 symlink | 是 | 否 |
| guest 在工作区创建 FIFO | 否（退出码 1） | 是 |
| guest 在工作区创建 Unix socket | 否（退出码 3） | 是 |

实际 9P backend 已在普通开发签名沙箱中运行，私有符号条件仍保留为架构约束。就绪时间只是各一次前台冷启动样本，不是稳定性或性能验收。

本轮 App 检查是有界子集，不是旧 26 项合同的完整重跑：尚未覆盖真机 VM 退出、网关 SIGKILL、同 uid `/proc` 绕过、SCM_RIGHTS、完整 Git/hook 或 watch 行为。已知 CAS TOCTOU、同 uid 绕过等缺口仍存在。网关未接官方 Worker；模型、网络、性能与内存占用也未验证。

## 当前关口与下一步

1. 本轮签名、安装与两模式真机子集检查已完成。换模式使用 `--terminate-existing`，完成后仅 SIGKILL 研究 App 并核验进程消失；这不证明 guest 有序关机或完整 VM 退出合同。
2. 下一步把 Swift 网关接入官方 Worker，验证原生写入与 Linux 写租约协调，再做真实模型/网络。
3. 补充完整合同及稳定性证据后，在 #32 形成用户架构决定；仍不启动 #17 的正式实现。

G3/G4 与完整 G0–G7 未通过；#32 OPEN、#17 保持依赖。正式安装代码仍为 `7956e8c`，签名截止仍为 2026-10-12 15:49:52（北京时间）；取消的锁屏/8 小时测试继续取消。

私有资产：`build/prototypes/plan500-ipad/unsigned-final/`（构建与摘要收据）、`host-none-final/`、`host-mapped-final/`（各随机子目录中的 result-safe.json、串口、QEMU 日志）；网关测试日志在 `build/prototypes/plan500-darwin/gated-tests-private.log`。不发布 profile、设备标识、token 或原始日志。

## 2026-10-06 已授权签名与安装尝试

用户明确同意使用本机现有开发团队为独立研究 App 签名、安装并运行隔离检查。

- 命令行 Xcode 报 `No Accounts` 与缺少新 bundle ID 的 profile；独立私有工程在 Xcode GUI 中 Build 成功，生成了研究 App 专属 profile。没有启动或构建正式 App 目标。
- 已验证 `codesign --verify --deep --strict`、App bundle ID、签名团队与 profile、证书包含关系、钥匙串组和当前 iPad 的设备授权；权限仅为普通开发签名，没有共享 App group 或额外运行时能力。最终五项 ProbeInputs 集合及三个 guest 文件摘要与锁定输入一致。
- 实际研究 App 的较早签名截止：**2026-10-13 01:02:35（北京时间）**。此日期只属于研究 App；正式 Harness 仍为 2026-10-12 15:49:52。
- CoreDevice 安装命令失败，明确为“免费开发签名 App 数量上限”。只读应用清单确认正式 Harness、LinuxPrototype、独立 DeviceAcceptance runner 均已安装，研究 bundle ID 未安装。
- 没有卸载、替换、启动现有 App，也没有运行研究 guest 或复制正式数据。建议在明确获准后仅卸载 `org.lvivvde.harness.acceptance.xctrunner` 以腾出名额，再安装已校验研究 App；这会删除 runner 自己的测试容器，并暂时移除 UI 验收工具，正式 Harness 与 LinuxPrototype 保留。

签名、profile、设备、Xcode 与安装原始日志留在忽略的 `build/prototypes/plan500-ipad/device-r1/`；从 `signing-safe.json`、`slot-audit-safe.json` 开始接手。签名 App 在 `gui-products/Release-iphoneos/Plan500Research.app`。该首次安装尝试未通过；后续授权与成功结果见下一节。#32 OPEN、#17 保持依赖。

## 2026-10-06 授权清理与真机完成

- 用户允许删除此前三个占位项目 App，并明确后续项目 IPA 卸载无需重复申请。只移除 DeviceAcceptance runner `org.lvivvde.harness.acceptance.xctrunner` 及其测试容器，随后研究 App 安装成功；Harness 与 LinuxPrototype 保留，没有复制或操作正式数据。授权范围记录在[交接](../agents/handoff.md)，后续不重复询问同一项目 App 清理。
- 研究 App 前台串行运行 `none` / `mapped-xattr`，各进程只启动一次 QEMU。各 15/15 必需检查通过：真实只读 9P/身份/uid/cgroup、中文双向文件、无租写入拒绝、CAS、generation、旧 fd、草稿冲突、超时、取消、12 路并发、断连保租和重连确认后释放。
- 两份完成收据的输入清单与签名包一致；七个编译源文件与仓库源码一致（QEMU 桥只有类名替换），二进制摘要与签名收据一致。签名仍截止 2026-10-13 01:02:35（北京时间）。
- 运行完成后研究 App 进程已停止；guest 位于该进程内，没有留下本次研究 VM。未进行锁屏、后台、8 小时或正式 App 验收。
- 私有总入口为 `build/prototypes/plan500-ipad/device-r1/device-validation-safe.json`，两份完整收据为 `device-none/latest-result-safe.json` 与 `device-mapped-xattr/latest-result-safe.json`；卸载、安装、停止收据和原始串口留同一忽略目录。


## 2026-10-06 官方 Worker / Swift / Linux 协作追加

原“未接官方 Worker”是上轮边界；本轮已在同一研究 App 内完成，两模式各 23 项协作检查与 9 项真实进程恢复检查通过。包括冷状态会话与原生文件、实际 ready 等待自动执行、统一租约及冲突草稿、取消写者停止后释放、官方会话及项目恢复。[详细报告与复跑入口](plan500-worker-gateway.md)区分三个研究工具适配与完整官方 fs provider。真实模型入口已安装，实际模型闭环仍未通过；完整 G0–G7 和架构决定继续保留。
