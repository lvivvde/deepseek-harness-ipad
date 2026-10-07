# 模型流式网关设计

依据：[ADR 0003](../adr/0003-native-worker-with-project-linux.md)，[#39](https://github.com/lvivvde/deepseek-harness-ipad/issues/39) 关口 4。2026-10-06 创建。

代码在 `ios/HarnessApp/Sources/ModelGateway/`（SwiftPM 目标 `ModelGateway`），测试在 `ios/HarnessApp/ModelGatewayTests/`。研究 App 和 macOS 宿主的接线在 `runtime/prototypes/plan500-ipad/`：`Sources/WorkerBridge.swift`、`web/worker-bridge.js`、`web/integration.html` 和 `fault_server.py`。这一层还没有接进正式 App 工程，接入属于 #17。

## 分工

官方 Worker 不改动。它自己的 Messages 解析器、重试策略、错误分类和取消逻辑照常运行。Worker 里的 `fetch` 换成垫片，经原生 RPC 交给 `ModelGateway`：

| 一方 | 负责 |
| --- | --- |
| Worker（官方代码） | 请求体、SSE 解析、重试与退避、`AUTH`/`RATE_LIMIT`/`SERVER`/`TRANSPORT`/`TIMEOUT` 分类、回合状态 |
| `ModelGateway`（Swift） | 端点、真实密钥、HTTP 请求的生命周期、按到达顺序交回字节、固定失败码 |

垫片的三个操作是 `model-open`（阻塞到响应头或失败）、`model-read`（取下一块或结束）和 `model-cancel`。原生回复由预置的监听器分流，因为官方隧道收到不认识的帧会让 Worker 失败。

## 端点与密钥

- 只接受 `https://api.deepseek.com/anthropic/v1/messages`。其他 URL 在发送前返回 `MODEL_ENDPOINT_REFUSED`。
- 重定向一律拒绝，不跟随，结果是 `MODEL_REDIRECT_REFUSED`。
- 真实密钥只在 Swift 一侧，按请求读取，以 `x-api-key` 发出。密钥必须非空且全是可打印 ASCII，否则返回 `MODEL_KEY_REQUIRED`，不发送。
- Worker 只拿到占位密钥。Worker 带来的 `authorization`、`x-api-key` 和 cookie 一律丢弃。转发的请求头只限 `content-type`、`accept`、`anthropic-version`、`anthropic-beta`、`user-agent` 和 `x-deepseek-harness-*` 前缀。
- 会话是 ephemeral：无缓存、无 cookie、无凭据存储、无代理。
- 记录（`Record`）只含计时、块数、字节数、状态码和最终结果，不含请求体、响应体或密钥。
- 研究 App 的密钥由用户在设备上输入，只用于本次检查：存进内存里的 `ModelKeyBox`，检查结束即清空，不落盘。正式 App 的钥匙串存储属于 #17。

## 流与取消

- 每次请求的响应体按到达顺序分块交回 Worker，不缓冲到结尾。单次读取最多 1 MiB。
- 官方 agent-loop 把解析出的增量作为 `agent/assistant-stream` 帧发出，官方 UI 据此逐步显示回复。验证同时记录原生分块和这些帧的时间，两者都要早于响应结束。
- 空闲超时 330 秒，比官方 Worker 自己的流看门狗长，所以通常由官方先报 `TIMEOUT`；网关的 `MODEL_TIMEOUT` 是兜底。
- 取消会结束真实的 HTTP 请求：在响应头之前、流中途，甚至在 `open` 之前到达，都有覆盖。
- 取消后回合以 `aborted` 结束，已收到的部分回复标记为中断，之后不运行任何工具。
- 官方适配器在流结束后还会再取消一次，这次取消可能晚于 `model-read` 交回结束。网关记住最近已结束的流，对它们的取消是空操作，不当作“先于 `open` 的取消”留下来。垫片的流 ID 带每个页面随机的前缀，网关比单个 Worker 活得长，ID 不在 Worker 之间重复。iPad 首轮验证发现过这个问题：旧 ID 上残留的取消让下一个 Worker 的同号请求在 1 ms 内以 `MODEL_CANCELLED` 失败，再由官方重试补上。
- Worker 没有要求的取消（URLSession 自己报告 `cancelled`）不报告为 `MODEL_CANCELLED`。底层错误是无网络、或当时网络路径不可用时报告为 `MODEL_OFFLINE`，否则报告为 `MODEL_TRANSPORT`。每条记录带错误域、错误码、底层错误域和错误码，以及当时网络路径是否可用，不含请求或响应内容。

## 固定失败码

| 码 | 含义 |
| --- | --- |
| `MODEL_ENDPOINT_REFUSED` | 非官方端点，未发送 |
| `MODEL_KEY_REQUIRED` | 缺少或不安全的密钥，未发送 |
| `MODEL_REDIRECT_REFUSED` | 服务器要求重定向，已拒绝 |
| `MODEL_OFFLINE` / `MODEL_DNS` / `MODEL_CONNECT` | 无网络、域名解析失败、连接失败 |
| `MODEL_TLS` | TLS 失败 |
| `MODEL_TIMEOUT` | 空闲超时 |
| `MODEL_DISCONNECTED` / `MODEL_TRANSPORT` | 连接中断、其他传输错误 |
| `MODEL_CANCELLED` | Worker 要求的取消 |
| `MODEL_STREAM_DUPLICATE` / `MODEL_STREAM_UNKNOWN` | 垫片协议错误 |

HTTP 错误状态不算网关失败：状态码、响应体和 `retry-after` 等头原样交给官方解析器，由它分类并决定是否重试。

## 验证

### SwiftPM 单元测试

`swift test --package-path ios/HarnessApp --filter ModelGatewayTests` 针对本机回环故障服务器运行，覆盖：

- 端点限制、密钥注入、Worker 凭据丢弃
- 分块先于结束到达
- 三种时机的取消
- 401/429/503 的状态、正文和重试头
- 流中断开、空闲超时、端口关闭、未知主机、重定向
- 离线错误映射
- 记录不含密钥和正文

### macOS 故障矩阵

`run-worker.py` 的 `gate4` 阶段在 macOS 宿主里运行真实 Worker，模型请求经网关指向 `fault_server.py`。服务器按提示词里的标签脚本化每个场景，并统计线上请求数。

| 场景 | 预期 | 线上请求 |
| --- | --- | --- |
| stream | 官方解析器完成回合，首块与末块相差 900 ms 以上，官方回复帧同样在末块前 900 ms 以上开始，无重试 | 1 |
| auth (401) | 官方 `AUTH` 错误，不重试 | 1 |
| rate (429) | 按 `retry-after` 等 1 秒，重试一次后完成 | 2 |
| server (5xx) | 两次 `SERVER` 重试后完成 | 3 |
| drop-head | 响应头前断开：一次 `TRANSPORT` 重试后完成 | 2 |
| drop-tool | 工具调用后流中断开：重试时不重放工具 | 3 |
| idle | 空闲流显式 `MODEL_TIMEOUT`，重试后完成 | 2 |
| exhaust | 持续 5xx：官方重试 5 次后以 `SERVER` 错误结束 | 6 |
| cancel | 首块后取消：回合 `aborted`，原生记录为 `MODEL_CANCELLED`，对端连接已关闭，不运行工具 | 1 |

线上检查还确认：

- 每个请求都带 Swift 侧的密钥，占位密钥从未发出。
- Worker 凭据被丢弃。
- 只访问了 `/anthropic/v1/messages`。

### iPad 真机

研究 App 在 `WorkerResearchView` 提供三个按钮。结果在 #39 评论中以脱敏形式记录，原始回执留在忽略的 `build/`。

| 按钮 | 密钥 | 检查 |
| --- | --- | --- |
| 真实流式与中途取消 | 用户在设备上输入 | 真实流式完成；多块先于结束到达；官方回复帧在结束前逐步发出；首块后约 800 ms 取消，回合 `aborted`，部分回复标记中断，不运行工具，原生记录为 `MODEL_CANCELLED` |
| 无效密钥 | 固定值 `sk-plan500-gate4-invalid-key` | 官方 `AUTH` 错误；一次请求、401、不重试 |
| 离线 | 固定无效值，先开飞行模式 | 官方 5 次重试后以 `TRANSPORT` 结束；6 次请求都在响应前失败 |

后台生成（生成中切到后台）只记录，不阻塞关口。
