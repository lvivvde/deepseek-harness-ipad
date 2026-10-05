# IPA 自签分发路径与权限边界

> 归档说明：本报告原在未合并分支 `research/ipa-distribution`（提交 `74d0ea5`），2026-10-06 原样归档进 main，分支随后删除。属早期历史研究，当前架构以 [ADR 0003](../adr/0003-native-worker-with-project-linux.md) 为准。

研究日期：2026-10-02。对应票：[研究：用户自行签名 IPA 的可行分发路径与权限边界是什么？](https://github.com/lvivvde/deepseek-harness-ipad/issues/4)。研究资产分支：`research/ipa-distribution`。

本票只调查分发与签名，不实际构建、签名或发布 IPA。约束为普通未越狱 iPad、开发工具本地执行、模型可联网、首版可限定项目兼容范围。首次安装是否允许电脑辅助仍是人类决策；“纯 iPad 生产”不自动回答这一点。

## 可供后续决策采用的结论

**事实：自己构建 iPadOS 应用、导出 IPA、由用户重签后安装，存在普通未越狱设备路径。** Apple 提供 archive/export IPA 和注册设备安装流程；Sideloadly、SideStore 的官方文档提供用户 Apple Account 自签流程。但用户身份、描述文件、设备、有效期和 entitlement 必须匹配，不能把一个任意 IPA 当作桌面可执行文件双击运行。[Apple 注册设备分发](https://developer.apple.com/documentation/xcode/distributing-your-app-to-registered-devices)、[Sideloadly 官方主页](https://sideloadly.io/)、[SideStore FAQ](https://docs.sidestore.io/docs/faq)

**事实：重签本身不解除 iPadOS 沙箱，不获得任意 native exec 或永久 JIT 权限。** 系统要求可执行代码签名，检查动态库签名身份；第三方应用依然被沙箱限制。JIT 的开发调试辅助路径另有系统/设备条件，不能从“已自签”推导“任意桌面工具链可执行”。[Apple 代码签名安全](https://support.apple.com/en-ca/guide/security/sec7c917bf14/web)、[Apple 运行时安全](https://support.apple.com/en-ca/guide/security/sec15bfe098e/web)

**推断：首版可把“可重签 IPA + 无必需 JIT 的受限本地工具运行时”作为验证候选。** 安装层与工具执行层分别验收；这只是研究给出的候选，分发方式与首次电脑依赖尚未由人类票锁定。

## 路径矩阵

| 路径 | 谁签名、设备限制 | 用户安装/续签条件 | 有效期与适用边界 |
| --- | --- | --- | --- |
| 免费 Personal Team 自签 | 用户 Apple Account 的个人开发身份；最多 3 台设备、每设备 3 个 app、10 个 App ID | Apple 官方为 Xcode；签名工具可自动重签现成 IPA；开发安装需 Developer Mode/信任身份 | profile 自签发起 7 天；不是长期公共分发服务。[账号概览](https://developer.apple.com/help/account/basics/about-your-developer-account) |
| 付费 Apple Developer Program 自签 | 用户自己的付费开发身份；仍须有效证书/profile/设备授权 | 例如 Sideloadly 重签；没有免费账号的 3-app 限制 | 工具官方称最长 1 年，实际以 profile/证书有效性为准；会员费通常 USD 99/年，地区价格有差异。[Sideloadly FAQ](https://sideloadly.io/faq.html)、[Apple 会员](https://developer.apple.com/programs/enroll/) |
| 开发者 Ad Hoc | 开发者签好；profile 列明设备 UDID；付费计划每产品类别每会员年最多 100 台 | 开发者收集并注册设备，生成 profile 再导出；用户无需用自己的账号重签 | 小规模已知设备测试；不是全球任何人下载即装。[Ad Hoc profile](https://developer.apple.com/help/account/provisioning-profiles/create-an-ad-hoc-provisioning-profile/)、[设备额度](https://developer.apple.com/help/account/devices/devices-overview/) |
| TestFlight | 开发者上传 App Store Connect；用户安装 TestFlight beta | 用户通常可只用 iPad；不需要开发安装的 Developer Mode；外部 beta 首个 build 要审核 | build 最长测试 90 天，最多 10,000 外部/100 内部测试者；不是永久 IPA 分发。[概览](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/)、[Developer Mode](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device) |
| 官方替代商店/网页分发 | 开发者通过 Apple 的替代分发体系，不由每位用户重签；应用需 Notarization | 当前读到的 Apple 支持页：EU 可装 iPad 应用，需 EU Apple Account 地区且身处 EU；日本、巴西该页仅列 iPhone | 官方 EU 网页分发最低 iPadOS 18，开发者/组织须获授权；不是普通下载链接到任意地区 iPad 的自签路径。[地区支持](https://support.apple.com/en-gb/118110)、[EU 网页分发](https://developer.apple.com/support/web-distribution-eu/) |
| Enterprise | 组织内私有应用签名，不是陌生公众自行重签 | 面向组织员工与内部系统 | 不作为本项目公开分享 IPA 的候选。[账号概览](https://developer.apple.com/help/account/basics/about-your-developer-account) |

### 自签工具与“是否需要电脑”

| 工具 | 首次安装 | 后续安装/更新/续签 | 对纯 iPad 日常生产的含义 |
| --- | --- | --- | --- |
| Sideloadly | Mac/Windows，连接 iPad，登录签名用 Apple Account | 自动续签仍要电脑运行 daemon；USB 或已配置同网 Wi-Fi | 可作为安装验证基线，不能称续签完全摆脱电脑。[官方 FAQ](https://sideloadly.io/faq.html) |
| AltStore Classic | 电脑运行 AltServer 安装 AltStore | 安装/refresh 等操作须同 Wi-Fi 的 AltServer 或 USB 连接 | AltStore 本身也占免费 3-app 名额；不是官方替代分发的 AltStore PAL。[AltServer](https://faq.altstore.io/altstore-classic/altserver)、[Getting Started](https://faq.altstore.io/altstore-classic/your-altstore) |
| SideStore | 当前官方要求电脑 USB 安装，iPadOS 15+、设备设密码、Apple Account | iPad 上 Wi-Fi + LocalDevVPN 安装/更新/refresh；蜂窝网络不能代替所要求 Wi-Fi | 首次电脑辅助后可日常本机续签；pairing file 在更新/重置或随机情况下会失效，因此不能承诺永不再碰电脑。[前提](https://docs.sidestore.io/docs/installation/prerequisites)、[安装](https://docs.sidestore.io/docs/installation/install) |

**事实与未知：**上述已读路径没有证明“新购 iPad、无任何电脑、任意地区、任意普通 IPA、用户免费账号”的首次自签安装闭环。EU 官方商店/网页或 TestFlight 可免用户电脑，但改变了签名主体、地域或审核链。其他证书服务/设备端签名工具未在本轮穷举，也不应据此作“不存在任何其他办法”的断言。

## 构建、重签与 entitlement 的边界

Apple 的标准路径是针对 iPad 真机目标 archive，使用证书及私钥、App ID 和匹配 profile 导出；模拟器产物和 Mac Catalyst 产物不能代替 iPad 应用。自己的 IPA 应来自自己可再分发的构建，不用 App Store 下载包作为重签输入。后者还可能涉及加密；Sideloadly 对加密 IPA 的错误有专门说明。[Apple 注册设备分发](https://developer.apple.com/documentation/xcode/distributing-your-app-to-registered-devices)、[Sideloadly FAQ](https://sideloadly.io/faq.html)

Profile 是 Apple 签名的授权材料：约束可签名者、App ID、设备、期限及受限 entitlement。重签需要替换匹配用户身份的 profile，并处理主 app、扩展与框架的签名。**不能只复制原开发者的 entitlement plist 就继承能力**：`get-task-allow` 等须由 profile 授权。升级服务、变更设备、过期等情况可能须重新生成 profile。[TN3125](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles)、[Apple profile 更新](https://developer.apple.com/help/account/provisioning-profiles/edit-download-or-delete-profiles)

**推断：**如果 Harness 首版依赖原作者团队的 iCloud 容器、App Groups、Keychain access groups、推送或审批型 entitlement，用户重签时可能失效/改名，需对每项实际 entitlement 做签后检查及功能测试；不能预先承诺“所有功能在免费账号重签后等价”。Apple 将 entitlement 与最终签名及账号配置共同确定。[Entitlements](https://developer.apple.com/documentation/bundleresources/entitlements)

开发安装通常要在设置中信任签名身份，并在 iPadOS 16+ 启用 Developer Mode、重启确认。Developer Mode 是开发 app 运行开关，不是 jailbreak，也不是解除沙箱的开关；App Store/TestFlight 的常规安装不受它影响。[Apple Developer Mode](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)、[SideStore 安装](https://docs.sidestore.io/docs/installation/install)

## JIT 与任意二进制：三个不同问题

1. **签名边界：**iPadOS 强制签名所有可执行代码，并验证链接动态库属于系统或与主 app 同 Team ID。IPA 重签不能把下载的任意 macOS/Linux 工具二进制变为可启动桌面进程。[Apple 代码签名安全](https://support.apple.com/en-ca/guide/security/sec7c917bf14/web)
2. **运行时边界：**所有第三方 app 被沙箱限制；后台执行也只能走系统提供的 API。Apple 运行时安全文档指出可写且可执行内存受到 Apple-only dynamic-code-signing entitlement 的控制。不能拿 macOS Hardened Runtime 的 `com.apple.security.cs.allow-jit` 当成 iPad 通用 entitlement。[Apple 运行时安全](https://support.apple.com/en-ca/guide/security/sec15bfe098e/web)、[allow-jit 文档](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.allow-jit)
3. **开发辅助例外：**不能断言未越狱 iPad 完全无法 JIT。AltJIT 官方描述开发辅助启用方式，退出/被系统清理后需重新启用；其 iOS 17 指引是 Mac + USB，且锁定旧版依赖。[AltJIT](https://faq.altstore.io/altstore-classic/enabling-jit/altjit)

SideStore FAQ 笼统写 17.4+ 可考虑 StikDebug；**细读其 JIT 指南则只明确列 iOS/iPadOS 17.4–18（排除 18.4b1）**，还要 pairing file、VPN、Wi-Fi 和每次设备重启挂载 DDI，目标 app 要用含 `get-task-allow` 的开发签名，随后附加 debugger。文档也给老设备/非 TXM 的另一条件。页面的范围与概括不一致，不能据 FAQ 保证当前所有新 iPadOS 支持稳定本机 JIT。即使成立，它也不是重签取得永久特权，更没有证明可运行任意 desktop native 子进程。[SideStore FAQ](https://docs.sidestore.io/docs/faq)、[JIT 详细指南](https://docs.sidestore.io/docs/advanced/jit)

**推断：**不依赖这些调试辅助 JIT 的首版更容易满足“普通设备、限定兼容范围、本地闭环”。是否采用可选 JIT 加速须单独列设备/系统矩阵并真机测；这不替代运行时选型票。

## 升级、续签与项目数据

Sideloadly 官方要求相同 Apple Account 与相同 bundle ID 才能覆盖原 app；不要先删除应用。Apple TN2319 记录 `application-identifier` 不匹配会拒绝升级，所以换签名团队不能承诺原地保留数据。该 Apple 文档最后更新为 2017-10-25，应把其规则作为测试假设并验证当前系统。[Sideloadly FAQ](https://sideloadly.io/faq.html)、[TN2319 升级身份](https://developer.apple.com/library/archive/technotes/tn2319/_index.html)

**待真机：**相同身份/profile 重签后工作区、Git 元数据、插件、Keychain 登录信息、文件访问 bookmarks 是否保留；换工具、换账号、换 bundle ID、过期后补签、卸载后恢复的差异。工具称数据可保留不等于 Harness 所有存储机制都已验证。**推断：**项目导出/备份需要在升级前可用，不能把应用容器当成唯一不可迁移的生产资产。

## 审核政策不能代替运行时结论

自签开发安装不走 App Store App Review，仍受 OS 签名、沙箱和所用开发计划约束。App Store/TestFlight/官方替代分发还要分别看审核规则。当前 App Review Guidelines 2.5.2 要求应用自包含，限制下载新增功能的代码，教育型代码执行例外有条件并要求源代码可看可改；页面将这一项标为 ASR & NR，表示 App Store Review 与 Notarization 均相关。4.7 另允许一些 HTML5/JavaScript 小程序、插件等，但有附加条件，向其中软件暴露 native APIs 需 Apple 事先许可。不能声称替代分发让插件代码无任何审核条件，也不能把 2.5.2 简化为完全禁止解释执行。审核政策与签名成功后系统能否执行代码不同。[当前审核规范](https://developer.apple.com/app-store/review/guidelines/)

## 后续决策与验证清单

这张研究票已能回答路径与权限边界；以下为后续可执行方案的验收内容，不是本轮已完成的测试：

- 人类确认首次安装/极少数修复续签是否允许借用 Mac/PC，是否允许用户付费开发账号；若要求零电脑，须重选分发链。
- 明确目标 iPad 型号、最低/当前 iPadOS、用户地区、账号等级、签名工具实际版本；固定测试组合后再承诺兼容。
- 最小自建 iPad IPA 验证免费/付费签名、Developer Mode、启动、到期/续签与过期修复；核对实际 profile 到期时间，不把“最长一年”写成保证。
- 导出签名前/后的 main app、每个 extension/framework 的 entitlement 与 profile 授权，逐项验收需要的能力；签名资产由用户工具管理，不要求公布开发者私钥。[Apple 证书保护](https://developer.apple.com/help/account/certificates/certificates-overview)
- 先写一个含源码、Git history、插件与凭据的工作区，覆盖更新、重签、OS 更新、配对文件失效、不同身份迁移、导出恢复测试。
- 单独验证受支持本地工具运行时；只有拟采用 JIT 才新增 JIT 重启/后台清理/系统更新矩阵，不以安装成功代替工具执行测试。

## 来源时间与调查限制

仅使用 Apple、AltStore、Sideloadly、SideStore 的一手页面。Apple 两篇 Platform Security 页面标注 2024-12-19；替代分发支持页标注 2026-06-22；TN2319 为归档文档，最后更新 2017-10-25。EU 网页分发页面本轮读到注明协议过渡自 2026-10-01 生效，且资格现在有多种选项，因此本笔记没有复述旧的“必须两年加百万下载”唯一门槛。没有明确更新时间的工具文档以本轮读取为准，其宽泛的未来系统支持承诺不视为真机证据。

本轮未验证 Xcode 工程、实际 IPA、签名工具版本、设备端安装或开发账号；没有声称硬件、最新系统或所有地区全部可用。研究关注首版可评估路径，不穷举签名服务、特殊证书或漏洞方案。
