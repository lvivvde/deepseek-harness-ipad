# 方案500：隔离共享工作区与真实 Linux RPC 探针

研究原型，关联 [Issue32](https://github.com/lvivvde/deepseek-harness-ipad/issues/32) 和 [研究结论](../../../docs/research/plan500-sharing-rpc.md)。不进入正式 App。

## Linux 复跑

需要 Linux、Python 3.10+、`qemu-system-aarch64`、`cpio`、`unsquashfs`；准备本仓库 runtime 构建输出（`Image`、`initramfs.gz`、`system.raw`、`build-receipt.json`）及 `runtime/inputs.lock.json` 固定的 `modloop-virt`。输出目录必须可写，建议使用没有逗号的普通路径。输入核对 SHA256；实际运行版本记入收据。本轮 QEMU 为 10.2.1。

```sh
python3 runtime/prototypes/plan500-sharing/run.py \
  --runtime /path/to/bundled-runtime \
  --modloop /path/to/locked/modloop-virt \
  --scratch /var/tmp
```

本机既有 Lima `ubuntu` 内 runtime 为 `/var/tmp/ipad-bundled-guest-storage-v6`，modloop 缓存为 `/var/tmp/ipad-storage-build/inputs/modloop-virt`；其他机器须按 runtime 构建流程重建。不要创建这些路径的虚假收据，也不要将个人项目目录用作 workspace。

脚本创建自己的 `plan500-sharing-*` 临时目录，为 `mapped-xattr`、`none` 各创建合成 workspace 和独立 QEMU 进程。系统盘只读，guest 用 RAM overlay；没有打开 user.raw 或 user-seed.raw。收据沿用构建 receipt 的文件元数据，不表示所有文件都被读取。原始串口、QEMU 日志和 token 只留该临时目录，不提交。

固定 initramfs 本身没有完整 9P/overlay 模块，探针从已验证 modloop 加入依赖闭包，再建立 `cache=none` 的实际 9P 挂载。QEMU 网络 `restrict=on`，只有随机 localhost 端口转发到合成 agent；不是模型或外网请求。结束/失败时仅关闭本次启动的 QEMU，不操作已有 VM。

`agent.cjs` 是可信合成命令执行器，验证 auth、项目身份和 cwd；`/bin/sh` 仍能访问 guest 的其他路径。它**不是项目工具沙箱**，不能直接用于不可信模型/插件。RPC operation ID 只在 agent 存活期间去重，不提供跨崩溃的 exactly-once 保证。`Gate` 是独立 Python 调度探针，尚未连接官方 Worker 或 Swift 产品调度。

## 结果如何解释

`result-safe.json` 的 `completed=true` / 退出码 0 只表示必需协议检查全部完成。必须另读 `models[].semantics` 和 `allSharedSemanticsCompatible`；兼容性观察失败不会变成“探针执行失败”。本轮每个模式 23 项协议检查通过，两者 `allSharedSemanticsCompatible=false`。

- 协议检查：一次真实准备、宿主编辑不中断、排队自动执行、去重及 ID 冲突拒绝、关闭/取消/过期请求不重放、身份不符拒绝；真实挂载和 Node/Git；双向中文文件操作、原子替换与旧 fd；Git index.lock 与 O_EXCL；显式轮询；执行中超时/取消；断连后不执行、不重启 VM。
- 兼容性观察：mode、双向 symlink、真实 pre-commit 非零阻止提交；宿主 flock→guest flock、宿主 lockf→guest flock、guest flock→宿主 flock；guest fs.watch 的 700ms 宿主写入样本。
- `mapped-xattr` 的普通宿主 mode/symlink 不等价；`none` 在本 Linux 样本保留二者。两者均未互斥上述跨域锁、fs.watch 未收到目标宿主写入事件；轮询收到。Git index.lock 与跨域 flock 是不同机制。

原子替换检查不包含掉电/崩溃耐久性。一个 pre-commit 探针不覆盖完整 hook 顺序。Linux 启动时长不是 iPad 性能。完整 G0–G7、Darwin 9P backend、iPad 生命周期、模型、生产写租约和迁移均未通过。

## Darwin SDK 接口探针

```sh
python3 runtime/prototypes/plan500-sharing/darwin-check.py
```

仅编译一个小 C 程序并在自己的 macOS scratch 内运行；iOS 仅链接 dylib，不运行、签名或安装。检查公开头文件和显式私有声明两种路径，收据在忽略的 `build/prototypes/plan500-sharing/darwin-api-safe.json`。

声明取自 [QEMU v10.2.1 9p-util.h](https://github.com/qemu/qemu/blob/v10.2.1/hw/9pfs/9p-util.h)，该源码明确标记 `pthread_fchdir_np` 为 private API。本轮 SDK 27.0：公开头文件两端编译失败，显式声明两端链接成功，macOS 隔离运行成功。此结果不证明公开 API 适用性、整个 QEMU 可构建、正式 IPA 支持 9P 或 iPad 可运行。
