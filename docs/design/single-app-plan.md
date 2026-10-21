# 合并成一个 App 的方案

> 草案，2026-10-21，待用户确认。目标：只留一个 App，也就是现在的 Harness Candidate；旧的正式 App 和研究原型退役。旧 App 里的数据不需要保留（用户 2026-10-21 确认）。

## 现状

| 部分 | 位置 | 去留 |
| --- | --- | --- |
| 候选 App 外壳 | `ios/HarnessApp/CandidateApp` | 保留，改成正式 App |
| 候选 App 用到的 Swift 模块 | `Sources/Candidate`、`Host`、`Workspace`、`NativeTools`、`LinuxPlugin`、`ModelGateway` | 保留 |
| 旧 App 导入 | `Sources/Candidate/BackupImport.swift`、`Sources/Migration` | 删除：旧数据不要了 |
| 旧正式 App | `Sources/Native`、`Sources/Core`、`HarnessApp.xcodeproj`、`Tests`、`UITests`、`scripts/` 里只给旧 App 用的脚本、`runtime/package-ipa.py`、`check-boot.py` | 删除 |
| 研究 App | `runtime/prototypes/plan500-ipad` 的 Swift 和构建脚本 | 删除 |
| 构建还在用的原型文件 | 原生 Git 的 4 个 JS、guest agent（`plan500-lease`）、initramfs 构建（`plan500-sharing`、`plan500-darwin`）、Worker 依赖锁（`plan500-worker`）、执行器整理脚本（`ios/LinuxPrototype/scripts/prepare-runtime.py`） | 挪到正式目录，其余原型删除 |
| 研究和验收文档 | `docs/research`、`docs/validation` 等 | 保留作历史，文首注明对应的是旧 App 或原型 |

删掉的东西都还在 Git 历史里，需要时能找回。

## 第 1 步：只留一个 App（不重建 Linux 镜像）

1. App 改名为 **DeepSeek Harness**（旧 App 的名字），去掉界面和代码注释里的“候选”。
2. `make` 命令改成 `make web`、`make app`、`make ipad`、`make test`，去掉旧 App 的目标。
3. 删除上表中标为“删除”的部分，把构建还在用的原型文件挪到 `runtime/` 下的正式位置。Linux 镜像的内容不变，所以已核对的哈希都还有效。
4. Swift 模块名（`HarnessCandidate` 等）和 `runtime/candidate` 目录改成不带“候选”的名字。纯改名，单独一个提交，方便审查。
5. README、开发说明和交接改成只有一条构建路径。
6. 重新打包装到 iPad 上冒烟：打开项目、跑一条 Linux 命令、Git 提交、模型回答一次。
7. 从 iPad 上卸载旧的正式 App 和研究 App（卸载前再问你一次）。

## 第 2 步：精简 Linux 系统盘（需要重建镜像，可以以后做）

现在的 `system.raw` 里有旧 App 用的 `/opt/harness`（约 537 MB 的官方 npm 树和旧 guest 脚本），新 App 根本不运行它。去掉以后：

- IPA 从约 1.1 GB 降到约 0.6 GB；
- 镜像的构建步骤可以合成一个脚本，不再经过旧 App 的构建器和三个原型目录。

代价是要在 Lima 虚拟机里重建系统盘和 initramfs，然后在 iPad 上把 Linux 相关的验收重跑一遍（Linux 项目、Git 闭环、预览）。

## 要你决定的

**bundle ID。** 我推荐保留 `org.lvivvde.harness.candidate`：

- iPad 上现在的 App 直接覆盖安装，项目和设置都还在，不用重新配置；
- bundle ID 用户看不到，界面上显示的是“DeepSeek Harness”；
- 别人从源码构建时，本来就得换成自己的 bundle ID（同一个 ID 只能属于一个开发者账号），所以构建脚本会让它在私有签名文件里可改。

如果改用旧 App 的 `org.lvivvde.harness.ipad`，就是装一个新 App：现在 Candidate 里的项目和设置不会带过去，需要重新输入 Key、重新克隆项目。

**做到哪一步。** 我推荐这次只做第 1 步，第 2 步以后再说。
