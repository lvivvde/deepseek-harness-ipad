#!/usr/bin/env python3
"""Append a pinned Node/glibc probe to build-miniguest.py's disposable guest.

Usage: build-node-guest.py DOWNLOAD_DIRECTORY MINIGUEST_DIRECTORY OUTPUT_DIRECTORY
This is a RAM-only runtime experiment, not a supported Harness distribution.
"""
import gzip
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import shutil
import stat
import subprocess
import sys
import tarfile
import zlib

source, base, output = map(Path, sys.argv[1:4])
receipts = {
    "node-v24.21.0-linux-arm64.tar.xz": "6ad1325edbdb5649c379b75a237147a666c95d4f9ae8d340fef2d1575d289ad2",
    "libc6.deb": "8784eda966b189c777a384dac5ce009e8fc9b52d006926c5a013e7fa8aa688cc",
    "libgcc-s1.deb": "1108bc87879833d6d9a145f22a4a15cddb34e065b4b5f4b97bee586adbac2851",
    "libstdcpp.deb": "6669b0c52a2e7c6af9adfdabce3ff6e286065cdfbc7b85280862b5f799daebee",
}
for name, expected in receipts.items():
    if hashlib.sha256((source / name).read_bytes()).hexdigest() != expected:
        raise SystemExit(f"Receipt mismatch: {name}")

entries = {}
def add_tar(archive, strip_root=False, libraries_only=False):
    for member in archive:
        parts = PurePosixPath(member.name).parts
        if strip_root:
            parts = ("opt", "node", *parts[1:])
        name = "/".join(parts)
        if not name and member.isdir():
            continue
        if not name or ".." in parts or name.startswith("/"):
            raise SystemExit(f"Unsafe archive path: {member.name}")
        if libraries_only and not name.startswith("usr/lib/"):
            continue
        if member.isdir():
            entries[name] = (stat.S_IFDIR | member.mode, b"")
        elif member.isreg():
            entries[name] = (stat.S_IFREG | member.mode, archive.extractfile(member).read())
        elif member.issym():
            entries[name] = (stat.S_IFLNK | 0o777, member.linkname.encode())
        else:
            raise SystemExit(f"Unsupported archive entry: {member.name}")

with tarfile.open(source / "node-v24.21.0-linux-arm64.tar.xz") as archive:
    add_tar(archive, strip_root=True)
for name in ("libc6.deb", "libgcc-s1.deb", "libstdcpp.deb"):
    data = subprocess.check_output(["ar", "-p", str(source / name), "data.tar.xz"])
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:xz") as archive:
        add_tar(archive, libraries_only=True)

# The base initramfs has /lib -> usr/lib. Debian's ELF loader therefore resolves
# /lib/ld-linux-aarch64.so.1; LD_LIBRARY_PATH supplies its multiarch libraries.
entries["etc/passwd"] = (stat.S_IFREG | 0o644, b"root:x:0:0:root:/root:/bin/sh\n")
entries["etc/group"] = (stat.S_IFREG | 0o644, b"root:x:0:\n")
entries["root"] = (stat.S_IFDIR | 0o700, b"")
entries["node-probe.cjs"] = (stat.S_IFREG | 0o644, b'''const start = Date.now();
const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');
const { Worker } = require('node:worker_threads');
const { DatabaseSync } = require('node:sqlite');
const fs = require('node:fs');
(async () => {
  console.log('NODE_VERSION:' + process.version + ':' + process.arch);
  assert.equal(execFileSync('/bin/busybox', ['sh', '-c', 'printf child-process-ok'], {encoding:'utf8'}), 'child-process-ok');
  console.log('NODE_CHILD_PROCESS_OK');
  fs.writeFileSync('/tmp/node-proof.txt', 'node-file-ok');
  assert.equal(fs.readFileSync('/tmp/node-proof.txt', 'utf8'), 'node-file-ok');
  console.log('NODE_FILE_OK');
  const db = new DatabaseSync(':memory:');
  assert.equal(db.prepare('SELECT 42 AS n').get().n, 42);
  db.close(); console.log('NODE_SQLITE_OK');
  await new Promise((resolve, reject) => {
    const w = new Worker("require('node:worker_threads').parentPort.postMessage(42)", {eval:true});
    w.once('message', value => { try { assert.equal(value, 42); resolve(); } catch(e) { reject(e); } });
    w.once('error', reject);
  });
  console.log('NODE_WORKER_OK');
  const res = await fetch('http://127.0.0.1:3000/');
  assert.equal((await res.text()).trim(), 'guest-local-http-ok');
  console.log('NODE_HTTP_OK');
  console.log('NODE_PROBE_OK elapsed_ms=' + (Date.now() - start));
})().catch(e => { console.error('NODE_PROBE_FAIL', e); process.exitCode = 1; });
''')

# Reuse the exact base init, replacing only its environment and adding a probe.
remaining = (base / "initramfs.cpio.gz").read_bytes()
while remaining:
    decoder = zlib.decompressobj(16 + zlib.MAX_WBITS)
    raw = decoder.decompress(remaining) + decoder.flush()
    remaining = decoder.unused_data
offset = 0
init = None
while raw[offset:offset + 6] == b"070701":
    fields = [int(raw[offset + 6 + i * 8:offset + 14 + i * 8], 16) for i in range(13)]
    name_begin = offset + 110
    name = raw[name_begin:name_begin + fields[11] - 1].decode()
    data_begin = (name_begin + fields[11] + 3) & ~3
    if name == "init":
        init = raw[data_begin:data_begin + fields[6]]
        break
    offset = (data_begin + fields[6] + 3) & ~3
needle = b"#!/bin/busybox sh\nexport PATH=/bin:/sbin:/usr/bin:/usr/sbin\n"
if init is None or not init.startswith(needle):
    raise SystemExit("Expected the known miniguest init")
init = init.replace(needle, b"#!/bin/busybox sh\nexport PATH=/opt/node/bin:/bin:/sbin:/usr/bin:/usr/sbin\nexport LD_LIBRARY_PATH=/usr/lib/aarch64-linux-gnu\nexport HOME=/root\n")
init = init.replace(b"echo MINIGUEST_INIT_READY\n", b"echo MINIGUEST_INIT_READY\n(node /node-probe.cjs 2>&1; echo NODE_PROBE_EXIT:$?) | $bb tee /www/node.txt &\n")
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

for inode, (name, (mode, data)) in enumerate(sorted(entries.items(), key=lambda item: (item[0].count('/'), item[0])), 1):
    emit(name, mode, data, inode)
emit("TRAILER!!!", 0, inode=len(entries) + 1)
output.mkdir(parents=True, exist_ok=True)
shutil.copyfile(base / "Image", output / "Image")
initramfs = (base / "initramfs.cpio.gz").read_bytes() + gzip.compress(bytes(archive), mtime=0)
(output / "initramfs.cpio.gz").write_bytes(initramfs)
spec = json.loads((base / "boot.json").read_text())
spec["memoryMiB"] = 1536
(output / "boot.json").write_text(json.dumps(spec, indent=2) + "\n")
(output / "receipts.json").write_text(json.dumps({
    "inputs": receipts, "baseSHA256": hashlib.sha256((base / "initramfs.cpio.gz").read_bytes()).hexdigest(),
    "initramfsSHA256": hashlib.sha256(initramfs).hexdigest(),
    "scope": "RAM-only Node/glibc probe; no persistent root filesystem or Harness.",
}, indent=2) + "\n")
print(f"Prepared Node probe in {output}; initramfs {len(initramfs)} bytes")
