---
status: proposed
---

# 原生 Worker 为主，Linux 作为项目兼容插件

方案500建议将固定官方 Worker 的会话与模型 Agent 放在 WKWebView 中，由 Swift 网关管理唯一原生项目工作区和耐久状态；只有启用 Linux 的项目才异步准备无 JIT guest，命令等待真实 ready 后执行。原生修改和 Linux 命令共用耐久写租约，取消确认写者停止后才释放，冲突保留草稿，断连不重放命令。

**这是待用户确认的方案，当前未生效。真实模型小闭环仍待完成。** 它将重新打开 [ADR 0001](0001-local-linux-emulation.md) 中“官方 Harness 本身先在完整 Linux 内运行”的选择；完整 Linux 工具能力仍保留。选择它的理由是冷启动 Linux 前，用户已可打开会话、读写项目并恢复状态。两种共享模式在 macOS 和独立 iPad 研究 App 的有界证据见 [Worker/Swift/Linux 报告](../research/plan500-worker-gateway.md)。

## Considered Options

- **继续全部 Harness 留在 Linux。** 已有维护路线和回退包，减少官方 provider 改写；项目操作和会话仍受 VM 启动影响。
- **全部工具改写为原生。** 不需要 guest，但不能提供用户要求的 Linux shell、子进程和项目依赖兼容范围。
- **原生 Worker 与项目 Linux 插件。** 接缝已可运行，选作下一阶段候选；增加官方工具 provider、数据恢复和双域写者合同的维护成本。

## Consequences

- 唯一项目内容在 App 原生工作区，Linux 挂载同一目录，禁止用 Worker VFS 副本批量覆盖。官方会话只检查点 `/dsh/home`，项目和草稿单独耐久保存；正式实现必须定义并验证崩溃恢复，当前不是跨文件事务。
- 普通 UTF-8 文件的研究入口是已验证子集，不代表官方 fs/Git/全部插件已原生化。项目类型与插件能力须逐项声明 `native/linux/unsupported`，安装脚本和 shell 明确属于 Linux 执行路径。
- 共享模式未做最终选定：`none` 的原生普通文件较直接，但 FIFO/socket 受限；`mapped-xattr` 的宿主 mode/symlink 不等价。二者都不能据一次 Node 测试宣布完整开发项目兼容。
- `pthread_fchdir_np` 私有接口、同 uid `/proc` 和 SCM_RIGHTS 绕过、CAS TOCTOU、完整 watcher/Git/hook、增量模型流、VM 生命周期/后台/内存仍是关口。当前研究租约保护协作写者，不能宣称对恶意 guest 工具完成隔离。
- [ADR 0002](0002-runtime-ships-inside-ipa.md) 的固定运行时随 IPA 整体交付、系统内容只读和保留用户数据原则继续适用；正式旧用户盘不直接挂为新原生工作区。迁移要隔离备份、逐文件核验，并保留旧 App/用户盘回退。
- 本提案不关闭 #32、不解除 #17 的技术依赖，也不触发正式 App 安装或数据迁移。真实模型证据完成后，用户可确认架构方向，并明确把哪些剩余关口列为首个正式兼容范围的前置条件。
