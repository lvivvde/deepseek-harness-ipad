# 开发交接

最后更新：2026-10-09，北京时间。此文件是接手入口，只记当前状态、约束和资产入口；GitHub Issues 是任务状态源，过往过程以 git 历史、研究报告和验收记录为准。

## 开始工作

1. 读根 `CONTEXT.md`、相关 `docs/adr/`，检查 `git status --short`、当前分支和最新提交。保留已有未提交改动。
2. 查 `gh pr list --state open` 和下表涉及的 Issues。已有待合并分支时先继续该分支，避免重新实现；每个新 PR 合并都另获用户同意。
3. 真机任务读 [真机自动化](../validation/ipad-device-automation.md)；其他任务读对应验收记录。先用只读 `probe` 确认连接，按明确缺项推进，减少用户交互。
4. 完成后更新本文件的状态、验证和下一步；原始日志/设备/签名参数保存到忽略的 `build/`，公开文档只记脱敏结果。

## 当前状态

架构基线为 [ADR 0003](../adr/0003-native-worker-with-project-linux.md)（2026-10-06 用户确认，accepted）：官方 Worker 在 WKWebView 中运行，Swift 网关与原生工作区为唯一权威；Linux 是项目级兼容插件，启用后异步预热；9P 共享模式 `none`；耐久写租约与草稿；隔离语义为事后检测并转为冲突；工具按能力声明走 `native` / `linux` / `unsupported`。[ADR 0001](../adr/0001-local-linux-emulation.md) 中“Harness 在 Linux 内运行”的部分被取代。

正式实现 #17 被 [#39 六项前置关口](https://github.com/lvivvde/deepseek-harness-ipad/issues/39)阻塞。#39 是任务清单，完成一项勾一项，并在 #39 评论附脱敏证据：

| 关口 | 内容 | 类型 | 先后 |
| --- | --- | --- | --- |
| 1 | G2 原生工作区、会话与草稿的崩溃耐久 | 硬关口 | 可立即开始 |
| 2 | `pthread_fchdir_np` 启动检测与 Linux 插件不可用 | 硬关口 | 可立即开始 |
| 3 | 官方 fs、编辑、搜索与原生只读 Git 接入原生工作区 | 可收紧 | 等关口 1 |
| 4 | G1 模型回复增量流式、取消、认证与网络错误 | 可收紧 | 可立即开始；需用户输入 Key 并切一次飞行模式 |
| 5 | G3/G5 Git 写操作与 hook 的一致性和提交前拦截 | 可收紧 | 等关口 2、3 |
| 6 | G7 从隔离备份迁入、逐文件核验与回退旧包 | 硬关口 | 等关口 1 |

用户确认的关口决定（已写入 #39）：

- 真机证据只来自独立 bundle ID 的候选 App。G7 用专用测试 bundle ID 演练旧包→新包→回旧包，数据为合成数据加一份由用户在 iPad“文件”App 导出的真实备份副本（不经 Mac）。正式 App 升级与真实数据迁移不属 #17，须另获授权。凭据不迁移。
- 崩溃恢复以工作区为准、不回滚：会话回到最后完整检查点，未记录完成的工具调用标“结果未知”且不重放，草稿保留，change generation 不一致在会话中标出。
- 原生 Git 只读；所有修改仓库的 Git 操作和全部 hook 走 `linux` 路径，原生不写 `.git/index`。
- 硬关口不通过即停；可收紧的关口不通过时收紧兼容范围，每次须用户确认，必要时修订 ADR。关口之后的集成实现暂留 #17 正文，不预先拆票。

拆票规则（用户定）：开放 Issue 尽量少；有阻塞关系的不合并，同一层级、无相互阻塞的细项写成任务清单。

#39 进展（脱敏证据见 #39 各条评论）：

