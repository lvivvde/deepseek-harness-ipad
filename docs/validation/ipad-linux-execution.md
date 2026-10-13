# iPad 候选 App 的 Linux 执行生命周期验收

2026-10-13，签名 r14 安装到用户的 iPad，分支 `feat/linux-execution-device-check`，基线为 main `016cbb2`（已含 [PR #56](https://github.com/lvivvde/deepseek-harness-ipad/pull/56)）。对应 [执行与写租约结算设计](../design/linux-execution-lifecycle.md) 的“验收与实施顺序”。全程无需用户操作，不用模型和 Key。

## 方法

候选 App 内置的 `MeasureProbe` 新增三个阶段，启动方式同 [#17 测量](ipad-candidate-measurements.md)：

- `execution`：在一个新项目里依次检查先到取消、运行中取消、重复 ID、终端租约、命令并入、关闭的终端 ID 和命令期间 VM 退出。
- `execution-hold`：在新项目里跑一个长命令，记下项目名后由驱动强制结束 App。
- `execution-stale`：下一次启动打开该项目，检查上一进程留下的写者。

每个阶段自己判定 `passed`，`execution` 另记未达预期的键（`missed`）。Mac 上的私有驱动是忽略目录里的 `build/candidate/device/measure-auto-private.py`，步骤 `execution` 和 `execution-stale`。macOS 用假 guest 跑同样三个阶段，测试在 `MeasureProbeTests`。

## 结果

### `execution`（`passed`，`missed` 为空）

| 检查 | 真机结果 |
| --- | --- |
| 命令前先到的取消 | `CANCELLED_BEFORE_DISPATCH`；命令本身也返回它，文件未写 |
| 同一 ID 再提交 | `REFUSED:DUPLICATE_OPERATION` |
| 之后再取消 | `FINISHED` |
| 取消运行中的命令（1.5 s 后） | `CANCEL_REQUESTED`；命令返回 `COMPLETED` 且 `cancelled=true`，文件未写，写者未变成未知 |
| 取消后的新命令 | `COMPLETED` |
| 已完成的 ID 再提交 | `REFUSED:DUPLICATE_OPERATION`，未运行 |
| 打开 `/bin/bash -i` 终端 | 打开；提示符出现时为 idle |
| 在终端运行一行 | `WRITTEN` 且取得租约；行结束后读取时租约释放，文件内容正确 |
| 终端释放后的命令 | `COMPLETED` |
| 终端运行中发命令 | 命令并入，返回 `COMPLETED`；之后终端仍持有租约，行结束后释放；两个文件都在 |
| 关闭终端 | 关闭；再写该 ID 返回 `TERMINAL_NOT_FOUND`；同一 ID 可重新打开 |
| 命令运行中 VM 退出 | 项目 `FAILED`；该命令返回 `WRITER_UNKNOWN`（结果未知）；写者未变成未知；原生写入立即提交；重开的终端已不存在（`TERMINAL_NOT_FOUND`） |
| VM 启动次数 | 1 |

VM 退出这一项说明：命令结果未知，但租约已按本进程派发的 fence 结算，所以原生写入可以继续。这与设计中“命令结果未知与租约是否仍占用分别表达”一致。

### `execution-hold` → 强制结束 → `execution-stale`（都 `passed`）

- 长命令运行时，同项目另一命令返回 `REFUSED:LEASE_BUSY`。随后驱动强制结束 App。
- 下一次启动打开该项目：写者未知；新命令返回 `REFUSED:WRITER_UNKNOWN`。
- 本次进程的 VM 退出后，项目 `FAILED`，写者仍未知。VM 退出没有释放上一进程的租约。
- 显式 `writer-release` 返回 `RELEASED`；之后写者不再未知，原生写入立即提交。VM 启动 1 次。

### 回归（r14，都 `passed`）

- 冷启动 1 次：Linux 就绪约 9.8 s，首条命令约 1.0 s，预热命令 0.5–0.7 s，watch 双向可见；VM 启动 1 次。
- 预热调度（G4）：打开后和原生操作时都是 `PREPARING`；就绪后 1 条完成、2 条 `LEASE_BUSY`；先到取消未运行。
- 插件生命周期（G6）：原生项目不启动 Linux；第二个插件项目不绑定；VM 退出后 `LINUX_VM_EXITED`，诊断已保存，原生写入提交。

## 未在真机验证

以下只由 macOS 行为测试覆盖，真机无法稳定注入，记为真机未验证：

- toolStart 单次或持续存储失败、并入的 toolStart 失败、VM 退出结算时存储失败及之后的显式补偿。
- VM 退出恰在准入后、grant 前，或派发后、回答前（需要确定的时序）。
- 断连后的未知结果、迟到的 `writerQuiescent`、释放中等待和显式 revoke。
- 有模型参与的回合（需要用户的 Key，本次未做）。

## 构建与测试

- `make test-app`：8 个 bundle，237 项，0 失败、0 跳过、0 警告（新增两项探针测试）。`make check` 通过。
- r14 用私有签名文件构建，签名校验通过；先重新生成了固定依赖网页。原始日志、收据和设备记录都在忽略的 `build/candidate/`：构建在 `ipad-signed-r14/`，设备证据在 `device/measure-auto-223332`（`execution`）、`223410`（hold 与 stale）、`223459`（冷启动）、`223523`（调度）、`223541`（生命周期）。
