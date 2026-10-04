<!-- harness-ipad managed: this file is replaced on upgrade; delete this line to keep your own edits. -->
# iPad 运行环境说明

你运行在 iPad 应用内置的 aarch64 Linux 虚拟机里（单核、无 JIT，命令比桌面慢）。

- 系统盘只读：没有 apt、Python、gcc/make。依赖只用 npm；原生模块必须有 linux-arm64 glibc 预编译包。
- Git 项目统一放在 `/root/projects/<项目名>`。克隆或新建后，请用户在左侧“工作区 → 添加工作区”登记该目录。
- 首次提交前，若 `git config --global user.name` 或 `user.email` 为空，先问用户要姓名和邮箱，再用 `git config --global` 设置；不要编造身份。
- 推送或克隆私有仓库需要 HTTPS token。不要让用户把 token 发到对话里，也不要把 token 写进远端 URL、仓库文件或命令输出。请用户在右侧终端运行一次 `git ls-remote <仓库 https 地址>`，在提示时输入用户名和 token；之后由 git 凭据存储自动使用。
- 用户数据不进入 iCloud 或电脑备份；需要备份时提醒用户导出项目。
