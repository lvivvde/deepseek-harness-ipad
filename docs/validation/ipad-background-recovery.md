# 长后台恢复故障诊断与修复

2026-10-04，基线 main `a3aafca`。对应 [前后台恢复、用户数据救援与重签交付验收](https://github.com/lvivvde/deepseek-harness-ipad/issues/19)。本轮未打包、安装或访问真机用户盘，不能登记为真实长后台故障已修复。

## 已证实的代码缺口

| 缺口 | 复现证据 | 修改 |
| --- | --- | --- |
| main 的串口/QMP 流读取可能等待凑满 8192 字节 | 真正 Unix socketpair 写入 11 字节问候后，`read(upToCount: 8192)` 一秒内未返回；对端关闭才返回。生产 QMP 类的小包测试在协商阶段约 4 秒后失败。 | 单次 POSIX `read` 立即交付已收到的小包；保留相同描述符。QMP/串口代码移入 Core，让 Swift 测试直接运行生产实现。 |
| HTTP 就绪不代表后台前的页面连接可用 | 现有 `RuntimeController.resume()` 定向测试中恢复成功，但 `pageRevision` 仍为 0。 | 前台恢复成功后重载官方入口，重新建立页面连接。 |
| 返回前台的新请求被尚未结束的旧恢复吞掉 | 暂停一个旧探测，再发前台请求，旧探测以控制超时结束；此前停在失败态，只探测一次。 | 将前台请求合并为旧探测结束后的一次新探测；不并发发送串口恢复命令。 |
| 控制超时错误地要求重开，隐藏重试入口 | 注入控制超时，失败态 `requiresRelaunch` 为 true。 | QMP/串口暂不可用保留重试；只有明确 VM 退出或既有启动终止故障禁止恢复。 |

旧代码 `cca6d41` 使用 NWConnection 串口和三轮 HTTP 检查，不包含 main 的 QMP/socketpair 健康与时间流程；因此小包阻塞不能直接解释旧版本的真实故障。两版都有“HTTP 正常时不重载页面”和重叠前台请求的问题。本轮锁定并修复的是上述代码路径，原始故障的版本、实际后台时长及运行层仍待真机证据确认。

## 分层诊断

诊断仅记录有限枚举，不包含 URL、token、设备标识或串口内容。

| 最后事件或错误 | 可得出的结论 |
| --- | --- |
| `runtimeExited` / `reconnectFailed:exited` | QEMU 的实际退出回调已触发；原用户盘保留，关闭并重新打开 App。 |
| `reconnectFailed:control` | QMP 命令未完成；不能据此宣称 VM 已退出，可以重试。 |
| `reconnectFailed:vmStopped` | QMP 返回非运行状态；不自动重新初始化 QEMU。 |
| `recovery:vmRunning` 后 `reconnectFailed:guestControl` | VM 状态确认运行，但串口健康握手未完成。 |
| `recovery:guestResponded` 后 `reconnectFailed:clock` | 收到健康回复，时间未达到宿主 ±2 秒门槛。 |
| `recovery:harnessRestarting` | VM 存活，Harness 已停止且 supervisor 确认可重启；只重启服务。 |
| `recovery:harnessRunning` 后 `recovery:forwardRepairing` | 服务进程存在，但 HTTP 页面未就绪；仅重建页面转发。 |
| `recovery:pageReady` | 宿主 HTTP 探测成功；随后重载页面。页面交互/流式连接仍需真机检查。 |

健康报告只表示 supervisor 所观察的进程/写入状态，不证明服务对所有请求都可用；supervisor 自身不可用时，旧 guest 协议会返回保守的失败字段，仍需按最后阶段定位，不据此断言物理磁盘损坏。

## 自动验证

- Swift 27 项通过，包括生产 socket 小包、对端 EOF、同描述符超时重试与迟到回复、恢复后的页面重载、旧请求跨前台、控制超时可重试、实际退出后不重新启动，以及原有存储/备份行为。
- guest 14 项通过且无跳过；Simulator Debug 与完整 guest 的无签名 iPhoneOS Release 编译通过。初次受限沙箱阻止测试 socket 的 listen 和 Xcode 宏插件，使用批准的本地执行重跑后通过，未修改业务代码来绕过失败。
- Linux QEMU `--recovery-only` 的 9 个固定检查通过，使用全新临时盘：基础 QMP/官方页面/健康、执行器 SIGSTOP/SIGCONT 后原 VM/原 Harness 恢复且小于 10 秒、过期时间检测及重新同步、未完成握手超时后新 nonce 重试、页面转发丢失与修复、仅 Harness 退出后的服务重启、明确 QEMU 退出后保留盘。
- SIGSTOP 测试只暂停 1 秒，旧时间由故障注入产生；没有模拟 iPad 的 30 分钟/8 小时系统后台策略。Linux lab 使用 Python 宿主，Swift 生产通道通过独立 macOS socket 测试验证；尚未把两者当作嵌入 iOS 执行器的完整验收。

可重复命令：

```sh
CLANG_MODULE_CACHE_PATH=/tmp/harness-clang-cache swift test --disable-sandbox \
  --package-path ios/HarnessApp --cache-path /tmp/harness-spm-cache \
  --scratch-path /tmp/harness-spm --filter QemuControlTests
# 以下命令需要 Linux aarch64 QEMU；只创建临时盘。
python3 runtime/tests/boot-acceptance.py /path/to/guest --recovery-only
```

## 下一次集中真机验收

最终包需包含本轮宿主修复；guest 源码未变，可复用已验证的 storage-v6。与 [恢复备份](ipad-recovery-backup.md) 和 [存储工具](ipad-storage-tools.md) 清单一同覆盖安装，避免反复安装。

记录 App 代码版本、实际锁屏起止时间、前台恢复耗时、失败页文字与固定诊断阶段；分别验证短后台、30 分钟、至少 8 小时，以及先发起恢复再立刻锁屏的重叠场景。HTTP 恢复后必须能在已有会话继续交互/流式响应。前台重载可能重置尚未提交的浏览器输入、终端显示或局部 UI 状态；这些需要同包检查，持久化项目/会话不能丢失。

存活 VM 目标 10 秒内恢复、时间误差不超过 2 秒；真正退出时明确要求关闭并重开，原盘和项目仍保留。不能因为本轮自动测试通过而关闭 Issue，不能登记 8 GB 下限设备、签名迁移、性能预算或公开分发许可已经通过。新 PR 合并 main 仍需单独授权；本轮不发布 GitHub Release。
