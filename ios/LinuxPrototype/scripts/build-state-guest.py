#!/usr/bin/env python3
"""Throwaway ext4 HOME experiment, not a persistent distribution rootfs.

Usage: build-state-guest.py DOWNLOAD_DIRECTORY HARNESS_GUEST OUTPUT UNSQUASHFS
OUTPUT/state.raw must already be a freshly formatted ext4 image seeded with
.prototype-state-version containing v1. Never replace the device's used image.
"""
import gzip
import hashlib
import json
import lzma
from pathlib import Path, PurePosixPath
import shutil
import stat
import subprocess
import sys
import zlib

source, base, output = map(Path, sys.argv[1:4])
unsquashfs = sys.argv[4]
release = "6.18.52-0-virt"
modloop = source / "modloop-virt"
modloop_digest = "e96d6f26f7bc7ce64946deb60dae5e3728d73ecd4f37bc59d974a2027cba825b"
if hashlib.sha256(modloop.read_bytes()).hexdigest() != modloop_digest:
    raise SystemExit("Fixed Alpine 3.23.6 modloop receipt mismatch")
image = (base / "initramfs.cpio.gz").read_bytes()
receipt = json.loads((base / "receipts.json").read_text())
if hashlib.sha256(image).hexdigest() != receipt["initramfsSHA256"]:
    raise SystemExit("Harness guest receipt mismatch")
disk = output / "state.raw"
with disk.open("rb") as stream:
    stream.seek(1024 + 56)
    if stream.read(2) != b"\x53\xef":
        raise SystemExit("Expected prepared ext4 state.raw; this script never formats disks")

entries = {}
module_receipts = {}
text = subprocess.check_output([unsquashfs, "-cat", str(modloop), "modules/" + release + "/modules.dep"]).decode()
dependencies = {}
for line in text.splitlines():
    name, children = line.split(":", 1)
    dependencies[name] = children.split()
candidates = [name for name in dependencies if name.split("/")[-1].split(".ko")[0] == "ext4"]
if len(candidates) != 1:
    raise SystemExit("Expected exactly one matching ext4 module")
pending = candidates[:]
selected = set()
while pending:
    name = pending.pop()
    if name in selected:
        continue
    if ".." in PurePosixPath(name).parts or name.startswith("/"):
        raise SystemExit("Unsafe module dependency path")
    selected.add(name)
    pending.extend(dependencies[name])
for name in sorted(selected):
    data = subprocess.check_output([unsquashfs, "-cat", str(modloop), "modules/" + release + "/" + name])
    if name.endswith(".gz"):
        data = gzip.decompress(data)
    elif name.endswith(".xz"):
        data = lzma.decompress(data)
    elif name.endswith(".zst"):
        data = subprocess.check_output(["zstd", "-d", "--stdout"], input=data)
    if b"vermagic=" + release.encode() + b" " not in data:
        raise SystemExit("Module vermagic mismatch: " + name)
    target = name.split(".ko")[0] + ".ko"
    entries["usr/lib/modules/" + release + "/" + target] = (stat.S_IFREG | 0o644, data)
    module_receipts[target] = hashlib.sha256(data).hexdigest()
for extension in [".ko.gz", ".ko.xz", ".ko.zst"]:
    text = text.replace(extension, ".ko")
entries["usr/lib/modules/" + release + "/modules.dep"] = (stat.S_IFREG | 0o644, text.encode())

remaining = image
init = None
while remaining:
    decoder = zlib.decompressobj(31)
    raw = decoder.decompress(remaining) + decoder.flush()
    remaining = decoder.unused_data
    offset = 0
    while raw[offset:offset + 6] == b"070701":
        fields = [int(raw[offset + 6 + i * 8:offset + 14 + i * 8], 16) for i in range(13)]
        nb = offset + 110
        name = raw[nb:nb + fields[11] - 1].decode()
        db = (nb + fields[11] + 3) & ~3
        if name == "init":
            init = raw[db:db + fields[6]]
        if name == "TRAILER!!!":
            break
        offset = (db + fields[6] + 3) & ~3
