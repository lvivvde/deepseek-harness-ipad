# Linux 执行可行性原型（可丢弃）

问题：普通签名的自有 iPad 应用，能否通过固定 UTM SE/QEMU 无 JIT 解释器运行 aarch64 Linux，再让官方 Harness 与 WKWebView 通过本机端口桥交互？对应[原型验证票](https://github.com/lvivvde/deepseek-harness-ipad/issues/11)。

这是技术验证资产。外壳可编译不等于 Linux 已运行；Linux 启动也不等于 Node、Harness、PTY、sandbox 或生产性能已通过。界面不会生成假的 guest 输出。

## 构建外壳

从仓库根目录执行：

```sh
xcodebuild -project ios/LinuxPrototype/LinuxPrototype.xcodeproj \
  -scheme LinuxPrototype -sdk iphoneos \
  -derivedDataPath ios/LinuxPrototype/build CODE_SIGNING_ALLOWED=NO build
```

普通签名安装：用 Xcode 打开此工程，target → Signing & Capabilities → Add Account，自己登录 Apple ID 并选择 Team，再选择连接的 iPad 运行。个人签名资料和设备日志不提交到公开仓库；本地 `Signing.local.xcconfig` 已忽略，可写入 `DEVELOPMENT_TEAM = 你的团队标识`。发布工程前，应将 Xcode 写入 project.pbxproj 的个人 Team 设置移到此本地配置。原型未申请 JIT、hypervisor、额外内存或共享 app group 权限。

## 固定执行器

官方构建 run `36090554968` / artifact `10845528675` 的 `Sysroot-ios-tci-arm64` 对应 UTM `7eadb056ae0f91d979059544d0ddcd2d5a40be92`，QEMU `v10.0.12-utm`。解包后在本目录执行：

```sh
python3 scripts/prepare-runtime.py /实际路径/sysroot-iOS-TCI-arm64
```

脚本核对 iOS 平台、三个共享库入口，记录每个二进制摘要并提取静态链接依赖闭包。它不下载组件，也不证明这些二进制的來源或许可合规；下载时需核对官方 artifact 元数据和摘要。产物位于忽略的 `.runtime/`，Xcode 构建阶段复制并用本次身份签名。设备框架不用于模拟器；模拟器只能检查外壳。

## 测试 guest

导入目录包括 `boot.json` 和其中指定的镜像文件。最小 kernel 模式示例：

```json
{"mode":"kernel","kernel":"Image","initrd":"initramfs.cpio.gz","append":"console=ttyAMA0 rdinit=/init","memoryMiB":512}
```

initramfs 必须明确提供可执行 `/init` 和适配 virt 机器的驱动；任意发行版 installer initrd 不保证直接出现 shell。应用将文件复制到自己的测试目录，启动单 CPU / 512 MiB 配置；这是引导实验参数，不是 Harness 内存预算。可选 `disk` 指定同目录 qcow2；UEFI 模式使用同产物 `edk2-aarch64-code.fd` 和 qcow2 根磁盘。

真实 guest 救援串口：设备 `127.0.0.1:18081`；QMP：`127.0.0.1:18082`。网页：设备 `127.0.0.1:18080` → guest 网卡端口 `3000`；guest 服务须监听其可达网卡。不能把 guest loopback 当作设备 loopback。串口视图是简易文本收发器，不能替代 Harness PTY 验收。

首次原型仅前台、单 VM、每个应用进程启动一次。需要重新启动时关闭应用再打开；没有实现后台运行、暂停/恢复、完整终端、项目工作区或镜像更新。QEMU 的致命退出仍可能终止宿主，错误日志由 Xcode 捕获。

所有 native frameworks、guest 镜像、签名资料和构建日志只留本地。将来分发含这些组件的 IPA 前，应按实际组件准备对应源码、补丁、构建及所需重链接资料；本分支不发布二进制。
