# 选用完整 Linux 系统模拟作为首个验证路线

用户要求普通未越狱 iPad 上具备 Linux 式 shell 与子进程，并优先保持官方 Harness 的运行方式。我们选择 Swift 原生外壳、WKWebView 官方界面和 UTM SE/QEMU 无 JIT aarch64 Linux 模拟作为验证基线，接受执行器构建、桥接和模拟性能的代价；这保留了 Linux 工具语义，减少以受限宿主工具重写上游能力的需求。

此决定选择验证方向，不表示已通过生产验收。固定版本、维护边界、对应源码资料及重新选型门槛见 [架构基线](../design/architecture-candidates.md)；决策详情由 [决策：满足本地执行约束的 Harness 架构与语言怎么选？](https://github.com/lvivvde/deepseek-harness-ipad/issues/5) 记录。
