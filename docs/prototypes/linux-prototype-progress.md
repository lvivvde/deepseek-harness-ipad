# 本地 Linux 原型：阶段记录

2026-10-03。对应[无 JIT 自签 IPA 原型验证](https://github.com/lvivvde/deepseek-harness-ipad/issues/11)。本文件只记录公开技术资产和阶段状态；个人签名、设备标识及完整设备日志保留本地。

已完成：SwiftUI/WKWebView 原生诊断工程、Objective-C 共享库入口、单次 VM 启动、真实串口收发、hostfwd 和本机 HTTP 探测。iOS device 目标无签名编译通过。

执行器来自固定 UTM `7eadb056ae0f91d979059544d0ddcd2d5a40be92` 的官方 `Sysroot-ios-tci-arm64` CI artifact `10845528675`。已解包核查 iOS 平台、三个 QEMU 入口及静态框架依赖闭包；提取 22 个 framework，连同固件的本地构建目录约 520 MiB。这不是最终 IPA 包体或 RAM 预算。内层 `sysroot.tgz` 本地 SHA256 为 `eed7cbea79c86d93f89813315f3fce388ddec52ff0af910ec1237eefd63c7c56`；未以外层 ZIP API 摘要冒充内层验证。

已取得 Alpine 3.23.6 / Linux 6.18.52-0-virt 的内核与匹配 initramfs，以及固定 Debian arm64 静态 BusyBox。输入摘要匹配研究收据；已构造 RAM-only shell/HTTP probe。此镜像无持久化根文件系统、Node 或 Harness。

真机第一阶段已通过：普通开发签名启动原型，未连接调试器或启用 native JIT；aarch64 Linux 启动、网络 DHCP、真实 shell 子进程与 wait、管道、临时文件读写均通过。应用 HTTP 探测得到 `200 / guest-local-http-ok`；用户随后确认 WKWebView 显示该正文。检查签名 entitlements 时未见 allow-jit、hypervisor、increased-memory-limit 或 extended-virtual-addressing；普通开发签名的 get-task-allow 存在。

第二阶段追加官方 Node 24.21.0 Linux arm64、Debian glibc 2.41 和 GCC 14 运行库。真机输出 `NODE_VERSION:v24.21.0:arm64`；Node child_process、文件读写、内存 SQLite、worker_threads、guest HTTP fetch 全部通过，`NODE_PROBE_EXIT:0`。探针内报告约 8 秒，未计 Node 启动、内核启动和镜像解压，因此不是 Harness 性能结论。脚本见 `build-node-guest.py`；配置 1536 MiB RAM、镜像约 70 MiB 压缩，仅用于本次实验。

本地已打包一个约 47 MiB 的个人签名原型 IPA（不含 guest 镜像）；它不是可发布的 Harness IPA，其他人重新签名的安装链仍未验证。二进制和签名资料不公开。

第三阶段使用 2048 MiB guest RAM 通过完整镜像解包。koffi 的 libc 调用、sharp 生成 PNG、node-addon-system 文件锁和 node-pty 的 bash 子进程均通过，`NATIVE_PROBE_EXIT:0`；Landlock 功能探针返回 `full`。1536 MiB 的第一次实验出现 initramfs 写满、依赖不完整；该失败不作为模块不兼容证据。

固定官方 `@deepseek-ai/dsh@0.2.0-rc.2` 的原版 Web profile 成功打印启动 URL。用户最初反馈鉴权错误或空白，等待后确认看到了官方 Harness 界面及预览说明。此反馈验证可见界面，尚不能替代 API、会话、流式模型和工具调用验收。旧的 `PrototypeHostBridge.txt` 仍含 BusyBox 探针的 `200` 响应，不把它归因于 Harness。

独立 FAT 磁盘先写入文件，随后保留磁盘重启应用，得到 `PERSISTENCE_RESTORED:persistence-file-ok`。这是持久化块 I/O 和单文件恢复证据，不是 POSIX 根文件系统或工程工作区。此次强制退出也触发 FAT 未正常卸载提示，尚无优雅关机或异常退出一致性结论。

已实际调用官方 LocalSandboxProvider（默认 5 秒 probe timeout）：选中 Landlock/full；workspace-write 允许写入测试目录、拒绝写入 `/root`，read-only 拒绝写入测试目录。通过 provider 的诊断 hook 指向故意缺失的 launcher，得到 `SANDBOX_UNAVAILABLE` 且命令未执行；这是明确注入的失效测试，不是本机 launcher 失败。Node 子进程 SIGTERM 处理及正常退出也已通过。guest 对官方平台公开主页 HTTPS GET 返回 200，未提交账户信息。

用户已通过 API Key 入口配置成功；官方网页登录、手机号验证和 PKCE 流程仍未验收。进入后提示没有工作区，用户随后通过官方目录选择界面新建 `QQ` 目录并成功进入工作区。这是交互反馈，尚未证明模型工具执行。此前向串口诊断 mailbox 发送的 `/root/ipad-proof` 文件准备命令未被消费，不把该目录或测试基线计为已创建。

在 `QQ` 中提交创建加法模块、两条断言并运行 `node test.cjs` 的请求后，用户确认末次测试输出 `ipad-local-test-ok`、退出码 0。检查工作区和 Node 版本的早期操作曾显示 `/root/qq` 及 `bash: line 1: ls: command not found`；最小镜像尚未安装 BusyBox 的独立 applet 命令入口。这次交互确认了一个小型 Node 请求的模型与本地文件/测试执行闭环；测试文件内容尚未通过独立串口复核，不扩大为完整工具链兼容结论。

构造脚本追加 `$bb --install -s /bin`，并在 `bb` 变量赋值后创建 Documents，修正新镜像的初始化顺序。用户在当前真机原型串口直接执行入口安装、`ls /root/qq` 和已有测试。用户反馈及随后采集的原型串口日志均包含 `hello.cjs  test.cjs`、`ipad-local-test-ok` 和 `IPAD_TEST_EXIT:0`；本地串口复测已通过。

用户随后关闭并重新打开 guest 网页，在原工作区与会话提交只读复测请求（`pwd`、`ls -l`、`node --version`、`node test.cjs`），反馈“全都成功了，没有红色的失败操作”。网页重开后的会话恢复及再次模型工具交互已获 HITL 确认。这里没有重启 Linux 或原型应用，不能推断跨 VM 重启的数据持久化；流式传输细节、连接中途断网恢复及工具取消仍未单独验收。

最小 Linux 缺少 `xdg-user-dir`；官方 workspace controller 的默认工作区查询依赖它，也支持 `documentsDirectory` 部署覆盖。构造脚本已追加 `/root/Documents` 目录和官方 `--patch` 配置覆盖，供下次镜像构造使用。用隔离的临时 Harness home 在 Mac 上执行官方 `--profile web --patch … --dump-config`，组合结果包含目标 row 的目录覆盖；这是配置组合检查，未启动 Linux 二进制。尚未替换当前真机镜像，避免中断已配置的 API 会话。当前根文件系统仍在 RAM 中，`QQ` 项目、会话及 API 配置的跨 VM 重启恢复均未验收。

带上述覆盖和 BusyBox 命令入口的新镜像已在独立临时输出目录构造，压缩 initramfs 为 195,738,663 字节。检查生成 cpio 内的 init、patch 与 launcher，`bb` 赋值、命令入口安装和目录创建顺序正确；生成的 shell/JavaScript 语法检查与 `make check` 通过。这些检查不替代下次真机启动验收。

使用当前原型实际 PID 再次尝试短时 Activity Monitor 采样，Instruments 返回找不到目标进程，未生成有效采样；不报告 native 峰值内存。guest RAM 配置和 guest 内存统计不能替代应用进程的峰值占用。

已验收的小范围是 API Key 模型响应、工作区登记、文件/Node 测试工具、独立串口复测和网页重开后的会话恢复。待验收：流式传输细节、连接中途故障恢复、持久化 POSIX 根文件系统、IPA 重签交付链、native 峰值内存、冷启动和代表命令性能。本票保持开放；小型 Node 任务不能替代整个原型的全部验收条件或首版生产闭环。

构建资料见[执行器来源](linux-executor-build-sources.md)和[最小 guest 来源](miniguest-build-sources.md)，代码与运行方式见[原型说明](../../ios/LinuxPrototype/README.md)。Working Copy 工作区参考已记录到[工作区决策](https://github.com/lvivvde/deepseek-harness-ipad/issues/7#issuecomment-5965757506)。

## 2026-10-03：持久化 HOME 与启动采样

以下记录更新前述待验收状态。先用 Node 枚举 `/proc`，向官方 CLI 发送 SIGTERM；确认退出后将 `/root` 归档到原 FAT 盘的 `/persist/root-backup.tgz`，检查 tar 可读取、sync 并正常卸载。用户反馈和设备串口均确认 `STATE_BACKUP_OK`；再次卸载得到 Invalid argument 是已卸载后的重复操作。包含 API 配置的备份仅留在 iPad 应用容器，没有导出到 Mac 或仓库。

新增第二块 512 MiB ext4 raw 状态盘，只挂载 `/root`；`/opt/harness`、系统库及其他 runtime 根目录仍为 RAM initramfs。匹配模块来自固定 Alpine 3.23.6 modloop，构造脚本核对内容收据、模块 vermagic 和依赖闭包。生成 initramfs 为 196,277,748 字节，SHA256 `fed80dace589d3d40382e5bbe4b5dbe84a801e241b1f222cb6a94edbd8e67449`。新盘离线 `e2fsck -fn` 通过；已有设备磁盘没有覆盖或重新格式化。

第一次状态盘启动出现 `STATE_RESTORED_FROM_BACKUP`、`STATE_HOME_READY`、`NATIVE_PROBE_EXIT:0`。独立串口探针导入原 `hello.cjs` 复核两个 add 断言，运行原 `test.cjs`，得到 `ipad-local-test-ok`。ext4 上 0640 权限、相对符号链接、硬链接 inode 和 SQLite WAL 写入检查通过；计数从 0 写到 1。原测试子进程耗时约 1.64 秒，整个探针约 1.88 秒，均不计 Node 自身启动。用户未重新填 Key，通过官方左侧“会话恢复”找回原会话，并再次让模型运行测试成功。这是实际跨 Linux 重启的项目、会话及 API 配置恢复证据。

外壳改用自身 Mach `TASK_VM_INFO` 采样。第一次状态盘启动从 QEMU 调用到官方启动 URL 为 237.67 秒；约 315 秒时内核报告宿主进程峰值 1,885,653,344 字节（约 1798.3 MiB）。它包括 QEMU、Swift 外壳与采样器，不含 WKWebView 独立进程，也不是生产工作负载总峰值或整个安装启动耗时。

发现第一版 HTTP 就绪采样仍命中旧的 BusyBox 缓存：虽然响应为 200，正文只有 29 字节，不能作为 Harness 就绪证据；该版约 244 秒的 HTTP 数值作废。独立 guest HTTP 请求按官方启动 token 换 cookie，再获取首页，实际得到 200、34,846 字节及 `__DSH_BOOT__`。外壳随后改为无缓存 ephemeral URLSession，并同时核对官方页面标记；更新后的第二次启动正在验收。

第二次启动前，仓库中的 `stop-harness.cjs` 正常停止官方 CLI，串口确认 `HARNESS_STOPPED` 与 `STATE_DISKS_UNMOUNTED`。仅更新同一签名应用，没有复制或覆盖设备已有两块磁盘。第二次启动得到 `STATE_HOME_EXISTING` 与 `STATE_HOME_READY`，没有再次从备份恢复；集成探针读回计数 1 和 SQLite 原行，写到 2，权限/符号链接/硬链接及原测试全部通过，`STATE_PROBE_EXIT:0`。此次原测试子进程约 4.30 秒、整个探针约 4.75 秒，探针与 Harness 冷启动并发，不能与第一次 1.64 秒直接作为稳定性能比较。

更新后的实际签名仍没有 allow-jit、hypervisor、increased-memory-limit 或 extended-virtual-addressing；普通开发签名的 get-task-allow 存在。完整持久化 OS 根文件系统、异常退出恢复、流式中断/取消、IPA 他人重签链等仍未验收，原型票保持开放。

修正后的第二次启动，原生无缓存探测得到 HTTP 200、34,846 字节及官方 `__DSH_BOOT__`。从 QEMU 调用到启动 URL 为 244.12 秒，到实际官方 HTTP 页面就绪为 251.30 秒（约 4 分 11 秒）；约 279.50 秒时宿主内核峰值 1,890,978,120 字节（约 1803.4 MiB / 1.76 GiB），274 次采样无失败。两次启动都包含镜像解压、系统与原生探针、Harness 启动；第二次还并发执行了状态盘探针。它们是本原型两次观测，不是统计性能承诺。用户随后确认第二次重启仍可恢复 QQ 原会话，无需重新填写 Key，再次模型执行 `node test.cjs` 成功，输出和退出码均符合预期。

用户按要求短暂返回主屏幕再打开原型，确认不需要重新启动 Linux，原会话仍能运行测试并得到正确输出。外壳 lifecycle 记录可见约 8.98 秒、1.50 秒和 13.83 秒的 background→active 间隔，QEMU 计时与采样保持同一轮运行。没有在后台持续运行模型任务，不能据此判断长期后台执行、锁屏保活或暂停期间的流式连接行为。后续交互至 QEMU 调用后约 516.35 秒，共 498 次采样、0 次失败；宿主内核峰值增至 2,073,627,360 字节（约 1977.6 MiB / 1.93 GiB），仍不含 WebView 辅助进程。

本轮 Xcode 真机签名构建、Python/Node/生成 init 语法检查、`make check` 和实际 ext4 跨重启集成探针均通过。结论限定为两次正常停服务/卸载后的 HOME 恢复与短暂前后台恢复；没有制作正式迁移器、备份产品或通过强制退出一致性验收。

## 2026-10-03：写入中强杀宿主应用

强杀前先正常停止官方 CLI，把当前 ext4 `/root` 归档为设备 FAT 盘上的 `root-backup-current-20261003.tgz`：46 个条目、67,129 字节，`gzip -t` 与工作区、计数、SQLite 关键条目检查通过，SHA256 前缀 `cb86acbacc3e0758`。原 `root-backup.tgz` 未覆盖；两份备份都只在 iPad 应用容器内。随后重启 Harness，集成探针计数 2→3 并 sync，卸载 `/persist`，再启动 `abnormal-writer.cjs`。

写入器超过 150 次后，用 `devicectl` 向宿主应用发 SIGKILL（QEMU 与 Linux 同时被杀，无正常关机）。两块 raw 磁盘文件仍在，随后以 autostart 重启。实测：

- guest 内核输出 `EXT4-fs (vdb): recovery complete`，以 ordered data mode 读写挂载；init 得到 `STATE_HOME_EXISTING`、`STATE_HOME_READY`，没有触发备份恢复，原生探针 `NATIVE_PROBE_EXIT:0`。
- 最后 fsync 检查点为 220：日志 1–220 连续无坏行，220 个 64 KiB 块全部正确；SQLite `integrity_check` 为 ok，224 行连续，提交后但未到下一个检查点的 4 行事务也保留。
- 普通文件 `writer.log` 末尾有 16 字节 NUL，正好对应未 fsync 的 221–224 四行：文件长度已进日志、数据页未写入。首版校验把它误判为 `ABX_MISMATCH`；改为单独统计未同步尾部后设备复跑 `ABX_OK`。这说明不 fsync 的普通文件写入在宿主被杀后可能留下 NUL 尾部，Harness 自身配置/会话文件是否 fsync 仍未审计。
- 集成探针计数 3→4，原 `node test.cjs` 得到 `ipad-local-test-ok`；`/persist` 两份备份 `gzip -t` 通过，当前备份哈希不变。
- FAT 盘挂载时内核报告 `Volume was not properly unmounted`；该警告在本次实验之前的多次启动日志中已存在，不是本次强杀引入。FAT 盘仅作迁移备份。
- 本次从 QEMU 调用到启动 URL 293.44 秒、到官方 HTTP 就绪 300.46 秒，比上次 251.30 秒慢，期间并发执行核对命令；约 302 秒时宿主内核峰值 1,954,728,312 字节（约 1.82 GiB），不含 WebView 进程。

重启后用户确认：通过“会话恢复”找回 QQ 原会话，无需重新填 Key，模型再次运行 `node test.cjs` 输出正确。

结论限定为一次写入中宿主进程 SIGKILL：ext4 日志恢复正常，fsync 过的数据和 SQLite 已提交事务完好。未测 iPad 断电/系统崩溃、长时间后台被系统回收、流式回答进行中的强杀，以及 Harness 自身写文件的持久化语义。

## 2026-10-03：官方 Harness 写文件持久化审计

针对上节“未 fsync 的普通文件追加可能留下 NUL 尾部”，阅读本次部署的官方 `@deepseek-ai/dsh@0.2.0-rc.2` 依赖源码（仅读取，不修改上游），并在设备 guest 内只读核对：

- 会话日志（`dsh-session-persistence-jsonl`，默认 zstd 压缩）每批事件追加后立即 `fsync`，新建/改名后 fsync 父目录。读取时能截断不完整的最后一帧，但帧扫描先检查 zstd 魔数：如果被杀后尾部留下 ≥4 字节 NUL，会抛出 `invalid frame magic`，该会话会被判为损坏；列表跳过这条会话，打开时报 `SessionQueryError`，不会走截断修复。触发窗口仅限追加写入后、fsync 完成前，并且同时有其他日志提交把新文件长度写入 ext4 日志；上节实验已在同一 ext4 上实际观察到这种 NUL 尾部。会话日志本身尚未观察到。
- `dsh-storage-json` 与本地附件写入同样 fsync 文件和父目录。
- 凭据（`dsh-credentials-local`）、配置编辑、插件管理、app boot 和 `dsh-llm-deepseek` 使用 `dsh-atomic-write`：临时文件加 rename 替换，源码注明 “Crash durability (fsync) is out of scope”。guest 中 `/root` 以默认选项挂载（含 `auto_da_alloc`），rename 覆盖已有文件时 ext4 会先分配并提交新数据块，被杀后应得到旧内容或新内容；首次创建的文件没有这层保护。
- `withFileLock` 在 `<file>.lock` 中记录持有者 PID，只有 PID 不存在时才接管；源码注明 PID 被其他活进程复用时锁会一直保留，需要人工删除，超时 2 秒后写入失败。guest 每次冷启动都是新的 PID 空间：强杀前官方 CLI 的 PID 是 452，重启后是 465，数值很接近，强杀时残留的锁在重启后可能被误判为仍有持有者。这种锁只在凭据/配置的一次改写期间存在，读取不需要锁。
- 会话租约 `session.lock` 使用 `flock(2)`，进程死亡后由内核释放，不受上述 PID 问题影响。强杀重启后设备上有 4 个会话 `session.lock`，没有 PID 记录锁或残留 `.tmp`，4 个会话日志末尾都不是 NUL。

候选缓解（未实施，需先观察到实际故障或在首版决策中定案）：guest init 在启动 Harness 前删除内容为 `PID\n` 格式的残留 `withFileLock` 锁，此时 guest 内没有官方进程，这类锁必然已过期；会话日志 NUL 尾部的修复属于上游持久化行为，应作为上游问题或首版风险处理，不在原型里私自截断用户会话。下一步“流式回答进行中强杀”应在重启后同样核对会话日志尾部和损坏报错。

## 2026-10-03：流式回答进行中强杀

用户在 QQ 会话中让模型生成长回答。第一次 SIGKILL 因为本机脚本查找设备时出错，晚了约 40 秒，回答已经结束，所以只算作“回答结束后强杀”：重启后 ext4 日志恢复正常，`/root` 读写，4 个会话日志末尾都不是 NUL，也没有 PID 残留锁或 `.tmp`。随后改为单步强杀脚本，进行有效重做。

重做：用户确认回答正在输出后，16:11:41（CST）对宿主应用发 SIGKILL，6 秒后以 autostart 重启。实测：

- guest 内核再次输出 ext4 `recovery complete`，0 条错误，`/root` 读写，init 得到 `STATE_HOME_EXISTING`/`STATE_HOME_READY`。
- 正在使用的会话日志最后写入时间为 16:11:30，比强杀早 11 秒。guest 内逐帧解压：113 个 zstd 帧全部成功，207 条 JSON 记录 0 条坏行，末尾 0 字节 NUL；最后一条记录是新请求的 `requestHeader`。其余 3 个会话日志同样完整。
- 只有 4 个 flock 型 `session.lock`，没有 PID 记录锁或 `.tmp`；官方 CLI 正常重新拉起。
- 用户确认：会话仍在、可以打开，被打断的回答没有保留；再发消息能正常回复。

结论：本次观测中，官方 Harness 在请求开始时就把请求头落盘，但流式输出过程中不增量保存回答，强杀会丢掉正在生成的整段回答，不会损坏会话或阻止继续对话。属于首版需告知用户的数据丢失范围，不是存储损坏。上节的会话日志 NUL 尾部风险本次未触发（流式期间没有会话日志追加，窗口更小）；该风险与 PID 锁风险仍只是源码推断。未测 iPad 断电、长时间后台被系统回收和流式取消。

## 2026-10-03：流式取消、冷启动白屏与启动耗时

**流式取消。** 用户在长回答输出中点官方“停止生成”，键盘弹出，输出没有停止。原因：官方停止按钮在 mousedown 时把焦点移回输入框，iPad 上弹出键盘导致这次点击被丢掉。外壳注入只匹配“停止生成”/“Stop generating”标签的触摸脚本，把不移动的单击直接转成按钮 `click()`，不改上游代码。修复后用户再测两次都能立即停止；guest 内逐帧读取会话日志，两次 `turnend` 均为 `aborted`、`reason.kind=user`，之后的新消息正常 `completed`。上游改标签后脚本会失效，作为候选上游问题。

**冷启动白屏。** 之前外壳在串口出现启动 URL 时就打开 WebView，比官方 HTTP 就绪早约 7 秒；而官方前端 `index.html` 只有空的 `#root`，要等约 1.5 MB 脚本（无缓存头、无压缩）在 TCG 下下载执行完才有内容。现在外壳等到启动入口返回 200 且含 `__DSH_BOOT__` 才自动打开，等待期间显示阶段和按上次实测时长估算的剩余时间；打开后原生遮罩保持到 `#root` 出现文字并经过两帧绘制。用户确认页面自动打开，可接受。`PrototypeMetrics.json` 记录（只含数字）：HTML 响应 0.5 秒，脚本 8.5 秒执行完并渲染出文字，遮罩在打开 WebView 后 17.1 秒移除；此时 256×256 截图只有 0.2% 像素与背景不同，官方初始界面较空，或者文字渲染后仍有几秒未绘制，未进一步区分。

**启动耗时拆分**（16:57 冷启动，从 QEMU 调用起，串口标记首次出现时间）：

| 阶段 | 时刻 | 耗时 |
|---|---|---|
| 内核启动并解包约 196 MB initramfs（展开约 679 MiB，含整棵 `/opt/harness` npm 树） | 88.5 秒 | 88.5 秒 |
| 挂载状态盘、init 就绪 | 89.6 秒 | 1.1 秒 |
| 原生模块探针 | 97.2 秒 | 7.6 秒 |
| relay 就绪 | 99.5 秒 | 2.3 秒 |
| 官方 CLI 打印启动 URL | 243.5 秒 | 144 秒 |
| 官方 HTTP 就绪 | 250.8 秒 | 7.3 秒 |
| 前端脚本执行完 / 遮罩移除 | 打开后 8.5 / 17.1 秒 | |

最大的一段是官方 CLI 在 1 个 vCPU 的 TCG 下加载 JavaScript。不重启 guest、经 mailbox 连续三次启动官方 CLI 实测（`url_s` 为进程启动到打印 URL，`cpu_s` 为该进程 CPU 时间）：

| 运行 | `NODE_COMPILE_CACHE` | url_s | cpu_s |
|---|---|---|---|
| A | 无 | 159.6 | 146.4 |
| B | 空缓存（首次写入） | 168.2 | 154.3 |
| C | B 写入的 1320 个缓存文件（约 10 MB） | 140.4 | 129.3 |

缓存命中约省 19 秒（12%），首次写入多花约 9 秒。Node 只在进程退出时写缓存，而 guest 通常随宿主应用被杀，所以加了一个 `--require` 预加载，在进程启动后 180、300、600 秒调用 `module.flushCompileCache()`（定时器 unref，不阻止退出）；本机用 SIGKILL 结束进程，缓存文件已落盘。缓存放在 ext4 状态盘 `/root/.cache/node-compile-cache`，随状态盘持久化。原生探针改为每个 Harness 镜像在该状态盘上通过一次后跳过（标记文件名含 base initramfs SHA256 前 16 位），从关键路径上省掉约 7.6 秒。

部署：本机 `HarnessGuest/` 早于 BusyBox 安装那次提交，不是设备当前的 base；按 `state-receipts.json` 的 `baseSHA256` 从已部署的 `initramfs-state.cpio.gz` 中切出原 base（尾部 overlay 539,085 字节）重建，新旧 init 只差 Harness 启动这一行。新 initramfs 以新文件名上传并回读核对 SHA256，`boot.json` 只改 `initrd`，旧镜像保留作回退；没有触碰 `persistence.raw` 和 `state.raw`。切换前确认没有进行中的 turn，经 mailbox 正常停止官方 CLI 并 sync。

新镜像第一次启动（17:19，缓存已由上述实验预热，探针标记尚不存在所以探针照常运行）：官方 CLI 从 relay 就绪到打印 URL 129.4 秒（上次 144 秒），启动 URL 228.9 秒、HTTP 就绪 236.3 秒（上次 243.5/250.8 秒）。定时刷新生效：运行约 5 分钟后 guest 内缓存从 1320 个文件增加到 1351 个，探针标记已写入。

第二次启动（17:28，没有先停止官方 CLI，只经 mailbox sync 后由宿主应用直接重启，与平常关应用的路径一致）：串口为 `NATIVE_PROBE_CACHED`，relay 在 91.7 秒就绪（原 99.5 秒），官方 CLI 129.3 秒后打印 URL，启动 URL 221.0 秒、HTTP 就绪 228.2 秒。与优化前的 250.8 秒相比快 22.6 秒（约 9%）：省下的约 15 秒来自编译缓存，约 8 秒来自跳过探针。剩余大头是内核解包 initramfs 约 88 秒，以及官方 CLI 在 TCG 下即使有编译缓存仍需约 129 秒 CPU。进一步方案（均未实施）：把 `/opt/harness` 从 initramfs 移到只读磁盘镜像以缩短解包；前端静态资源加缓存头或压缩；QEMU 内存快照可接近秒开，但快照后状态盘继续变化，恢复时会与内存中的 ext4 状态不一致，必须先解决磁盘一致性才能考虑。
