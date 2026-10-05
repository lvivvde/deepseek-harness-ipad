# 原生工作区耐久层设计

依据：[ADR 0003](../adr/0003-native-worker-with-project-linux.md)，[#39](https://github.com/lvivvde/deepseek-harness-ipad/issues/39) 关口 1（G2）。2026-10-06 创建。

代码在 `ios/HarnessApp/Sources/Workspace/`（SwiftPM 目标 `NativeWorkspace`）。崩溃探针是 `ios/HarnessApp/Tools/WorkspaceCrashProbe/`，测试在 `ios/HarnessApp/WorkspaceTests/`。这一层还没有接进正式 App 工程，接入属于 #17。

## 范围

`WorkspaceStore` 是原生网关的耐久层，负责以下状态：

- 原生读写的版本（CAS）
- 与 Linux 共用的写租约
- 草稿：`DRAFT_HELD`、`CONFLICT`、`RECOVERED`、`APPLIED`、`MISSING`
- 变更代际日志
- `/dsh/home` 会话检查点
- 工具调用账本

传输、RPC 和 VM 生命周期不在这一层，由网关组合。调用方必须串行访问：一个网关持有一个 store。每项状态变化都先写入日志，之后才回复调用方。

## 磁盘布局

状态目录：

| 文件 | 内容 |
| --- | --- |
| `journal.log` | 追加日志，是唯一的提交点 |
| `state.snapshot` | 压缩快照：`DSHSNAP1` + 正文 SHA-256（hex）+ JSON `{through, state}` |
| `drafts/<id>` | 草稿原始字节，权限 0600 |
| `session/home.checkpoint` | `DSHCKPT1` + SHA-256 + JSON `{serial, generation, snapshot}` |
| `quarantine/` | 损坏或来历不明的文件。只进不删 |

日志帧格式：

- 文件以 8 字节魔数 `DSHJRNL1` 开头。
- 之后每条记录依次是：`u32 LE 负载长度`、`u64 LE 序号`、`SHA-256(序号 ‖ 负载)` 的前 16 字节，最后是 JSON 负载。
- 序号严格 +1 递增。
- 一帧写完并完成 sync 后才算提交。

记录类型：`baseline`、`intent`、`commit`、`resolve`、`leaseGrant`、`leaseUnknown`、`leaseRelease`、`draftAdd`、`draftStatus`、`checkpoint`、`toolStart`、`toolEnd`。

版本令牌是 `代际:指纹`，各类条目的指纹：

| 条目 | 指纹 |
| --- | --- |
| 普通文件 | `F:<sha256>:<mode>` |
| 符号链接 | `L:<目标 hex>` |
| 特殊文件 | `S:<类型>:<mode>` |
| 不可读条目 | `U:<errno>` |

路径按字节比较，NFC 与 NFD 写法互不合并。

## 写入协议

### 原子替换

步骤依次为：

1. 用 `O_EXCL|O_NOFOLLOW` 创建临时文件 `.dsh-tmp-<id>`。
2. 写入数据，再 `fchmod`。
3. 对文件执行完整同步。
4. `renameat` 替换目标。
5. 对目录执行完整同步。

父目录逐级用 `openat(O_NOFOLLOW)` 打开。父目录如果是符号链接就拒绝。新建的目录会同步其父目录。

### 原生写

1. 用磁盘指纹核对已记录的版本。不一致说明有同 uid 写入者绕过了网关，先把它记为一个 `external` 代际。
2. 核对 CAS 基线。不匹配就保存 `CONFLICT` 草稿。
3. 写 `intent {id, path, temporary, old, new}`。
4. 执行原子替换。
5. 写 `commit {generation, origin: native, paths, intent}`。
6. 回复调用方。

第 4 或第 5 步失败时，立即按磁盘结果结算 intent：已落地并已记录，就照常返回成功；否则返回 `failed`。

### 租约

- **授予**：先把磁盘与版本记录对齐，再写 `leaseGrant {fence, epoch}`。
- **租约期间**：原生读返回 `leaseBusy`，原生写保存为 `DRAFT_HELD`。
- **释放**：由持有者调用 `releaseLease(fence:reason:)`。扫描出的差异与释放动作写在同一条 `leaseRelease` 记录里。之后按基线重放 `DRAFT_HELD` 草稿：基线仍匹配的写入并标为 `APPLIED`，其余标为 `CONFLICT`。
- **原因 `GUEST_TERMINATED`**：epoch +1，旧租约此后无法使用。

### 草稿

先原子写入草稿字节，再写 `draftAdd {id, path, base, status, sha256}`。如果记录没能写入，字节移入隔离区，草稿列表与磁盘始终一致。

### 检查点

原子替换 `home.checkpoint`，之后写 `checkpoint {serial, generation}`。替换中途中断时，旧文件仍完整可读。

## 恢复规则

1. **会话**：会话回到最后一个完整检查点（`restoreSession().snapshot`）。如果检查点文件比日志记录新（文件已换好、记录还没写入），以文件为准。
2. **工作区**：检查点之后由工具写入的内容，保持工作区的实际字节，不回滚。重开时把磁盘与已记录的版本对齐，差异记为 `recovered` 代际。
3. **工具调用**：没有完成记录的工具调用，重开时补记 `toolEnd UNKNOWN`，在 `unknownToolCalls` 中报告，不重放。已完成的列在 `completedAfterCheckpoint`。
4. **草稿**：草稿原样保留。只要字节还在，就不改动、不重写。字节丢失（外部损坏）的标为 `MISSING` 并报告，不凭空补出内容。
5. **代际提示**：检查点代际低于工作区代际时，`workspaceChanged` 为真，界面显示“工作区在此之后有变化”。

### 重开时的处理顺序

1. 读取快照，再读取日志。日志只回放有效且完整的前缀。
2. 处理租约：如果有仍在 `ACTIVE` 的租约，记一条 `leaseUnknown`，状态变为 `WRITER_UNKNOWN`。不自动释放，不重放任何命令。
3. 工具调用：没有完成记录的补记为 `UNKNOWN`。
4. 结算未决 intent。只看磁盘，不重放：
   - 临时文件：内容完整的，转为 `RECOVERED` 草稿（未落地的完整写入）；不完整的移入隔离区。
   - 目标指纹等于 `new`：记为 `LANDED` 并提交。
   - 目标指纹等于 `old`：记为 `NOT_LANDED`。
   - 其他情况：作为 `external` 提交。
5. 草稿：缺少字节的草稿标为 `MISSING`；没有记录的草稿字节移入隔离区。
6. 清理残留临时文件：状态目录和工作区里的都移入隔离区，Linux 不会看到它们。
7. 如果没有租约：把磁盘与版本记录对齐，再重放 `DRAFT_HELD` 草稿（租约已释放、但重放前进程退出的情况）。

### 日志损坏

出现以下任一情况，即在该处停止回放：

- `EMPTY_FILE`：零长度文件
- `BAD_HEADER`：魔数不对
- `TORN_TAIL`：尾部半帧
- `CHECKSUM`：中间某条记录校验和不符
- `DUPLICATE`：序号不大于上一条
- `SEQUENCE_GAP`：序号跳号

处理方式：

1. 原文件逐字节复制到 `quarantine/`。
2. 把日志原子改写为有效前缀。
3. 在 `recovery.anomalies` 中报告种类、偏移和隔离文件名。

App 继续运行：后续磁盘差异按规则 2 记录。快照或检查点校验失败时，文件移入隔离区，分别报告为 `BAD_SNAPSHOT` / `BAD_CHECKPOINT`。

### ENOSPC

- **日志追加失败**：截断回追加前的长度并同步，不留半帧。
- **临时文件阶段失败**：原子替换会删除临时文件，目标保持原样。
- **intent 已写、提交失败**：日志里留下 intent 而没有 commit，这正是重开时按磁盘结算的状态，不算半提交。
- **草稿或检查点写入失败**：已有的草稿和检查点不受影响。

### 压缩

先原子写入快照（`through` 为当前序号），再把日志原子换成空日志。两步之间中断时，日志里留下的记录序号不大于 `through`，回放时按序号跳过。默认每 4096 条记录压缩一次。

## 同步原语

使用 `fcntl(F_FULLFSYNC)`，失败时退回 `fsync`。

在 Darwin（macOS/iOS，APFS）上，`fsync` 只把数据交给存储设备，不要求设备清空写缓存。断电时数据仍可能丢失或乱序。`F_FULLFSYNC` 要求设备把缓存落盘，这才是日志“提交”所需的保证。

文件系统不支持 `F_FULLFSYNC` 时返回错误，这时退回 `fsync`，这是剩下最强的保证。

代价：每次提交大约要几毫秒。目录在 rename 之后也会做同样的同步。

## 注入点与证据

注入点由 `FaultPoint(site, stage)` 定义，生产代码不传入 hook。

| 位置（site） | 阶段（stage） |
| --- | --- |
| `workspace` | `beforeTemp`、`halfWritten`、`beforeSync`、`beforeRename`、`afterRename`（已 rename、尚未提交日志）、`afterCommit`（已提交、尚未回复） |
| `draft`、`checkpoint`、`snapshot` | 原子替换的前五个阶段 |
| `journal` | 追加的 `halfWritten`、`beforeSync`；压缩改写时的原子替换阶段 |

测试（`swift test --package-path ios/HarnessApp --filter NativeWorkspaceTests`）：

| 测试 | 覆盖 |
| --- | --- |
| `CrashMatrixTests` | 探针在每个注入点 SIGKILL 自己，重开后核对规则，并再次重开确认恢复幂等 |
| `CrashMatrixTests.testAppKilledWhileLinuxWriterHoldsLease` | 持租约时被杀 |
| `CrashMatrixTests.testRandomKillPositions` | 父进程在随机时刻 SIGKILL 随机操作循环 |
| `JournalRecoveryTests` | 四种日志损坏 |
| `NoSpaceTests` | 各阶段注入 ENOSPC |
| `WorkspaceStoreTests` | CAS、草稿、租约、会话、压缩 |

每个注入点的重复次数由 `CRASH_REPEATS` 控制，随机杀进程的次数由 `CRASH_RANDOM_RUNS` 控制。

每次重开都执行 `audit()`，检查以下不变量：

- 无租约时，磁盘与已记录的版本一致
- 工作区里没有临时文件
- 没有未决 intent
- 每份草稿的字节都存在，且 SHA-256 与记录一致

进程被杀不会丢失已写入页缓存的数据，因此这些测试不能代替断电。系统崩溃和断电不在验证范围内，在证据中记为未验证。

## 未完成

iPad 候选 App 真机证据还没有采集，要求见 #39 关口 1。

关口 1 在此之前不勾选。
