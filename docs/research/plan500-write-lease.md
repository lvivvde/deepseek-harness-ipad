# 方案500：统一写租约、版本冲突与变更 generation 验证

2026-10-05，北京时间。用户要求“继续推进”，按交接中记录的下一关口执行。继续 [Issue32](https://github.com/lvivvde/deepseek-harness-ipad/issues/32)、[PR36](https://github.com/lvivvde/deepseek-harness-ipad/pull/36)。上一轮结果见[共享/RPC 报告](plan500-sharing-rpc.md)，源码与复跑入口见[写租约探针](../../runtime/prototypes/plan500-lease/README.md)。

## 结论

**真实 Linux 上，单一网关发放写租约、所有 guest 写者都必须持租的有界合同可以成立。** `none` 与 `mapped-xattr` 各 **26/26** 项必需检查通过：

- 无租命令即使以 owner uid 运行，写入也被内核以只读挂载拒绝。
- 原生写入按版本比较后再交换，冲突时不覆盖；租约期间的原生编辑成为持久草稿，释放后 rebase。
- 每次释放只生成一个 change generation，guest 可以轮询；断连期间漏掉的 generation 在恢复连接后补齐。
- 超时、取消、`setsid` 逃逸、RPC 断开、网关重启和 VM 退出，都只能在确认写者已停止或 VM 已退出后才释放租约。

上一轮发现的跨域 flock 与 watcher 缺口，在本合同下不再作为正确性前提：互斥由租约提供，通知由 generation 提供。

**仍未通过 G3。** 同 uid 进程在租约期间可以经 `/proc` 写入私有 rw 视图。网关是 Python 替身，不是 Swift；Darwin 9P backend、iPad 文件行为、模型与网络均未验证。本结果只能作为候选架构的写者合同证据，不能据此关闭 #32、启动 #17 或改选 ADR。

## 输入和隔离边界

在既有 Lima Linux 内启动自己的 QEMU 10.2.1（TCG、aarch64），与上一轮使用同一组固定 kernel、initramfs、只读 system.raw 和锁定 modloop（SHA256 见[上一轮报告](plan500-sharing-rpc.md)），9P 使用 cache=none。本轮源文件：

| 文件 | SHA256 |
| --- | --- |
| run.py | `d58ddefd0e6dd5b37de009cc2e167d1d96951b8e8817e1f8beff42f74e61d579` |
| init.sh | `2cf2658d1442d64c3503d6435b69ebc29ecd189140c2105fd6b78dba2712589a` |
| agent.cjs | `e219a8505774819e8158ffcb232a7cc42f6365548dd7d854593ef4ff85f9c0fc` |
| 复用的 plan500-sharing/run.py（未修改） | `81c4a8613baeda2a3a3e0e6c905a00112e0506f43f3b8b4350f950353f4516e6` |
| 探针 initramfs | `dae3254f170a04749bb04a567f5b9d34b2592ba2084cba698b38f25c462b1efd` |

没有读取 user.raw/user-seed.raw 或 iPad 原盘，没有接触设备、签名、安装、外部模型或项目远端。token 与原始串口只留在本次 Lima scratch。结束后探针 QEMU 残留数为 0；Lima 内与本任务无关的既有 QEMU 未动。

## 合同

1. **唯一发放者。** 网关持久化 `epoch`、`fence`、`generation`、当前租约、草稿与每个路径的版本，发出请求前先把租约落盘。同一时刻最多只有一个整工作区写租约。
2. **guest 内强制执行。** 9P 只挂载在 root-only 的 `/run/ws/rw`，命令可见的 `/workspace` 是 `ro,nosuid,nodev` bind。持租命令进入私有 mount namespace，只 remount 自己的视图为 rw，再以 `no_new_privs` 降为 owner uid。无租命令使用 reader uid 65534。user namespace 被关闭，因此无法另建可写视图。
3. **写者存活。** 每个命令拥有独立 cgroup v2。结束、超时或取消时执行 `cgroup.kill`，`populated 0` 后再 kill 外部持有私有挂载的进程（fd、cwd、root、map），然后才回报 `writerQuiescent`。网关只在收到此回报后释放租约。
4. **fence。** agent 每次开机只接受一次 `/bind` 的 epoch，并拒绝旧 fence 和外来 epoch。`/revoke` 抬高 lastFence，使已发放但延迟到达的请求不生效。RPC 不可达时租约保持 HELD；只有确认 VM 已退出才能释放，并让 epoch 递增。网关重启后，原租约标为 WRITER_UNKNOWN。
5. **原生写入与 generation。** 原生写入前比较版本 token 和磁盘指纹。不一致时报告 VERSION 冲突，若属外部写者则报告 EXTERNAL_CHANGE，两种情况都不覆盖。租约期间的编辑持久化为草稿；释放时与基线比对、生成一个 generation，再按草稿的 base 版本 rebase，未变化的路径为 APPLIED，已变化的为 CONFLICT。guest 发布 `/run/plan500/generation` 与 `changes.jsonl` 供轮询。

## 实测

两种模式结果一致，以下均为必需检查：

| 范围 | 检查 |
| --- | --- |
| 强制只读 | ready 时验证 `ro,nosuid,nodev`、cgroup.kill、uid 与 user namespace 关闭；无租 owner 写入失败（EROFS）；reader 可读；owner 无法 remount、无法进入 rw share、无法创建 user namespace、无法离开 cgroup |
| 版本与通知 | 旧 base 与覆盖已存在文件都报冲突、不覆盖；guest 轮询看到原生写入的路径与内容（约 57ms） |
| 草稿与 rebase | 租约期间原生编辑成为草稿；释放后被 Linux 改动的文件为 CONFLICT，未改动的为 APPLIED；Linux 改动合并为一个 generation |
| Git | 持租时真实提交，并报告 `.git` 变更；无租时只读 `git log` 可用 |
| fence | 重用的 fence 与外来 epoch 被拒绝，无副作用 |
| 写者存活 | `setsid` 守护进程在释放前被杀，之后无写入；超时与取消都先杀 cgroup、再报告部分效果；长驻的无租进程在他人持租期间保持只读 |
| `/proc` 魔法链接 | reader 无法经 `/proc/<pid>/cwd` 打开租约视图；owner 可以打开，释放时 sweep 杀掉持有者，此后无写入；**负对照**：去掉 sweep 后泄露的 fd 在释放后 1 秒内继续写入（20→50 字节），下一次租约的 sweep 杀掉两个 fd 持有者后停止 |
| 断连与崩溃 | 断连期间漏掉的通知被补齐；RPC 中途丢失时租约保持 WRITER_UNKNOWN/HELD，原生编辑成为草稿；恢复连接后只有写者已结束才释放；网关重启后保持 WRITER_UNKNOWN 并持久化草稿，旧写者结束后释放并应用草稿；`/revoke` 使未送达的租约失效；绕过网关的宿主写入被检测为冲突 |
| VM 退出与重启 | 只有确认 VM 退出才释放不可达写者，epoch 递增；重启后旧 epoch 租约失败、新租约可用，guest 追上 generation（最终 generation 19、epoch 2、fence 15） |

观察项（不计入通过数）：只读视图中可以运行 `git status`（兼容）。同 uid 的无租进程在租约期间经 `/proc/<leased>/cwd` 写入**未被阻止**（不兼容），这次写入被释放扫描记入 generation。

## 缺口与限制

- 写入只能事后发现，不能实时阻止：同 uid 绕过的写入、外部宿主写入、原生 CAS 的 hash 与 rename 之间的 TOCTOU。产品需要不同 uid、更强隔离，或接受“检测并转为冲突”的语义。
- SCM_RIGHTS fd 传递未直接构造，只依赖 sweep 的 mnt_id 检查；无租命令的 reader uid 会使 0600 文件不可读。
- 只有整工作区写租约。长驻的 dev server、watcher 写入或插件如何持租，以及持租多久会阻塞原生编辑，属于产品设计问题，尚未决定。
- 草稿冲突目前只标记 CONFLICT，草稿保留在网关状态中，没有合并或展示界面。
- 崩溃耐久性只覆盖网关自身状态的 fsync；VM 退出时持租命令的部分写入按“已发生”记入 generation，不会回滚。
- Swift 网关、Darwin 9P backend（含上一轮的 `pthread_fchdir_np` 私有接口条件）、iPad 沙箱与生命周期、模型、网络、官方 Worker 接入及性能均未验证。

## 关口状态与下一步

- **G3**：获得统一写者合同的真实 Linux 证据，但存在同 uid 绕过与 Darwin/iPad 未验，**未通过**。
- **G4**：补充了超时、取消、断连、网关重启与 VM 退出时写者存活的证据；iPad 生命周期仍未验证。
- **G5**：只有一次持租 Git 提交，hook 顺序未完整验证。
- G0–G7 均未完整通过。

下一步应在 Darwin/iPad 上验证文件行为与 9P backend 的可行性，并把网关移植到 Swift，接入官方 Worker 的原生写入路径；随后验证模型与网络路径，再在 #32 形成用户的架构决定。ADR/CONTEXT 未改选，#32 保持 OPEN，#17 继续依赖。正式 App 仍为 `7956e8c`，签名截止 2026-10-12 15:49:52 北京时间；锁屏/8 小时测试保持取消。

本地收据：忽略的 `build/prototypes/plan500-lease/result-safe.json`。公共交付只包含复跑源码和上述脱敏结论。
