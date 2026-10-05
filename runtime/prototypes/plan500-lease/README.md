# 方案500：统一写租约、版本冲突与变更 generation 探针

研究原型，关联 [Issue32](https://github.com/lvivvde/deepseek-harness-ipad/issues/32) 和 [研究结论](../../../docs/research/plan500-write-lease.md)。不进入正式 App。

## Linux 复跑

前置条件与 [共享探针](../plan500-sharing/README.md) 相同：Linux、Python 3.10+、`qemu-system-aarch64`、`cpio`、`unsquashfs`，本仓库 runtime 构建输出和锁定的 `modloop-virt`。本探针通过 importlib 复用 `../plan500-sharing/run.py` 的构建、启动与 RPC 代码，只把 `init.sh` / `agent.cjs` 换成本目录版本；共享探针源文件不改动，其 SHA256 一并记入收据。

```sh
python3 runtime/prototypes/plan500-lease/run.py \
  --runtime /path/to/bundled-runtime \
  --modloop /path/to/locked/modloop-virt \
  --scratch /var/tmp
```

默认依次跑 `none`、`mapped-xattr`，每种模式启动独立 QEMU（同一模式内为验证重启还会再启动一次）。脚本只使用自己的 `plan500-lease-*` 临时目录、合成 workspace 和网关状态目录；系统盘只读，没有打开 user.raw 或 user-seed.raw。原始串口、QEMU 日志与 token 只留在该目录，结束或失败时只关闭本次启动的 QEMU。

## 组成

- `run.py` 中的 `Gateway`：Python 版 Swift 工作区网关替身，是写租约、fence 和 change generation 的唯一发放者。状态以 fsync + rename 原子持久化。原生写入按版本 token（`generation:sha16`）比较后再交换；租约期间原生编辑先落成持久草稿，释放时 rebase，冲突时不覆盖。释放时把整个 workspace 与领租时的基线比对，只生成一个 generation，经 `/notify` 推给 guest，断连时延后补发。
- `init.sh`：9P 只挂在 `/run/ws/rw`（目录 0700 root），`/workspace` 是它的 `ro,nosuid,nodev` bind。挂载 cgroup2 与可写 `/tmp`，并把 `max_user_namespaces` 设为 0。
- `agent.cjs`：guest RPC。每个命令放进独立 cgroup，以 `cgroup.kill` 结束，确认 `populated 0` 后才算写者停止。持租命令在私有 mount namespace 中把自己的视图 remount 为 rw，再经 `setpriv --no-new-privs` 降为 owner uid；无租命令以 uid 65534 只读执行。agent 按开机 epoch 拒绝旧 fence 与外来 epoch，`/revoke` 可作废已发放但未送达的租约。持租命令结束时，agent 还会 kill 外部进程中仍经 fd/cwd/root/map 指向私有 rw 挂载的持有者。
- 测试专用开关：`/test/sever`（断开全部 RPC 连接）、请求的 `asOwner`、`testSkipSweep`。它们只用于故障注入与负对照，不是产品接口。

## 结果如何解释

`result-safe.json` 中 `completed=true` 表示全部必需检查通过；`models[].semantics` 是另行记录的兼容性观察，不计入通过数。本轮每种模式 26/26 通过，其中一项为去掉 sweep 的负对照。`swiftGateway`、`DarwinVerified`、`iPadVerified` 均为 false。

已知边界：

- 同 uid 的无租进程在租约期间仍可经 `/proc/<leased>/cwd` 打开私有 rw 视图并写入（观察项 `compatible=false`）。这次写入会被释放时的扫描记入 generation，持有者随后被 kill，但租约期间并未被阻止。产品必须让无租命令换用不同 uid，或采用更强的隔离。
- 经 SCM_RIGHTS 传递 fd 的路径未直接构造（guest 中没有 socat/python），只依赖同一 sweep 对 fdinfo `mnt_id` 的检查。
- 原生写入在“比对 hash”与“rename”之间存在 TOCTOU 窗口；外部宿主写者只能被事后发现，无法阻止。
- 租约只覆盖整个 workspace，没有路径级租约或读者租约。reader uid 无法读取 0600 文件。
- 网关是 Python 进程；Swift 实现、Darwin 9P backend、iPad 生命周期、模型/网络与正式调度接入均未验证。
