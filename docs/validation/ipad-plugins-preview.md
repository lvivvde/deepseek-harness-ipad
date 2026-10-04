# 插件、预览与终端辅助键

对应 [首版插件、端口预览与终端辅助键](https://github.com/lvivvde/deepseek-harness-ipad/issues/23)。guest 固定 pnpm 11.28.4，官方 web profile 位于用户盘。插件由官方管理器安装；支持纯 JS 与已有 Linux ARM64 glibc 预编译依赖，Python、编译工具和系统包命令明确返回首版不支持。

首次启动将最小可编辑插件放在 `/root/projects/ipad-hello-plugin`。通过官方插件管理器或 `dsh plugin --profile web add /root/projects/ipad-hello-plugin` 安装，再让模型调用 `ipad_hello`。升级保留已有示例、profile 和插件。

guest 扫描 TCP 监听表并以 HTTP 探测筛选服务，支持 IPv4 loopback、guest 网卡和 IPv6 loopback/wildcard，筛选非特权端口，最多记录 32 个端口。为 loopback 开发服务器提供 HTTP/WS relay，QMP 增加仅宿主 loopback 的转发。固定后备端口为 3000、4173、5173、8080。宿主每 5 秒查询；每个端口提示一次，也可从悬浮工具菜单选择。优先通过官方 sidebarRight.openTab 打开 browser；没有可见会话或插件不可用时，横屏原生并排、竖屏原生全屏。关闭预览不关闭 VM。

终端辅助键在终端有焦点且软件键盘显示时出现，提供 Esc/Tab/粘滞 Ctrl/方向键及常用符号。通过官方 terminal model.write 输入。组合输入期间清除 Ctrl 并暂停辅助键；普通编辑框不接收终端控制字符。

自动验证：Swift 核心 19 项、guest 14 项、iOS Simulator 编译通过。真实 IPv4/IPv6 HTTP 与 WS 往返、端口停止、官方侧栏接口适配、中文输入隔离和官方 CLI 将自制插件安装到临时持久 profile 均通过。

完整 guest 启动、官方插件安装及备份恢复后启动已在隔离 Linux QEMU 通过。待统一验收：社区插件/模型调用/升级保留、示例模型调用，S 项目 ≤2 分钟启动与 HMR ≤15 秒，终端触摸/外接键盘、横竖屏预览。自动验证不能代替真机记录。

恢复与真机统一清单见 [恢复、备份与一次集中验收](ipad-recovery-backup.md)。
