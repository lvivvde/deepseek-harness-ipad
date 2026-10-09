# 原生只读 Git 选型

依据：[ADR 0003](../adr/0003-native-worker-with-project-linux.md)，[#39](https://github.com/lvivvde/deepseek-harness-ipad/issues/39) 关口 3，组件清单 [#14](https://github.com/lvivvde/deepseek-harness-ipad/issues/14)。2026-10-08 创建。

## 要回答的问题

官方 `dsh-workspace-changes`（审阅和差异）不调用 Git 库，而是起 `git` 子进程，解析标准输出。用到的只有八种调用：`rev-parse`、`add`、`write-tree`、`ls-tree`、`cat-file`、`diff-tree`、`ls-files`、`check-ignore`。它只写两处：`GIT_INDEX_FILE` 指定的临时索引，和 `GIT_OBJECT_DIRECTORY` 指定的临时对象目录。iPad 上没有 `git` 可执行文件，所以要有一个原生实现来回答这八种调用，要求如下：

1. 退出码、stdout 和 stderr 与 `git` 逐字节一致，因为官方代码直接解析这些输出。
2. 不写 `.git` 下的任何文件。
3. Linux 没有启动时也能用。

## 比较

| | libgit2 | isomorphic-git | 自写（采用） |
| --- | --- | --- | --- |
| 形态 | C 库，交叉编译成 iOS 静态库 | 纯 JS，可接自定义 fs | 纯 JS，约 3,700 行，跑在 JavaScriptCore 里 |
| 许可 | GPLv2 加链接例外 | MIT | 本仓库 |
| CLI 输出 | 只有 API，要另写八种调用的输出格式层 | 只有 API，同样要写输出层 | 直接实现这八种调用的输出 |
| 忽略、属性、CRLF | 有，但细节与 `git` 不完全一致 | 用自己的忽略实现，属性和 CRLF 支持有限 | 按 `git` 行为实现，并与 `/usr/bin/git` 做差分测试 |
| 差异与改名检测 | 有，启发式与 `git` 有差别 | 没有文本差异，也没有改名检测 | 移植 xdiff 和 `diffcore-rename` 的相似度规则 |
| 不写 `.git` | 要逐个 API 审计索引和对象的写入路径 | `add` 默认写 `.git/index`，要靠 fs 适配拦截 | 构造上只读：唯一的写入口是临时索引和临时对象目录，而且这两处一旦落在 Git 目录或未排除的工作区内就拒绝 |
| 包体与构建 | 要原生构建链和 OpenSSL/zlib 选项，增加签名产物 | 一个 npm 包加依赖 | 4 个脚本文件，随 Worker 资源打包 |
| 超出子集时 | 库能做的更多，误用面更大 | 同左 | 不认识的参数一律退出码 128 并拒绝，不猜 |

## 结论

采用自写。libgit2 和 isomorphic-git 都没有省掉最难的部分，也就是与 `git` 逐字节一致的八种调用输出。两者还都带来了需要逐个审计的 `.git` 写入路径。自写实现只覆盖官方真正用到的子集，只读是由构造保证的，等价性靠与系统 `git` 的差分测试证明，而不是依赖文档。

这个选择的代价是：官方插件以后如果新增 Git 调用，原生实现不会自动跟上。新调用会以退出码 128 拒绝，而不是给出错误结果，所以升级官方包时要重跑差分测试。

Git 写操作和 hook 不在本选型内，仍然走项目 Linux，见 [git-writes-and-hooks.md](git-writes-and-hooks.md)（#39 关口 5）。Linux 提交后，原生侧用本子集的 `rev-parse -q --verify HEAD` 和 `diff-tree` 复核，结果必须与 Linux 一致，`.git` 不能有变动。

## 代码与验证

- JS 模块：`runtime/prototypes/plan500-ipad/web/native-git-objects.js`、`native-git-match.js`、`native-git-xdiff.js`、`native-git.js`。
- Swift 宿主：`ios/HarnessApp/Sources/NativeTools/GitHost.swift`（`NativeGitHost`）。它在私有的 JSContext 里运行上面四个模块，文件访问经 `NativePathSpace` 落到原生工作区。
- 差分测试：`runtime/prototypes/plan500-ipad/test_native_git.mjs`。每种调用都在同一仓库上分别跑本实现和 `/usr/bin/git`，要求以下各项一致：
  - 退出码、stdout、stderr
  - 解析后的索引条目、对象集合
  - `.git` 未被改动

  覆盖的情况：中文路径、symlink、二进制与大文件、带固定种子的忽略规则模糊测试、属性与 CRLF、精确与非精确改名、嵌套仓库、未合并条目、pack、linked worktree、锁冲突、不可读文件、超出子集的请求。
- 关口 3 集成：macOS 宿主跑完整官方工具序列后，把变更摘要与系统 `git diff --numstat` 逐文件比对（`run-worker.py` 的 `git_diff_agrees`）。iPad 研究 App 用真实模型跑同一序列。
