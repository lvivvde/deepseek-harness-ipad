# 存储与工具补齐验收

2026-10-04，在 `codex/ipad-storage-tools` 实现；基线为 main `e5bab0f`。对应 [内置运行时与持久化用户盘](https://github.com/lvivvde/deepseek-harness-ipad/issues/17) 和已定的 [首版范围、工具与预算](https://github.com/lvivvde/deepseek-harness-ipad/issues/6)。本轮没有生成 IPA、没有安装，也没有访问设备或原型用户盘；后续与 [恢复与备份清单](ipad-recovery-backup.md) 一次集中验收。

## 本轮实现

- 悬浮按钮 →“iPad 应用设置…”显示用户盘逻辑上限、已分配宿主空间和 iPad 可用空间。用户手动在线增大至 64 GiB，默认仍为 8 GiB；拒绝缩小和超范围值。同容量可重试未完成的扩容。
- 扩容前提示不可缩小、真实剩余空间和保持前台；宿主余量低于 2 GiB 时拒绝扩容。前台每 15 秒检查并显示低空间提醒。
- QMP `block_resize` 修改 QEMU 正在使用的唯一 raw 盘，guest 验证 virtio 容量、在线运行 resize2fs、同步并核实 ext4 容量。扩容和备份/恢复共享互斥租约；失败不缩盘、不删除原数据，未完成操作可重试或冷启动补完。扩容期间的页面恢复请求在扩容结束后处理。
- 固定 Debian 快照的包集合由 66 扩到 135 项，包含全部已定系统工具及其运行依赖。真实执行 GNU 基础工具、Git/OpenSSH/curl、归档命令、rg/jq/less/nano；nano 的 PTY 退出也已验证。npm 全局前缀为用户盘 `/root/.local`，corepack 缓存在用户盘。
- `/bin/sh` 使用 Bash，启动与救援显式使用 BusyBox；保留 xterm-256color 终端定义、全部 IANA 时区、许可证/源码通知。网络、离线能力和代理边界已写入运行时说明。
- 新安装种子由旧版 512 MiB 缩到 8 MiB，仍为带日志的 ext4；Harness 启动前扩大到默认 8 GiB，已有盘不会被种子替换。Release 的 framework 副本去掉本地/调试符号，动态导出全部保留；virt 直接内核启动禁用网卡 PXE ROM，不嵌入其他机器固件。

## 自动验证

| 检查 | 本轮结果 |
| --- | --- |
| Swift 核心行为 | 21 项通过，含容量限制、低空间保护、QEMU 外部改变文件大小后的实时读值、备份排除属性、扩容与页面恢复互斥。 |
| guest 集成测试 | 14 项通过，没有跳过；含扩容失败释放租约、备份互斥、真实官方项目生命周期和归档校验。 |
| 原生编译 | Simulator Debug 与完整 guest 的无签名 iPhoneOS Release 通过。 |
| Linux QEMU 最终镜像 | 16 个固定检查全部通过；全新临时盘从 8 MiB 种子启动，扩至 8 GiB，再在线扩到 16/64 GiB；文件内容和运行中的官方 Harness 均保留。 |
| 插件、预览和备份回归 | 官方插件安装/组合、IPv4/IPv6 HTTP/WS 预览、转发修复、冻结期间控制服务、传输中断解冻、ext4 一致备份、完整恢复、坏归档保留数据、回收站清空均通过。 |
| 执行器导出 | 对照原始输入，所有 framework 的全局动态导出名称一致，QEMU 的三个桥接入口仍在。 |

测试程序持续读取串口，与生产宿主行为一致；若停止读取，较多内核/命令输出会反压 QEMU，使 HTTP 扩容请求超时。测试只输出固定结果，不打印串口全文、设备信息或启动凭据。

可复现命令（所有目录替换为自己的临时构建路径）：

```sh
CLANG_MODULE_CACHE_PATH=/tmp/harness-clang-cache swift test --disable-sandbox \
  --package-path ios/HarnessApp --cache-path /tmp/harness-spm-cache \
  --scratch-path /tmp/harness-spm
make test-runtime
make check
# Linux 环境；测试只使用新建临时盘，不使用已有用户盘。
python3 runtime/tests/boot-acceptance.py /path/to/final-guest
```

完整 sysroot 在大小写敏感的 Linux 文件系统上构建；若 `/tmp` 是小容量 tmpfs，设置 `TMPDIR` 到有足够空间的构建磁盘。固定输入、构建与无签名接入命令见 [运行时说明](../../runtime/README.md)。

## 体积与待验项目

最终无签名 App 的文件逻辑总量约 **1.199 GB（1.117 GiB），共 1,199,248,822 字节**，包含 1 GiB 系统盘和 8 MiB 用户盘种子，不包含安装后创建的用户盘。这是构建目录测量，不能登记为 iPad 的实际安装占用已通过。IPA ≤350 MB、安装本体 ≤1.2 GB、冷启动和内存门槛仍要用最终签名包实测；本轮未打包。

下一次一次覆盖安装，在同一包集中记录：

1. 项目与回收站点击菜单后行文字可见，清空后官方侧栏同步，旧会话不重建已删除目录。
2. 设置显示实际容量与宿主余量，扩容 8→16→64 GiB 后项目/会话/插件仍在；拒绝缩小，低空间提醒有效；前后台或网络中断后可完成同容量重试。
3. 运行中的扩容与备份互斥；完整备份恢复后数据有效。磁盘空间不足或损坏仍进入救援，保留原盘。
4. 删除文件后宿主实际占用是否下降（discard/打洞）；未验证前不承诺自动回收。恢复会保留旧数据目录，不能作为压缩原盘的保证。
5. 预装 nano/less 的官方终端 PTY、软键盘辅助键和中文输入；S 档七步开发闭环、社区与自制插件的模型调用、HMR/HTTP/WS。
6. 长后台、强杀、同身份覆盖安装、重签及实际体积/内存/启动时间；8 GB 下限设备尚未落实，不能写为已验证。

GitHub 实现票仍开放，状态说明代码已实现、验收待补；公开分发的许可证判断继续由 #14 处理。合并 main 前需用户同意，不发布 Release；重签截止为 2026-10-10 21:11（北京时间）。

## 源码复查

按照 code-review 技能，以 main `e5bab0f` 为固定基线，主 agent 顺序核对 Standards 和 Spec，遵守不开子 agent 的约束。当前图索引在本工作树就绪；所有改动代码文件核对覆盖信息，Swift 解析缺口第 131 行附近另读源码，不把索引无记录当作完整性证明。

| 轴 | 结论 |
| --- | --- |
| Standards | 没有留下已知硬性规范违反。沿用现有运行时与 supervisor 边界，扩容逻辑单独放在 guest user-disk 模块；不引入设备数据写入、凭据输出或备用执行副本。 |
| Spec | 工具、用户级 npm、手动在线扩容与空间提醒已补齐。复查修正 URL 文件大小缓存及扩容期间丢失页面恢复请求；真机、IPA 体量与法律发布条件保持待验，未据编译或隔离 VM 宣称全部首版验收完成。 |
