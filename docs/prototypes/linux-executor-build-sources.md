# 原型构建入口：固定 UTM SE/QEMU 的无 JIT ARM64 headless 路径

2026-10-03（用户时区）。只读研究，无 IPA/镜像下载、无构建、无设备运行。父代理负责下载、原生外壳与设备工作。

## 立即可用的预构建来源

**已找到精确源码 SHA 的官方 CI sysroot artifact。** 只按 head_sha 查询 actions runs 曾返回空；直接 artifacts 列表/单个 artifact API 给出正面结果，因此不能把前者误作“无产物”。

| 字段 | 固定值 |
|---|---|
| UTM source | `7eadb056ae0f91d979059544d0ddcd2d5a40be92` |
| Run | `36090554968` |
| Artifact name / id | `Sysroot-ios-tci-arm64` / `10845528675` |
| ZIP size | `335757842` bytes |
| ZIP digest | `sha256:fb8c4bfbe25f9168f112631f0148abc94639ab417ab6be1a53de38859a16e22a` |
| Status | `expired=false`，expires `2026-12-24T03:29:23Z` |
| URL | `https://api.github.com/repos/utmapp/UTM/actions/artifacts/10845528675/zip` |

来源：[单个官方 artifact API](https://api.github.com/repos/utmapp/UTM/actions/artifacts/10845528675)、[固定 workflow 的 sysroot upload](https://github.com/utmapp/UTM/blob/7eadb056ae0f91d979059544d0ddcd2d5a40be92/.github/workflows/build.yml#L51-L107)。上传物内部是 `sysroot.tgz`，预期目录 `sysroot-iOS-TCI-arm64`；下载后先 `tar -tzf` 核对，而非假定所有文件已在。

```sh
mkdir -p /private/tmp/wayfinder-ipad/utm-prebuilt
# API zip 摘要对应下面这个下载文件；需 gh 登录且token具有适用访问权
 gh api repos/utmapp/UTM/actions/artifacts/10845528675/zip > /private/tmp/wayfinder-ipad/utm-prebuilt/sysroot-artifact.zip
shasum -a 256 /private/tmp/wayfinder-ipad/utm-prebuilt/sysroot-artifact.zip
unzip -q /private/tmp/wayfinder-ipad/utm-prebuilt/sysroot-artifact.zip -d /private/tmp/wayfinder-ipad/utm-prebuilt
# gh run download 则会自动解ZIP，不能用上表ZIP摘要核对内层tgz
# gh run download 36090554968 --repo utmapp/UTM --name Sysroot-ios-tci-arm64 --dir /private/tmp/wayfinder-ipad/utm-prebuilt
tar -tzf /private/tmp/wayfinder-ipad/utm-prebuilt/sysroot.tgz
tar -xzf /private/tmp/wayfinder-ipad/utm-prebuilt/sysroot.tgz -C /private/tmp/wayfinder-ipad/utm-prebuilt
```

**官方 v5.0.6 SE IPA 是可追溯备选，也更小。** 下载URL `https://github.com/utmapp/UTM/releases/download/v5.0.6/UTM-SE.ipa`；asset id `585272736`；size `237265886`；GitHub API digest `sha256:b676908830bd77414994d2b0afea22c1c449c1f8e7b30c939ce4cc61f56a7bcc`。标签固定到 `968fef31ee3299224feaf4de1e40e1e5f46369c1`，发布于 `2026-09-24T05:35:31Z`。[官方 release API](https://api.github.com/repos/utmapp/UTM/releases/tags/v5.0.6)、[tag API](https://api.github.com/repos/utmapp/UTM/git/ref/tags/v5.0.6)

只读比较了这两个提交的五个文件：`patches/sources`、`Services/UTMQemuSystem.m`、`Services/UTMProcess.m`、`README.md` 全相同；`scripts/build_dependencies.sh` 唯一差异为较新 7ead 在 LLVM15 构建增加 `-DLLVM_ENABLE_TERMINFO=Off`。本范围内 QEMU manifest、TCTI/ARM64 target 配置、共享库导出桥等价；不是全仓等价证明。源码版本应记录实际用了哪个产物，不把 release tag写作7ead。[v5.0.6 source manifest](https://github.com/utmapp/UTM/blob/968fef31ee3299224feaf4de1e40e1e5f46369c1/patches/sources)、[v5.0.6 构建脚本](https://github.com/utmapp/UTM/blob/968fef31ee3299224feaf4de1e40e1e5f46369c1/scripts/build_dependencies.sh)

```sh
curl --fail --location 'https://github.com/utmapp/UTM/releases/download/v5.0.6/UTM-SE.ipa' -o /private/tmp/wayfinder-ipad/utm-prebuilt/UTM-SE-v5.0.6.ipa
shasum -a 256 /private/tmp/wayfinder-ipad/utm-prebuilt/UTM-SE-v5.0.6.ipa
mkdir -p /private/tmp/wayfinder-ipad/utm-prebuilt/release
unzip -q /private/tmp/wayfinder-ipad/utm-prebuilt/UTM-SE-v5.0.6.ipa -d /private/tmp/wayfinder-ipad/utm-prebuilt/release
```

这是父代理可执行的命令，本研究未下载、未检查ZIP内部。API摘要核对成功和解包只证明获取了指定产物，不证明自有app可加载或真机运行。

## 首次原型应复用什么

目标是 app 内加载 `qemu-aarch64-softmmu.framework/qemu-aarch64-softmmu`；宿主是 arm64 iOS，guest 为 aarch64，并无JIT/hypervisor。实际Frameworks目录通过 `find` 定位，先记录 Mach-O architecture、platform/minOS、导出与依赖：

```sh
find /private/tmp/wayfinder-ipad/utm-prebuilt -type d -name 'qemu-aarch64-softmmu.framework'
# 设置为上一步实际目录；下面路径是sysroot候选
UTM_QEMU_FW=/private/tmp/wayfinder-ipad/utm-prebuilt/sysroot-iOS-TCI-arm64/Frameworks/qemu-aarch64-softmmu.framework
file "$UTM_QEMU_FW/qemu-aarch64-softmmu"
xcrun vtool -show-build "$UTM_QEMU_FW/qemu-aarch64-softmmu"
xcrun nm -gU "$UTM_QEMU_FW/qemu-aarch64-softmmu" | rg ' _qemu_(init|main_loop|cleanup)$'
otool -L "$UTM_QEMU_FW/qemu-aarch64-softmmu"
```

UTM源码解析 `qemu_init`（`int(int,const char*[],const char*[])`）、`qemu_main_loop`（`void(void)`）、`qemu_cleanup`（`void(void)`），顺序调用，并通过 `UTMProcess` 在 pthread 内运行。iOS默认没有macOS的XPC helper。框架需作为 app bundle 内已签名的 native 库，不在 guest 安装后下载 native iOS 代码。[共享库桥](https://github.com/utmapp/UTM/blob/7eadb056ae0f91d979059544d0ddcd2d5a40be92/Services/UTMQemuSystem.m#L29-L43)、[导出解析](https://github.com/utmapp/UTM/blob/7eadb056ae0f91d979059544d0ddcd2d5a40be92/Services/UTMQemuSystem.m#L256-L287)、[pthread 与 dlopen](https://github.com/utmapp/UTM/blob/7eadb056ae0f91d979059544d0ddcd2d5a40be92/Services/UTMProcess.m#L157-L245)

**不能只复制 QEMU 一个framework。** 必须从其 `otool -L` 递归抽取非系统依赖，连同运行时动态加载的可选组件核查。首次原型可保守保留所有同产物 frameworks，等加载成功后才裁剪；以下只给依赖闭包审计方法，静态闭包不是所有运行时dlopen依赖证明：

```sh
# 将第一个参数指向实际同产物Frameworks目录；第二个输出清单
python3 - "$UTM_QEMU_FW/.." /private/tmp/wayfinder-ipad/utm-prebuilt/framework-closure.txt <<'PY'
import pathlib,re,subprocess,sys
root=pathlib.Path(sys.argv[1]).resolve()
pending=['qemu-aarch64-softmmu']; seen=set(); report=[]
while pending:
    name=pending.pop()
    if name in seen:continue
    seen.add(name)
    binary=root/f'{name}.framework'/name
    if not binary.exists():raise SystemExit(f'Missing framework binary: {binary}')
    report.append(str(binary.parent))
    lines=subprocess.check_output(['otool','-L',str(binary)],text=True).splitlines()[1:]
    for line in lines:
        dep=line.strip().split(' (',1)[0]
        if dep.startswith(('/usr/lib/','/System/')):continue
        match=re.search(r'([^/]+)\.framework/(?:Versions/[^/]+/)?([^/]+)$',dep)
        if match:
            if match.group(1)!=match.group(2):raise SystemExit(f'Unexpected framework import: {dep}')
            pending.append(match.group(1))
        else:raise SystemExit(f'Unresolved non-system import: {dep}')
pathlib.Path(sys.argv[2]).write_text('\n'.join(sorted(report))+'\n')
print('\n'.join(sorted(report)))
PY
```

Xcode app `LD_RUNPATH_SEARCH_PATHS` 需含 `@executable_path/Frameworks`；复制并 Embed & Sign 依赖，不能沿用上游签名当作自己的有效开发身份。符号无需直接静态链接，可用 runtime dlopen/dlsym，实际所有ABI仍需nm与运行确认。QEMU启动错误可能调用退出路径；UTM桥处理线程退出与资源生命周期，不宜把三函数调用当完整错误隔离SDK。首次应单VM、单启动路径。[UTM框架封装与install-name](https://github.com/utmapp/UTM/blob/7eadb056ae0f91d979059544d0ddcd2d5a40be92/scripts/fixup.sh)

## headless direct boot 的具体候选参数

`virt` ARM board、`cortex-a72`、direct `-kernel/-initrd/-append` 可避免guest UEFI，serial socket替代SPICE显示与terminal。这不意味着QEMU预编译库不再链接SPICE。`-display none` 关闭显示，`-monitor none` 关闭默认HMP；不传UTM的 `-S`（否则停在启动前，需QMP继续）。QEMU官方说明 `virt` 用aarch64必须显式CPU；支持PL011 UART，Linux需合适kernel drivers。[QEMU virt文档](https://www.qemu.org/docs/master/system/arm/virt.html)、[direct Linux boot 参数](https://www.qemu.org/docs/master/system/invocation.html#linux-multiboot-boot-specific)、[UTM linuxKernel/initrd支持](https://github.com/utmapp/UTM/blob/7eadb056ae0f91d979059544d0ddcd2d5a40be92/Configuration/UTMQemuConfiguration%2BArguments.swift#L751-L778)

下面是送给库 `qemu_init` 的argv候选（不是在iPadOS shell执行一个Mach-O命令）；所有路径由app对导入到container的实际URL生成：

```text
qemu-system-aarch64
-machine virt,gic-version=3
-cpu cortex-a72
-accel tcg,thread=single
-smp 1
-m 512
-nodefaults
-display none
-monitor none
-kernel <app-container>/guest/Image
-initrd <app-container>/guest/initramfs.cpio.gz
-append "console=ttyAMA0 rdinit=/init"
-chardev socket,id=console0,host=127.0.0.1,port=23001,server=on,wait=off
-serial chardev:console0
-qmp tcp:127.0.0.1:23002,server=on,wait=off
-device virtio-net-pci,netdev=net0
-netdev user,id=net0,hostfwd=tcp:127.0.0.1:23003-:8080
```

需自有带 `/init` 的initramfs或明确发行版要求；随意下载发行版的initrd不保证出现可用shell，它可能要求modloop/ISO/root设备、专用boot参数。首个无盘shell验收后，再加虚拟磁盘 `-drive if=none,id=rootdisk,format=qcow2,file=<container>/guest/root.qcow2 -device virtio-blk-pci,drive=rootdisk`；kernel配置、rootfs/init方式由guest制作者明确。这里没有提供不存在的guest镜像或声称无需rootfs可运行Harness。HTTP服务应listen guest可达网卡，如0.0.0.0:8080；host端显式绑定loopback。guest loopback不是iOSloopback，WKWebView到23003仍需实际验证。

可省的是guest UEFI文件、SPICE服务/客户端控制路径、guest图形桌面；**现成QEMU dylib的链接依赖不能仅凭未开启SPICE参数删掉**。若裁剪自编，必须检查configure选项和link结果；此轮优先现成exact sysroot或v5.0.6包，不自行开巨大构建。

## 自编退路：原样完整构建可跑入口

固定脚本不提供“只aarch64/headless/无SPICE/GPU”的用户开关：download_all、build_qemu_dependencies、build_spice_client、build_vulkan_drivers、build_d3d_drivers均被调用。TCI arm64 target list含aarch64/x86/PPC/RISC-V/m68k；自行缩到aarch64必须修改脚本再验证。现有 flags 为 `--enable-tcg-threaded-interpreter --enable-shared-lib --disable-cocoa --disable-sdl --disable-coreaudio --disable-slirp-smbd --enable-ucontext --with-coroutine=libucontext`；ios代码还含private HVF build flag，但SE运行必须使用解释器，不能启用special entitlement才算成功。[构建设置](https://github.com/utmapp/UTM/blob/7eadb056ae0f91d979059544d0ddcd2d5a40be92/scripts/build_dependencies.sh#L1023-L1061)

下载包括manifest的QEMU10.0.12-utm源、每源对应patch、patches/data、SPICE/GLib/slirp/gstreamer/libucontext；还有WebKit ANGLE、virgl、Mesa、MoltenVK、Vulkan、LLVM15、DXMT等。脚本会将 dylib 包成 framework并重写imports；这是完整依赖构建，不是廉价QEMU单文件编译。[download逻辑](https://github.com/utmapp/UTM/blob/7eadb056ae0f91d979059544d0ddcd2d5a40be92/scripts/build_dependencies.sh#L110-L227)、[无条件构建序列](https://github.com/utmapp/UTM/blob/7eadb056ae0f91d979059544d0ddcd2d5a40be92/scripts/build_dependencies.sh#L1189-L1201)

如下可作为完整build命令计划，需完整固定checkout和patches；研究没有执行安装/构建。不要照抄CI的brew卸载或全局删除pkgconfig：

```sh
brew install bison pkg-config gettext glib-utils libgpg-error nasm make meson ninja cmake llvm spirv-llvm-translator libxcb libxrandr
python3 -m venv /private/tmp/wayfinder-ipad/utm-build-python
. /private/tmp/wayfinder-ipad/utm-build-python/bin/activate
python3 -m pip install six pyparsing pyyaml setuptools distlib mako
export PATH="$(brew --prefix bison)/bin:$(brew --prefix gettext)/bin:$PATH"
# 在固定完整UTM源码checkout根目录执行；TCI官方CI强制单job，避免内存暴涨
NCPU=1 ./scripts/build_dependencies.sh -p ios-tci -a arm64
# 若要上游完整SE archive，而不是父代理自己的外壳
./scripts/build_utm.sh -s iOS-SE -k iphoneos -a arm64 -o /private/tmp/wayfinder-ipad/UTM-SE
```

`check_env`还检查host Xcode工具、bison>=2.4及Python模块；脚本现已专门针对27SDK设pipe2/dup3不可用的cross探测，降低旧部署目标weak-import风险，但不证明Xcode27全量通过。Full app另有submodules/SPM和host build plugins，应按项目锁文件。[官方CI要求与单job](https://github.com/utmapp/UTM/blob/7eadb056ae0f91d979059544d0ddcd2d5a40be92/.github/workflows/build.yml#L83-L107)、[27SDK处理](https://github.com/utmapp/UTM/blob/7eadb056ae0f91d979059544d0ddcd2d5a40be92/scripts/build_dependencies.sh#L280-L302)

## 溯源/分发实际需要记录

此次只将官方预构建用于原型分析，不把它包装成已经符合再分发条件的产品。若后续发自有IPA，要记录：artifact/release的API元数据+SHA256、源commit、QEMU源压缩包版本和digest、UTM patches与data、framework依赖闭包/link map、各组件准确LICENSE/COPYING、保留对象或重新链接安排、实际源码提供位置、guest镜像清单。`patches/sources`是下载版本起点但不是完整许可证证明，UTM旧License.plist不能替代清单。若用SE IPA，framework对应968fef31，不随意拿7ead源码包冒充exact对应源码；记录两者所读相同文件仅减少技术不确定性。

## 本轮证据范围

初始list_projects确认已有故意有限 `wayfinder-utm-se-exact` 图；沿用父提供Verify Tier2与上一研究实际读取的Process/System/Arguments/build脚本。新增对象是非代码构建/manifest/workflow与固定tag的准确同名来源，用direct source/diff fallback；没有将5文件等价推广为整仓。所有shell命令仅形成可执行方案；未下载二进制，未核验nm/otool实际输出，未构建或真机通过。父代理必须完成下载/哈希/解包后验证这些假设。
