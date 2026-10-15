# #18 小型项目的 Git 闭环验收

对应 [#18](https://github.com/lvivvde/deepseek-harness-ipad/issues/18)：小型项目的获取、安装依赖、模型开发、测试、提交与推送。真机证据只来自独立 bundle ID 的候选 App，macOS 只算回归证据。

## 范围（用户 2026-10-14 确认）

- **测试远端：** 用户新建的私有 GitHub 仓库。fine-grained token 只授权这个仓库，权限为 Contents 读写，有效期短。token 由用户在 iPad 上 git 的提示处输入，不经聊天。guest 会在内存里留存它，直到 VM 退出，见“发现”第 2 条。
- **guest 网络：** 去掉 `restrict=on`，guest 命令可以直接访问外网。端口转发仍只绑定 `127.0.0.1`。见 [调度与隔离边界](../design/linux-plugin-scheduling.md)“网络（#18）”。
- **固定项目：** [`runtime/acceptance/ts-git-loop`](../../runtime/acceptance/ts-git-loop/)，一个只依赖 `typescript` 的小库。测试用 `node --test`，类型检查用 `tsc --noEmit`，构建用 `tsc`。Vite 与 HMR 属于 #23。
- **长命令：** `git fetch`、`npm ci` 和 `git push` 在终端里运行，不受 shell 工具 60 s 上限的限制。需要 token 的 fetch 和 push 由用户运行，其余由探针在自己的终端里运行。

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
| 不支持 | `git clone URL .`、HMR | `unsupported` | 工作区根有保留文件，`clone` 到 `.` 被 git 拒绝，改用下面的 `init` 加 `fetch`；HMR 属于 #23 |

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

iPad 上外网可达，但 guest 的 git 走 HTTPS 很慢：`git ls-remote` 超过 shell 工具 60 s 的上限被终止，同一命令在 macOS 上用 22.9 s。Node 的 HTTPS 请求在 iPad 上用 15.1 s。所以获取、推送只在没有时限的终端里运行。

## 探针与用户操作

除去 token、模型指令和审阅，其余步骤由候选 App 的两个探针阶段完成，从 Mac 启动，不需要在 iPad 上点屏幕。探针只记录退出码、用时和提交号，不记录命令输出。

**`git-fetch`**（`HARNESS_CANDIDATE_MEASURE=git-fetch`，`..._PROJECT` 为项目名，`..._REMOTE` 为测试远端）在项目中打开自己的终端，逐行运行，每行打印带退出码的标记。失败的行按输出归为固定原因码（如 `NOT_EMPTY`、`PROMPTS_DISABLED`、`PROMPTED`、`DNS`、`AUTH`），记录里只有原因码。用户在 App 里打开终端会启动新的 Worker，它会关闭之前的终端；探针遇到 `TERMINAL_NOT_FOUND` 时重开一次终端，并记下次数。

1. 项目不存在时新建（启用插件）。再建同名项目应被拒绝（`PROJECT_NAME_TAKEN`），工作区不变。
2. `git clone URL .` 应以 128 失败：工作区根有保留文件。前后列表相同。
3. 建仓：`git init -b main`，把三个保留文件写进 `.git/info/exclude`，添加 `origin`，在仓库配置里写身份和 `core.hooksPath .githooks`（guest 的 `HOME` 是重启即清空的 tmpfs）。
4. 再加一个 `origin` 应以 3 失败，原地址不变。
5. 失败：`GIT_TERMINAL_PROMPT=0 git fetch origin` 应以 128 失败，不留下 `origin/main`。
6. 取消：`git fetch origin` 出现 `Username for` 提示后发 Ctrl-C，应以 130 结束，不留下 `origin/main`。
7. 记录 `state: waiting-fetch`，等用户在 App 的终端里运行 `git fetch origin` 并输入 token。探针从原生侧读引用，看到 `origin/main` 后继续。
8. `git checkout main`，然后依次运行 `npm ci`、`npm test`、`npm run typecheck`、`npm run build` 和 `.githooks/pre-commit`，记录退出码与用时。
9. 在 `/tmp` 的临时克隆里写入类型错误再提交，hook 应拒绝，`HEAD` 不变。

**`git-push`**（`HARNESS_CANDIDATE_MEASURE=git-push`）在模型修改并经用户审阅后启动：

1. 打开项目后立即在新终端里提交 `git add -A && git commit`，这时 Linux 仍在准备。打开终端要等插件就绪，hook 通过后提交才完成。用终端而不用 shell 工具，是因为 iPad 上带 hook 的提交超过 shell 工具 60 s 的上限（见“发现”第 1 条）。
2. 核对 `HEAD` 前进一步、父提交是原来的 `HEAD`、工作区干净。
3. 记录 `state: waiting-push`，等用户在 App 的终端里运行 `git push origin main` 并输入 token；看到 `origin/main` 等于新的 `HEAD` 后结束。
4. Mac 用 `gh api repos/<owner>/<repo>/commits/main` 核对远端提交号。

**`git-keep`**（`HARNESS_CANDIDATE_MEASURE=git-keep`）在重开、覆盖升级或迁移后的第一次启动中运行：

1. 打开项目，等 Linux 就绪。
2. 记录 `HEAD`、提交数、`git fsck` 退出码、工作区是否干净、`origin` 是否仍是测试远端。
3. 检查 guest 是否配置了 credential helper，以及 `~/.git-credentials` 等凭据文件是否存在。
4. 分块扫描 App 容器里的全部文件（含工作区、`.git`、日志、会话存档和探针记录），查找 GitHub token 前缀（`github_pat_`、`ghp_`、`gho_`）。只记录命中的相对路径，不记录内容。

会话和配置由 Mac 端驱动比对。它取下 Worker 存的 home 存档（`home-current.json`）作为基线，在重开或升级后按项目名打开 App，等 Worker 恢复并重新保存，再比对两份存档：基线里的每个会话文件仍在，原内容是新内容的前缀；`config.yaml`、`settings.json` 和 `AGENTS.md` 不变。

迁移用合成的旧 App 备份：一个有 3 个提交的 Git 项目（`origin` 为测试远端）、它的会话、配置，以及 `.dsh/.credentials.yaml` 和 `.netrc` 两个假凭据。假凭据只是随机标记，不是真 token。导入后用 `git-keep` 核对 Git 历史，再比对 home 存档里的会话，并在 home 存档和拉回的工作区里查找该标记。

用户在 iPad 上只做三件事：在 git 提示处输入用户名和 token（fetch 和 push 各一次）、给模型发修改指令、审阅 diff。token 不经聊天。

## 探针结果

| 平台 | 阶段 | 结果 | 要点 |
| --- | --- | --- | --- |
| macOS（2026-10-15，回归） | `git-fetch` | passed | 拒绝克隆 128、重名项目被拒、重复 `origin` 3、失败 128、取消 130，均未留下引用；`npm ci` 0，498 s；test 0，2.8 s；typecheck 0，5.0 s；build 0，4.8 s；pre-commit 0，5.9 s；坏提交被 hook 拒绝（1），`HEAD` 不变；QEMU 启动 1 次 |
| macOS（2026-10-15，回归） | `git-push` | 提交部分通过，未推送 | 提交在 PREPARING 时发出，Linux 2.9 s 就绪，提交 11.1 s 完成，退出码 0；`HEAD` 前进一步，父提交正确，工作区干净。macOS 上 fetch 由 Mac 的 git 代为完成，push 不做，只在 iPad 上真推。这次回归时提交还走 shell 工具，改成终端后没有在 macOS 上重跑，由单元测试覆盖 |
| iPad（2026-10-15，r19） | `git-fetch` 前半 | 通过 | 拒绝克隆 128（`NOT_EMPTY`），前后列表相同；重名项目 `PROJECT_NAME_TAKEN`，工作区不变；重复 `origin` 3，原地址不变；失败 128（`PROMPTS_DISABLED`），无引用；取消：出现提示后 Ctrl-C，130，无引用；Linux 9.7 s 就绪。用户 fetch 后，探针的终端被新 Worker 关闭，`checkout` 得 -1，这次运行作废，r20 加上重开终端后续跑 |
| iPad（2026-10-15，r20） | `git-fetch` 续跑 | passed | `checkout` 0；`npm ci` 0，138.7 s；test 0，22.9 s；typecheck 0，47.7 s；build 0，48.3 s，产物齐全；pre-commit 0，69.9 s；坏提交被 hook 拒绝（1），`HEAD` 不变；QEMU 启动 1 次 |
| iPad（2026-10-15，r21） | `git-push` | 未通过 | 提交还走 shell 工具，在 PREPARING 时发出，Linux 9.7 s 就绪。hook 运行中到 70.8 s 被 60 s 上限终止，退出码 -1；`HEAD` 不变，没有残留 `index.lock` |
| iPad（2026-10-15，r22） | `git-push` | passed | 提交改在终端，在 PREPARING 时发出，Linux 9.8 s 就绪，提交 103.1 s 完成，退出码 0；`HEAD` 前进一步，父提交正确，工作区干净；用户 push 后 457 s 内看到 `origin/main` 等于新 `HEAD`；QEMU 启动 1 次 |
| iPad（2026-10-15，r22→r23） | `git-keep`，覆盖升级 | Git、会话、配置保留 | 覆盖安装 r23 后首次启动：`HEAD` 与 push 后相同，2 个提交，`fsck` 0，工作区干净，`origin` 不变；没有凭据文件；扫描 1247 个文件、118 MB，无 token 命中。未判通过只因 guest 配置了 credential helper（发现第 2 条） |
| iPad（2026-10-15，r23） | `git-keep`，重开 | 同上 | 结果与升级后相同，扫描 1250 个文件，无 token 命中。随后按项目名打开 App，Worker 恢复后重新保存：基线 27 个会话文件全部保留且内容未变，Acc-ts 的 4 个会话都在，3 个配置文件不变 |
| iPad（2026-10-15，r23） | 迁移 | Git、会话、配置保留 | 导入合成备份：38 个文件、1 个会话，排除 2 个凭据文件。`HEAD` 与备份中相同，3 个提交，`fsck` 0，`origin` 不变；会话迁到 `/dsh/workspace/migrated-git`；home 存档和工作区都没有假凭据标记；扫描 1293 个文件，无 token 命中。工作区不干净：App 的保留文件 `.plan500-identity` 是未跟踪文件（发现第 3 条） |

模型修改（2026-10-15，r20）：用户在 App 里让 DeepSeek 新增 `truncateWords` 及其测试。模型运行 `npm test`，5/5 通过，退出码 0。diff 只涉及 `src/index.ts`（+15）和 `test/index.test.ts`（+16 −1），用户审阅后通过。

远端核对（2026-10-15）：`gh api repos/lvivvde/harness-acceptance-ts/commits/main` 返回 `f4386365da59f2660af472718fbc8feee60f9106`，父提交是种子提交 `afdb0935e0577a32fb3ad4c82e55461d16409bbe`，提交说明为 “Apply the reviewed model edit (#18)”，与探针记录的 `HEAD` 一致。

## 发现

1. **iPad 上带 hook 的提交超过 shell 工具 60 s 的上限。** pre-commit 运行类型检查和测试，单独运行约 70 s，提交合计 71–103 s。r21 用 shell 工具提交，hook 被终止，退出码 -1；git 没有留下 `index.lock`，`HEAD` 不变。所以提交、获取和推送都应在终端里运行。模型若用 shell 工具提交，会遇到同样的上限。
2. **guest 把输入的 token 留在内存里，直到 VM 退出。** 候选 App 的 guest 系统盘沿用旧运行时的 `/etc/gitconfig`（[`runtime/guest/gitconfig`](../../runtime/guest/gitconfig)），其中 `credential.helper = store`；guest 命令和终端的 `HOME` 是 tmpfs 上的 `/tmp`。按 git 的行为，认证成功后 token 会写进 `/tmp/.git-credentials`。它不落盘，App 重开后就消失：三次扫描都没有命中，重开后也没有凭据文件。但 VM 运行期间，之后的 guest 命令（含模型的 shell 命令和 hook）都能读到它。这与 [Git 写操作与 hook](../design/git-writes-and-hooks.md) 的要求不符：令牌只在单条网络命令里提供，hook 环境中没有令牌。这一条是按配置推断的：VM 运行期间没有直接查看该文件，因为那样需要用户再输入一次 token。
3. **迁移来的 Git 项目里，App 的保留文件显示为未跟踪。** 工作区根的 `.plan500-identity` 不在仓库的忽略规则里，`git status` 不干净，`git add -A` 会把它提交进去。Acc-ts 没有这个问题，是因为探针建仓时把保留文件写进了 `.git/info/exclude`。用户自己建仓、clone 或迁移来的项目都会遇到。
4. **新 Worker 会关闭之前打开的终端。** Worker 启动时会发 `terminals-reset`。用户在 App 里打开终端，可能启动新的 Worker，于是探针的终端被关闭，下一行得到 `TERMINAL_NOT_FOUND`。探针遇到时会重开一次终端。
5. **官方会话和 guest 看到的项目路径不同。** 官方会话的 cwd 是 `/dsh/workspace/<项目>`，guest 的 bash 在 `/workspace`。两者是同一个目录，这是设计如此；模型输出里两种路径都会出现。
6. **模型 Key 输入。** Key 只在内存里，App 重启后要重新输入。粘贴时常带空格或换行，网关会当作缺少 Key 而拒绝。r21 起输入时去掉首尾空白，并在输入框下显示“正在使用 …末 4 位，共 N 个字符”，方便用户核对。之前报“API 无效”的根因没有确认；加上提示后，模型调用成功。

## 逐条验收

| # | 验收内容 | 结果 | 证据 |
| --- | --- | --- | --- |
| 1 | Git 获取，新建或打开项目；取消、重名、失败不覆盖已有数据，也不误报成功 | 通过 | iPad r19 `git-fetch` 前半：拒绝克隆、重名、重复 `origin`、失败和取消都不改变已有数据，失败带原因码；用户在终端 fetch 成功 |
| 2 | 按固定清单安装依赖，声明 native、linux 和不支持的路径 | 通过 | 固定工具与依赖清单；iPad r20 `npm ci` 0（138.7 s） |
| 3 | 真实模型修改项目，用户审阅 diff；测试、类型检查和构建报告真实退出码 | 通过 | DeepSeek 修改，模型自测 5/5；用户审阅 diff；iPad r20 test、typecheck、build 均为 0 |
| 4 | git commit，向用户授权的测试远端真实推送，并核对远端提交 | 通过 | iPad r22 提交 0；用户在终端 push；远端 `main` 为 `f4386365`，父提交和说明一致 |
| 5 | pre-commit 等 Linux hook：插件准备时等待，检查通过后才完成 Git 操作 | 通过 | r22 提交在 PREPARING 时发出，等 Linux 就绪、hook 通过后才完成；坏提交被 hook 拒绝，`HEAD` 不变。另见发现第 1 条 |
| 6 | 项目、Git 历史、会话和配置在重开、覆盖升级和迁移后保留；凭据不进日志，token 不经聊天 | 通过，附发现 | 重开、r22→r23 覆盖升级、迁移后，`HEAD`、提交数、`fsck`、`origin`、会话和配置都保留；App 容器扫描无 token 命中；迁移排除凭据文件；token 只在 iPad 的 git 提示处输入。发现第 2、3 条另行处理 |
