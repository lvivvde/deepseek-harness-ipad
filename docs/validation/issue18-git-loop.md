# #18 小型项目的 Git 闭环验收

对应 [#18](https://github.com/lvivvde/deepseek-harness-ipad/issues/18)：小型项目的获取、安装依赖、模型开发、测试、提交与推送。真机证据只来自独立 bundle ID 的候选 App，macOS 只算回归证据。

## 范围（用户 2026-10-14 确认）

- **测试远端：** 用户新建的私有 GitHub 仓库。fine-grained token 只授权这个仓库，权限为 Contents 读写，有效期短。token 由用户在 iPad 上 git 的提示处输入，不保存，也不经聊天。
- **guest 网络：** 去掉 `restrict=on`，guest 命令可以直接访问外网。端口转发仍只绑定 `127.0.0.1`。见 [调度与隔离边界](../design/linux-plugin-scheduling.md)“网络（#18）”。
- **固定项目：** [`runtime/acceptance/ts-git-loop`](../../runtime/acceptance/ts-git-loop/)，一个只依赖 `typescript` 的小库。测试用 `node --test`，类型检查用 `tsc --noEmit`，构建用 `tsc`。Vite 与 HMR 属于 #23。
- **长命令：** `git fetch`、`npm ci` 和 `git push` 由用户在候选 App 的终端里手动运行。终端没有 shell 工具的 60 s 上限。

## 固定工具与依赖清单

| 环节 | 工具 | 路径 | 说明 |
| --- | --- | --- | --- |
| 获取、提交、推送 | guest 的 `git` | `linux` | 能力声明 `git.write` 为 `SHELL_ONLY`，只在终端或 shell 中运行 |
| 查看状态、diff、历史 | 原生只读 Git | `native` | 不写 `.git/index` |
| 安装依赖 | guest 的 `npm ci`（Node 24.21.0） | `linux` | 按 `package-lock.json` 安装 `typescript@7.0.2` 及其 `linux-arm64` 原生包 |
| 测试 | `node --test` | `linux` | Node 24 直接运行 `.ts` 测试 |
| 类型检查、构建 | `tsc`（TypeScript 7 原生版） | `linux` | `tsc --noEmit`、`tsc -p tsconfig.build.json` |
| pre-commit | `.githooks/pre-commit` | `linux` | 由 guest 的 git 调用，运行类型检查和测试 |
| 模型修改代码 | 官方编辑工具 | `native` | 用户在 diff 中审阅 |
| 不支持 | `git clone URL .`、HMR、凭据保存 | `unsupported` | 工作区根有保留文件，`clone` 到 `.` 被 git 拒绝，改用下面的 `init` 加 `fetch`；HMR 属于 #23；guest 不配置 credential helper |

## 网络探针

候选 App 新增探针阶段 `network`（`HARNESS_CANDIDATE_MEASURE=network`），在一个启用插件的项目中运行三条 guest 命令：

- `dns`：Node 解析 `github.com`。
- `git`：`git ls-remote https://github.com/octocat/Hello-World.git HEAD`。
- `npm`：Node `fetch` 访问 `registry.npmjs.org/-/ping`。

三条都以 0 退出且 QEMU 只启动一次，才算通过。另外只记录、不判定 guest 能否连上 host 回环（`10.0.2.2`）上的监听。

| 平台 | 结果 | dns | git | npm | host 回环 | 启动次数 |
| --- | --- | --- | --- | --- | --- | --- |
| macOS（2026-10-14） | passed | 0，312 ms | 0，22.9 s | 0，8.8 s | 能连上 | 1 |
| iPad（2026-10-14，r17） | 未通过 | 0，2.5 s | 被 60 s 上限终止 | 0，15.1 s | 能连上 | 1 |

iPad 上外网可达，但 guest 的 git 走 HTTPS 很慢：`git ls-remote` 超过 shell 工具 60 s 的上限被终止，同一命令在 macOS 上用 22.9 s。Node 的 HTTPS 请求在 iPad 上用 15.1 s。所以获取、推送只走没有时限的终端，耗时以终端里 `time` 的结果为准。

## 终端步骤

在候选 App 中新建一个空项目并启用 Linux 插件，等插件就绪后打开终端（起点是 `/workspace`）。先核对“重名、失败、取消不覆盖”：

```sh
ls -A
git clone https://github.com/<owner>/<repo>.git . ; echo "clone=$?"
ls -A
```

工作区根有保留文件，git 应拒绝克隆到非空目录，前后两次 `ls -A` 相同。之后在第一次 `git fetch` 的密码提示处按 Ctrl-C（取消），再运行一次并输入错误的密码（失败），每次之后 `git branch -a` 都应为空。

```sh
cd /workspace
git init -b main
printf '.dsh-identity\n.plan500-identity\n.dsh-mount-check\n' >> .git/info/exclude
git remote add origin https://github.com/<owner>/<repo>.git
git config user.name "Harness Acceptance"
git config user.email "acceptance@invalid"
time git fetch origin       # 在提示处输入用户名和 token，token 不回显
git checkout main
git config core.hooksPath .githooks
time npm ci
npm test; echo "test=$?"
npm run typecheck; echo "typecheck=$?"
npm run build; echo "build=$?"
```

- 工作区根有三个保留文件，所以写进 `.git/info/exclude`，不进入提交。
- 身份和 `core.hooksPath` 写在仓库配置里，因为 guest 的 `HOME` 是重启即清空的 tmpfs。
- 模型修改并经用户审阅后，在终端运行 `git add -A && git commit -m "..."`（pre-commit 先跑类型检查和测试），再 `git push origin main`，同样在提示处输入 token。

## 逐条验收

| # | 验收内容 | 结果 | 证据 |
| --- | --- | --- | --- |
| 1 | Git 获取，新建或打开项目；取消、重名、失败不覆盖已有数据，也不误报成功 | 待测 | |
| 2 | 按固定清单安装依赖，声明 native、linux 和不支持的路径 | 待测 | |
| 3 | 真实模型修改项目，用户审阅 diff；测试、类型检查和构建报告真实退出码 | 待测 | |
| 4 | git commit，向用户授权的测试远端真实推送，并核对远端提交 | 待测 | |
| 5 | pre-commit 等 Linux hook：插件准备时等待，检查通过后才完成 Git 操作 | 待测 | |
| 6 | 项目、Git 历史、会话和配置在重开、覆盖升级和迁移后保留；凭据不进日志，token 不经聊天 | 待测 | |
