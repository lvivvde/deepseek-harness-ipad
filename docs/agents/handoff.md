# 开发交接

最后更新：2026-10-05，北京时间。此文件是接手入口，GitHub Issues 是任务状态源；旧聊天和临时目录不作为接手前提。

## 开始工作

1. 读根 `CONTEXT.md`、相关 `docs/adr/`，检查 `git status --short`、当前分支和最新提交。保留已有未提交改动。
2. 查 `gh pr list --state open` 和下表涉及的 Issues。已有待合并工具分支时先继续该分支，避免重新实现；每个新 PR 合并都另获用户同意。
3. 真机任务读 [真机自动化](../validation/ipad-device-automation.md)；其他任务读对应验收记录。先用只读 `probe` 确认连接，按明确缺项推进，减少用户交互。
4. 完成后更新本文件的状态、验证和下一步；原始日志/设备/签名参数保存到忽略的 `build/`，公开文档只记脱敏结果。

## 当前代码与交付

- 本交接的代码基线：PR30 后的 main `5a5f93d`，PR27–PR30 已合并且 CI 通过；PR31 合并后的当前 main SHA 以开始工作时的 Git 查询为准。PR30 修复原生菜单打开时隐藏行文字、hello 示例工具未进入模型工具面。
- 真机工具及本交接由 [PR31](https://github.com/lvivvde/deepseek-harness-ipad/pull/31) 交付；用户已同意合并。未合并时从 `codex/device-automation-handoff` 分支接手，合并后直接从 main 接手。
- 当前安装包仍是 **da2d0aa**：`build/HarnessApp-0.1.0-main-da2d0aa.ipa`，293.2 MiB，旁有 SHA256、receipt 和 acceptance。PR30 修复尚未重新打包或安装。不要把源码合并当作设备已升级。
- 最后已知正式包签名截止：**2026-10-10 21:11:14（北京时间）**。后续签名以实际新 profile 为准，不沿用旧截止。本轮无需立即重包。
- #1 规划地图、#16 原 M1 入口已关闭；#16 后续交互回归转 #23，恢复转 #19，资源测量留 #17，整体验收由 #15 跟踪。

| 开放任务 | 下一步与边界 |
| --- | --- |
| [#17 运行时与用户盘](https://github.com/lvivvde/deepseek-harness-ipad/issues/17) | 真机安装占用/峰值内存/8 GB 下限、容量/低空间/删除后宿主回收仍未完整测量。 |
| [#18 Git 开发闭环](https://github.com/lvivvde/deepseek-harness-ipad/issues/18) | 缺真实模型修改、用户差异审阅、外部授权远端推送及整套 iPad 冷启动。ARM64 guest Vite production build 180 秒超时，根因未知。 |
| [#19 恢复与重签](https://github.com/lvivvde/deepseek-harness-ipad/issues/19) | 保持开放。首次真实解锁恢复 ≤10 秒、时差 ±2 秒、完整真机备份救援/重签未验证。用户已取消后续锁屏，不能自行重启。 |
| [#23 插件/预览/辅助键](https://github.com/lvivvde/deepseek-harness-ipad/issues/23) | 新包交互回归、社区插件外部模型/升级、实体辅助键与中文组合输入、原生预览回退待验。 |
| [#15 整体交付](https://github.com/lvivvde/deepseek-harness-ipad/issues/15) | 汇总完整 Spec 的实际交付和未验项。 |
| [#14 许可证发布判断](https://github.com/lvivvde/deepseek-harness-ipad/issues/14) | 公开发布前的判断仍开放。本轮不发布 GitHub Release。 |

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
