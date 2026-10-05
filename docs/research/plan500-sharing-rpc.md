# 方案500：共享工作区与真实 Linux 就绪/RPC 验证

2026-10-05，北京时间。用户在隔离 Worker 原型之后授权“开始下一步”。继续 [Issue32](https://github.com/lvivvde/deepseek-harness-ipad/issues/32)、[PR36](https://github.com/lvivvde/deepseek-harness-ipad/pull/36)，源代码与复跑入口见 [共享探针](../../runtime/prototypes/plan500-sharing/README.md)。

## 结论

**真实 Linux 准备/RPC 的有界合同可运行；直接 9P 挂载仍未通过统一工作区关口。** 两种模式各 23 项必需协议检查通过，但两者均未协调实测的跨域文件锁，guest watcher 未收到目标宿主修改。`mapped-xattr` 还使普通宿主 mode/symlink 与 guest 不等价。不能把 `completed=true` 当作共享语义全部兼容，也不能因本轮结果关闭 #32、启动 #17 或改选 ADR。

建议下一隔离原型验证：**统一工作区网关的写租约、版本冲突与明确变更通知/轮询**。原生与 Linux 的所有写者须经过可验证合同；仅由宿主领取租约而让任意 guest 命令继续直接写入，不能解决问题。Git 事务及 hook 执行保持 Linux 单路径；普通文件传输可继续研究 `none`，前提是补齐 UID/权限、安全边界及 Darwin/iPad 验证。这些是设计推断，尚未实现。

## 输入和隔离边界

本轮在既有 Lima Linux 内启动自己的 QEMU 10.2.1（TCG、aarch64、1 CPU、1GiB），没有改变 Lima 配置或其他 QEMU。Node `24.21.0`、Git `2.47.3` 来自只读 system.raw。guest 没启动 Harness；Python gate 经真实 TCP/RPC 驱动合成 Node agent，尚未连接 WKWebView/Swift。

| 输入 | 固定 SHA256 / 结果 |
| --- | --- |
| kernel `6.18.52-0-virt` / Image | `06196d2cf51e9a2bac421564bb64c63a8b7146c9a22755dd22a713e337023013` |
| 原 initramfs.gz | `4845f78c6c040d61ab1a68caedd2fba70678b4793a57d0c37bb26b8ba3d61246` |
| 只读 system.raw | `a1a33f394f393bb408cabec3b92a186de88e6125d83a8e9591b2506cb1b91d5f` |
| 锁定 modloop-virt | `e96d6f26f7bc7ce64946deb60dae5e3728d73ecd4f37bc59d974a2027cba825b` |
| 最终运行的 run.py | `81c4a8613baeda2a3a3e0e6c905a00112e0506f43f3b8b4350f950353f4516e6` |
| init.sh | `a8ecc27f191ad3da1bc872eb0b20cb36097cfd5a0712f9e44e574255d8a587c4` |
| agent.cjs | `0efaff910319c80996573939d1e22d2cfb7385338f78c752c6eac2b4e0256de1` |

原 initramfs 不足以挂载此探针所需的 9P/overlay；只在 scratch 中从锁定 modloop 补入 13 个模块，virtio-pci 为 builtin。系统盘 readonly，修改进入 RAM overlay，合成权威 workspace 位于独立 Linux 临时目录，经实际 `virtio-9p-pci`、9p2000.L、cache=none、writeout=immediate 挂载。没有读取 user.raw/user-seed.raw 或 iPad 原盘；没有设备、签名、安装、外部模型或项目远端 push。probe token 与原始串口只留私有目录。

QEMU 文档说明 mapped-xattr 将 guest ownership/mode/symlink 编码为扩展属性，mapped-file 元数据不适合普通 Unix 工具直接交互；none 使用 passthrough 思路但忽略 ownership 设置失败。故路径相同不保证原生访问语义相同，writeout=immediate 也不能补出跨域锁和通知。[QEMU fsdev](https://www.qemu.org/docs/master/system/qemu-manpage.html)

## 实测矩阵

以下均来自运行结果。每个模式必需检查 **23/23**；另外记录 8 项兼容性观察，不将失败隐藏在总计中。

| 检查 | mapped-xattr | none | 能证明的范围 |
| --- | --- | --- | --- |
| 双向 create/read/write/rename/delete、中文名 | 通过 | 通过 | 合成普通文件路径；不是所有特殊文件、大小写和逃逸行为 |
| 双向原子替换，已打开 fd 保留旧 inode | 通过 | 通过 | rename/os.replace 与 fd 的样本；不是崩溃耐久性 |
| guest chmod 755 → 普通宿主 mode | **0600，不等价** | 0755 | mapped-xattr 样本有 user.virtfs.uid/gid/mode 属性 |
| guest symlink → 普通宿主 symlink | **普通文本文件，内容为目标名** | 真实 symlink | mapped-xattr 不能交给现有普通宿主 FS 桥直接理解 |
| host symlink → guest 等价读取 | **失败** | 通过 | 合成相对链接；未验越界、环和并发替换 |
| host .git/index.lock 阻止真实 git add | 通过 | 通过 | 锁存在时 index 未创建，锁内容未变；释放后 add 成功 |
| guest .git/index.lock 阻止 host O_EXCL | 通过 | 通过 | 排他创建命名锁；不等同于 flock |
| host flock → guest flock 排他 | **未互斥** | **未互斥** | guest `flock -n` 仍成功 |
| host POSIX lockf → guest flock 排他 | **未互斥** | **未互斥** | 仅此混合锁样本；不声称全部 POSIX record lock 都失败 |
| guest flock → host flock 排他 | **未互斥** | **未互斥** | guest 持锁期间 host nonblocking flock 仍成功 |
| guest fs.watch 收到 host 目标文件写入 | **0 个目标事件** | **0 个目标事件** | 700ms 已就绪 watcher 窗口；不是所有 watcher/HMR 的穷举 |
| guest 显式轮询读到 host 修改 | 通过 | 通过 | 后续变更通知/轮询合同的起点 |
| host 写可执行 pre-commit，Git 执行并因非零拒绝提交 | 通过 | 通过 | marker 证明 hook 实际执行、HEAD 不存在；不是完整 G5 |

协议部分还证明：打开即一次真实准备，准备期间宿主编辑继续；待就绪请求自动执行一次，重复请求复用准备/执行；取消、超时、关闭项目的排队请求不在 ready 后重放；关闭在准备尚未完成时返回。ready 核对实际 9P 挂载、项目身份、协议、Node/Git 和认证 RPC，不仅看进程存在。

执行前再次检查 live RPC/身份；agent 对同 ID 相同 payload 返回缓存结果，对不同 payload 拒绝且无副作用。实际执行超时与取消杀掉本次命令的进程组，未发生其后续 touch；关闭自己的 QEMU 后下一请求失败，没有副作用、重放或 VM 重启。此去重只覆盖单 agent 生命周期，未实现跨崩溃幂等日志；取消不回滚已发生副作用。Linux ready 的两个主机样本约 2.4 秒，不用于 iPad 性能承诺。

## Darwin/iPad 尚存的独立条件

固定 QEMU v10.2.1 构建配置允许 Darwin VirtFS，但会检查 `pthread_fchdir_np`；9p-util.h 明确称其 private API，声明为 weak import 以应对未来消失。允许 Darwin 构建不证明当前签名 IPA 的 backend、iPad 沙箱或接口适用性。[固定构建条件](https://github.com/qemu/qemu/blob/v10.2.1/meson.build)、[固定 Darwin 声明](https://github.com/qemu/qemu/blob/v10.2.1/hw/9pfs/9p-util.h)

本机 SDK 27.0 实测：仅公共头文件的 macOS/iOS C 编译均因未声明函数失败；按上述源码显式声明后，两个 SDK 都链接成功，macOS 在自己的 scratch 中切换线程目录并写入 sentinel 成功。iOS 只链接 dylib，未执行。符号存在不构成公开 API 或分发适用性保证；也未编译整个 QEMU。本机没有可直接运行的 macOS QEMU，未为此安装新运行时；**Darwin 9P 与 iPad G3 未验**。

## 关口状态与下一步

G3 取得实际 Linux 双向文件和 Git 命名锁证据，同时普通 metadata、跨域锁、watcher 存在明确缺口，关口未通过。G4 获真实 boot/RPC、等待/取消/关闭/超时/断连的部分证据；iPad 生命周期、官方 Worker 接入、准备失败恢复、后台以及资源控制仍未验。G5 仅一个真实 pre-commit 非零用例；G0–G2 保留前轮 Worker 结果，G6/G7 未通过。

下一步应验证一个受控写者合同：以 project ID/epoch 和 operation ID 发放有界写租约，检查文件版本冲突；Linux 写任务/Git 事务期间原生编辑以待提交草稿保留，不能绕过租约覆盖文件；释放/失败/取消后发明确 change generation，双方重读并重新校验。任意 guest 长驻进程及 watcher 如何进入此合同仍是设计问题；协议断连时不能贸然释放仍可能存在的写者。随后补 Darwin/iPad 文件行为与模型/网络路径，再在 #32 形成用户架构决定。这些后续工作尚未登记通过。

与现有 ADR 的关系：原生候选仍会重新讨论 ADR0001 的统一 Linux 基线；当前只提供候选研究证据，ADR/CONTEXT 未改选，#32 OPEN、#17 继续依赖。正式 App 仍为 `7956e8c`、签名截止 2026-10-12 15:49:52 北京时间；用户取消的锁屏/8 小时测试未恢复。

本地收据：忽略的 `build/prototypes/plan500-sharing/linux-result-safe.json` 与 `darwin-api-safe.json`；原始 Linux 串口留本轮自己的 Lima scratch。公共交付保存复跑源码、固定输入和上述脱敏结论，不包含 workspace 内容、token 或设备资料。

图证据采用 Tier 2 Verify、项目 `Users-edwin-Projects-deepseek-harness-ipad`。原型路径的 coverage generation `2026-10-05T13:29:34Z` 为 metadata_match、无已记录缺口（不证明全集完备）；主研究文档 22 行有 parse_partial，已直接读回。忽略的 build、外部 Linux runtime/模块和 SDK 以精确源文件/收据回退，不冒称纳入图覆盖。
