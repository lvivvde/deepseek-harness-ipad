# 开发交接

最后更新：2026-10-23，北京时间。此文件是接手入口，只记当前状态、约束和资产入口；GitHub Issues 是任务状态源，过往过程见 Git 历史（2026-10-21 之前的详细交接在提交 `111817f` 的本文件里）和验收记录。

## 开始工作

1. 读根 `CONTEXT.md`、相关 `docs/adr/`，检查 `git status --short`、当前分支和最新提交。保留已有未提交改动。
2. 查 `gh pr list --state open` 和下表的 Issues。已有待合并分支时先继续该分支；每个 PR 合并都另获用户同意。
3. 真机任务读 [真机自动化](../validation/ipad-device-automation.md)；先用只读 `probe` 确认连接，减少用户交互。
4. 完成后更新本文件的状态、验证和下一步；原始日志、设备、签名参数留在忽略的 `build/`，公开文档只记脱敏结果。

## 当前状态

只有一个 App：**DeepSeek Harness**，bundle ID `org.lvivvde.harness.candidate`（沿用，覆盖安装保留数据）。架构见 [ADR 0003](../adr/0003-native-worker-with-project-linux.md)：官方 Worker 在 WKWebView 中运行，Swift 是唯一权威，Linux 是项目级插件，在 App 进程内的 QEMU 里运行。结构和签名见 [App 说明](../../ios/HarnessApp/README.md)，构建输入见 [runtime/README.md](../../runtime/README.md)。

[单一 App 方案](../design/single-app-plan.md)第 1 步（分支 `feat/single-app`）已合并：删掉旧正式 App、研究 App 和原型，纯改名为 `HarnessCore`、`runtime/app`、`build/app`，版本 1.0.0。落盘或设备上的名字不改：bundle ID、`candidate-lock.json`、`config/candidate-installation.json`、`HARNESS_CANDIDATE_*` 启动环境变量、Worker 帧和挂接点的 `candidate*` 标识、guest 里的 `.plan500-identity` 和 `/run/plan500*`。`make` 只剩 `doctor`、`check`、`test`、`web`、`app`、`ipad`；设备工具只剩只读 `scripts/device.py probe`。

