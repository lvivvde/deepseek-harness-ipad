# 方案500：官方 Worker 接入 Swift 工作区与 Linux 网关

2026-10-06，北京时间。继续 Issue #32、`research/plan500-feasibility` 和 draft [PR36](https://github.com/lvivvde/deepseek-harness-ipad/pull/36)。本轮只修改独立研究 App；正式 Harness、用户盘和 ADR/CONTEXT 保留。

## 当前结果

**官方 Worker、Swift 原生文件入口与真实 Linux 9P 已在同一合成工作区接通。** iPad 的 `none` / `mapped-xattr` 各通过 23 项协作检查和 9 项独立 App 进程重启恢复检查。macOS 使用同一 HTML/Swift 检查逻辑，已通过相同有界合同。**真实模型小闭环已在 iPad（`none` 模式）有界通过**：用户在研究 App 自行输入 Key，官方 Agent 带版本修改 `math.cjs`，经 Linux 精确运行 `node test.cjs` 成功后返回最终结果；不是增量流式或完整 G0–G7 验收。

| 用户要求 | 已验证行为 |
| --- | --- |
| Linux 未就绪时 Worker 可用 | 真实官方 Worker 创建会话、中文标题、原生读取与带版本的耐久写入；冷状态不调用 guest RPC |
| 工具等待真实 ready 后自动执行 | 项目启用入口异步准备一次；Worker 的 Linux 工具等实际 9P、项目身份、只读挂载、cgroup kill 和 `/bind`；未 ready 不取写租约；ready 后自动执行一次；取消等待不产生文件 |
| 同一写租约、保草稿和取消 | 两种写者均走一个 Swift Gateway；Linux 写入期间原生修改保存 HELD 草稿，读拒绝部分内容；Linux 变更造成冲突时保存草稿字节；取消只请求停止，`/execute` 返回 `writerQuiescent=true` 后才释放，非冲突草稿随后应用；实际循环写者停止后文件不再变化 |
| App 重启恢复 | 真机 `--terminate-existing` 再启动研究 App；官方 JSONL 会话身份及中文标题、原生文件、Linux 文件/修改和冲突草稿恢复；恢复检查本身不启动 Linux |

每种模式切换都使用新 App 进程；一个进程最多启动一次 QEMU。恢复测试为干净检查点之后的进程重启，不是系统崩溃、损坏日志或活动写者崩溃恢复的完整证明。

## 接缝和权威数据

- 项目唯一权威目录在研究 App 的 Documents。Swift Gateway 与 Linux 9P 使用同一路径。项目文件不写入 Worker 的内存工作区再批量覆盖宿主。
- 保留固定官方 `0.2.0-rc.2` Worker、packer、会话 API、工具注册器与模型 Agent。沿用先前 Zod CJS、WebKit disposal 和原生构造器比较适配。新增桥接仪器只附加到 scratch Worker 副本。
- 研究会话用官方工具注册器注册 `plan500_read`、`plan500_write`、`plan500_linux`。原继承 VFS/shell 工具被过滤；作用域内 subagent 插件在研究打包配置中禁用，避免子会话旁路。**这是三个研究工具的适配，不是官方全部 fs/Git/插件已经原生化。**
- 原生读返回 CAS 版本；Linux 租约期间不读取正在变化的文件。原生写明确区分 WRITTEN、DRAFT_HELD 和 CONFLICT；无租约的版本冲突也把草稿持久保存。路径遍历用已有 `openat/O_NOFOLLOW`，读取限于普通 UTF-8 文件、1 MiB。
- 冷状态只保存原生 generation 日志；绑定 Linux 后补发通知。Linux 命令在网关取得耐久租约后发出，掉线保持 WRITER_UNKNOWN，不自动重跑。
- 会话只对 `/dsh/home` 做官方 flush 后的原生检查点；原生工作区和草稿单独持久化。重启读取相同项目身份，不覆盖已有合成内容。检查点并非会话与项目的跨文件事务。

## 真实模型小闭环（iPad `none` 模式有界通过）

研究 App 完成检查后显示 SecureField 和“运行真实模型修改与 Linux 测试”。用户自行在设备输入 DeepSeek API Key，不从聊天取值，不读取正式 App 凭据。Key 仅留 Swift 内存，Worker 的凭据服务只得到占位值；检查结束清除本次 Key。

固定流程：在研究工作区生成有减法缺陷的 `math.cjs` 和断言 `add(2,3) === 5` 的 `test.cjs`；官方 Agent 读取并带版本修改前者，调用 Linux `node test.cjs`，接收退出码 0 / `MODEL_TEST_OK`，再返回结果。验收要同时看到真实模型 HTTP 200、官方 session/tool 事件中的 `math.cjs` 带版本写入、其后精确 `node test.cjs` 成功、原断言文件字节未变、成功工具结果之后的最终文本和 `turn/end(completed)`；不能用手写工具序列或模拟模型代替。本次模型工具范围只允许写 `math.cjs`、运行该测试命令，拒绝临时替换测试或其他 shell 命令。

研究网络桥只接受 `https://api.deepseek.com/anthropic/v1/messages`，拒绝重定向，不记录 Key；每次检查最多 12 次请求、每次最多 2048 输出 token。当前原型缓冲 HTTPS SSE body 再交官方 adapter 解析，**不是增量流式交付的验收**。HTTP/模型失败保留为未通过。

