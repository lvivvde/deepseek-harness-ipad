# 开发交接

最后更新：2026-10-08，北京时间。此文件是接手入口，GitHub Issues 是任务状态源；旧聊天和临时目录不作为接手前提。

## 开始工作

1. 读根 `CONTEXT.md`、相关 `docs/adr/`，检查 `git status --short`、当前分支和最新提交。保留已有未提交改动。
2. 查 `gh pr list --state open` 和下表涉及的 Issues。已有待合并工具分支时先继续该分支，避免重新实现；每个新 PR 合并都另获用户同意。
3. 真机任务读 [真机自动化](../validation/ipad-device-automation.md)；其他任务读对应验收记录。先用只读 `probe` 确认连接，按明确缺项推进，减少用户交互。
4. 完成后更新本文件的状态、验证和下一步；原始日志/设备/签名参数保存到忽略的 `build/`，公开文档只记脱敏结果。

## 2026-10-08 #39 关口 2、3、4、6

- **当前状态**：
  - 关口 1、2、3、4、6 已在 #39 勾选，证据见各自评论；只剩关口 5（Git 写操作与 hook，走项目 Linux）。
  - 代码仍在分支 `feat/issue39-gate1-durability`，已推送并开 [PR46](https://github.com/lvivvde/deepseek-harness-ipad/pull/46)（2026-10-08，含关口 1–4、6）。合并需另获用户同意。
- **各关口落点**：
  - **关口 2**：检测 `pthread_fchdir_np`，启动时据此决定 Linux 插件是否可用。见 [linux-plugin-availability.md](../design/linux-plugin-availability.md)。
  - **关口 3**：原生文件服务、ripgrep 模拟和原生只读 Git。见 [native-official-tools.md](../design/native-official-tools.md)（含用户确认的 4 项收紧）和 [native-read-only-git.md](../design/native-read-only-git.md)。
  - **关口 4**：Swift 流式模型网关。见 [model-gateway.md](../design/model-gateway.md)。
  - **关口 6**：迁移器 `Sources/Migration`、合成矩阵和真机演练 App `scripts/gate6/drill`。见 [user-data-migration.md](../design/user-data-migration.md)。
- **已验证**：
  - 完整测试通过：`make check`、`test-app`、`test-runtime`、`test-device-tools`、`test-plan500-ipad`（含网关 18 项）。
  - iPad 真机：
    - 关口 2 两个分支都通过：Linux 可用 29/29；缺少私有符号时 15/15，且关口 3 仍为 34/34。
    - 关口 3 为 33/33。
    - 关口 4 为流式 7/7、无效 Key 2/2、离线 2/2。
    - 关口 6 回退演练两轮都是 7/7；用户经“文件”导出的真实备份 5/5。
    - 关口 6 审查后补测：被杀矩阵 10/10，名字冲突 2/2。#39 第 200 行要求的被杀和大小写/Unicode 语义因此有了真机证据，不只靠 macOS 和 Lima。iPad 容器区分大小写，但不区分 Unicode 规范化。
  - 关口 4 首轮在真机发现一个缺陷：流结束后才到的取消会让下一个同号请求失败。已在 `98a7143` 修复，修复后按原顺序重测通过。
- **设备状态**：
  - iPad 上装有正式 Harness、LinuxPrototype 和演练 App `org.lvivvde.harness.g6drill`（新版）。
  - 免费签名最多 3 个 App，所以研究 App `plan500.research` 已卸载；关口 5 需要时用 `build/issue39-gate3/device/device-private.py sign/install` 重装，装前先卸演练 App。
  - 正式 Harness 和 LinuxPrototype 的数据没有动过。
- **未完成**：
  - 关口 5 未开始。
  - 生成过程中切到后台的情况未在真机运行，只记录、不阻断。
  - 关口 2 的 hook 路径用的是研究适配器，官方 hook runner 留给关口 5。
- **下一步**：
  1. PR46 等 CI 和用户决定合并。
  2. 关口 5 依赖关口 2、3，现在可以开工。
- **私有资产**：
  - `build/issue39-gate3/device/`：关口 2、3、4 的收据，`*-safe.json`。
  - `build/issue39-gate6/`：`synthetic-matrix.json`；`device/gate6-private.py` 的步骤为 sign、resign-old、synthetic、conflict-export、install-old/new、boot-old、push、drill、real、push-conflicts、conflicts、kills；`device/` 下还有收据。

## 2026-10-06 #39 关口 1（G2 崩溃耐久）

- **当前状态**：代码在分支 `feat/issue39-gate1-durability`（基于 main，提交 `1fac863`、`af60484`），未推送、未开 PR。`ios/HarnessApp` 新增 `NativeWorkspace` 模块（日志、版本校验写入、写租约、草稿、会话检查点、恢复）与 `WorkspaceCrashProbe` 工具；研究 App（独立 bundle ID）加入真机耐久探针。规则与证据见[工作区耐久设计](../design/workspace-durability.md)，术语“代际、写者未知、隔离区”已入 `CONTEXT.md`。
- **已验证**：
  - macOS：25 项 NativeWorkspace 测试，崩溃矩阵重复 10 次，随机杀进程 200 次，无撕裂尾帧；完整 `swift test`、`make check`、`make test-plan500-ipad` 通过。
  - 模拟器：12 个 SIGKILL 场景和 22 项进程内检查（损坏、ENOSPC）通过。
  - iPad 真机：研究 App 同身份覆盖安装，12/12 场景被杀后恢复一致，22/22 项检查通过。未触碰正式 Harness 或 LinuxPrototype 的数据。
  - 代码审查已完成；有效缺陷已修：未确认写入改为回滚到旧内容并返回 `failed`，F_FULLFSYNC 错误不再被吞，日志重置后重开描述符。
- **未完成**：
  - 系统崩溃和断电未验证。
  - 真机写租约场景中的 Linux 写者是模拟的；真实 VM 写者留给 #17。用户于 2026-10-06 确认以此勾选关口 1，真实 VM 补测已作为评论记到 #17。
  - 快照损坏或日志中段损坏时，草稿和租约记录会丢失，只记为已知限制，未做保守处理。
- **下一步**：#39 关口 1 已勾选，证据见 #39 评论；关口 2、3、4、6 可开工，关口 5 等关口 2、3。本分支合并需另获用户同意。
- **私有资产**：`build/issue39-gate1/`。真机收据从 `device/durability-safe.json` 开始看，原始日志不公开。

## 2026-10-06 方案500架构决定已确认

用户确认 [ADR 0003](../adr/0003-native-worker-with-project-linux.md)（accepted）：原生 Worker 为主、Linux 为项目兼容插件，9P 共享模式选 `none`，首个正式范围的隔离语义为“事后检测并转为冲突”，独立 uid 加固留作后续。[ADR 0001](../adr/0001-local-linux-emulation.md) 中“Harness 在 Linux 内运行”的部分被取代；`CONTEXT.md` 新增原生工作区、Linux 兼容插件、预热、执行路径、能力声明、写租约、草稿等术语，并改写用户盘定义。

[PR38](https://github.com/lvivvde/deepseek-harness-ipad/pull/38) 只含真实模型闭环提交，已先合入 main；架构决定提交 `e2e888c` 随后直接推到 main（本地已在 main，非经 PR 审阅）。用户要求合并后关闭 #32，#17 解除技术阻塞。#17 的实现须先关闭 ADR 0003 列出的六项前置关口（G2 耐久、G1 增量流、G3/G5 Git/hook、官方工具等价、G7 迁移回退、私有接口检测），任一不通过就收紧兼容范围。确认决定不触发正式 App 安装、用户盘迁移或新设备安装。

## 2026-10-06 #17 按 ADR 0003 重整与前置关口清单

本轮只整理 Issue 与交接，未写代码、未连设备、未打包安装。[#17](https://github.com/lvivvde/deepseek-harness-ipad/issues/17) 正文已按 ADR 0003 重写（范围、非范围、完成条件、保留约束），并移除 `needs-triage`，只留 `wayfinder:task`；原正文备份与本轮草稿在忽略的 `build/issue-drafts/`。

六项前置关口合并为一个任务清单 [#39 03.1｜ADR 0003 六项前置关口](https://github.com/lvivvde/deepseek-harness-ipad/issues/39)（`ready-for-agent`），每项含验收判据、真机与 macOS 证据分工及不可替代说明，完成一项勾一项并在 #39 评论附脱敏证据。#17 被 #39 阻塞，#39 是 #17 唯一的子 Issue。曾拆出的 #40–#44 已关闭（not planned）并指向 #39 对应关口。

用户定的拆票规则：开放 Issue 尽量少；有阻塞关系的不合并（#17←#39、#18←#17、#23←#18、#14←#17 保持独立），同一层级、无相互阻塞的细项写成任务清单。

| 关口 | 内容 | 类型 | 先后 |
| --- | --- | --- | --- |
| 1 | G2 原生工作区、会话与草稿的崩溃耐久 | 硬关口 | 可立即开始 |
| 2 | `pthread_fchdir_np` 启动检测与 Linux 插件不可用 | 硬关口 | 可立即开始 |
| 3 | 官方 fs、编辑、搜索与原生只读 Git 接入原生工作区 | 可收紧 | 等关口 1 |
| 4 | G1 模型回复增量流式、取消、认证与网络错误 | 可收紧 | 可立即开始 |
| 5 | G3/G5 Git 写操作与 hook 的一致性和提交前拦截 | 可收紧 | 等关口 2、3 |
| 6 | G7 从隔离备份迁入、逐文件核验与回退旧包 | 硬关口 | 等关口 1 |

用户确认的决定（已写入 #39 各关口）：

- 真机证据只来自独立 bundle ID 的候选 App；G7 用专用测试 bundle ID 演练旧包→新包→回旧包，数据为合成数据加一份由用户在 iPad“文件”App 导出的真实备份副本（不经 Mac）。正式 App 升级与真实数据迁移不属 #17，须另获授权。凭据不迁移。
- 崩溃恢复以工作区为准、不回滚：会话回到最后完整检查点，未记录完成的工具调用标“结果未知”且不重放，草稿保留，change generation 不一致在会话中标出。
- 原生 Git 只读；所有修改仓库的 Git 操作和全部 hook 走 `linux` 路径，原生不写 `.git/index`。
- G2、G7、私有接口检测为硬关口；工具等价、G1、G3/G5 不通过时可收紧兼容范围，每次须用户确认。
- 关口之后的集成实现暂留 #17 正文，不预先拆票。

#18、#23、#14、#15 正文已与 ADR 0003 对齐（只改正文，评论未动）：#18 补“与 ADR 0003 对齐”节（`/root/projects`、凭据库与 Landlock 参数转为历史；Git 写与 hook 走 `linux`，凭据存储随 #39 关口 5）；#23 明确“重试”是重提任务、同进程不重启 QEMU，dev server 按能力声明默认 `linux`，阈值改由本票开工前提出并经用户确认（#32 未给阈值）；#14 增列 Worker bundle、适配补丁、原生只读 Git（#39 关口 3）与原生搜索；#15 改为 #32 已关闭、#17 经 #39 前置关口推进。#18、#23、#14 仍带 `needs-triage`，本轮未处理。

分支清理（用户要求）：已合入 main 的 13 个远端分支及对应本地分支、一个干净的旧 worktree 已删除；PR 合并后其分支一并删除。另 7 个从未合并的旧分支也按用户要求删除：5 份早期研究报告先原样归档到 `docs/research/`（ipa-distribution、ipad-local-runtime、runtime-licensing、upstream-android、utm-se-embedding，文首注明原分支与提交）；`codex/ipad-architecture-baseline`、`docs/runtime-delivery` 只含 main 已有文件的旧版本，直接删除。对应的干净 worktree 一并移除。远端现只剩 `main` 与本 PR 分支。

#37（续签与恢复验证维护）已由用户于 2026-10-06 取消并关闭；不再主动提醒续签，除非用户提起。

下一步：#39 的关口 1、2、4 可并行开工，推荐先做关口 1（关口 1 进展见上节）。上方“PR / Issue 收尾”节中的开放任务与依赖描述为当时历史，以本节和 GitHub 为准。

## 2026-10-06 PR / Issue 收尾

用户要求把已完成交付实际合并和关单。本轮 PR36 的研究代码、报告与 proposed ADR 合入 main；架构决定仍未生效。#19 的备份恢复、同身份续签覆盖、83 文件保留及导出修复已交付，关闭为 completed；剩余续签/恢复缺口转入 [#37 维护跟进](https://github.com/lvivvde/deepseek-harness-ipad/issues/37)，不是登记历史故障已修复。旧评论及下方日期记录保留为历史。

当前开放任务为 #15、#37、#32、#17、#18、#23、#14；#1/#16/#19 已关闭。路线图维护入口改为 #37，其余依赖保持 #17←#32、#18←#17、#23←#18、#14←#17。#37 独立于研究，正式签名须在 2026-10-12 15:49:52 前续签；研究的真实模型小闭环已在 iPad `none` 模式有界通过，下一步为用户确认方案500架构决定。完整 G0–G7、正式实现和取消锁屏的边界保留。

合并只结算研究交付，不启动 #17、不迁移正式用户盘、不新增设备安装。后续新 PR 合并仍按已有约定另获用户同意。

## 当前研究接手

继续方案500 #32 时，先读 [iPad 研究 App 真机报告](../research/plan500-ipad-preflight.md)和 [Darwin 报告](../research/plan500-darwin.md)，再按需读[写租约报告](../research/plan500-write-lease.md)、[共享/RPC 报告](../research/plan500-sharing-rpc.md)、[候选研究](../research/plan500-feasibility.md)及原型 README。PR36 已合入 main；新研究工作从含该交付的 main 接手，原 `research/plan500-feasibility` 分支已于 2026-10-06 按用户要求删除，提交保留在 main 与 PR36。

统一写租约、版本冲突与 change generation 已在真实 Linux 上完成有界验证（两种模式各 26/26）；Darwin/macOS 与 Swift 网关原型也完成了有界验证。**独立研究 App 已签名、安装并在 iPad 上运行：`none` 和 `mapped-xattr` 各 15/15 必需检查通过。** iPad 研究容器样本保留大小写不同的名称；`none` 不能建 FIFO/socket，`mapped-xattr` 宿主 mode/symlink 不普通。私有 `pthread_fchdir_np` 符号存在且实际 9P backend 可运行，完整语义与私有接口条件仍未解决。Worker 与 Swift 网关协作现已通过两模式的有界真机检查，真实模型小闭环也已在 `none` 模式有界通过，**当前下一步是形成并由用户确认架构决定**；详见下方本轮入口。同 uid 经 /proc、SCM_RIGHTS、CAS TOCTOU 及完整 G0–G7 缺口保留。#32 OPEN，#17 等待架构决定。

用户于 2026-10-06 明确允许删除三个占位项目 App 及后续项目 IPA，不重复询问卸载；本次只移除独立验收 runner，Harness 与 LinuxPrototype 保留。签名安装授权继续有效。真机收据从忽略的 `build/prototypes/plan500-ipad/device-r1/device-validation-safe.json` 接手；原始日志不公开。下方历史状态以本入口及 GitHub 当前状态为准。

## 2026-10-06 Worker 与 Swift 网关协作接手

本轮详见[Worker/Swift/Linux 接缝报告](../research/plan500-worker-gateway.md)。独立研究 App 中，官方 Worker 工具注册器接三个研究工具；项目唯一权威目录通过 Swift Gateway 和真实 9P 共享。iPad 两模式各 23 项协作检查 + 9 项真实 App 进程恢复检查通过。会话只检查点 `/dsh/home`，原生项目和草稿分别持久化；不是完整 fs provider 或跨文件事务。

真实模型小闭环（分支 `research/plan500-real-model`）：用户在研究 App 自行输入 Key，`none` 模式 8/8 通过——7 次 HTTP 200、带版本修改 `math.cjs`、一次非精确命令被守卫派发前拒绝后精确 `node test.cjs` 成功、最终回复与 `turn/end(completed)`。SSE 仍缓冲交付，`mapped-xattr` 未跑模型。通过收据 `build/prototypes/plan500-ipad/worker-device-r4/model-result-safe.json`；审查修复（成功收据改脱敏轨迹、错误码允许表、未知工具/重复 callId 判越界）后 10 项判据测试、`make check` 和 macOS 两模式 23 + 9（`worker-host-trace-r3/`）通过，未在真机重跑模型。

下一步（已完成）：方案500架构决定已由用户确认，见上方“架构决定已确认”。G0–G7 / 私有接口 / 完整隔离与 Git/hook 缺口转为 #17 的前置关口。正式数据不变，取消的锁屏测试不重启。

研究签名继续截止 2026-10-13 01:02:35（北京时间），本轮同身份覆盖安装，未卸载任何 App。私有设备资产在 `build/prototypes/plan500-ipad/worker-device-r1/`；只查看脱敏收据，Key 不从聊天获取、不可读取正式 App 的凭据。代码审查及复审已完成：Standards 无硬违反，Spec 三项模型误判均已修复，5 项判据测试通过。最终源码/资产的真机复跑在 `worker-device-r2/`，macOS 两模式 23 + 9 在 `worker-host-final-r3/`。模型及正式架构确认仍待完成；[ADR 0003](../adr/0003-native-worker-with-project-linux.md) 仅为 proposed，不改变既有决定。

## 当前代码与交付

- 正式 iPad 交付代码基线：`7956e8c`，已包含 PR #34 的导出中断修复，签名预检通过。仓库 main 已合入 PR35 的交付记录及 PR36 的研究代码；正式 App 尚未包含 PR36，接手时查询最新提交。既有用户项目不会因为示例更新而被覆盖。
- 真机工具及本交接最初由已合并的 [PR31](https://github.com/lvivvde/deepseek-harness-ipad/pull/31) 交付；维护任务从 main 接手，方案500研究从已合入 PR36 的 main 接手。
- 当前安装包为 **7956e8c**：`build/maintenance19/r2-7956e8c/HarnessApp-0.1.0-main-7956e8c.ipa`，已同身份覆盖安装，安装前后 83 个文件一致。签名未延期，截止仍为 2026-10-12 15:49:52（北京时间）。详见末尾“导出修复真机交付”。
- 当前正式包签名截止：**2026-10-12 15:49:52（北京时间）**。已核验实际新 profile；后续仍以真实签名检查为准。
- #1 保持关闭并改名为历史规划归档；#16 原 M1 入口保持关闭。当前总路线图改由 #15 承载，历史证据与已完成状态不变；尚未通过的旧验收在对应新范围中保留，不自动扩展测试。

| 开放任务 | 下一步与边界 |
| --- | --- |
| [路线图：iPad 原生基础能力与 Linux 兼容插件](https://github.com/lvivvde/deepseek-harness-ipad/issues/15) | 当前总入口；开放子 Issue 顺序 37→17→18→23→14，#32 已关闭，#19/#16 作为历史子项保留。架构基线为 ADR 0003（accepted）。 |
| [03｜实现：原生运行时、共享工作区与 Linux 插件预热](https://github.com/lvivvde/deepseek-harness-ipad/issues/17) | 架构决定已确认（ADR 0003），#32 阻塞已解除；被 #39 阻塞，先完成其六项前置关口（关口 1、2、4 可并行），再做原生 Harness 宿主、同一项目工作区、准备/就绪/取消/失败调度；保留旧 Linux 和用户盘保护。资源、低空间、删除回收等未验转兼容插件技术债，不标记通过。 |
| [04｜验收：小型项目的 Git 获取、开发、测试与推送闭环](https://github.com/lvivvde/deepseek-harness-ipad/issues/18) | 被 #17 阻塞。正文已对齐 ADR 0003：按能力声明区分原生/插件路径，Git 写与 hook 走 `linux`（#39 关口 3、5）；真实模型修改、审阅、测试、hook 顺序及授权远端推送；既有模拟结果保留，Vite production build 超时仍未知。仍带 `needs-triage`。 |
| [05｜验收：插件、预览、键盘与前后台交互](https://github.com/lvivvde/deepseek-harness-ipad/issues/23) | 被 #18 阻塞。验证插件预热及任务等待、两种执行路径的预览/HMR、中文/键盘和恢复交互；同进程不重启 QEMU，阈值在开工前提出并经用户确认。仍带 `needs-triage`。 |
| [06｜发布前：实际分发组件的许可证与对应源码审查](https://github.com/lvivvde/deepseek-harness-ipad/issues/14) | 被 #17 的实际组件清单阻塞，可与后续交互验收并行准备；新增 Worker bundle、适配补丁、原生只读 Git 与原生搜索的审查。需要适当法律判断，本轮不发布 GitHub Release。仍带 `needs-triage`。 |

### 2026-10-05 用户授权的任务重排

用户已授权调整标题、范围和执行顺序。7 个开放任务改为上表范围，旧代码、验证、失败和取消记录保留；#1 历史归档与 #16 原入口均不重开。#15 为当前父路线图；#14 从旧地图移入当前路线图。旧认领与不合适的就绪标签已清理，未开始实现、打包、安装或锁屏。

重排时 #32 的人工阻塞仍有效，随后已由用户于 2026-10-05 明确解除并授权研究，见当前研究入口。#17←#32、#18←#17、#23←#18、#14←#17 的原生 blocked-by 继续有效；#19 的旧 #17 依赖已移除，维护不等重构。接手时核对技术依赖和当前人工约束，按已获授权范围推进，架构决定前保留 ADR/CONTEXT。

## 已有证据

- 27 Swift、14 guest（无跳过）、16 完整 Linux/QEMU、9 恢复故障注入通过。菜单截图 OCR 与模型工具声明/实际执行/结果回归均为修复前红、修复后绿。
- 正式 IPA 覆盖安装成功；新包启动 170.037 秒。真实 Home 短切换检查 6.401 秒，输入原值相同；它不是物理锁屏。
- 约 30 分钟锁屏后页面可交互、已有会话固定请求完成。首次实际解锁时间未采样；3.613 秒只是已解锁后的检查，不能作 ≤10 秒证据；5.981 秒是请求到回复时间。
- 独立模拟验证草稿/终端重载保留、侧栏删除同步、Vite 更新、自建 Git 远端 push 和跨 guest 项目归档。不是正式 iPad 的全部数据完整性或 S 档七步通过。
- 未通过/未解决：guest Vite production build 超时；删除/trim 后未观察到宿主 raw 占用下降。不要猜测根因或承诺原盘压缩。

完整范围见 [非锁屏验收](../validation/ipad-non-lock-acceptance.md)、[后台恢复](../validation/ipad-background-recovery.md)、[备份恢复](../validation/ipad-recovery-backup.md)、[存储工具](../validation/ipad-storage-tools.md)。

## 本机接手资产

这些路径都相对仓库根，全部在忽略的 `build/`；其他机器可以从源码重建工具，但需要重新配对、签名和准备本机资源。

- `build/device-acceptance/local-settings.json`：本机 runner 签名设置，文件权限 600；`selected-device-private.json` 是多设备时可用的私有选择记录。单设备自动发现无需后者。
- `build/device-acceptance/portable-signed-final/derived/Build/Products/`：本轮独立签名 runner 的 xctestrun。测试源码变更后按真机工具说明重建，不用旧 runner 冒充新源码测试。
- `build/acceptance-archive/2026-10-05/`：旧日志、xcresult、截图、模拟脚本及锁文件、脱敏结果、历史交接与 SHA256 清单。2055 个验收文件已逐项验证复制一致；排除了解包 IPA、node_modules 和派生构建。原始证据不可贴聊天、提交或公开。
- `build/test-dependencies/harness/`：固定官方 `@deepseek-ai/dsh@0.2.0-rc.2`、pnpm 11.28.4 的宿主测试依赖和 lock。设置 `HARNESS_TEST_MODULES="$PWD/build/test-dependencies/harness/node_modules"` 后运行 `make test-runtime`，核对无跳过。依赖丢失时在此目录用保留的 lock 重装，不需要用户 token。
- 既有 Lima `ubuntu` 内 `/var/tmp/ipad-bundled-guest-storage-v6` 可跑 Linux 验收，使用新临时盘。`/Users/edwin` 为只读挂载，`/private/tmp` 不挂载；跨机器用 runtime 构建流程重建该资源。Linux/QEMU 仅用隔离盘，不读取 iPad 原盘。
- `harness-30` 锁屏提醒已暂停。没有 8 小时起点/提醒，后续接手也保持取消状态。

## 持续约束

保护正式 Harness 数据和现有草稿；覆盖升级只用同签名身份，保留原盘。2026-10-06 用户明确允许删除三个占位项目 App（Harness、LinuxPrototype、DeviceAcceptance runner）及后续项目 IPA，卸载不再重复询问；按实际需要选择清理对象，本次仅移除 runner。此授权不扩展为其他 App 或数据清理。不能在同进程重新初始化未经验证的 QEMU。VM 真退出时保存固定诊断，明确关闭重开。

设备标识、签名身份、凭据和原始串口只留私有日志；token 由用户在设备适当入口自行输入，不从聊天取值、不替用户输入。小事直接处理，少安装/打包；后续物理锁屏已取消，不安排提醒或等待。API 及 Token 消耗无需另问，但外部 Git push 仍要有用户授权的测试远端。

## 本轮工具验证

真机工具的 11 项无设备行为测试通过；实际生成的签名 xctestrun 已确认只有独立 runner/测试 bundle 依赖。无签名与个人团队签名 build-for-testing 成功。只读 probe 实际识别已配对 iPad、确认 Harness 已安装，初次 probe 返回锁定并正确停止；用户正常解锁后，新 CLI 和最新独立 runner 的 `page` 真机检查通过，页面检查阶段约 7.145 秒。固定状态复制返回 `recovery:pageReady`，`settings` 真机检查也通过（容量、备份/恢复入口可见并关闭设置）。GUI 辅助脚本类型检查通过。该数不是首次解锁恢复耗时，旧 runner 的锁屏验收边界继续保留。


## 2026-10-05 Issue #19 本机维护：工具阶段

新增只读 `runtime/check-signing.py`，检查新旧 IPA 的 SHA256/ZIP、签名、应用身份、钥匙串组、描述文件设备与 profile/证书有效期；不调用设备工具或修改原资产。16 项 CLI 测试、27 Swift、14 guest（无跳过）、11 真机工具及 `make check` 通过。真实 da2d0aa IPA 预检通过，截止仍为 2026-10-10 21:11:14（北京时间），未延长；真机现有页面检查通过，约 3.650 秒不作为首次解锁恢复耗时。

以上为工具阶段的历史记录，随后实际备份、续签覆盖与数据核验见下节。历史恢复、实际时差和救援盘仍未验证，#19 保持 OPEN。详细边界见 [维护与重签前校验](../validation/ipad-signing-maintenance.md)，私有日志/安全收据在忽略的 `build/signing-check/` 和 `build/device-acceptance/`。接手时保留本轮开始前已有的任务重排文档改动。


## 2026-10-05 Issue #19 授权续签交付

实际已从 `da2d0aa` 同身份覆盖到代码基线 `3dd1301`；候选 IPA 及 SHA256 在 `build/maintenance19/`，新签名截止 **2026-10-12 15:49:52（北京时间）**。真实预检、候选 App 与归档逐文件一致及系统覆盖安装成功；未卸载或发布 Release。

真实备份 651776 字节，SHA256、布局和排除项通过；安装前备份在禁外网的临时 Linux 用户盘恢复成功，全部 83 个文件摘要一致，损坏归档被拒绝后有效副本仍保留。安装后再次导出，与安装前全部 83 个文件摘要一致，原空草稿保留。新运行时原有 16 项 QEMU 检查通过。新包固定冷启动 ready 约 175.224 秒，UI 观察约 196.371 秒，均不作首次解锁耗时证据。

导出曾出现连接/网络中断，固定诊断为 userDataOperationFailed，重试成功；根因未确认，不能写成已修复。下一步优先诊断可复现的导出问题，按新截止继续维护；历史长后台、首次解锁、时差和救援盘仍未验，#19 保持 OPEN，不重启取消的锁屏/8 小时测试，不解除 #32。原 App 仅在有界同步后冷重开，未同进程重建 QEMU；未直接读/换正式原盘。原始证据、签名缓存备份及安装前后 tar 留在私有 `build/maintenance19/`，接手从 `delivery-receipt-safe.json` 与[维护记录](../validation/ipad-signing-maintenance.md)开始。


## 2026-10-05 Issue #19 导出中断诊断与修复

- **根因**：完整备份前 supervisor 只等 dsh 退出 8 秒。dsh 刚启动或重启后可能很久才处理 SIGTERM：隔离 QEMU 实测 14–98 秒。超时后暂停失败，而传输服务已发出 200 响应头，只能断开连接，于是 App 显示“网络连接已断开”。重试时 dsh 已退出，所以成功。
- **修复**：只对 Harness 本身最多等 180 秒；暂停成功后才发响应头；暂停被拒时返回固定错误，诊断记录固定代码；宿主空闲超时 300 秒。
- **当前状态**：runtime 32 项、Swift 29 项、Linux supervisor 用例和修复后 guest 循环导出均已通过。PR #34 已合并为 main `7956e8c`。详情和边界见[维护记录](../validation/ipad-signing-maintenance.md)的“导出中断诊断与修复”。
- **真机**：已安装并复测，见下节。
- **私有资产**：反馈循环 `build/export-diagnosis/export-loop.py`、实验 guest 生成脚本与变体、Lima 实验盘 `/var/tmp/export-diag/`（可删）。Lima 内另有一个不属于本任务的 QEMU，不要动。

## 2026-10-05 Issue #19 导出修复真机交付

- **当前状态**：main `7956e8c` 已同身份覆盖安装到 iPad，App 留在前台，阶段为 `recovery:pageReady`。
- **已验证**：
  - 安装前，旧包首次导出再次断开，重试成功，复现了原问题。
  - 安装后，冷启动后首次导出（约 40 秒）和重启 Harness 后立即导出（34.3 秒）都一次成功。
  - 安装前后的真实备份中 83 个文件全部一致。
  - 新 guest 在 QEMU 中启动验收 16/16，限速重启后导出 3/3。
- **未完成**：
  - 签名未延期（`renewalExtended=false`）。
  - `Could not connect to the server.` 未复现。
  - 历史长后台、首次解锁、时差和救援盘未验证。
  - #19 保持 OPEN。
- **下一步**：
  1. 在 2026-10-12 15:49:52（北京时间）前获取新 profile，从 `7956e8c` 或之后的 main 重签。
  2. 另获安装授权后再安装，安装前后照旧做真实备份和 83 文件比较。
- **私有资产**：`build/maintenance19/r2-7956e8c/`，从 `delivery-receipt-safe.json` 开始看。导出用例超时可能截断冷启动，可用同目录的 900 秒版本 `run-check-long-private.py`。

## 2026-10-05 方案500研究授权与维护收尾

- 用户已授权合并 [PR #35](https://github.com/lvivvde/deepseek-harness-ipad/pull/35)，已进入 main `0edae81`；这是交付记录，正式 iPad 的代码基线和签名截止仍为 `7956e8c`、2026-10-12 15:49:52（北京时间）。#19 正文已同步安装版本、真实导出结果与 83 文件比较，保持 OPEN。
- 用户随后明确回答“解除阻塞，进入可行性研究和架构决策”。此授权取代上述历史 #32 人工阻塞，已移除 `blocked` 并认领研究；#17/#18/#23/#14 的技术依赖继续有效，架构决定前不更新 ADR/CONTEXT。
- 研究分支：[research/plan500-feasibility](https://github.com/lvivvde/deepseek-harness-ipad/pull/36)（分支已在合并后删除，提交保留在 main 和 PR36）。报告保存为 [方案500可行性研究](../research/plan500-feasibility.md)，区分固定源码事实、方案推断和未通过的 iPad 验证关口。
- 本轮不打包或安装，不读取、迁移或替换正式用户盘；取消的锁屏测试继续取消。实际 QEMU 二进制仅作只读静态字符串检查，不能登记共享目录可用。脱敏收据在忽略的 `build/research/plan500/`。
- 已核实：固定官方源码有实验 Worker/packer 接缝，但目前面向预览；现成 mobile Node 为 18.20.4，不满足固定上游 Node 版本要求。官方 plugin-manager、stdio MCP、JSONL 锁/验证线程存在独立平台依赖；hook 基础设施失败可能默认非阻断，因此 Linux 就绪门禁必须位于调用 hook 之前。研究报告提供精确源码链接和未知项，不登记 iPad 可用性通过。
- 下一步建议：先评估官方 Worker + iPad 工作区桥 + Linux 能力网关候选，优先验证无 VM 的核心与耐久存储、同一工作区双向语义和预热就绪门禁。用户随后已接受该候选并授权隔离原型，见下一节；#32 不因研究或部分探针完成自动关闭，#17 不自动启动。


## 2026-10-05 方案500隔离 Worker 原型

- 用户已授权“官方实验 Worker + Swift 工作区桥 + Linux 能力网关”候选的隔离原型验证。继续 `research/plan500-feasibility` 和 [PR #36](https://github.com/lvivvde/deepseek-harness-ipad/pull/36)，不另建正式实现分支；PR 合并仍需另获用户同意。
- 可复跑源码：[原型说明](../../runtime/prototypes/plan500-worker/README.md)，入口 `python3 runtime/prototypes/plan500-worker/run.py`。固定两个 npm lock；依赖仅在忽略 build 中，原先 Harness 测试依赖只读复用。`--install` 会安装到独立 prototype 目录且禁用 install scripts。
- 真实 macOS WKWebView 14/14：官方核心加载 860 模块，无 Linux 启动；会话创建、中文标题、中文文件经 Swift 检查点确认后，Worker 终止重建再重开会话均恢复；注入检查点拒绝不误报 saved，上一有效文件保留；schema 拒绝回归通过。
- 注入调度模型 7/7：打开项目立即开始一次准备，队列等 ready，自动续执行/去重/取消/超时/失败/项目关闭/disabled 行为通过。不是实际 Linux、Git 或 hook 的验收。
- 必要适配均保留在 scratch/Worker 副本：固定 Zod 4.6.5 的 CJS 导出选择、WebKit disposal 符号补齐、两处原生 Object/Array 字符串比较。去掉 Zod/schema 适配的负对照 HTTP 503；不得宣称上游逐字节原样可运行。官方会话 flush 必须先于 Swift 确认；列表缓存滞后时以重开会话的权威投影为准。
- 本阶段未验：iPad/真实模型/完整 UI/实际 RSS；App 或系统崩溃、并发写、损坏日志、压缩日志迁移。共享文件及真实 Linux RPC 的后续证据与缺口见下一节，不能把本阶段的缺项当成最新总状态。完整 G0–G7 均未通过；原型 snapshot 不直接进入产品。
- 本阶段提出的双向共享与真实就绪/RPC 探针已由下一节完成。当前下一步见本文件开头；ADR/CONTEXT 未改选，#32 OPEN、#17 保持依赖。正式 iPad 仍是 `7956e8c`，签名截止仍为 2026-10-12 15:49:52 北京时间；未接触设备或原盘，锁屏测试继续取消。
- 复现：两个提交的 lock 已在独立目录 `npm ci --ignore-scripts` 全新安装，14 + 7 项重新通过；最终启动器检查安装完成标记，半成品依赖目录不会冒充可用树。`make check` 和 PR CI 通过。
- 私有资产：`build/prototypes/plan500-worker/run-safe.json`、`unadapted-run-safe.json`、检查点/镜像/原始日志。启动器的本机 HTTP 服务会在结束时关闭，无需手工留下服务器。

## 2026-10-05 方案500共享工作区与真实 Linux RPC

- 用户授权“开始下一步”，已完成隔离共享与真实 boot/RPC 探针；继续研究分支及 draft [PR36](https://github.com/lvivvde/deepseek-harness-ipad/pull/36)，PR 合并仍需另获同意。源码和入口见[共享探针](../../runtime/prototypes/plan500-sharing/README.md)、[结果报告](../research/plan500-sharing-rpc.md)。
- 实际 Linux QEMU 10.2.1，两种 9P 模式各 **23/23 必需协议检查**：双向中文文件、原子替换/旧 fd、真实 Git index.lock、一次异步准备、ready 验挂载/身份/工具/RPC、队列与去重、关闭/取消/超时、断连无副作用和无 VM 重启。未启动 guest Harness、未接官方 Worker/Swift 调度。
- **共享语义未通过**：mapped-xattr 的普通宿主 mode/symlink 不等价；none 在本 Linux 样本保留二者。两者均未协调实测 host flock→guest flock、host lockf→guest flock、guest flock→host flock；guest fs.watch 700ms 样本目标事件为 0，显式轮询成功。Git 命名 index.lock 通过不等同于跨域 flock 通过。两者有一个真实 pre-commit 非零阻止提交的用例，不代表完整 hook 验收。
- Darwin SDK 27.0：公共头文件无法声明 pthread_fchdir_np，显式私有声明后 macOS/iOS 链接成功、macOS 自有 scratch 运行成功；iOS 未执行、QEMU backend 未测，不证明公开接口适用性。后续共享实现必须单独处理此条件。
- 隔离边界：只读 system.raw + RAM overlay、锁定 modloop 中补 9P/overlay 模块、自己的合成 workspace；没有打开 user.raw/user-seed.raw、设备或正式原盘。自己的探针 QEMU 已退出，既有 Lima 与无关 QEMU 保留。agent 仅执行可信合成命令，不是产品沙箱；去重只覆盖单 agent 生命周期。
- **下一步**：验证统一写租约、文件版本冲突、失败/取消后的 writer 存活边界及明确 change generation/轮询；所有原生/Linux 写者都须进入合同，不能只锁宿主而放任 guest 直写。随后做 Darwin/iPad、真实模型及网络。完整 G0–G7 未通过，ADR/CONTEXT 未改选，#32 OPEN、#17 继续依赖。
- 私有收据：`build/prototypes/plan500-sharing/linux-result-safe.json`、`darwin-api-safe.json`，原始串口只留本次自己的 Lima scratch。正式 iPad 仍 `7956e8c`，签名截止仍 2026-10-12 15:49:52 北京时间；锁屏/8 小时测试继续取消。
- 交付检查：23+23 项真实 Linux 收据已核对源文件 SHA256；Darwin 小探针、Python/Node/shell 语法、本地文档链接和 `make check` 通过。本次 QEMU 残留数为 0；原型观测的失败语义保留在报告中，不作为兼容性通过。

## 2026-10-05 方案500统一写租约与 change generation

- 用户要求“继续推进”，按上节下一步完成写者合同探针；继续研究分支及 draft [PR36](https://github.com/lvivvde/deepseek-harness-ipad/pull/36)，PR 合并仍需另获同意。源码见[写租约探针](../../runtime/prototypes/plan500-lease/README.md)，结论见[写租约报告](../research/plan500-write-lease.md)。
- **已验证**：实际 Linux QEMU 10.2.1，`none` 与 `mapped-xattr` 各 **26/26**。
  - Python 网关是唯一的租约/fence/generation 发放者，状态 fsync 持久化。原生写入按版本比较后交换，冲突不覆盖；租约期间的原生编辑成为持久草稿，释放后 rebase 为 APPLIED/CONFLICT；guest 可轮询 generation，漏掉的通知会补齐。
  - guest 只暴露 `ro,nosuid,nodev` 的 `/workspace`。持租命令在私有 mount namespace 中以 owner uid 写入，无租命令为 reader uid，user namespace 关闭。
  - 每个命令拥有独立 cgroup，`cgroup.kill` 加 sweep 后才确认写者停止。`setsid`、超时、取消、RPC 断开、网关重启、`/revoke` 和 VM 退出都不会过早释放租约。另有一项去掉 sweep 的负对照，证明 sweep 是必需的。
- **未完成**：同 uid 无租进程经 `/proc/<leased>/cwd` 写入未被阻止，只能在释放时检测；SCM_RIGHTS 未直接构造；原生 CAS 存在 TOCTOU；只有整工作区租约；网关不是 Swift；Darwin/iPad、模型、网络和官方 Worker 接入均未验证。G3 未通过，G0–G7 未完整通过，ADR/CONTEXT 未改选，#32 OPEN、#17 继续依赖。
- **下一步**：验证 Darwin/iPad 文件行为与 9P backend 的可行性（含 `pthread_fchdir_np` 私有接口条件），把网关移植为 Swift 并接入官方 Worker 的原生写入，再做模型/网络路径，之后在 #32 形成用户架构决定。
- **私有收据**：`build/prototypes/plan500-lease/result-safe.json`；原始串口只留在 Lima 的 `/var/tmp/plan500-lease-*`（可删）。本次探针 QEMU 残留数为 0，无关的既有 QEMU 未动。正式 iPad 仍为 `7956e8c`，签名截止仍为 2026-10-12 15:49:52 北京时间；锁屏/8 小时测试继续取消。

## 2026-10-05 方案500 Darwin 9P 与 Swift 网关

- 用户要求“继续下一步”，按上节完成 macOS 宿主上的 Darwin 9P 与 Swift 网关探针；继续研究分支及 draft [PR36](https://github.com/lvivvde/deepseek-harness-ipad/pull/36)，PR 合并仍需另获同意。源码见 [Darwin 探针](../../runtime/prototypes/plan500-darwin/README.md)，结论见 [Darwin 报告](../research/plan500-darwin.md)。
- **已验证**：Homebrew QEMU 11.1.2 在 macOS 上用 Darwin local fsdev 原样运行写租约 26 项检查，覆盖区分大小写 APFS 稀疏镜像与默认卷、Python 与 Swift 网关、`none` 与 `mapped-xattr`，结果见报告。Swift 网关崩溃用真实 SIGKILL；`swift test` 与 iOS 模拟器单元测试通过。
- **新约束**：
  - `none` 下 guest 无法在共享工作区建 FIFO（ENXIO）或 Unix socket（ENOTSUP）。原因在 QEMU Darwin backend 源码（无 O_PATH，打开特殊文件失败后删除节点），UTM 10.0.12 相同；`mapped-xattr` 把它们模拟成普通文件，且宿主 mode/symlink 不再普通。
  - libslirp hostfwd `listen(s, 1)`（IPA 内 4.9.1 相同）遇到 XNU 会对溢出连接回 RST，并发 RPC 随机重置；Linux 不会。`backlog.py` 无 VM 复现。探针加了单上游连接闸门后不再出现。正式 App 的页面/传输/预览 hostfwd 可能受影响，未验证。
  - 大小写不敏感卷上只差大小写的文件名静默合并。
  - 正式 IPA 静态检查：QEMU 10.0.12 iOS 构建含 9P backend，weak import 私有 `pthread_fchdir_np`。
- **未完成**：没有 iPad 运行；Swift 网关未进 App/QemuBridge/官方 Worker；同 uid /proc 绕过、SCM_RIGHTS、CAS TOCTOU 仍在；模型/网络未做。G3 未通过，G0–G7 未完整通过，ADR/CONTEXT 未改选，#32 OPEN、#17 继续依赖。
- **下一步**：经用户另行同意（含签名与安装细节）后，用独立 bundle ID、独立容器、合成工作区与 guest 的研究 App 在 iPad 上验证 9P backend、`pthread_fchdir_np` 与连接闸门，不接触正式 Harness 数据；随后把 Swift 网关接入官方 Worker，再做模型/网络。
- **私有收据**：`build/prototypes/plan500-darwin/runs/`、`repeat/`；调试目录 `build/prototypes/plan500-darwin/debug*/`（含抓包，可删）。inputs 只从运行时清单抄录 user 盘 SHA256，没有打开原盘。探针 QEMU 与稀疏镜像均已清理，Lima 与无关 QEMU 未动。正式 iPad 仍为 `7956e8c`，签名截止仍为 2026-10-12 15:49:52 北京时间；锁屏/8 小时测试继续取消。

## 2026-10-06 方案500独立 iPad 研究 App 安装前预检

- 用户要求“继续执行”，继续现有研究分支及 draft [PR36](https://github.com/lvivvde/deepseek-harness-ipad/pull/36)。源码见 [研究 App](../../runtime/prototypes/plan500-ipad/README.md)，结果见 [预检报告](../research/plan500-ipad-preflight.md)。没有修改正式 App 目标、ADR/CONTEXT 或启动 #17。
- **已完成**：独立 bundle ID `org.lvivvde.harness.plan500.research` 的 iPhoneOS Release 未签名构建；输入/最终 bundle 校验。Swift 网关 15/15、构建输入拒绝 4/4；同一 App 检查逻辑在真实 macOS QEMU 上两模式各 15/15，直接使用 Swift gate，无 Python 中继。默认卷兼容性限制继续单列，不计入协议通过。
- **设备**：只读 probe 确认已连接、已配对、已解锁、正式 Harness 已安装。没有研究 App 签名、安装、启动或正式数据访问；正式签名截止仍为 2026-10-12 15:49:52（北京时间）。
- **未完成**：真机 9P/backend/沙箱/私有符号运行、VM 退出等完整合同、官方 Worker 接入、模型/网络、性能。既有同 uid /proc 绕过、SCM_RIGHTS 与 CAS TOCTOU 缺口保持；G3/G4 及完整 G0–G7 未通过，#32 OPEN、#17 继续依赖。
- **下一步**：另获独立研究 App 的签名及安装同意，确认 profile 后安装；分别运行两模式，只重启研究 App 进程并取回其独立容器收据。不能为名额自动卸载正式 Harness、LinuxPrototype 或其他 App；锁屏测试继续取消。之后接官方 Worker。
- **私有资产**：`build/prototypes/plan500-ipad/unsigned-final/build-safe.json`、同目录独立 Xcode 工程与未签名 App；`host-none-final/`、`host-mapped-final/` 的随机子目录收据/串口，自己的 macOS QEMU 完成后退出。token、设备与签名参数不公开；不要将此包作为已验证 iPad 交付。

## 2026-10-06 研究 App 首次安装受阻（已解决）

- 用户已明确同意本机现有团队为独立研究 App 签名、安装并运行两模式隔离检查。授权保留，后续不重复询问同一签名安装动作；此首次安装阶段尚无卸载授权，随后用户已明确授权，见下节。
- 独立私有工程经 Xcode GUI Build 取得新 profile，真实深度严格签名、团队/应用标识/钥匙串/证书/当前设备授权及 guest 输入摘要均已核验。研究 App 截止为 **2026-10-13 01:02:35（北京时间）**；正式 Harness 的截止仍为 2026-10-12 15:49:52。
- 实际安装失败：免费开发 App 名额已满。只读清单确认正式 Harness、LinuxPrototype、DeviceAcceptance runner 已安装，研究 App 未安装。没有启动或卸载已有 App、运行研究 guest、操作正式数据。
- 下一步：明确获准后，仅卸载独立验收 runner `org.lvivvde.harness.acceptance.xctrunner`，删除其测试容器以腾出名额，再继续已获授权的研究安装与检查；不能卸载 Harness/LinuxPrototype。若用户不同意卸载，保留签名研究包，等待其他名额解决办法。
- 私有入口：`build/prototypes/plan500-ipad/device-r1/signing-safe.json`、`slot-audit-safe.json`，签名包在 `gui-products/Release-iphoneos/Plan500Research.app`；原始日志/profile/设备信息只留此目录。#32 OPEN、#17 继续依赖，真机证据尚未取得。

## 2026-10-06 项目 App 卸载授权

- 用户明确表示“之前占位的3个APP都可以删。后续如果要卸载IPA文件，可以不用申请权限，直接删除就行。”这取代历史未获卸载授权的限制；后续本项目 App/IPA 清理不重复询问。
- 为处理研究安装名额，已只卸载 `org.lvivvde.harness.acceptance.xctrunner` 及其测试容器；只读清单确认 Harness 与 LinuxPrototype 仍安装。独立 UI runner 后续可按需重装，不影响既有研究签名安装授权。
- 随后研究 App 安装成功并完成两种模式，各 15/15，结果见下节。签名参数、设备标识与卸载收据保存在忽略的 `build/prototypes/plan500-ipad/device-r1/`。

## 2026-10-06 方案500 iPad 真机子集完成

- **已验证**：普通开发签名独立 App 内，iOS QEMU 10.0.12 的 `none` 与 `mapped-xattr` 各 15/15；两份收据 `physicalDevice=true`、`completed=true`，来源与编译源码/输入/签名包摘要核验一致。RPC ready 单次样本分别 8.241 / 8.179 秒，不登记性能验收。
- **兼容性观察**：研究容器样本区分大小写；`none` 宿主 chmod/symlink 普通但 FIFO/socket 失败；`mapped-xattr` 能创建 FIFO/socket，但宿主 chmod/symlink 不等价。私有 `pthread_fchdir_np` 符号存在，实际 9P 执行通过；这些观察不计入协议通过数。
- **设备收尾**：换模式只重启研究 App 进程，每进程一次 QEMU；完成后只停止研究 App，核验 PID 消失。研究 App 保留安装，正式 Harness 与 LinuxPrototype 未更改。没有操作正式数据或执行取消的锁屏测试。独立 UI runner 后续需要时可重装。
- **未完成**：官方 Worker 网关接入、真实模型/网络、完整旧 26 项合同（含 VM 退出/网关 SIGKILL）、稳定性/内存、/proc 绕过、SCM_RIGHTS 与 CAS TOCTOU。G3/G4 和完整 G0–G7 未通过。
- **下一步**：在同一研究分支接官方 Worker 与 Swift 网关，验证原生编辑及 Linux 写者共同遵守租约，再验证真实模型/网络；#32 保持 OPEN、#17 不自动启动、ADR/CONTEXT 不改选。
- **私有入口**：`build/prototypes/plan500-ipad/device-r1/device-validation-safe.json`；两模式 `device-none/latest-result-safe.json` / `device-mapped-xattr/latest-result-safe.json`。签名研究包截止 2026-10-13 01:02:35（北京时间），正式包仍为 2026-10-12 15:49:52。
