# 现有版本维护与重签前校验

对应 [01｜维护：现有版本的数据保护、恢复诊断与重签](https://github.com/lvivvde/deepseek-harness-ipad/issues/19)。只读工具开发起点为 main `3749969`。下文保留工具阶段的历史记录；随后获准的实际续签、覆盖安装和数据核验见本页末尾。

## 工具使用

需要 macOS、Python 3.11+、`codesign`、`security` 和 `openssl`。准备可信安装记录对应的旧 IPA、新候选 IPA，以及各自的 `<文件名>.ipa.sha256`。摘要文件第一项必须是 64 位十六进制摘要，来自可信构建记录；校验和只证明资产一致性。

```sh
python3 runtime/check-signing.py \
  --baseline build/current-installed.ipa \
  --candidate build/renewed-candidate.ipa \
  --output build/signing-check/new-preflight
```

输出目录必须不存在，权限 700。工具顺序创建并校验副本、解包、检查，临时副本自动清理；须留一个 IPA 和一个解包 App 的空间，当前包约需 1.5 GiB。原始签名输出和描述文件仅留权限 600 的 `*-private.log`，不得提交或公开。终端只输出固定结果和 UTC 截止时间；成功时的 `summary-safe.json` 包含摘要、有效期、检查时间、身份比较和是否延长有效期，不含团队、设备、证书标识或路径。

工具检查以下条件：

- 新旧 IPA 的 SHA256、ZIP CRC 和布局；拒绝重复路径、路径越界、越界符号链接、特殊文件、加密条目以及超过 100000 条目/3 GiB 解包上限的包。
- 正式 Harness bundle ID；`codesign --verify --deep --strict` 通过，签名中的应用标识、团队和钥匙串组获描述文件许可。
- 新旧团队、完整应用标识（含 App ID prefix）及钥匙串组顺序一致；新证书可以更换，但须列在新描述文件中。无显式钥匙串组时默认使用应用标识，首组决定默认组，依据 [Apple 钥匙串访问组说明](https://developer.apple.com/documentation/Security/sharing-access-to-keychain-items-among-a-collection-of-apps)。
- 新描述文件保留旧描述文件全部设备，这是不连接设备的保守检查。旧包到期后仍可作比较基线。
- 描述文件和叶证书已进入有效期；候选的较早截止时间默认至少剩余 24 小时。`--min-valid-hours` 可设 0–8760，0 仍拒绝到期候选。

退出码 0 表示本机预检通过，1 表示固定阻塞原因，如 `SIGNING_IDENTITY_CHANGED`、`CANDIDATE_VALIDITY_TOO_SHORT`、`BASELINE_DEVICES_NOT_PRESERVED`。工具不调用设备工具、申请 profile、签名、安装或访问用户数据。预检不验证证书撤销、设备信任和实际覆盖安装，也不能确认 baseline 就是设备当前安装包；`deviceInstallationVerified` 始终为 false。

## 2026-10-05 实际维护记录

- 只读 probe 确认已配对 iPad 已连接、解锁，Harness 已安装；固定状态为 `recovery:pageReady`。状态文件可能来自旧事件，单独不证明进程健康。
- 现有独立 runner 的 `page` 通过：页面和输入可用，无恢复/失败遮罩，检查阶段约 **3.650 秒**。未发送、修改草稿或重启正式 App；此数不是首次解锁恢复耗时。
- 现有 `da2d0aa` IPA 同时作为 baseline 和 candidate 完成真实预检：摘要、ZIP CRC、签名、描述文件与证书通过。较早截止为 **2026-10-10 13:11:14 UTC / 北京时间 21:11:14**；`renewalExtended=false`、`deviceInstallationVerified=false`。这是现有资产核验，未续签。
- 27 项 Swift 核心、14 项 guest（无跳过）、11 项真机工具通过。新增 16 项 CLI 测试覆盖身份、完整性、有效期、证书更换、默认钥匙串组、越界、脱敏、输入/既有输出保留及设备零写入。系统签名工具使用进程边界替身，真实签名由上述 IPA 预检另验。

原始记录留在忽略的 `build/`。本次未做完整真机备份、raw 救援、覆盖升级或续签后的数据验收。首次解锁恢复 ≤10 秒、时差 ±2 秒和历史长后台根因继续未验证；取消的物理锁屏/8 小时项目不重启，Issue #19 保持 OPEN。

## 下一次明确重签任务

截止前用原团队、原 bundle ID 和原 App ID prefix 生成候选，以实际新 profile 为准。核对可信安装记录后运行预检，确认 `renewalExtended=true`；重复使用当前 profile 不会续期。失败先保留私有诊断，不卸载正式 App 或换身份绕过。

明确安装任务获准后，先记录已有项目、会话、配置、Git 历史和插件，再按 [备份恢复](ipad-recovery-backup.md) 在受控副本验证失败不覆盖有效数据。同身份覆盖安装后核验原数据及页面；换身份通过用户数据备份迁移，不直接替换原盘。新 PR 合并仍另获用户同意，不发布 GitHub Release。


## Standards

以 `3749969` 为固定点，独立规范审查未发现文档规范违反或需处理的基线异味。原资产保留、设备零写入、私有证据和已确认的 CLI 测试边界均符合约束。

## Spec

独立规格审查发现 1 项 P2：默认参数解析错误会回显传入值，违反脱敏输出边界。已新增先失败后通过的 CLI 回归，将参数错误转为 `INVALID_ARGUMENTS`、退出码 1、空 stderr，并确认不创建输出目录。未发现其他已验证的实现违反或范围扩展；归档符号链接按实现和行为测试验证，审查未作穷尽安全保证。实际重签、数据救援和历史恢复验收仍按上述记录保留未完成。

本轮审查：Standards 0 项；Spec 1 项已修正，剩余 0 项已确认实现缺陷。Issue 验收缺口不因预检通过而关闭。


## 2026-10-05 授权续签与覆盖安装

用户明确授权真实备份、隔离恢复、同身份续签覆盖及原数据核验。本轮交付代码为 main `3dd1301`，包括 PR30 修复及只读签名预检；后续文档提交不改变该 IPA 的代码基线。

- 已生成并实际覆盖安装 `HarnessApp-0.1.0-main-3dd1301-renewed.ipa`（307461891 字节，约 293.2 MiB）。新旧包完整性、深度严格签名、团队、完整应用标识和钥匙串组比较通过；新 profile 保留原设备集合，`renewalExtended=true`。待安装 App 的每个归档文件与已预检 IPA 一致，系统安装命令成功；未卸载、换身份或发布 Release。
- 新 profile/证书的较早截止为 **2026-10-12 07:49:52 UTC / 北京时间 15:49:52**，以私有真实预检为据。
- 安装前通过原 App 生成并复制真实 tar 与 SHA256，校验和、布局及排除项通过，大小 651776 字节。备份含私密配置，仅保存在忽略的 `build/maintenance19/backup-before/`；没有直接读取或替换正式 `user.raw`。
- 真实归档在禁止外网访问的临时 Linux/QEMU 用户盘恢复成功，官方页面可用，归档全部 **83 个文件**摘要一致；损坏归档被拒绝后有效副本仍保留。测试结束销毁临时盘，不把恢复写回正式 App。新运行时另有 16 项原有 QEMU 检查通过。
- 安装后新进程冷启动固定 `ready` 记录约 **175.224 秒**；UI 检查从启动调用到页面和输入可用约 **196.371 秒**。两者均不是首次解锁恢复耗时。原空草稿保持不变。再次导出真实备份与 SHA256，安装前后全部 83 个文件（含项目、Git、会话、配置和 profile）摘要一致；此结论覆盖归档内文件内容，不证明所有 raw 元数据、排除的依赖/缓存/Git 凭据或物理锁屏行为。

原 App 导出曾提示 `Could not connect to the server.`，安装后首次实际导出曾提示 `The network connection was lost.`，并记录固定 `userDataOperationFailed`；后续重试成功。TCP 与无认证 HTTP 探针确认传输服务响应 403，不能据此证明完整导出健康。隔离盘设置旧访问时间仍可导出，未支持该阻塞假设。**故障根因仍未确认，未新增运行时修复，不登记为已解决。** 原 App 曾通过 Home 后有界同步再冷重开，未在同进程重建 QEMU；私有 runner 的设置等待/滚动问题单独处理，不作为 App 故障修复。

私有签名、设备、原始日志、界面树和备份留在 `build/maintenance19/`；固定收据为 `delivery-receipt-safe.json`，数据比较在 `postinstall-comparison-private.json`。后续应先诊断可复现的导出故障，再按实际签名截止安排维护。历史长后台根因、首次解锁 ≤10 秒、真机时差 ±2 秒及救援盘路径仍未验证，#19 保持 OPEN；取消的锁屏/8 小时项目和 #32 的人工阻塞继续有效。


### Standards：续签交付增量

独立审查未发现规范问题。维护记录对应私有收据，明确限定 83 个归档文件的内容比较，保留未确认故障、取消项和 #32 人工阻塞；文档增量无需处理的基线异味。

### Spec：续签交付增量

独立审查未发现缺失授权交付或误导性通过声明。真实备份、隔离恢复、同身份安装、签名延期与安装前后数据比较有记录；冷启动与首次解锁恢复已区分。历史恢复、真机时差和救援盘继续未验，#19 保持 OPEN。

续签交付增量审查：Standards 0 项；Spec 0 项。
