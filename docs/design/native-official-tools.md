# 官方工具的原生能力声明（#39 关口 3）

依据：[ADR 0003](../adr/0003-native-worker-with-project-linux.md)，[#39](https://github.com/lvivvde/deepseek-harness-ipad/issues/39) 关口 3。2026-10-08 创建，收紧范围经用户确认。

首个兼容范围内的官方工具全部标为 `native`：它们经原生工作区和网关运行，Linux 没有启动、或因缺少私有符号不可用时也能用。所有写入走关口 1 的带版本写入和写租约（[workspace-durability.md](workspace-durability.md)），Worker VFS 和 Node 直写工作区一律拒绝，子会话的写入经同一个网关。

| 官方工具 | 路径 | 原生实现 |
| --- | --- | --- |
| `read`、`write`、`edit`（`dsh-tool-fs`） | `native` | `NativeFileService` 经 `NativePathSpace` |
| `read_image`（`dsh-tool-fs`） | `native`，有收紧 | `NativeImageCodec`（ImageIO） |
| `str_replace_editor` | `native` | 同一文件服务 |
| `glob`、`grep`（`dsh-tool-fs-search`） | `native`，有声明差异 | `NativeSearch` 模拟打包的 rg 15，`RustRegex` 翻译正则方言 |
| `dsh-workspace-changes`、`dsh-api-workspace-files`、`dsh-file-reference` | `native` | 原生只读 Git（[native-read-only-git.md](native-read-only-git.md)） |

## 收紧范围（用户已确认）

1. **read_image**：PNG、JPEG 和不需要重新编码的图片与官方一致。官方附件存储把需要重新编码的透明图片编为 WebP，这类图片返回 `IMAGE_ENCODER_UNAVAILABLE`，因为 iOS 没有 WebP 编码器。
2. **写租约期间的草稿**：真机验证用的是模拟的 Linux 租约持有者。“Linux 写入后原生读到新内容”由研究 App 基础检查（Linux 编辑在重启后仍为权威内容）覆盖，没有经过官方 `read` 工具。
3. **审阅与 Linux 内 `git diff` 一致**：只在 macOS 上与系统 `git diff --numstat` 逐文件对比，iPad 上没有在 guest 里跑 `git`。
4. **同步 `node:fs`**：Worker 里对挂载目录的同步读取看到空目录，`watch` 不起作用。官方工具都走异步网关，不受影响；以后新增依赖同步读取或 watch 的官方代码，要先接网关。

## 声明差异（与 ripgrep 15 对比，90 个用例零差异之外）

- 符号链接指向工作区外时拒绝，不跟随。
- 正则的 `U`、`R` 标志和 `~~` 字符类差集拒绝，不改变贪婪性；`[:^name:]` 取反的 POSIX 类按 ICU 处理。
- 文件按路径顺序逐个搜索（rg 的顺序本来不确定）；任何位置含 NUL 的文件跳过；不读全局 git excludes。

## 证据

- **macOS**：宿主关口 3 阶段 34 项全部通过，包括与系统 git 的 numstat 对比；搜索等价 90 例零差异；`swift test --filter NativeToolsTests`。
- **iPad（真机）**：Linux 可用分支 33/33 通过，真实模型经官方会话发起 `read`、`edit`、`write`，其余工具经官方会话 API 调用；绕过注入 14 种全部拒绝；租约期间编辑被拒；中文路径和 symlink；`.git` 前后不变。缺少私有符号分支的结果见 #39 关口 2 评论。