if init is None or init.count(b"echo HARNESS_INIT_READY") != 1:
    raise SystemExit("Expected known Harness guest init")
setup = b'''homeReady=0
if $bb modprobe ext4 && $bb mount -t ext4 -o errors=remount-ro /dev/vdb /root; then
    if [ "$($bb cat /root/.prototype-state-version 2>/dev/null)" = v1 ]; then
        if [ -f /root/.state-restored-v1 ]; then
            homeReady=1
            echo STATE_HOME_EXISTING
        elif [ -f /persist/root-backup.tgz ]; then
            if $bb tar -xzf /persist/root-backup.tgz -C /root; then
                $bb touch /root/.state-restored-v1
                $bb sync
                homeReady=1
                echo STATE_RESTORED_FROM_BACKUP
            else
                echo STATE_RESTORE_FAILED
            fi
        else
            echo STATE_BACKUP_MISSING
        fi
    else
        echo STATE_DISK_VERSION_MISMATCH
    fi
else
    echo STATE_DISK_MOUNT_FAILED
fi
if [ "$homeReady" = 1 ]; then
    $bb mkdir -p /root/Documents
    echo STATE_HOME_READY
fi
echo HARNESS_INIT_READY'''
init = init.replace(b"echo HARNESS_INIT_READY", setup)
startup = b"(cd /opt/harness; node native-probe.cjs; echo NATIVE_PROBE_EXIT:$?; node harness-start.cjs; echo HARNESS_EXIT:$?) 2>&1 | $bb tee /www/harness.txt &"
if init.count(startup) != 1:
    raise SystemExit("Expected known Harness startup")
init = init.replace(startup, b'if [ "$homeReady" = 1 ]; then\n' + startup + b'\nelse\n    echo HARNESS_SKIPPED_NO_STATE_HOME\nfi')
entries["init"] = (stat.S_IFREG | 0o755, init)
for name in list(entries):
    for parent in PurePosixPath(name).parents:
        if str(parent) != ".":
            entries.setdefault(str(parent), (stat.S_IFDIR | 0o755, b""))
archive = bytearray()
def emit(name, mode, data=b"", inode=1):
    encoded = name.encode() + b"\0"
    fields = [inode, mode, 0, 0, 1, 0, len(data), 0, 0, 0, 0, len(encoded), 0]
    archive.extend(b"070701" + b"".join(f"{v:08x}".encode() for v in fields))
    archive.extend(encoded)
    archive.extend(b"\0" * (-len(archive) % 4))
    archive.extend(data)
    archive.extend(b"\0" * (-len(archive) % 4))
for inode, (name, (mode, data)) in enumerate(sorted(entries.items(), key=lambda item: (item[0].count("/"), item[0])), 1):
    emit(name, mode, data, inode)
emit("TRAILER!!!", 0, inode=len(entries) + 1)
result = image + gzip.compress(bytes(archive), mtime=0)
(output / "initramfs-state.cpio.gz").write_bytes(result)
(output / "init-state.sh").write_bytes(init)
shutil.copyfile(base / "Image", output / "Image")
spec = json.loads((base / "boot.json").read_text())
if spec.get("disk") != "persistence.raw" or spec.get("diskFormat") != "raw":
    raise SystemExit("Expected retained FAT backup disk as the first device")
spec.update(initrd="initramfs-state.cpio.gz", stateDisk="state.raw")
(output / "boot.json").write_text(json.dumps(spec, indent=2) + "\n")
(output / "state-receipts.json").write_text(json.dumps({
    "kernelRelease": release, "modloopSHA256": modloop_digest,
    "baseSHA256": hashlib.sha256(image).hexdigest(),
    "initramfsSHA256": hashlib.sha256(result).hexdigest(),
    "modulesSHA256": module_receipts,
    "scope": "Persistent ext4 /root only; runtime rootfs remains RAM-only. Backup archive stays on device.",
}, indent=2) + "\n")
print("Prepared ext4 HOME experiment; modules:", ", ".join(sorted(module_receipts)))