真机结果（2026-10-06，研究 App，`none` 模式）：8/8 模型检查通过，Worker 协作检查同时通过。7 次 HTTP 200；模型带版本写入 `math.cjs`，`test.cjs` 字节未变；Linux 精确 `node test.cjs` 退出 0、见到 `MODEL_TEST_OK` 且写者已结束；其后最终中文回复与 `turn/end(completed)` 在同一轮。模型先发出过一次非精确测试命令，被模型运行守卫在派发前以固定代码拒绝，随后重试精确命令；网关收据确认本次模型只有 1 次 Linux 租约运行。前两次真机运行未通过：第一次收据缺少工具轨迹无法定位；第二次因判据把派发前被拒的越界尝试也算违规而误判，补脱敏轨迹并收紧为“仅接受对应守卫以固定代码拒绝的越界尝试”后第三次通过。

安全收据只含检查名、布尔、计数和脱敏轨迹（工具名、轮次、事件顺序、成败、允许表内的固定错误码或状态/退出码、是否见到标记、是否为限定路径/精确命令），不含 Key、文件文本、命令原文或输出；错误码只做精确匹配，其余记为 `OTHER`，未知工具与重复 callId 均算越界。`mapped-xattr` 模式未跑模型闭环；SSE 仍缓冲交付。

## 复跑

依赖沿用 Worker 原型的两个固定 npm lock；缺失时先按其 README 安装到忽略 build 中。

```sh
# 固定配置打包 + 同一 macOS 合同 + 两个真实进程的恢复
python3 runtime/prototypes/plan500-ipad/run-worker.py \
  --inputs build/prototypes/plan500-darwin/inputs \
  --output build/prototypes/plan500-ipad/worker-host-new
# 只准备 Worker 资产
python3 runtime/prototypes/plan500-ipad/run-worker.py --prepare-only
# 独立 iPad 未签名包；签名/安装沿用已经获准的研究身份
python3 runtime/prototypes/plan500-ipad/build.py \
  --inputs build/prototypes/plan500-darwin/inputs \
  --executor ios/LinuxPrototype/.runtime \
  --worker-web build/prototypes/plan500-worker/web \
  --output build/prototypes/plan500-ipad/worker-unsigned-new
```

设备首次协作检查用 `--worker-probe --model none --project-id <新的 UUID> --run-id <本轮随机值>`，恢复用相同模式和 project-id、新的 run-id；另一模式为 `mapped-xattr`。研究 App 保存上次模式和项目选择，普通图标重开自动根据 `/dsh/home` 检查点进入恢复；`--resume` 仍可明确要求恢复检查。首次检查要求新的合成样本，不能对已被 Linux 修改的旧样本冒充首次检查。独立 `--plan500-probe` 原有 15 项协议入口继续保留。

## 回归与审查

29 项正式 Swift、32 项 runtime（固定官方依赖，无跳过）、11 项设备工具、4 项研究输入拒绝、17 项 Swift 网关测试、10 项模型验收判据测试（含脱敏轨迹、拒绝码允许表、未知工具/重复 callId）及 `make check` 通过。新增两个网关测试均有红绿证据：Linux 冷状态原生读写、冲突草稿跨网关恢复。最终 macOS 复跑入口两模式各 23 + 9，通过并记录源码/Worker 资产摘要。代码审查以本轮起点 `776020f` 为固定基线，Standards 无硬违反；低优先状态字符串建模建议保留。Spec 最初发现测试标记和中途评论会误判，复审又发现临时替换测试后恢复的误判；均已修复，5 项反例/正例测试红后绿，最终聚焦复审无新增发现。另补齐 WebKit 私有日志入口和普通图标重开自动恢复。

## 尚未解除的关口

四项协作检查是有界证据，不补齐完整 G0–G7。`none` 的 FIFO/socket 限制、`mapped-xattr` 的宿主 mode/symlink 非等价、私有 `pthread_fchdir_np`、同 uid `/proc` / SCM_RIGHTS 绕过、CAS TOCTOU、完整 watch/Git/hook 和 VM 退出合同继续保留。当前文件入口也没有字节/目录/链接/编辑/搜索的完整官方 provider 等价性。性能、内存、后台和增量模型流仍未验。

下一步把受支持范围、剩余隔离风险、插件生命周期和迁移边界作为可审阅的方案500架构决定提交用户确认。#32 OPEN，#17 继续等待；不据这四项检查直接改选正式架构。

私有证据入口：`build/prototypes/plan500-ipad/worker-device-r1/signing-safe.json`、`worker-none-first/latest-result-safe.json`、`worker-none-resume/latest-result-safe.json`、`worker-mapped-xattr-first/latest-result-safe.json`、`worker-mapped-xattr-resume/latest-result-safe.json`。最终审查修复后的真机收据与签名/编译摘要同结构位于 `worker-device-r2/`；两种模式恢复均使用不带 `--worker-probe`、`--model` 或 `--resume` 的普通入口启动（仅传新 run-id 关联收据）。macOS 最终收据与编译来源在 `worker-host-final-r3/worker-host-safe.json`；原始网络、串口、设备和签名信息均不提交。真实模型通过收据为 `worker-device-r4/model-result-safe.json`（含签名/安装摘要），失败运行留在 `worker-device-r3/` 和 `build/device-acceptance/`；审查修复后的最终资产 macOS 两模式 23 + 9 在 `worker-host-trace-r3/`。审查修复只改变收据形状（成功收据也改用脱敏轨迹）与等价但更严的判据，未在真机重跑模型；同类脱敏轨迹经 JSON 往返的 WebKit 回传已由第二次真机失败收据验证。
