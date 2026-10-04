<!-- harness-ipad managed: this file is replaced on upgrade; delete this line to keep your own edits. -->
# iPad 运行环境说明

你运行在 iPad 应用内置的 aarch64 Linux 虚拟机里（单核、无 JIT，命令比桌面慢）。

- 系统盘只读：没有 apt、Python、gcc/make。项目依赖可用 npm 或 pnpm；原生模块必须有 linux-arm64 glibc 预编译包。
- Git 项目统一放在 `/root/projects/<项目名>`。克隆或新建后，请用户在左侧“工作区 → 添加工作区”登记该目录。
- 首次提交前，若 `git config --global user.name` 或 `user.email` 为空，先问用户要姓名和邮箱，再用 `git config --global` 设置；不要编造身份。
- 推送或克隆私有仓库需要 HTTPS token。不要让用户把 token 发到对话里，也不要把 token 写进远端 URL、仓库文件或命令输出。请用户在右侧终端运行一次 `git ls-remote <仓库 https 地址>`，在提示时输入用户名和 token；之后由 git 凭据存储自动使用。
- 插件用官方设置中的插件管理安装到持久化的 web profile；终端等效命令为 `dsh plugin --profile web add <包名或绝对路径>`。不要安装到只读的 `/opt/harness`。纯 JS 与已有 linux-arm64 glibc 预编译包可用；Python、原生编译和系统包安装需明确说明首版不支持。
- `/root/projects/ipad-hello-plugin` 是可编辑的最小工具插件，安装该绝对路径后，让模型调用 `ipad_hello`。已安装插件与 profile 在升级后保留。
- HTTP/WS 开发服务器可只监听 loopback；检测到新端口后，用户点“在侧栏预览”。触摸悬浮工具按钮也可打开端口预览。关闭预览继续运行项目。
- 用户数据不进入 iCloud 或电脑备份。备份或迁移单个项目：点屏幕边缘的悬浮工具按钮，选“项目管理…/导入项目…”（也可从顶部菜单栏的“项目”进入）（外接键盘 ⌘⇧E / ⌘⇧I）；只导出 `/root/projects` 下的项目，不含 node_modules 与 .cache。