- 六项关口全部勾选。关口 1、2、3、4、6 的代码在 [PR46](https://github.com/lvivvde/deepseek-harness-ipad/pull/46)，已合并。设计与限制见 [工作区耐久](../design/workspace-durability.md)、[Linux 插件可用性](../design/linux-plugin-availability.md)、[原生官方工具](../design/native-official-tools.md)（含用户确认的 4 项收紧）、[原生只读 Git](../design/native-read-only-git.md)、[模型网关](../design/model-gateway.md)、[用户数据迁移](../design/user-data-migration.md)。
- 关口 5 的代码在 [PR47](https://github.com/lvivvde/deepseek-harness-ipad/pull/47)，设计与限制见 [Git 写操作与 hook](../design/git-writes-and-hooks.md)。Git 写操作和 hook 走项目 Linux，原生只读复核。授权推送用的是本仓库的专用分支 `gate5-push-test`，token 由用户在 iPad 上输入；核对后该分支已删除。
- 遗留限制：系统崩溃和断电未验；关口 1 真机写租约中的 Linux 写者是模拟的，真实 VM 补测记在 #17；快照或日志中段损坏时会丢草稿和租约记录；生成中切后台未在真机运行；hook 的 `workdir` 被忽略；shell 工具能直接 `git commit --no-verify`，同 uid 代码能从 `/proc` 读到 Git 令牌；iPad 上完整 clone 本仓库超过单条命令 60 s 的上限，大项目的 clone 时长留给 #18。

**下一步：** #39 可关闭，转 #17。

## 开放任务

| Issue | 依赖与边界 |
| --- | --- |
| [#15 路线图](https://github.com/lvivvde/deepseek-harness-ipad/issues/15) | 总入口；执行顺序 39→17→18→23→14。#1、#16、#19、#32 已关闭，作为历史保留。 |
| [#39 前置关口](https://github.com/lvivvde/deepseek-harness-ipad/issues/39) | 见上表；`ready-for-agent`。曾拆出的 #40–#44 已关闭并指向对应关口。 |
| [#17 实现](https://github.com/lvivvde/deepseek-harness-ipad/issues/17) | 被 #39 阻塞。关口后实现原生 Harness 宿主、同一项目工作区、Linux 预热及准备/就绪/取消/失败调度；保留旧 Linux 和用户盘保护。资源、低空间、删除回收等未验项转兼容插件技术债，不标记通过。 |
| [#18 Git 开发闭环验收](https://github.com/lvivvde/deepseek-harness-ipad/issues/18) | 被 #17 阻塞。按能力声明区分路径；Git 写与 hook 走 `linux`；推送只用用户授权的测试远端。仍带 `needs-triage`。 |
| [#23 插件/预览/键盘/前后台验收](https://github.com/lvivvde/deepseek-harness-ipad/issues/23) | 被 #18 阻塞。“重试”是重提任务，同进程不重启 QEMU；dev server 默认 `linux`；阈值在开工前提出并经用户确认。仍带 `needs-triage`。 |
| [#14 许可证与对应源码审查](https://github.com/lvivvde/deepseek-harness-ipad/issues/14) | 被 #17 的实际组件清单阻塞，可与交互验收并行准备；含 Worker bundle、适配补丁、原生只读 Git 与原生搜索。不发布 GitHub Release。仍带 `needs-triage`。 |

## 已交付基线

- 正式 iPad 安装代码基线 `7956e8c`（含导出中断修复），同身份覆盖安装前后真实备份 83 个文件一致。main 另含研究原型与 ADR 0003，正式 App 尚未包含。
- 已有实现：完整 Linux 原型、正式全屏入口、持久用户盘、恢复诊断、备份/存储工具、签名预检 `runtime/check-signing.py`、真机 runner、原生菜单标签与示例插件声明。既有用户项目不会因示例更新被覆盖。
- 独立研究 App（`org.lvivvde.harness.plan500.research`）在 iPad 上有界通过：`none` / `mapped-xattr` 各 15/15 必需检查、23 项 Worker/Swift/Linux 协作 + 9 项进程恢复；真实模型小闭环在 `none` 模式 8/8 通过。这些不是完整 G0–G7。

## 已知缺口与技术约束

- `none` 模式不能建 FIFO/socket；`mapped-xattr` 宿主 mode/symlink 不普通。
- iPad 容器样本保留大小写不同的名称，但大小写不敏感卷会合并同名；工作区须显式处理。
- libslirp `listen(s,1)` 在 XNU 下积压溢出会 RST。
- 私有 `pthread_fchdir_np` 符号存在且 9P backend 可运行，但完整语义与私有接口条件未解决（关口 2）。
- 同 uid 经 /proc、SCM_RIGHTS、写租约 CAS TOCTOU 的隔离缺口保留，独立 uid 加固留作后续。
- 研究中 SSE 仍为缓冲交付（关口 4 处理）；`mapped-xattr` 未跑模型。
- 旧 Linux 路径：guest Vite production build 超时；删除/trim 后未观察到宿主 raw 占用下降。不要猜测根因或承诺原盘压缩。
- 历史恢复、实际时差、救援盘仍未验；物理锁屏与 8 小时验收已取消，不登记通过。

## 文档入口

- 研究：[Worker/Swift/Linux 接缝](../research/plan500-worker-gateway.md)、[iPad 研究 App](../research/plan500-ipad-preflight.md)、[Darwin](../research/plan500-darwin.md)、[写租约](../research/plan500-write-lease.md)、[共享/RPC](../research/plan500-sharing-rpc.md)、[候选研究](../research/plan500-feasibility.md)；原型在 `runtime/prototypes/plan500-*/README.md`。早期研究报告已归档在 `docs/research/`，文首注明原分支。
- 验收：[非锁屏](../validation/ipad-non-lock-acceptance.md)、[后台恢复](../validation/ipad-background-recovery.md)、[备份恢复](../validation/ipad-recovery-backup.md)、[存储工具](../validation/ipad-storage-tools.md)、[签名维护](../validation/ipad-signing-maintenance.md)、[插件预览](../validation/ipad-plugins-preview.md)。

## 本机接手资产

全部在忽略的 `build/`，路径相对仓库根；其他机器可从源码重建工具，但需重新配对、签名和准备本机资源。原始证据不可贴聊天、提交或公开。

- `build/device-acceptance/local-settings.json`：本机 runner 签名设置（权限 600）；多设备时用 `selected-device-private.json`。runner xctestrun 在 `build/device-acceptance/portable-signed-final/derived/Build/Products/`，测试源码变更后按真机工具说明重建。
- `build/test-dependencies/harness/`：固定官方 `@deepseek-ai/dsh@0.2.0-rc.2`、pnpm 11.28.4 的宿主测试依赖和 lock。设置 `HARNESS_TEST_MODULES="$PWD/build/test-dependencies/harness/node_modules"` 后运行 `make test-runtime`，核对无跳过。依赖丢失时用保留的 lock 重装。
- Lima `ubuntu` 内 `/var/tmp/ipad-bundled-guest-storage-v6` 可跑 Linux 验收，使用新临时盘；`/Users/edwin` 只读挂载，`/private/tmp` 不挂载。Linux/QEMU 只用隔离盘，不读 iPad 原盘。
- 正式包：`build/maintenance19/r2-7956e8c/`。研究 App 与收据：`build/prototypes/plan500-ipad/`（`device-r1/` 签名与两模式收据，`worker-device-r1/`、`r2/`、`r4/` 协作与模型收据）；macOS 原型收据在 `build/prototypes/plan500-{worker,sharing,lease,darwin}/`。
- #39 关口：`build/issue39-gate1/`（从 `device/durability-safe.json` 看起）；`build/issue39-gate3/device/`（关口 2、3、4 的收据与 `device-private.py`）；`build/issue39-gate6/`（合成矩阵，`device/gate6-private.py` 与收据）；`build/issue39-gate5/`（`device/device-private.py`，步骤为 sign、install、launch、wait；收据在 `device/*-safe.json`，macOS 运行在 `mac-3/` 和 `mac-push-dry/`）。iPad 上现装的是关口 5 版研究 App，演练 App `g6drill` 已卸载。
- 历史归档：`build/acceptance-archive/2026-10-05/`（旧日志、xcresult、截图、脱敏结果与 SHA256 清单）；Issue 正文备份与草稿在 `build/issue-drafts/`。
- `harness-30` 锁屏提醒已暂停，保持取消。

## 持续约束

- 保护正式 Harness 数据、草稿、Git 历史和有效备份；覆盖升级只用同签名身份，保留原盘；原盘迁移只经校验副本。设备备份不导出到 Mac 或仓库。
- 免费开发团队的 App 名额有限。用户已授权按需卸载本项目占位 App（Harness、LinuxPrototype、DeviceAcceptance runner）及后续项目 IPA，不再重复询问；不扩展为其他 App 或无关数据。研究 App 同团队签名安装已获授权。
- 每进程 QEMU 最多启动一次；VM 真退出时保存固定诊断，明确关闭重开。
- 设备标识、签名身份、凭据和原始日志只留 `build/`；Key 由用户在设备入口自行输入，不从聊天取值、不替用户输入。
- API 及 Token 消耗无需另问；外部 Git push 只用用户授权的测试远端。当前不发布 GitHub Release。
- 文档与代码改动走分支和 PR，不直接推 main；每个 PR 合并另获用户同意。
