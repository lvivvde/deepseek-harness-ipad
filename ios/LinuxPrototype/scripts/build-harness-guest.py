#!/usr/bin/env python3
"""RAM-only official Harness startup experiment; no production workspace.

Usage: build-harness-guest.py DOWNLOAD_DIRECTORY NODE_GUEST HARNESS_NPM_DIRECTORY OUTPUT
Prepare HARNESS_NPM_DIRECTORY with npm install --ignore-scripts --os=linux
--cpu=arm64 --libc=glibc --save-exact @deepseek-ai/dsh@0.2.0-rc.2.
Keep the resulting package-lock.json with the local artifact receipts.
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

source, base, harness, output = map(Path, sys.argv[1:5])
pins = {
    "bash.deb": "9e2d2b3646b250f53be79b6128d9cff5e99cc5ff4a8c84e58efab59ad9bb0ddc",
    "libtinfo6.deb": "2a747f7fff3c2347c357387a7133df997410f07ba1b1df1a1461a97bd7fbc2fc",
}
for name, expected in pins.items():
    if hashlib.sha256((source / name).read_bytes()).hexdigest() != expected:
        raise SystemExit(f"Receipt mismatch: {name}")
manifest = json.loads((harness / "node_modules/@deepseek-ai/dsh/package.json").read_text())
if manifest["version"] != "0.2.0-rc.2":
    raise SystemExit("Expected fixed official Harness version")
lock = (harness / "package-lock.json").read_bytes()
entries = {}
for path in sorted(harness.rglob("*")):
    name = "opt/harness/" + path.relative_to(harness).as_posix()
    if path.is_symlink():
        entries[name] = (stat.S_IFLNK | 0o777, str(path.readlink()).encode())
    elif path.is_dir():
        entries[name] = (stat.S_IFDIR | 0o755, b"")
    elif path.is_file():
        entries[name] = (stat.S_IFREG | (path.stat().st_mode & 0o777), path.read_bytes())
    else:
        raise SystemExit(f"Unsupported filesystem entry: {name}")
for name in pins:
    data = subprocess.check_output(["ar", "-p", str(source / name), "data.tar.xz"])
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:xz") as archive:
        for member in archive:
            parts = PurePosixPath(member.name).parts
            path = "/".join(parts)
            if not path.startswith(("usr/bin/", "usr/lib/")):
                continue
            if ".." in parts:
                raise SystemExit("Unsafe package entry")
            if member.isdir():
                entries[path] = (stat.S_IFDIR | member.mode, b"")
            elif member.isreg():
                entries[path] = (stat.S_IFREG | member.mode, archive.extractfile(member).read())
            elif member.issym():
                entries[path] = (stat.S_IFLNK | 0o777, member.linkname.encode())
            else:
                raise SystemExit(f"Unsupported package entry: {path}")

remaining = (base / "initramfs.cpio.gz").read_bytes()
while remaining:
    decoder = zlib.decompressobj(31)
    raw = decoder.decompress(remaining) + decoder.flush()
    remaining = decoder.unused_data
offset = 0
init = None
while raw[offset:offset + 6] == b"070701":
    fields = [int(raw[offset + 6 + i * 8:offset + 14 + i * 8], 16) for i in range(13)]
    nb = offset + 110
    name = raw[nb:nb + fields[11] - 1].decode()
    db = (nb + fields[11] + 3) & ~3
    if name == "init":
        init = raw[db:db + fields[6]]
        break
    offset = (db + fields[6] + 3) & ~3
if init is None or b"/node-probe.cjs" not in init:
    raise SystemExit("Expected known Node guest init")
init = init.replace(b"export HOME=/root\n", b"export HOME=/root\nexport TERM=xterm-256color\n")
init = init.replace(b"MINIGUEST_INIT_READY", b"HARNESS_INIT_READY")
if (source / "persistence-probe.raw").exists():
    init = init.replace(b"echo HARNESS_INIT_READY", b'''$bb modprobe vfat
$bb mkdir -p /persist
if $bb mount -t vfat /dev/vda /persist; then
    if [ -f /persist/proof.txt ]; then
        echo PERSISTENCE_RESTORED:$($bb cat /persist/proof.txt)
    else
        echo persistence-file-ok >/persist/proof.txt
        $bb sync
        echo PERSISTENCE_WRITTEN
    fi
else
    echo PERSISTENCE_MOUNT_FAILED
fi
echo HARNESS_INIT_READY''')
init = init.replace(b"$bb httpd -f -p 0.0.0.0:3000 -h /www &", b"$bb httpd -f -p 0.0.0.0:3002 -h /www &")
init = init.replace(b"(node /node-probe.cjs 2>&1; echo NODE_PROBE_EXIT:$?) | $bb tee /www/node.txt &", b"(cd /opt/harness; node native-probe.cjs; echo NATIVE_PROBE_EXIT:$?; node harness-start.cjs; echo HARNESS_EXIT:$?) 2>&1 | $bb tee /www/harness.txt &")
entries["init"] = (stat.S_IFREG | 0o755, init)
entries["opt/harness/native-probe.cjs"] = (stat.S_IFREG | 0o644, b'''const fs = require('node:fs');
const assert = require('node:assert/strict');
(async () => {
  const koffi = require('koffi');
  assert.equal(koffi.load('libc.so.6').func('int getpid(void)')(), process.pid);
  console.log('NATIVE_KOFFI_OK');
  const sharp = require('sharp');
  const png = await sharp({create:{width:1,height:1,channels:4,background:'#ffffff'}}).png().toBuffer();
  assert(png.length > 0); console.log('NATIVE_SHARP_OK');
  const {tryLockExclusive} = await import('@deepseek-ai/node-addon-system/flock');
  const fd = fs.openSync('/tmp/flock-proof', 'w');
  await tryLockExclusive(fd); fs.closeSync(fd); console.log('NATIVE_FLOCK_OK');
  const {launcherPath, probe} = await import('@deepseek-ai/node-addon-system/landlock-run');
  console.log('LANDLOCK_PROBE:' + probe(launcherPath(), {timeoutMs:30000}));
  await new Promise((resolve, reject) => {
    const pty = require('node-pty').spawn('/bin/bash', ['-c','printf pty-ok'], {name:'xterm',cols:80,rows:24,cwd:'/tmp',env:process.env});
    let text = '';
    const timer = setTimeout(() => {pty.kill(); reject(new Error('PTY timeout'));}, 60000);
    pty.onData(data => {text += data;});
    pty.onExit(({exitCode}) => {clearTimeout(timer); try {assert.equal(exitCode,0);assert(text.includes('pty-ok'));resolve();} catch(e) {reject(e);}});
  });
  console.log('NATIVE_PTY_OK');
})().catch(e => {console.error('NATIVE_PROBE_FAIL',e);process.exitCode=1;});
''')
entries["opt/harness/harness-start.cjs"] = (stat.S_IFREG | 0o644, b'''const net = require('node:net');
const {spawn} = require('node:child_process');
// UTM's host port is bound to device loopback. Forward raw HTTP/SSE/WebSocket
// bytes without changing Harness authentication or browser trust checks.
const relay = net.createServer(client => {
  const upstream = net.connect(3001,'127.0.0.1');
  client.pipe(upstream).pipe(client);
  client.on('error',()=>upstream.destroy());
  upstream.on('error',()=>client.destroy());
  client.on('close',()=>upstream.destroy());
  upstream.on('close',()=>client.destroy());
});
relay.listen(3000,'10.0.2.15',()=>console.log('HARNESS_RELAY_READY'));
const child = spawn(process.execPath,['node_modules/@deepseek-ai/dsh/lib/bin.js','web','--no-open','--port','3001','--trusted-host','127.0.0.1:18080'], {stdio:'inherit',env:process.env});
child.on('error',e=>{console.error('HARNESS_SPAWN_FAIL',e);relay.close();process.exitCode=1;});
child.on('exit',(code,signal)=>{console.log('HARNESS_CHILD_EXIT',code,signal);relay.close();process.exitCode=code??1;});
''')
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
for inode, (name, (mode, data)) in enumerate(sorted(entries.items(), key=lambda item:(item[0].count('/'),item[0])),1):
    emit(name, mode, data, inode)
emit("TRAILER!!!",0,inode=len(entries)+1)
output.mkdir(parents=True, exist_ok=True)
shutil.copyfile(base / "Image", output / "Image")
image = (base / "initramfs.cpio.gz").read_bytes() + gzip.compress(bytes(archive), mtime=0)
(output / "initramfs.cpio.gz").write_bytes(image)
spec = json.loads((base / "boot.json").read_text())
spec["memoryMiB"] = 2048
if (source / "persistence-probe.raw").exists():
    if not (output / "persistence.raw").exists():
        shutil.copyfile(source / "persistence-probe.raw", output / "persistence.raw")
    spec.update(disk="persistence.raw", diskFormat="raw")
(output / "boot.json").write_text(json.dumps(spec, indent=2) + "\n")
shutil.copyfile(harness / "package-lock.json", output / "harness-package-lock.json")
(output / "receipts.json").write_text(json.dumps({
    "inputs": pins, "harnessVersion":manifest["version"],
    "packageLockSHA256": hashlib.sha256(lock).hexdigest(),
    "baseSHA256":hashlib.sha256((base / "initramfs.cpio.gz").read_bytes()).hexdigest(),
    "initramfsSHA256":hashlib.sha256(image).hexdigest(),
    "scope":"RAM-only native addons and official Harness boot probe; not a production filesystem.",
},indent=2)+"\n")
print(f"Prepared Harness probe in {output}; initramfs {len(image)} bytes")