正式界面（分支 `feat/official-ui`，[PR #73](https://github.com/lvivvde/deepseek-harness-ipad/pull/73) 已于 2026-10-21 合并）：用户要求和 Mac 上的 DeepSeek Harness 一样的正式界面。

- 整窗就是官方网页界面（左侧栏新会话、插件、工作区列表；输入框带模型选择和“工作区内修改”）。自建的 SwiftUI 侧栏删掉，运行状态（会话保存、Linux、预览、能力声明）挪到右下角小圆按钮的表单里，macOS 菜单“运行状态…”（⌘⇧I）。界面文字中文。
- 第一次启动自动建“默认工作区”（启用 Linux），启动时打开全部项目再显示网页。
- 官方工作区选择器的浏览后端被包装：根是 `/dsh/workspace`，列出原生项目；“新建文件夹”就新建一个原生项目（启用 Linux）。`registry.resolveByPath` 对还没打开的项目返回 undefined，否则官方会报 `ENOENT: no open project, realpath`。
- 官方首次提示和“设置 → 模型”写 Key 时经 `credentials.set` 交给 Swift（`model-key`），Worker 只留占位值，见 ADR 0003。
- 官方侧栏在页面宽度小于 1024 px 时收成图标条；macOS 窗口被遮挡时 CSS 动画暂停，后台截图里侧栏文字是空的，前置窗口就正常，不是缺陷。
- 已验证（macOS）：`make app` 通过，桥接测试 23/23；窗口前置后侧栏完整，自动建默认工作区，选择器列出项目，新建文件夹后不用重启就能打开，重启后项目都在，运行状态表单正常、Linux 绑定到项目。Key 输入框是安全输入框，自动化打不进去，Key 路径只由单元测试覆盖。
- iPad：r30 已安装并启动，进程在运行。之前 App 已被删掉，重装后要在“设置 → 通用 → VPN 与设备管理”里重新信任开发者才能打开。

第 2 步（去掉 `system.raw` 里约 537 MB 的 `/opt/harness`，需重建镜像并重跑 Linux 验收）以后再做。

## 已验证的能力（iPad，r28 及以前）

| 范围 | 结果 | 记录 |
| --- | --- | --- |
| #39 六项前置关口 | 全部通过 | #39 评论、各设计文档 |
| #17 App 竖切：项目、原生工作区、模型回合、shell、终端、会话恢复、Linux 执行生命周期 | 通过，缺口按核对表放行 | [#17 完成条件核对](../validation/issue17-closeout.md)、[测量](../validation/ipad-candidate-measurements.md)、[Linux 执行生命周期](../validation/ipad-linux-execution.md) |
| #18 Git 开发闭环（测试仓库 `lvivvde/harness-acceptance-ts`） | 6 步通过，发现已修 | [#18 验收](../validation/issue18-git-loop.md) |
| #23 预览与 HMR、插件安装、键盘、中文输入法、前后台 | 通过 | [预览与 HMR](../validation/issue23-preview-hmr.md)、[插件](../validation/issue23-plugins.md)、[键盘与前后台](../validation/issue23-keyboard.md) |
| #14 许可证审查 | 不发布 IPA，只公开源码；已加 MIT `LICENSE` | [简报](../design/license-review-brief.md)、[分发组件](../design/distribution-components.md) |

仍未测：外接硬件键盘、语音输入法切换、需要 Linux 的社区插件、iPad 上卸载插件、网页进程被系统结束后的重新加载、断电与系统崩溃。

**下一步：** 用户在 iPad 上看 r30 的界面。

以后可选：第 2 步精简系统盘；桥接对 shell 执行也重试 `LEASE_BUSY`。

## 开放任务

| Issue | 说明 |
| --- | --- |
| [#15 路线图](https://github.com/lvivvde/deepseek-harness-ipad/issues/15) | 总入口；#39、#17、#18、#23、#14 已关闭。 |

## 已知缺口与技术约束

- 能力声明的兼容限制：同项目 Linux 命令一次一条（`ONE_COMMAND_AT_A_TIME`），命令运行中进入后台会变成写者未知，需手动释放；`git.write` 只经 shell（`SHELL_ONLY`）。见 [能力声明](../design/capability-declaration.md)。
- shell 工具单条命令 60 s 上限；iPad guest 是单核解释执行，大仓库完整 clone 放不下。
- 9P 共享模式 `none` 不能建 FIFO/socket；iPad 容器大小写不敏感，工作区须显式处理同名。
- libslirp `listen(s,1)` 在 XNU 下积压溢出会 RST。
- 私有 `pthread_fchdir_np` 只做启动检测，符号缺失时 Linux 插件不可用。
- 同 uid 经 /proc、SCM_RIGHTS、写租约 CAS TOCTOU 的隔离缺口保留；shell 能直接 `git commit --no-verify`。
- 每进程 QEMU 最多启动一次；VM 退出后提示关闭并重开 App。
- 物理锁屏与 8 小时验收已取消，不登记通过。

## 文档入口

- 设计：`docs/design/`（调度与隔离、会话恢复、Linux 执行生命周期、能力声明、原生工具、原生只读 Git、模型网关、分发组件）。
- 验收：`docs/validation/`。r28 及以前的记录里写的“候选 App”“`make candidate-*`”就是现在的 App 和 `make` 命令。
- 研究：`docs/research/`，原型代码已删除，见 Git 历史。

## 本机接手资产

全部在忽略的 `build/`，路径相对仓库根。原始证据不可贴聊天、提交或公开。

- `build/device-acceptance/local-settings.json`：私有签名设置（权限 600）；多设备时用 `selected-device-private.json`。
- `build/test-dependencies/harness/`、`build/worker-dependencies/`：固定官方依赖（`npm ci` 装出）。设置 `HARNESS_TEST_MODULES="$PWD/build/test-dependencies/harness/node_modules"` 后镜像构建测试不跳过。
- `build/guest/`：App 用的 guest 输入（含 0600 的 `token-private`）；`build/executor/`：QEMU framework 闭包。
- `build/app/`：`Web/`（网页根目录与 `web-receipt.json`）、`app/`、`ipad/`、`ipad-signed-rNN/`（签名构建与收据，r28 前为改名前的构建）、`run/`（macOS 数据根）。
- `build/app/device/`：私有设备脚本。`device-private.py`（install、launch、running、terminate、pull 等，依赖 `scripts/device.py`）、`measure-auto-private.py`（内置探针各阶段）、`stack-private.py`（停住取栈再 detach，不杀进程）及历次证据。脚本按可执行名 `DeepSeekHarness` 找进程；r28 及以前的构建叫 `HarnessCandidateApp`。
- Lima `ubuntu` 内可构建 guest 和跑 Linux 验收，只用隔离盘，不读 iPad 原盘。
- 旧 App 与原型的历史资产：`build/maintenance19/`、`build/prototypes/`、`build/issue39-*`、`build/acceptance-archive/`，可按需清理。

## 持续约束

- 免费开发团队的 App 名额有限。用户已授权按需卸载本项目占位 App（Harness、LinuxPrototype、DeviceAcceptance runner）及后续项目 IPA，不再重复询问；不扩展为其他 App 或无关数据。
- 设备标识、签名身份、凭据和原始日志只留 `build/`；Key 和 token 由用户在设备上输入，不从聊天取值、不替用户输入。不需要模型输出的测试用假 Key。
- API 及 Token 消耗无需另问；外部 Git push 只用用户授权的测试远端。
- 不发布 IPA 和 GitHub Release；以后要发布须重新审查许可证。
- 文档与代码改动走分支和 PR，不直接推 main；每个 PR 合并另获用户同意，用 merge commit。
