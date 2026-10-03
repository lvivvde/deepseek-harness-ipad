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

待验收：官方账号/模型、会话、流式响应、真实工具调用与重连、持久化 POSIX 根文件系统和生产性能。本票保持开放；启动与可见界面不能替代完整闭环。

构建资料见[执行器来源](linux-executor-build-sources.md)和[最小 guest 来源](miniguest-build-sources.md)，代码与运行方式见[原型说明](../../ios/LinuxPrototype/README.md)。Working Copy 工作区参考已记录到[工作区决策](https://github.com/lvivvde/deepseek-harness-ipad/issues/7#issuecomment-5965757506)。
