# Minimal aarch64 guest recipe — research only

Research date: 2026-10-03 (Asia/Shanghai). Scope: prototype ticket “shell/fork/pipe/guest-local HTTP” stage; not Node, Harness, a distribution installation, or a production guest. No guest was constructed or booted by this researcher. Only this note was written. Official source artifacts below 20 MB each were read in memory for hashes, archive entries/config and ELF metadata; none were saved by the researcher. Commands below are for the parent to execute if useful.

## Recommended first input set

Use fixed **Alpine 3.23.6 aarch64 netboot-3.23.6, Linux 6.18.52-0-virt**. Keep its original initramfs and matched modules. Append a second, small initramfs overlay with a custom `/init`, Debian static BusyBox, DHCP hook, and HTTP test file. This avoids an Alpine installer/rootfs download and avoids attempting privileged device-node extraction on macOS. It is also simpler than rebuilding a kernel or downloading the full 406 MB netboot tarball.

Do not use mutable `/netboot/`. Exact directory: [Alpine fixed netboot release](https://dl-cdn.alpinelinux.org/alpine/v3.23/releases/aarch64/netboot-3.23.6/).

| Input | Exact bytes | SHA256 |
|---|---:|---|
| `vmlinuz-virt` | 10387968 | `06196d2cf51e9a2bac421564bb64c63a8b7146c9a22755dd22a713e337023013` |
| `initramfs-virt` | 9169574 | `b0be51c9de43d582da897df3583114192933872a7e219218752b18082d75b6cb` |
| `config-6.18.52-0-virt` | 161386 | `18bb325df712efc698503ab3442f4c41017d9799a728464b7ec8a5b86ea9cf10` |
| `busybox-static_1.37.0-6+b9_arm64.deb` | 847552 | `c833be48abfa16bc19c4966ec93e289ff1ce5d2f1476cad3a57bd105378cd15c` |

First three digests are researcher-calculated receipts over bytes fetched from the exact HTTPS URLs, **not claimed to be upstream-published individual checksums**. Debian's package SHA256 is independently published on its [official download page](https://packages.debian.org/trixie/arm64/busybox-static/download), and matched the fetched bytes. For release-authenticated provenance beyond this prototype receipt, Alpine provides signed release tarballs/checksums; fetching those is more expensive and outside this minimum recipe. HTTPS+matching receipt pins consistency, not a substitute for a signed trust chain.

Debian binary URL: `https://deb.debian.org/debian/pool/main/b/busybox/busybox-static_1.37.0-6+b9_arm64.deb`.

## What was actually inspected

- Original Alpine initramfs begins gzip magic, decompresses to `newc` cpio. Original `/init` identifies mkinitfs 3.13.0-r0 and performs Alpine boot setup; it is **not** a guaranteed direct shell entry. This recipe explicitly replaces it.
- Archive contains `bin -> usr/bin`, `sbin -> usr/sbin`, `lib -> usr/lib`. Preserve these via the base archive. Original BusyBox is `usr/bin/busybox`; matched kernel modules are under `usr/lib/modules/6.18.52-0-virt`, with text `modules.dep`.
- Actual module entries: `virtio_mmio.ko`, `virtio_net.ko`, `virtio_blk.ko`, `af_packet.ko`, `net_failover.ko`, `failover.ko`. `modules.dep` gives `virtio_net -> net_failover -> failover`. All of these inspected entries are **uncompressed `.ko`**, so the Debian static modprobe does not need to understand Alpine compressed-module formats for this experiment.
- Fixed kernel config: `CONFIG_BLK_DEV_INITRD=y`, `RD_GZIP=y`, `DEVTMPFS=y`, `DEVTMPFS_MOUNT=y`, `TMPFS=y`, `INET=y`, `UNIX=y`, `VIRTIO=y`, `VIRTIO_PCI=y`; `VIRTIO_MMIO=m`, `VIRTIO_NET=m`, `VIRTIO_BLK=m`, `PACKET=m`; `SERIAL_AMBA_PL011=y` and `SERIAL_AMBA_PL011_CONSOLE=y`. Explicitly modprobe `af_packet` before udhcpc, since raw packet DHCP can require it.
- `EXT4_FS=m`, but no ext4 module was found in the inspected base initramfs. **Do not claim an ext4 persistent disk works from this input set.** `fat.ko`/`vfat.ko` are present; a later disposable vfat volume experiment or an exact same-version additional-module set is possible, but excluded from these minimum commands.
- Debian `.deb` has `data.tar.xz`; main executable is `./usr/bin/busybox`, 1975064 bytes. ELF program headers have no `PT_INTERP`. Its [official packaging tarball](https://deb.debian.org/debian/pool/main/b/busybox/busybox_1.37.0-6.debian.tar.xz), `debian/config/pkg/static`, explicitly sets `CONFIG_STATIC=y`, `STATIC_LIBGCC=y`, `MODPROBE=y`, `HTTPD=y`, `UDHCPC=y`, `ASH=y`, `ASH_JOB_CONTROL=y`, `SETSID=y`, `CTTYHACK=y`; default DHCP hook `/etc/udhcpc/default.script`. No reliance on copying a glibc/musl loader is required for this BusyBox executable.

These are artifact observations, not execution results. External artifact/source repositories are absent from the supplied graph project inventory; exact official archive/config fallback was used, without claims of graph access to them.

## Executable acquisition and preparation commands (macOS)

Run in a new throwaway directory. Tools: curl, shasum, ar, macOS/libarchive tar with xz support, gzip, cpio, Python 3. No host execution of Linux BusyBox is attempted.

```sh
set -eu
guest_work=$(mktemp -d /private/tmp/ipad-miniguest.XXXXXX)
export guest_work
cd "$guest_work"
base=https://dl-cdn.alpinelinux.org/alpine/v3.23/releases/aarch64/netboot-3.23.6
curl --fail --location --output vmlinuz-virt "$base/vmlinuz-virt"
curl --fail --location --output initramfs-virt "$base/initramfs-virt"
curl --fail --location --output config-6.18.52-0-virt "$base/config-6.18.52-0-virt"
curl --fail --location --output busybox-static.deb 'https://deb.debian.org/debian/pool/main/b/busybox/busybox-static_1.37.0-6+b9_arm64.deb'
cat > SHA256SUMS <<'SUMS'
06196d2cf51e9a2bac421564bb64c63a8b7146c9a22755dd22a713e337023013  vmlinuz-virt
b0be51c9de43d582da897df3583114192933872a7e219218752b18082d75b6cb  initramfs-virt
18bb325df712efc698503ab3442f4c41017d9799a728464b7ec8a5b86ea9cf10  config-6.18.52-0-virt
c833be48abfa16bc19c4966ec93e289ff1ce5d2f1476cad3a57bd105378cd15c  busybox-static.deb
SUMS
shasum -a 256 -c SHA256SUMS
mkdir -p busybox overlay/usr/bin overlay/etc/udhcpc overlay/www
ar -p busybox-static.deb data.tar.xz | tar -xJf - -C busybox
cp busybox/usr/bin/busybox overlay/usr/bin/busybox
chmod 755 overlay/usr/bin/busybox
file overlay/usr/bin/busybox
```

The following deliberately does not fetch a rootfs, use `apk`, mount modloop, perform switch_root, or run an installer.

```sh
cat > overlay/init <<'INIT'
#!/bin/busybox sh
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
bb=/bin/busybox
$bb mkdir -p /dev /proc /sys /tmp /run /www
$bb mount -t devtmpfs devtmpfs /dev
exec </dev/console >/dev/console 2>&1
$bb mount -t proc proc /proc
$bb mount -t sysfs sysfs /sys
$bb mount -t tmpfs -o mode=1777,size=64m tmpfs /tmp
$bb mkdir -p /dev/pts
$bb mount -t devpts -o mode=620 devpts /dev/pts
$bb hostname ipad-prototype
$bb ifconfig lo 127.0.0.1 up
for m in virtio_mmio virtio_net af_packet; do
    $bb modprobe "$m" || echo "MODULE_FAIL:$m"
done
# Optional block-device enumeration only; does not format or mount any drive.
$bb modprobe virtio_blk || echo MODULE_FAIL:virtio_blk
$bb ifconfig -a
# A failure must not suppress shell or guest-loopback HTTP evidence.
$bb udhcpc -q -n -t 5 -T 1 -i eth0 -s /etc/udhcpc/default.script || echo DHCP_FAIL
$bb httpd -f -p 0.0.0.0:3000 -h /www &
echo MINIGUEST_INIT_READY
# Keep PID1 alive; run interactive shell as a separate guest process/session.
# This is a prototype loop, not a general-purpose init/service supervisor.
while :; do
    $bb setsid /bin/busybox cttyhack /bin/busybox sh -i
    echo SHELL_RETURNED
    $bb sleep 1
done
INIT
cat > overlay/etc/udhcpc/default.script <<'DHCP'
#!/bin/busybox sh
bb=/bin/busybox
case "$1" in
    deconfig)
        $bb ifconfig "$interface" 0.0.0.0
        ;;
    bound|renew)
        $bb ifconfig "$interface" "$ip" netmask "${subnet:-255.255.255.0}" up
        $bb route del default dev "$interface" 2>/dev/null || :
        for gw in $router; do $bb route add default gw "$gw" dev "$interface"; done
        : >/etc/resolv.conf
        for ns in $dns; do echo "nameserver $ns" >>/etc/resolv.conf; done
        ;;
esac
exit 0
DHCP
chmod 755 overlay/init overlay/etc/udhcpc/default.script
printf '%s\n' 'guest-local-http-ok' > overlay/www/index.html
```

### Rootless archive overlay

Linux's [documented initramfs buffer format](https://docs.kernel.org/driver-api/early-userspace/buffer-format.html) permits a series of compressed/uncompressed cpio archives. Appending a gzip-newc overlay preserves the original device nodes, paths and matched modules, while replacing `/init` and BusyBox. Do **not** treat the concatenated result as one ordinary filesystem image.

For maximum portability, the small Python packer below writes only regular files/directories in the overlay, with root uid/gid and executable modes. It does not create host device nodes or require sudo. This is a recipe, not code executed by the researcher.

```sh
python3 - <<'PY'
import gzip, os, stat
from pathlib import Path
root=Path(os.environ['guest_work'])/'overlay'
entries=[root]+sorted(root.rglob('*'),key=lambda p:(len(p.relative_to(root).parts),p.as_posix()))
out=bytearray()
def emit(name,mode,data=b'',ino=1):
    encoded=name.encode()+b'\0'
    fields=[ino,mode,0,0,1,0,len(data),0,0,0,0,len(encoded),0]
    out.extend(b'070701'+b''.join(f'{v:08x}'.encode() for v in fields))
    out.extend(encoded)
    out.extend(b'\0'*(-len(out)%4))
    out.extend(data)
    out.extend(b'\0'*(-len(out)%4))
for i,p in enumerate(entries,1):
    name='.' if p==root else './'+p.relative_to(root).as_posix()
    mode=p.stat().st_mode
    if p.is_dir(): emit(name,stat.S_IFDIR|0o755,ino=i)
    elif p.is_file(): emit(name,stat.S_IFREG|stat.S_IMODE(mode),p.read_bytes(),i)
    else: raise RuntimeError(f'unsupported overlay path: {p}')
emit('TRAILER!!!',0,ino=len(entries)+1)
base=Path(os.environ['guest_work'])/'initramfs-virt'
result=base.read_bytes()+gzip.compress(bytes(out),mtime=0)
(Path(os.environ['guest_work'])/'initramfs-prototype.gz').write_bytes(result)
PY
shasum -a 256 vmlinuz-virt initramfs-prototype.gz
```

Record the generated initramfs hash; no precomputed expected hash is asserted for it. Packaging/root ownership is deterministic within this recipe's file modes/content, but it has not been executed/validated here.

## QEMU direct-boot arguments

Use the prototype's bundled aarch64 system-emulator entry point. Reference CLI shape (adapt filenames to app Documents; never invoke host-side remote execution):

```sh
qemu-system-aarch64 \
  -machine virt -cpu cortex-a72 -accel tcg -smp 1 -m 512M \
  -kernel "$guest_work/vmlinuz-virt" \
  -initrd "$guest_work/initramfs-prototype.gz" \
  -append 'console=ttyAMA0,115200 rdinit=/init loglevel=6 panic=0' \
  -display none -monitor none \
  -serial tcp:127.0.0.1:18081,server=on,wait=off \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:18080-:3000 \
  -device virtio-net-device,netdev=n0
```

This supplies a Linux kernel and external initramfs directly; no UEFI/DTB download is needed for QEMU virt direct boot, because [QEMU virt](https://www.qemu.org/docs/master/system/arm/virt.html) generates its DTB and passes it using the Linux boot protocol. Use the aarch64 `cortex-a72`; the default ARM virt CPU can be 32-bit. `-accel tcg` here selects the emulator's compiled TCG backend; the prototype must ensure its bundled backend is the non-JIT interpreter build. This note cannot validate a particular QEMU binary/build feature set.

[Linux kernel parameters](https://docs.kernel.org/admin-guide/kernel-parameters.html) specify `rdinit=<full_path>` for early-userspace initramfs startup; it differs from later rootfs `init=`. Do not add `root=/dev/vda` without an actual prepared root filesystem. The prototype can remove serial TCP in favor of its already implemented equivalent socket bridge; do not run two servers on port 18081. Network requires QEMU slirp/user-net compiled in; failure there is emulator integration evidence, not proof that this guest passed.

## Acceptance commands and limits

After observing **kernel logs**, the expected `MINIGUEST_INIT_READY`, and an actual shell prompt, execute in the guest:

```sh
/bin/busybox uname -a
/bin/busybox cat /proc/version
/bin/busybox sh -c '/bin/busybox sleep 1 & p=$!; echo CHILD:$p; wait "$p"; echo CHILD_EXIT:$?'
/bin/busybox sh -c '/bin/busybox printf "pipe-ok\n" | /bin/busybox tr a-z A-Z'
/bin/busybox wget -qO- http://127.0.0.1:3000/
/bin/busybox cat /proc/net/dev
/bin/busybox cat /proc/mounts
```

Expected: aarch64 Linux 6.18.52-0-virt; a real child pid and zero completion; `PIPE-OK`; `guest-local-http-ok`. Then request `http://127.0.0.1:18080/` from the **iPad-host app** to check host→guest forwarding. The guest loopback HTTP success and host-forwarding success are separate results. DHCP failure should be diagnosed via module logs, `/proc/net/dev`, interface name and QEMU network features, not silently patched into a host-native HTTP response.

Shell/background process proves an initial guest fork/exec path, not the full POSIX/toolchain contract. PID1 loop is intentionally minimal and will need a real init/supervisor, resource handling, app lifecycle recovery and disk layout later. This recipe has no package manager/rootfs and does not provide glibc Node, native addons, Harness or persistent workspace. Alpine's host-distribution provenance is not a promise that official glibc Node binaries will run; those require a separately designed glibc rootfs (Debian/Ubuntu guest or suitable compatible root) and exact version verification.

## References

- Alpine versioned netboot files/config: https://dl-cdn.alpinelinux.org/alpine/v3.23/releases/aarch64/netboot-3.23.6/
- Debian fixed arm64 BusyBox download metadata: https://packages.debian.org/trixie/arm64/busybox-static/download
- Debian packaging source/config: https://deb.debian.org/debian/pool/main/b/busybox/busybox_1.37.0-6.debian.tar.xz (`debian/config/pkg/static`)
- BusyBox usage reference (version-independent flags must still be checked against the pinned binary): https://busybox.net/downloads/BusyBox.html
- Linux initramfs and `/init`: https://docs.kernel.org/filesystems/ramfs-rootfs-initramfs.html
- Linux concatenated initramfs buffer format: https://docs.kernel.org/driver-api/early-userspace/buffer-format.html
- Linux `rdinit=`: https://docs.kernel.org/admin-guide/kernel-parameters.html
- QEMU virt device tree / CPU / PL011: https://www.qemu.org/docs/master/system/arm/virt.html
