# 方案500隔离 Worker 探针

这是 Issue #32 的可证伪原型，运行真实官方模块，不接入正式 App。只支持 macOS GUI 会话中的 WKWebView，需 Xcode/Swift、Python 3、Node 24 和 npm。依赖、镜像、日志、检查点和可执行文件全部留在忽略的 `build/prototypes/plan500-worker/`。

从仓库根运行：

```sh
python3 runtime/prototypes/plan500-worker/run.py
```

默认使用安装完成的独立原型依赖树，或只读复用交接中已有的 Harness 测试依赖，并检查 lock SHA256 和 npm 完成标记；不接受中断留下的半成品目录。首次运行缺少依赖时，用以下命令按提交的两个 lock 安装到独立的 build 目录，安装脚本禁用：

```sh
python3 runtime/prototypes/plan500-worker/run.py --install
```

安装不会修改既有测试依赖。配置由官方 CLI 在独立 `DSH_HOME` 中组合；不改 HOME、不读取用户凭据，不发模型请求。HTTP 服务器仅监听本机随机端口，退出时关闭；Swift 不显示窗口，180 秒未完成即失败。单次只运行一个探针，输出目录不支持并发使用。

负对照移除 Zod/schema 适配，预期非零退出；仍含测量代码和 disposal 符号补齐，因此不能称为官方 bundle 的逐字节原样运行：

```sh
python3 runtime/prototypes/plan500-worker/run.py --unadapted
```

每次删除本探针旧收据和检查点，避免旧成功被误认成本轮结果。先保存需要保留的结果再重跑。`run-safe.json` 汇总 Worker、门禁、镜像、lock 和源码摘要；`*-private.log` 只留本机。原型不调用 QEMU、设备、签名或安装工具，不读原盘。

## 必要适配与仪器

- `pack.mjs` 用固定官方 packer 组装真实 web profile；复制 Zod 4.6.5 到 scratch，让 ESM 导出选择其发布的 CJS 等价物，避开模块 lowering 后的循环引用 TDZ。
- 同一脚本复制 `dsh-tools`、`dsh-cordis-host-runner`，把精确匹配 Chromium 原生函数字符串改为比较当前 realm 的原生 Object/Array。保留构造器名、prototype 身份及其余 schema 校验；真实浏览器探针额外拒绝 Date、类实例和无效 type。
- `prepare-web.mjs` 在官方 Worker 的副本中补齐缺失的 `Symbol.dispose/asyncDispose`，原有释放 helper 仍执行释放。按唯一锚点注入诊断、检查点恢复和受限调试操作；锚点变更就失败，不修改上游安装树。
- `worker-instrumentation.js` 先等官方 `sessionPersistence.flush()`，再抓取 `/dsh/home`、`/dsh/workspace`。其内存写入显式返回 `durable:false`。
- Swift 原生桥验证根路径，原子写单个 JSON 检查点、同步文件、读取比较并返回摘要；只有此确认表示这次检查点写入成功。恢复在官方 boot 前进行。
- `gate-probe.mjs` 是注入准备器/执行器的调度模型，证明准备、排队、取消、超时、去重、失败和项目关闭行为；没有真实 Linux、Git 或 hook。

## 证据边界

14 项真实 WebKit 检查涵盖官方接口、模块加载、schema 拒绝、会话创建/中文标题、文件写入、Swift 确认、Worker 重建恢复和注入保存失败。会话列表缓存可能滞后；重开官方会话后校验 JSONL 的权威标题，不能把列表缓存当成恢复完成。

这只是有界文件/会话检查点。没有跨 App/系统崩溃证明、目录 fsync、损坏日志恢复、并发写、外部写者、hardlink/symlink 身份保留、压缩日志迁移或实时 POSIX 共享协议。snapshot base64 与主线程写入也不适合直接用于大型工作区。没有 iPad、模型流式请求、完整 UI、真实 Linux 预热或 Git hook 验收。完整 G0–G7 门槛见研究报告；任何部分通过均不关闭 #32 或自动启动 #17。
