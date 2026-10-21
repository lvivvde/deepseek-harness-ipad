# Linux 运行时与 App 构建输入

App 的 Linux 插件在 QEMU 里跑一台 arm64 guest。guest 由三样东西组成，都在构建机上准备好，设备首次启动不下载：

| 文件 | 来源 | 说明 |
| --- | --- | --- |
| `Image` | `build-runtime.py` | Alpine 6.18.52-0-virt 内核 |
| `system.raw` | `build-runtime.py` | 只读 ext4 系统盘：Debian 13 arm64 固定快照的工具集、Node 24.21.0 |
| `initramfs.gz` | `prepare-guest.py` | 小 initramfs，加上 9P、overlay、virtio 模块和 guest agent |

App 构建（`make app`、`make ipad`）只接受 `build/guest` 里这三个文件，并按 `inputs.json` 逐个核对哈希；guest agent 的源码哈希也必须和 `guest-agent/` 一致。

> `system.raw` 目前还带着已退役旧 App 用的 `/opt/harness`（官方 npm 树和旧 guest 脚本，约 537 MB）。App 不运行它，去掉要重建镜像，见 [单一 App 方案第 2 步](../docs/design/single-app-plan.md)。`guest/` 和 `tests/` 是构建这一部分的脚本和测试。

## 目录

- `inputs.lock.json`：Debian 快照 `20261003T000000Z` 的 135 个软件包、内核、modloop 和 Node 输入，含 URL、版本和 SHA256。收据只核对输入一致，不代替上游签名验证。
- `harness-package.json`、`harness-package-lock.json`：官方 dsh `0.2.0-rc.2` 的 npm 依赖锁。`make web` 用它装出的 `build/test-dependencies/harness` 取官方网页和终端客户端；系统盘里的 `/opt/harness` 也来自它。
- `worker-dependencies/`：官方 Web Worker 运行时和网页打包器的依赖锁，装到 `build/worker-dependencies`。
- `native-git/`：原生只读 Git（JS），App 和 `make web` 都用它。
- `guest-agent/`：guest 的 `/init` 和 agent（`agent.cjs`），打进 initramfs。
- `app/`：网页根目录生成（`prepare.mjs`）、App 工程生成和构建（`build.py`）及其测试。
- `acceptance/`：验收用的固定项目。

## 准备依赖

在构建机上执行，用 `npm ci`，不要用 `npm update`：

```sh
mkdir -p build/test-dependencies/harness build/worker-dependencies
cp runtime/harness-package.json build/test-dependencies/harness/package.json
cp runtime/harness-package-lock.json build/test-dependencies/harness/package-lock.json
npm ci --ignore-scripts --prefix build/test-dependencies/harness
cp runtime/worker-dependencies/package.json runtime/worker-dependencies/package-lock.json build/worker-dependencies/
npm ci --ignore-scripts --prefix build/worker-dependencies
```

## 构建 guest

需要 Linux（macOS 没有 `unsquashfs`，默认文件系统也不区分大小写），以及 Python 3.11+、ar、cpio、mke2fs、unsquashfs。输出目录必须不存在；失败的目录保留，重试用新目录。

1. 下载固定输入：`python3 runtime/prepare-inputs.py /path/to/inputs`。
2. 准备 `/opt/harness` 用的依赖：按上文把 `harness-package*.json` 放进一个目录，再运行 `npm ci --ignore-scripts --os=linux --cpu=arm64 --libc=glibc --prefix /path/to/harness`。
3. 构建内核和系统盘：

   ```sh
   python3 runtime/build-runtime.py \
     --inputs /path/to/inputs --lock runtime/inputs.lock.json \
     --harness /path/to/harness --output /path/to/system \
     --mke2fs /path/to/mke2fs --unsquashfs /path/to/unsquashfs \
     --system-mib 1024 --user-mib 8 --memory-mib 2048
   ```

4. 生成 App 用的 guest 输入（modloop 是 `inputs.lock.json` 里的 `modloop-virt`）：

   ```sh
   python3 runtime/prepare-guest.py --runtime /path/to/system \
     --modloop /path/to/inputs/modloop-virt --out /path/to/guest
   ```

   输出 `Image`、`system.raw`、`initramfs.gz`、`inputs.json` 和权限 0600 的 `token-private`。token 每次构建随机生成，打进 initramfs，App 用它和 guest agent 通信；不要打印或提交它。把整个目录拷回 macOS 的 `build/guest`。

## QEMU 执行器

iPad 版嵌入 UTM SE 的 `ios-tci-arm64` QEMU（无 JIT）。从固定的 UTM 构建产物里取出 sysroot 后运行：

```sh
python3 runtime/prepare-executor.py /path/to/sysroot-iOS-TCI-arm64
```

它把 QEMU 及其依赖框架整理到 `build/executor`，来源和哈希记在 `build/executor/frameworks.json`。`make ipad` 只嵌入这里核对过的文件。

## 测试

`make test` 里的 `runtime/tests` 检查镜像构建的固定输入和输出保留；部分集成测试需要 `HARNESS_TEST_MODULES=/path/to/harness/node_modules`，缺少依赖时跳过。
