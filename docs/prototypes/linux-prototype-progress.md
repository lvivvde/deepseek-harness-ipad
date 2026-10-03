# 本地 Linux 原型：阶段记录

2026-10-03。对应[无 JIT 自签 IPA 原型验证](https://github.com/lvivvde/deepseek-harness-ipad/issues/11)。本文件只记录公开技术资产和阶段状态；个人签名、设备标识及完整设备日志保留本地。

已完成：SwiftUI/WKWebView 原生诊断工程、Objective-C 共享库入口、单次 VM 启动、真实串口收发、hostfwd 和本机 HTTP 探测。iOS device 目标无签名编译通过。

执行器来自固定 UTM `7eadb056ae0f91d979059544d0ddcd2d5a40be92` 的官方 `Sysroot-ios-tci-arm64` CI artifact `10845528675`。已解包核查 iOS 平台、三个 QEMU 入口及静态框架依赖闭包；提取 22 个 framework，连同固件的本地构建目录约 520 MiB。这不是最终 IPA 包体或 RAM 预算。内层 `sysroot.tgz` 本地 SHA256 为 `eed7cbea79c86d93f89813315f3fce388ddec52ff0af910ec1237eefd63c7c56`；未以外层 ZIP API 摘要冒充内层验证。

已取得 Alpine 3.23.6 / Linux 6.18.52-0-virt 的内核与匹配 initramfs，以及固定 Debian arm64 静态 BusyBox。输入摘要匹配研究收据；已构造 RAM-only shell/HTTP probe。此镜像无持久化根文件系统、Node 或 Harness。

真机 Linux、子进程、网页桥与官方 Harness 尚未验收。本票保持开放，继续收集实际启动日志和用户反馈；安装或界面出现均不能替代执行验收。

构建资料见[执行器来源](linux-executor-build-sources.md)和[最小 guest 来源](miniguest-build-sources.md)，代码与运行方式见[原型说明](../../ios/LinuxPrototype/README.md)。Working Copy 工作区参考已记录到[工作区决策](https://github.com/lvivvde/deepseek-harness-ipad/issues/7#issuecomment-5965757506)。
