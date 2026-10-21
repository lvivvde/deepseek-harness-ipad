# #23 插件安装验收

对应 [#23](https://github.com/lvivvde/deepseek-harness-ipad/issues/23) 中的插件能力。真机证据只来自独立 bundle ID 的候选 App，macOS 只算回归证据。预览与 HMR 见 [预览与 HMR 验收](issue23-preview-hmr.md)；键盘与前后台见 [键盘与前后台验收](issue23-keyboard.md)；模型调用插件另行记录。

## 方案（用户 2026-10-19 选定“原生 JS 安装”）

官方插件管理器在 profile 目录里运行 pnpm 安装，浏览器 Worker 做不到。候选 App 不改官方界面，而是在 Worker 里放一个虚拟 `pnpm`（[`candidate-pnpm.js`](../../runtime/candidate/candidate-pnpm.js)），原生回答官方管理器发出的 `config get registry`、`view`、`add`、`remove` 和 `install`：

- **解析与下载：** 从所选源（默认中国大陆镜像源）解析版本范围，按 sha512 校验每个 tarball，解包到 `/dsh/home/profiles/preview/node_modules`。
- **持久化：** 校验过的 tarball 由原生 [`PackageStore`](../../ios/HarnessApp/Sources/Candidate/PackageStore.swift) 按完整性摘要存一份；锁文件 `candidate-lock.json` 进 home 检查点，`node_modules` 不进。每次 Worker 启动按锁文件重新解包。卸载后，锁文件不再提到的 tarball 会被删除。
- **只装纯 JS：** 以下情况用 pnpm 自己的错误码拒绝，官方界面照常显示原因，并且什么都不改：
  - 有安装脚本（`ERR_PNPM_IGNORED_BUILDS`）；
  - 带原生二进制（`ERR_PNPM_UNSUPPORTED_PLATFORM`）；
  - 入口静态导入了 Worker 没有的 Node 内置模块，例如 `node:https`（`ERR_PNPM_UNSUPPORTED_PLATFORM`，消息写明“`<包> needs node:https`”）。只沿入口的相对静态导入检查，动态 `import()` 和 `require()` 不算；
  - 解包后超过 32 MB（`ERR_PNPM_TOO_LARGE`）；
  - 同一位置需要两个版本（`ERR_PNPM_UNSUPPORTED_TREE`）；
  - git 地址或本地路径（`ERR_PNPM_UNSUPPORTED_SPEC`）。
- **ESM 降级与模块解析：** 插件模块按需降级到 Worker 加载器能执行的形式；`execa`、`events.once` 和 home 内模块解析按 Worker 的能力补齐。
- **卸载锚点：** 官方 web 预览把 `installAnchor` 设成 profile 自己的 `package.json`。管理器认为锚点里列出的包不可卸载，所以任何插件都卸不掉（“卸载失败：这个包不属于当前 profile…”）。`prepare.mjs` 把锚点改为 `/dsh/home/config/candidate-installation.json`（`{"private":true}`）；查找插件目录仍会回落到 profile。

## 结果

| 项目 | macOS（2026-10-20） | iPad（r27） |
| --- | --- | --- |
| 官方界面安装 `@jonathanleelx/dsh-balance`，启用 | 通过 | 通过（2026-10-20）：store 有 1 个 tarball，锁文件和 `dependencies` 记录 0.1.0，`bundles` 含该插件 |
| 重启 App 后插件仍在、仍启用 | 通过 | 通过 |
| 官方界面卸载（`dsh-free-search`），store 同步清理 | 通过，store 剩 1 个 tarball | 未测（与 macOS 同一份 Worker 代码） |
| 安装 `dsh-balance`（无 scope，0.2.7）被官方兼容检查拒绝：同级依赖 `@deepseek-ai/dsh-credentials` 不在 DSH 0.2.0-rc.2 里 | — | 通过，界面显示不兼容原因 |
| 安装 `dsh-free-search` 被拒，界面显示原因，什么都不改 | 通过：`ERR_PNPM_UNSUPPORTED_PLATFORM dsh-free-search needs node:https, which the plugin Worker does not provide` | — |

`make test-candidate`（含 pnpm 11 项，1 项跳过）、`make test-app`（53 项）和 `make check` 通过。

## 限制

- **升级：** 官方界面写明不支持自动更新，要升级就先卸载再装新版。这条路径与上面的卸载、安装相同，没有单独测。
- **需要 Worker 没有的内置模块的插件：** 被拒，例如 `dsh-free-search`（`node:https`）。Worker 里没有 `node:https`，`node:http` 的 `request`/`get` 也不可用。
- **有安装脚本、原生二进制、超过 32 MB 的插件：** 被拒。
- **插件索引入口：** 官方页是静态 `index.html`，点插件索引的条目不会生效，只能手输包名。

## 未验证

- iPad 上的卸载与拒绝 `node:https` 插件：只在 macOS 测过。
- 模型通过插件调用工具（例如 dsh-balance 的余额查询），需要用户在设备上输入真实 Key。
