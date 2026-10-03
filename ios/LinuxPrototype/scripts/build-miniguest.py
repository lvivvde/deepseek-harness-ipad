#!/usr/bin/env python3
"""Build a disposable RAM-only Linux shell/HTTP probe, never a Harness rootfs.

Usage: python3 scripts/build-miniguest.py DOWNLOAD_DIRECTORY OUTPUT_DIRECTORY
Fetch exact sources separately; this script checks receipts and never downloads.
"""
import gzip
import hashlib
import json
from pathlib import Path
import shutil
import stat
import subprocess
import sys

source, output = map(Path, sys.argv[1:3])
receipts = {
    "vmlinuz-virt": "06196d2cf51e9a2bac421564bb64c63a8b7146c9a22755dd22a713e337023013",
    "initramfs-virt": "b0be51c9de43d582da897df3583114192933872a7e219218752b18082d75b6cb",
    "busybox-static.deb": "c833be48abfa16bc19c4966ec93e289ff1ce5d2f1476cad3a57bd105378cd15c",
}
for name, expected in receipts.items():
    if hashlib.sha256((source / name).read_bytes()).hexdigest() != expected:
        raise SystemExit(f"Receipt mismatch: {name}")
package = subprocess.Popen(["ar", "-p", str(source / "busybox-static.deb"), "data.tar.xz"], stdout=subprocess.PIPE)
busybox = subprocess.check_output(["tar", "-xJOf", "-", "./usr/bin/busybox"], stdin=package.stdout)
package.stdout.close()
if package.wait() != 0:
    raise SystemExit("Failed to extract pinned BusyBox")
if busybox[:4] != b"\x7fELF" or int.from_bytes(busybox[18:20], "little") != 183:
    raise SystemExit("Expected Linux aarch64 ELF")

init = b'''#!/bin/busybox sh
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
for m in virtio_mmio virtio_net af_packet virtio_blk; do
    $bb modprobe "$m" || echo "MODULE_FAIL:$m"
done
$bb ifconfig -a
$bb udhcpc -q -n -t 5 -T 1 -i eth0 -s /etc/udhcpc/default.script || echo DHCP_FAIL
$bb uname -a > /www/kernel.txt
$bb httpd -f -p 0.0.0.0:3000 -h /www &
echo MINIGUEST_INIT_READY
while :; do
    $bb setsid /bin/busybox cttyhack /bin/busybox sh -i
    echo SHELL_RETURNED
    $bb sleep 1
done
'''
dhcp = b'''#!/bin/busybox sh
bb=/bin/busybox
case "$1" in
deconfig) $bb ifconfig "$interface" 0.0.0.0 ;;
bound|renew)
    $bb ifconfig "$interface" "$ip" netmask "${subnet:-255.255.255.0}" up
    $bb route del default dev "$interface" 2>/dev/null || :
    for gw in $router; do $bb route add default gw "$gw" dev "$interface"; done
    : >/etc/resolv.conf
    for ns in $dns; do echo "nameserver $ns" >>/etc/resolv.conf; done
    ;;
esac
exit 0
'''
files = {
    "init": (0o755, init),
    "usr/bin/busybox": (0o755, busybox),
    "etc/udhcpc/default.script": (0o755, dhcp),
    "www/index.html": (0o644, b"guest-local-http-ok\n"),
}
archive = bytearray()
def emit(name, mode, data=b"", inode=1):
    encoded = name.encode() + b"\0"
    fields = [inode, mode, 0, 0, 1, 0, len(data), 0, 0, 0, 0, len(encoded), 0]
    archive.extend(b"070701" + b"".join(f"{v:08x}".encode() for v in fields))
    archive.extend(encoded)
    archive.extend(b"\0" * (-len(archive) % 4))
    archive.extend(data)
    archive.extend(b"\0" * (-len(archive) % 4))

directories = {".", "usr", "usr/bin", "etc", "etc/udhcpc", "www"}
inode = 1
for name in sorted(directories, key=lambda n: (n.count("/"), n)):
    emit(name, stat.S_IFDIR | 0o755, inode=inode)
    inode += 1
for name, (mode, data) in sorted(files.items()):
    emit(name, stat.S_IFREG | mode, data, inode)
    inode += 1
emit("TRAILER!!!", 0, inode=inode)
output.mkdir(parents=True, exist_ok=True)
shutil.copyfile(source / "vmlinuz-virt", output / "Image")
initramfs = (source / "initramfs-virt").read_bytes() + gzip.compress(bytes(archive), mtime=0)
(output / "initramfs.cpio.gz").write_bytes(initramfs)
(output / "boot.json").write_text(json.dumps({
    "mode": "kernel", "kernel": "Image", "initrd": "initramfs.cpio.gz",
    "append": "console=ttyAMA0,115200 rdinit=/init loglevel=6 panic=0", "memoryMiB": 512,
}, indent=2) + "\n")
(output / "receipts.json").write_text(json.dumps({
    "inputs": receipts,
    "initramfsSHA256": hashlib.sha256(initramfs).hexdigest(),
    "scope": "RAM-only Linux shell and local HTTP probe. No persistence, Node, or Harness.",
}, indent=2) + "\n")
print(f"Prepared disposable guest in {output}; initramfs {len(initramfs)} bytes")
