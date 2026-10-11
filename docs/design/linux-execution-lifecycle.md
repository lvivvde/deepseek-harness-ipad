# Linux 执行与写租约结算（架构候选 2）

状态：2026-10-11 用户已确认原生侧范围和具体设计；实现、验证与两轴审查已完成；用户已授权推送及创建草稿 [PR #56](https://github.com/lvivvde/deepseek-harness-ipad/pull/56)，base 为 main，尚未合并。基线为 `c81f9dc`（PR #53 已合并）；开工时会话恢复 PR #54 仍开放，本项从 `origin/main` 独立开展，不依赖其未合并实现。

## 问题与证据

有界源码核对发现两个失败路径，均已通过失败测试复现并修正。

1. `ProjectGateway.execute` 取得独立写租约后，`toolStarted` 写入失败，catch 只撤销并入成员，没有释放独立取得的租约。guest 尚未收到 `/execute`，却可能残留 ACTIVE 租约，后续返回 LEASE_BUSY。终端首次写入的相同路径已有撤销逻辑。见 `ios/HarnessApp/Sources/Host/ProjectGateway.swift:202–230`、`359–408`。
2. `CandidateHost.execute` 消费先到的取消记录后直接返回，没有保留该 ID 的终结事实。同 ID 再提交可能被派发。现有 `ProjectGatewayTests` 明确要求取消后同 ID 不运行，宿主测试只覆盖第一次提交。见 `ios/HarnessApp/Sources/Candidate/CandidateHost.swift:235–240`，`HostTests/ProjectGatewayTests.swift:171–183`，`CandidateTests/CandidateHostTests.swift:304–309`。

另有已用受控日志写入顺序复现并修正的状态窗口：准入返回 ready 后、取得租约前 VM 退出，退出处理可能先看见无租约，随后执行仍取得租约并请求已退出的 guest。命令和终端均在持久准备后与进程退出事实核对，再进入可能已派发状态；不以重复 phase 检查代替同步所有权。

本轮没有可用的代码图工具，项目代际和索引覆盖未知；证据来自指定基线中上述源码、LinuxPlugin、LinuxBringUp、GuestRPC、WorkspaceStore 和相关行为测试的定向读取，不声称全库审计。

## 已确认约束

沿用 [ADR 0003](../adr/0003-native-worker-with-project-linux.md) 与 [现有调度合同](linux-plugin-scheduling.md)：每进程单 VM、首个启用项目绑定、失败不重启；执行路径不变更；命令不重放；原生操作不等待 Linux；未知写者仅在既有停止证明或用户显式释放流程下结算。

空闲终端保持只读，运行时取得写租约，模型命令和 hook 并入同一 fence。并入成员结束不能释放终端写者。取消只重试幂等 `/cancel`。旧进程遗留的未知租约不因当前 VM 退出而释放。Guest 协议、终端前端、工作区耐久格式及会话恢复均保持现有合同。

## 三种 interface 比较

| 方案 | interface 与 implementation | depth、locality 和代价 |
| --- | --- | --- |
| A：最少入口 | `open / perform(Request) / guestExited`，请求枚举包含命令和终端 | 统一所有权，leverage 高；枚举仍承载全部操作，容易把项目打开和预热也搬入，迁移较广 |
| B：运行句柄 | `start -> CommandRun`，`terminal -> TerminalSession`；调用者持有句柄并等待 | 适合多个观察者，结算 locality 好；当前同步调用者要新增句柄身份与等待规则，收益有限 |
| C：普通调用优先 | 同步 `execute / cancel`，终端采用类型化操作；保持宿主只做验证和结果转换 | 最贴近现有调用者，减少调用者编排；入口较多，必须真正集中状态而非增加转发层 |

推荐 C，采用 A 的统一状态所有权，保留现有 ProjectGateway 同步调用方式；终端仍按 ID 调用，本轮不引入外部运行句柄。

## 推荐 module 与 seam

在 `HarnessHost` 内增加进程级 `LinuxExecution` module。CandidateHost 为所有打开的项目共享同一实例；独立网关测试可使用独立实例。内部集中保存全局操作 ID、取消事实、终端归属、每个 fence 的本进程所有权、并入成员和结算状态。

建议的同步 interface 形状如下，具体参数结构在实施时贴合现有类型：

```swift
execute(_ command: Command, in gateway: ProjectGateway) -> ExecuteOutcome
cancel(_ operationID: String) -> CancelOutcome
openTerminal(_ request: TerminalRequest, in gateway: ProjectGateway) throws -> Int
writeTerminal(_ id: String, data: Data) -> TerminalWrite
readTerminal(_ id: String, offset: Int, waitMs: Int) throws -> TerminalRead
closeTerminal(_ id: String, graceMs: Int) throws -> LeaseRelease?
// resize / signal / inspect / reset 沿用现有返回类型和固定错误码
releaseUnknownWriter(in gateway: ProjectGateway) -> UnknownWriterRelease
guestExited(status: Int32?)
```

ProjectGateway 继续是项目原生工作区的唯一权威，其现有执行与终端 interface 可委托给该 module。访问 WorkspaceStore 使用现有串行机制；不得另建一把互不协调的锁。原生操作与 Linux 租约、ledger 访问共用同一 storeLock；RPC 和等待准入期间不持有 storeLock。进程登记锁也不得跨越阻塞 RPC。

CandidateHost 删除 operations、pendingCancels 和 terminals 的生命周期编排，由 module 记录；宿主保留输入验证、项目路径映射、JSON 转换和原生工具。Gateway 删除分散的 operations/cancelled/dispatched 与 terminal lease/join/releasing 编排，将规则收进同一 implementation。保留 LinuxPlugin 的绑定、phase、admit，以及 LinuxBringUp 的 ready proof、bind、mount check、失败 stop 顺序，不整体合并。

依赖类别：运行状态是进程内依赖；WorkspaceStore 是本地依赖，测试用真实临时目录；guest 是自有远端依赖，已有 GuestRPC seam 的生产 HTTP adapter 和测试 fake adapter 足够。无需新增 WorkspaceStore port 或通用调度抽象。

删除测试：删除 LinuxExecution 会把 ID 终结、派发资格、取消及租约结算重新分散回 Host 和 Gateway；若实施后它只是转发这些旧表，未达到本次 deepening 的完成标准。

## 结算规则

- 操作登记与先到取消共同决定是否可执行。第一次消费先到取消返回 CANCELLED_BEFORE_DISPATCH，并永久保留已终结事实；该 ID 后续提交返回 DUPLICATE_OPERATION。记录在当前进程内不按超时清理。
- 明确区分等待、已取得但未派发、可能已派发和已结算。工具开始记录耐久完成前不发命令；VM 退出事实与取得及派发决策使用同一同步规则。标记可能已派发之后，VM 退出只结算本进程拥有的 fence，且只结算一次。
- 派发前失败，独立取得的租约以 REFUSED 尝试结算；并入失败仅移除成员，不释放终端写者。一次写入失败且后续存储恢复时应能清理并继续工作。若存储持续失败，保留实际耐久状态并返回 STORE_FAILED，不声称撤销或写者未知已耐久记录，也不发命令；后续只可重试已知未派发的清理，不重放原命令。
- 派发后无停止证明保持写者未知；有效的迟到 writerQuiescent 仍可按现有合同完成。VM 退出已结算的 fence 不被迟到回答再次释放、标记未知或用于更新另一租约。
- 命令结果未知与租约是否仍占用分别表达：VM 已退出可以释放租约，但丢失的命令输出仍可按现有结果类型返回未知。不把停止证明等同于成功执行。
- 存储记录和工作区内容的事务语义不扩大；toolFinished 或草稿 rebase 失败按实际提交状态报告，不因异常假设整个 release 未发生。

## 验收与实施顺序

先通过现有外部 interface 增补能揭示遗漏的测试，再逐步迁移状态所有权；不测试新内部 helper。

1. Host 先取消、两次同 ID 提交：第一次取消、第二次拒绝，无 `/execute`；保留晚到 cancel 和重复 ID 行为。
2. 命令 grant 后 toolStart 单次存储失败：无 `/execute`，租约撤销耐久完成，下一新 ID 可执行；持续失败则不虚报撤销，重开保持保守状态。
3. 并入的 toolStart 失败：终端租约仍保留，成员不会阻止后续正确释放。
4. 确定顺序覆盖 VM 退出在准入后、grant 前，以及派发后、回答前；验证不遗漏新授予的租约，不重复结算，不重写旧进程未知写者。
5. 保留并复验现有取消、断连未知、迟到停止证明、终端 idle/busy、并入、释放中等待、关闭及显式 revoke 行为。

最终运行适用 Swift 测试、`make check` 和候选桥接测试；构建候选 App 验证依赖配置。真机行为未验证就明确记录为未验证。代码完成后按固定基线做规范和规格两轴审查，修复发现后更新交接。推送新分支、创建新 PR 以及合并均按本项具体授权处理，不继承第一项的发布范围。

## 实现说明

`LinuxExecution` 的私有项目 implementation 集中命令、终端与 fence 结算；进程实例保存全局 ID 终结事实、先到取消、终端归属和退出事实。ProjectGateway 的原生读写与 withStore 继续使用同一项目 storeLock，其同步执行和终端 interface 保留为兼容入口；CandidateHost 的三张执行路由/取消/终端状态表已删除。

尚未发送的独立租约及 guest 明确拒绝的派发用同一 releaseUnsent 结算；存储恢复后可重试该清理，不重发原命令。并入失败仅撤销成员。VM 退出先记录进程事实，随后保存既有诊断并结算本进程写者；若该结算因存储失败未提交，用户显式释放仍使用 VM 退出证明及 GUEST_TERMINATED 的 epoch 规则。

新增测试覆盖：单次和持续 toolStart 存储失败、终端持续存储失败后的清理、并入开始记录失败、命令与终端 grant 期间退出、VM 退出耐久结算失败后的显式补偿。宿主提前取消测试增补重复提交和迟到取消。验收结果完成后写入交接。

两轴审查：规范轴无发现；规格轴先发现两项并已修正，增量审查又发现 Gateway 兼容终端入口绕过归属，已补行为测试并修正；三项均复核关闭，最终无未解决发现。终端每次打开使用独立登记身份，打开、关闭及短调用协调该登记，旧关闭/旧 reset 不能移除或关闭同 ID 的新登记；输出长轮询保持可被关闭打断。guest 拒绝后的耐久清理或工具结束记录失败改报 STORE_FAILED。行为测试复现打开与 reset 并发遗留无登记 shell，以及命令/终端拒绝时持续存储失败。项目打开的存储初始化串行，避免并发恢复同一耐久状态。

Gateway 的全部终端兼容入口现在校验同一进程登记及项目归属；未登记、已关闭或其他项目的 ID 返回 TERMINAL_NOT_FOUND，不发送 guest 请求。既有租约测试先通过公开 openTerminal 建立登记。新测试复现错误项目调用和已关闭 ID 的迟到关闭；打开、短调用及关闭沿用登记生命周期锁，长读取仅等待打开完成，不在轮询期间持锁。

## 最终验证

2026-10-11，代码提交 `b64e6be`：Swift 全量测试及 `make check` 通过，无警告；网关 35 项、候选宿主 16 项。`make test-candidate` 桥接 15 项、构建闸门 15 项全部通过，无跳过。macOS 与 iPad 候选 App 未签名构建完成，不安装、不启动；本项未做真机行为验收。构建脱敏收据在忽略目录 `build/candidate/linux-execution-{mac,ipad}-reviewed/build-safe.json`，原始日志保留私有。

规范轴最终无文档规则违反或判断性 smell；规格轴三项发现均已修复并复核。审查为有界源码核查，代码图工具不可用、索引覆盖未知。用户随后授权本项分支推送及草稿 PR，已创建 PR #56；后续为验收，合并仍另获授权。

### 同步 main 后的组合复验

用户询问合并条件时，main 已合入会话恢复 PR #54（`021959c`）。本项以 merge 同步 main，仅交接文档发生冲突，已保留两项记录并更新合并状态；CandidateHost 及测试自动合并，LinuxExecution/Gateway 保持已审查实现。组合两轴审查无新发现，Host 基线采集仍通过同一 Gateway.storeLock，Host 锁不跨存储或恢复调用。

组合后 `make check`、`make test-app` 全量测试通过（网关 35、候选宿主 20 项）；`make test-candidate` 恢复合同 9、桥接 20、构建闸门 15 项全通过，无跳过。重新生成固定依赖网页，macOS/iPad 未签名构建复验成功；脱敏收据在忽略的 `build/candidate/linux-execution-{mac,ipad}-integrated/build-safe.json`。未安装、未上真机。PR 合并仍须具体授权。
