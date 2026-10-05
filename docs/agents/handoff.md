# 开发交接

最后更新：2026-10-05，北京时间。此文件是接手入口，GitHub Issues 是任务状态源；旧聊天和临时目录不作为接手前提。

## 开始工作

1. 读根 `CONTEXT.md`、相关 `docs/adr/`，检查 `git status --short`、当前分支和最新提交。保留已有未提交改动。
2. 查 `gh pr list --state open` 和下表涉及的 Issues。已有待合并工具分支时先继续该分支，避免重新实现；每个新 PR 合并都另获用户同意。
3. 真机任务读 [真机自动化](../validation/ipad-device-automation.md)；其他任务读对应验收记录。先用只读 `probe` 确认连接，按明确缺项推进，减少用户交互。
4. 完成后更新本文件的状态、验证和下一步；原始日志/设备/签名参数保存到忽略的 `build/`，公开文档只记脱敏结果。

## 当前研究接手

继续方案500 #32 时，先读[写租约最新报告](../research/plan500-write-lease.md)，再按需读[共享/RPC 报告](../research/plan500-sharing-rpc.md)、[候选研究](../research/plan500-feasibility.md)及三个原型 README。使用现有 `research/plan500-feasibility` 分支与 draft [PR36](https://github.com/lvivvde/deepseek-harness-ipad/pull/36)。

统一写租约、版本冲突与 change generation 已在真实 Linux 上完成有界验证（两种模式各 26/26），同 uid 经 /proc 的绕过仍是缺口。当前下一关口是 **Darwin/iPad 文件行为与 9P backend、Swift 网关接入官方 Worker，随后是模型/网络**。#32 保持 OPEN，#17 继续等待架构决定。下方按时间排列的阶段记录用于追溯，历史“下一步”和阻塞状态以此入口及 GitHub 当前状态为准。

## 当前代码与交付

- 正式 iPad 交付代码基线：`7956e8c`，已包含 PR #34 的导出中断修复，签名预检通过。仓库 main 随后合入 PR35 的交付记录；研究代码仍在 PR36，接手时查询实际分支和最新提交。既有用户项目不会因为示例更新而被覆盖。
- 真机工具及本交接最初由已合并的 [PR31](https://github.com/lvivvde/deepseek-harness-ipad/pull/31) 交付；维护任务从 main 接手，方案500研究继续上述 PR36 分支。
- 当前安装包为 **7956e8c**：`build/maintenance19/r2-7956e8c/HarnessApp-0.1.0-main-7956e8c.ipa`，已同身份覆盖安装，安装前后 83 个文件一致。签名未延期，截止仍为 2026-10-12 15:49:52（北京时间）。详见末尾“导出修复真机交付”。
- 当前正式包签名截止：**2026-10-12 15:49:52（北京时间）**。已核验实际新 profile；后续仍以真实签名检查为准。
- #1 保持关闭并改名为历史规划归档；#16 原 M1 入口保持关闭。当前总路线图改由 #15 承载，历史证据与已完成状态不变；尚未通过的旧验收在对应新范围中保留，不自动扩展测试。

| 开放任务 | 下一步与边界 |
| --- | --- |
| [路线图：iPad 原生基础能力与 Linux 兼容插件](https://github.com/lvivvde/deepseek-harness-ipad/issues/15) | 当前总入口；子 Issue 的顺序是 19→32→17→18→23→14，已完成 #16 留在最后。重排不是新架构实施授权，当前 ADR 尚未改选。 |
| [01｜维护：现有版本的数据保护、恢复诊断与重签](https://github.com/lvivvde/deepseek-harness-ipad/issues/19) | 已验证真实备份、隔离恢复、同身份续签覆盖与安装后内容保留。导出中断已修复（`7956e8c`），真机复测通过：冷启动后首次导出和重启后立即导出都一次成功。须在 2026-10-12 15:49:52 前续签。历史首次解锁/时差和救援盘仍未验，保持 OPEN；后续锁屏已取消。 |
| [02｜方案500：原生优先架构与项目级 Linux 插件预热（可行性研究与架构决策）](https://github.com/lvivvde/deepseek-harness-ipad/issues/32) | 用户已解除人工阻塞并授权研究，已认领，保持 OPEN。Worker、真实共享/RPC 与写租约原型已完成有界验证。**下一步为 Darwin/iPad 文件行为、Swift 网关和模型/网络**，入口见[最新报告](../research/plan500-write-lease.md)；正式实现与用户架构决定仍待完成。 |
| [03｜实现：原生运行时、共享工作区与 Linux 插件预热](https://github.com/lvivvde/deepseek-harness-ipad/issues/17) | 等待 #32 的可行性证据和用户架构决定。原生 Harness 宿主、同一项目工作区、准备/就绪/取消/失败调度；保留旧 Linux 和用户盘保护。资源、低空间、删除回收等未验转兼容插件技术债，不标记通过。 |
| [04｜验收：小型项目的 Git 获取、开发、测试与推送闭环](https://github.com/lvivvde/deepseek-harness-ipad/issues/18) | 被 #17 阻塞。明确原生/插件执行路径、真实模型修改、审阅、测试、hook 顺序及授权远端推送；既有模拟结果保留，Vite production build 超时仍未知。 |
| [05｜验收：插件、预览、键盘与前后台交互](https://github.com/lvivvde/deepseek-harness-ipad/issues/23) | 被 #18 阻塞。验证新架构插件预热及任务等待、两种执行路径的预览/HMR、中文/键盘和恢复交互；旧明确故障的必要维护可在 #19 处理。 |
| [06｜发布前：实际分发组件的许可证与对应源码审查](https://github.com/lvivvde/deepseek-harness-ipad/issues/14) | 被 #17 的实际组件清单阻塞，可与后续交互验收并行准备；需要适当法律判断。不是当前维护的前置，本轮不发布 GitHub Release。 |

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

保护正式 Harness 数据和现有草稿；覆盖升级只用同签名身份，保留原盘；LinuxPrototype 不操作。不能在同进程重新初始化未经验证的 QEMU。VM 真退出时保存固定诊断，明确关闭重开。

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
- 研究分支：[research/plan500-feasibility](https://github.com/lvivvde/deepseek-harness-ipad/tree/research/plan500-feasibility)。报告保存为 [方案500可行性研究](../research/plan500-feasibility.md)，区分固定源码事实、方案推断和未通过的 iPad 验证关口。
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
