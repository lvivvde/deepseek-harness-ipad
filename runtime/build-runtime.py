#!/usr/bin/env python3
"""Build the bundled guest from locked, locally prepared inputs."""
import argparse
import hashlib
import json
import gzip
import io
import lzma
from pathlib import Path, PurePosixPath
import plistlib
import shutil
import stat
import subprocess
import tarfile
import tempfile

HERE = Path(__file__).resolve().parent

def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()

def verify_inputs(directory, lock):
    for item in lock['inputs']:
        path = directory / item['file']
        name = item['file']
        if not name or PurePosixPath(name).name != name or name in ('.', '..'):
            raise ValueError('Unsafe input filename')
        if path.is_symlink() or not path.is_file() or digest(path) != item['sha256']:
            raise ValueError('Input digest mismatch: ' + item['file'])

def path_name(name):
    parts = PurePosixPath(name).parts
    if '..' in parts or name.startswith('/'):
        raise ValueError('Unsafe archive path')
    # Debian 13 uses merged /usr, even for tar members still named bin/ or lib/.
    if parts and parts[0] in ('bin', 'sbin', 'lib', 'lib64'):
        parts = ('usr', *parts)
    return '/'.join(parts)

def read_tar(archive, entries, prefix='', strip=0):
    for member in archive:
        original = PurePosixPath(member.name)
        if '..' in original.parts or original.is_absolute():
            raise ValueError('Unsafe archive path')
        parts = original.parts[strip:]
        if not parts:
            continue
        name = path_name(prefix + '/'.join(parts))
        if member.isdir():
            entries[name] = (stat.S_IFDIR | member.mode, b'')
        elif member.isreg():
            entries[name] = (stat.S_IFREG | member.mode, archive.extractfile(member).read())
        elif member.issym():
            entries[name] = (stat.S_IFLNK | 0o777, member.linkname.encode())
        elif member.islnk():
            target = path_name(member.linkname)
            entries[name] = ('hardlink', target)
        else:
            raise ValueError('Unsupported archive file type')

def write_tree(entries, destination):
    # Delay symlinks until all ordinary writes finish: extraction never follows them.
    for name, (mode, data) in entries.items():
        if mode == 'hardlink' or stat.S_ISLNK(mode):
            continue
        path = destination / name
        path.parent.mkdir(parents=True, exist_ok=True)
        if stat.S_ISDIR(mode):
            path.mkdir(exist_ok=True)
        else:
            path.write_bytes(data)
        path.chmod(stat.S_IMODE(mode))
    for name, (mode, data) in entries.items():
        path = destination / name
        if mode == 'hardlink':
            path.parent.mkdir(parents=True, exist_ok=True)
            path.hardlink_to(destination / data)
        elif stat.S_ISLNK(mode):
            path.parent.mkdir(parents=True, exist_ok=True)
            path.symlink_to(data.decode())

def make_cpio(entries):
    for name in list(entries):
        for parent in PurePosixPath(name).parents:
            if str(parent) != '.':
                entries.setdefault(str(parent), (stat.S_IFDIR | 0o755, b''))
    result = bytearray()
    def emit(name, mode, data, inode):
        encoded = name.encode() + b'\0'
        fields = [inode, mode, 0, 0, 1, 0, len(data), 0, 0, 0, 0, len(encoded), 0]
        result.extend(b'070701' + b''.join(f'{value:08x}'.encode() for value in fields))
        result.extend(encoded)
        result.extend(b'\0' * (-len(result) % 4))
        result.extend(data)
        result.extend(b'\0' * (-len(result) % 4))
    ordered = sorted(entries.items(), key=lambda item: (item[0].count('/'), item[0]))
    for inode, (name, (mode, data)) in enumerate(ordered, 1):
        emit(name, mode, data, inode)
    emit('TRAILER!!!', 0, b'', len(entries) + 1)
    return gzip.compress(bytes(result), mtime=0)

def modules(inputs, lock, unsquashfs):
    release = lock['kernelRelease']
    prefix = 'modules/' + release + '/'
    dependency_text = subprocess.check_output([unsquashfs, '-cat', str(inputs / 'modloop-virt'), prefix + 'modules.dep']).decode()
    dependencies = dict((name, children.split()) for name, children in
                        (line.split(':', 1) for line in dependency_text.splitlines()))
    wanted = {'virtio_mmio', 'virtio_pci', 'virtio_net', 'virtio_blk', 'af_packet', 'ext4'}
    pending = [name for name in dependencies if name.split('/')[-1].split('.ko')[0] in wanted]
    selected = set()
    while pending:
        name = pending.pop()
        if name in selected:
            continue
        if '..' in PurePosixPath(name).parts or name.startswith('/'):
            raise ValueError('Unsafe module path')
        selected.add(name)
        pending.extend(dependencies[name])
    if not any('/ext4.ko' in name for name in selected):
        raise ValueError('Missing ext4 module')
    result = {}
    def uncompressed(name):
        return name.split('.ko')[0] + '.ko'
    for name in sorted(selected):
        data = subprocess.check_output([unsquashfs, '-cat', str(inputs / 'modloop-virt'), prefix + name])
        if name.endswith('.gz'): data = gzip.decompress(data)
        elif name.endswith('.xz'): data = lzma.decompress(data)
        elif name.endswith('.zst'): data = subprocess.check_output(['zstd', '-d', '--stdout'], input=data)
        if b'vermagic=' + release.encode() + b' ' not in data:
            raise ValueError('Module vermagic mismatch')
        result['usr/lib/modules/' + release + '/' + uncompressed(name)] = (stat.S_IFREG | 0o644, data)
    text = ''.join(uncompressed(name) + ': ' + ' '.join(map(uncompressed, dependencies[name])) + '\n' for name in sorted(selected))
    result['usr/lib/modules/' + release + '/modules.dep'] = (stat.S_IFREG | 0o644, text.encode())
    return result

def make_disk(mke2fs, tree, disk, size_mib, label):
    with disk.open('xb') as stream:
        stream.truncate(size_mib * 1024 * 1024)
    subprocess.run([mke2fs, '-q', '-t', 'ext4', '-F', '-L', label, '-m', '0',
                    '-E', 'root_owner=0:0,lazy_itable_init=0,lazy_journal_init=0',
                    '-d', str(tree), str(disk)], check=True)

def ipad_profile_patch():
    return ('- id: workspace-controller\n  config:\n    documentsDirectory: /root/Documents\n'
            '- insert:\n  - id: ipad-project-lifecycle\n    name: /opt/harness/project-lifecycle.mjs\n')

def patch_client_bridges(harness):
    """Version-pinned, small adapters to the official terminal and sidebar services."""
    def replace(relative, before, after):
        file = harness / 'node_modules/@deepseek-ai' / relative
        text = file.read_text()
        if text.count(before) != 1:
            raise ValueError('Official client bridge seam changed: ' + relative)
        file.write_text(text.replace(before, after, 1))
    replace('dsh-client-ui-sidebar-terminal/lib/client.terminal.js',
            'xterm.open(node);',
            'xterm.open(node);\n                xterm.element.harnessTerminalInput = data => { if (current.current.state.writable) model.write(data); };')
    replace('dsh-client-ui-sidebar-terminal/lib/client.terminal.js',
            'xterm.dispose();', 'delete xterm.element.harnessTerminalInput;\n                    xterm.dispose();')
    replace('dsh-client-ui-sidebar-browser/lib/client.js',
            'const openTabs = ctx.sidebarRight.openTabs;',
            """const openTabs = ctx.sidebarRight.openTabs;
            ctx.effect(() => {
                const open = value => {
                    const url = new URL(value);
                    if (url.protocol !== 'http:' || url.hostname !== '127.0.0.1' || !url.port) return false;
                    const target = ctx.sidebarRight.commandTarget(document.activeElement);
                    if (!target) return false;
                    ctx.sidebarRight.openTab('browser', {paneId: target.paneId, params: {url: url.href}});
                    return true;
                };
                window.harnessOpenSidebarPreview = open;
                return () => { if (window.harnessOpenSidebarPreview === open) delete window.harnessOpenSidebarPreview; };
            }, 'ipad.sidebar-preview');""")

def build(args, lock):
    if not args.output or not args.harness or not args.mke2fs or not args.unsquashfs:
        raise ValueError('Build requires --output, --harness, --mke2fs and --unsquashfs')
    if digest(HERE / 'harness-package-lock.json') != lock['harnessLockSHA256'] or \
       digest(args.harness / 'package-lock.json') != lock['harnessLockSHA256']:
        raise ValueError('Harness lockfile mismatch; prepare with npm ci')
    app = plistlib.loads((HERE.parent / 'ios/HarnessApp/Sources/Info.plist').read_bytes())
    if app['CFBundleShortVersionString'] != lock['runtimeVersion'] or lock['protocolVersion'] != 1:
        raise ValueError('App/runtime version or protocol mismatch')
    package = json.loads((args.harness / 'node_modules/@deepseek-ai/dsh/package.json').read_text())
    if package['version'] != lock['harnessVersion']:
        raise ValueError('Unexpected Harness version')
    entries = {}
    for item in lock['inputs']:
        if 'package' not in item: continue
        package_path = Path(args.inputs) / item['file']
        members = subprocess.check_output(['ar', '-t', str(package_path)], text=True).splitlines()
        data_name = next(name for name in members if name.startswith('data.tar.'))
        data = subprocess.check_output(['ar', '-p', str(package_path), data_name])
        with tarfile.open(fileobj=io.BytesIO(data), mode='r:*') as archive:
            read_tar(archive, entries)
    with tarfile.open(Path(args.inputs) / 'node-v24.21.0-linux-arm64.tar.xz') as archive:
        read_tar(archive, entries, prefix='opt/node/', strip=1)
    busybox = entries['usr/bin/busybox'][1]
    if busybox[:4] != b'\x7fELF' or int.from_bytes(busybox[18:20], 'little') != 183:
        raise ValueError('Expected Linux arm64 BusyBox')
    module_entries = modules(Path(args.inputs), lock, args.unsquashfs)
    entries.update(module_entries)
    for directory in ('dev', 'proc', 'sys', 'tmp', 'run', 'root', 'var', 'opt', 'usr/local/bin'):
        entries[directory] = (stat.S_IFDIR | 0o755, b'')
    for name, target in [('bin', 'usr/bin'), ('sbin', 'usr/sbin'), ('lib', 'usr/lib')]:
        entries[name] = (stat.S_IFLNK | 0o777, target.encode())
    for applet in 'sh ls cat mkdir rm rmdir cp mv chmod chown touch sync sleep printf echo ps kill uname hostname ifconfig route udhcpc setsid cttyhack modprobe mount umount tar gzip gunzip wget find sed grep awk head tail sort cut wc df du readlink realpath xargs stat ln date env id whoami test true false basename dirname'.split():
        entries.setdefault('usr/bin/' + applet, (stat.S_IFLNK | 0o777, b'busybox'))
    entries['etc/passwd'] = (stat.S_IFREG | 0o644, b'root:x:0:0:root:/root:/bin/bash\n')
    entries['etc/group'] = (stat.S_IFREG | 0o644, b'root:x:0:\n')
    entries['etc/resolv.conf'] = (stat.S_IFLNK | 0o777, b'/run/resolv.conf')
    entries['etc/udhcpc/default.script'] = (stat.S_IFREG | 0o755, (HERE / 'guest/default.script').read_bytes())
    entries['etc/gitconfig'] = (stat.S_IFREG | 0o644, (HERE / 'guest/gitconfig').read_bytes())
    entries['usr/sbin/harness-init'] = (stat.S_IFREG | 0o755, (HERE / 'guest/harness-init').read_bytes())
    metadata = dict(runtimeVersion=lock['runtimeVersion'], protocolVersion=lock['protocolVersion'],
                    inputManifestSHA256=digest(Path(args.lock)), debianSnapshot=lock['debianSnapshot'])
    entries['etc/harness-runtime.json'] = (stat.S_IFREG | 0o644, (json.dumps(metadata) + '\n').encode())
    certificates = b''.join(data for name, (mode, data) in entries.items()
                            if name.startswith('usr/share/ca-certificates/') and name.endswith('.crt') and mode != 'hardlink')
    if not certificates: raise ValueError('Missing CA certificates')
    entries['etc/ssl/certs/ca-certificates.crt'] = (stat.S_IFREG | 0o644, certificates)
    args.output.mkdir()
    with tempfile.TemporaryDirectory(prefix='harness-rootfs-') as scratch:
        root = Path(scratch) / 'system'
        root.mkdir()
        write_tree(entries, root)
        harness = root / 'opt/harness'
        shutil.copytree(args.harness, harness, symlinks=True)
        for script in ('harness-start.cjs', 'compile-cache-flush.cjs', 'clean-locks.cjs', 'transfer.cjs', 'project-lifecycle.mjs', 'preview.cjs', 'supervisor.cjs', 'control.cjs', 'backup.cjs', 'AGENTS.md'):
            shutil.copyfile(HERE / 'guest' / script, harness / script)
        patch_client_bridges(harness)
        shutil.copytree(HERE / 'guest/examples', harness / 'examples')
        dsh = root / 'usr/local/bin/dsh'
        dsh.write_text('#!/bin/sh\nexec /opt/node/bin/node /opt/harness/node_modules/@deepseek-ai/dsh/lib/bin.js "$@"\n')
        dsh.chmod(0o755)
        pnpm = root / 'usr/local/bin/pnpm'
        pnpm.write_text('#!/bin/sh\nexec /opt/node/bin/node /opt/harness/node_modules/pnpm/bin/pnpm.mjs "$@"\n')
        pnpm.chmod(0o755)
        for command in ('python', 'python3', 'pip', 'pip3', 'gcc', 'g++', 'cc', 'c++', 'make', 'cmake', 'apt', 'apt-get'):
            stub = root / 'usr/local/bin' / command
            stub.write_text('#!/bin/sh\nprintf "%s\\n" "首版暂不支持 Python、原生编译或系统包安装；请使用纯 JS 或 linux-arm64 glibc 预编译依赖。" >&2\nexit 126\n')
            stub.chmod(0o755)
        (harness / 'ipad.patch.yml').write_text(ipad_profile_patch())
        seed = Path(scratch) / 'user'
        seed.mkdir(mode=0o700)
        (seed / '.harness-layout-version').write_text('1\n')
        (seed / 'projects').mkdir()
        (seed / 'Documents').mkdir()
        make_disk(args.mke2fs, root, args.output / 'system.raw', args.system_mib, 'HARNESS_SYSTEM')
        make_disk(args.mke2fs, seed, args.output / 'user-seed.raw', args.user_mib, 'HARNESS_USER')
    mini = dict(module_entries)
    mini['usr/bin/busybox'] = (stat.S_IFREG | 0o755, busybox)
    mini['init'] = (stat.S_IFREG | 0o755, (HERE / 'guest/init').read_bytes())
    for name, target in [('bin', 'usr/bin'), ('sbin', 'usr/sbin'), ('lib', 'usr/lib')]:
        mini[name] = (stat.S_IFLNK | 0o777, target.encode())
    (args.output / 'initramfs.gz').write_bytes(make_cpio(mini))
    shutil.copyfile(Path(args.inputs) / 'vmlinuz-virt', args.output / 'Image')
    manifest = dict(formatVersion=1, memoryMiB=args.memory_mib, kernel='Image', initramfs='initramfs.gz',
                    systemDisk='system.raw', userDiskSeed='user-seed.raw', userDiskMiB=args.user_disk_mib)
    (args.output / 'runtime.json').write_text(json.dumps(manifest, indent=2) + '\n')
    receipt = dict(metadata, inputs=lock, harnessLockSHA256=lock['harnessLockSHA256'],
                   systemMiB=args.system_mib, userMiB=args.user_mib, userDiskMiB=args.user_disk_mib, memoryMiB=args.memory_mib,
                   files={name: dict(bytes=(args.output / name).stat().st_size, sha256=digest(args.output / name))
                          for name in ('Image', 'initramfs.gz', 'system.raw', 'user-seed.raw', 'runtime.json')})
    (args.output / 'build-receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print('Built bundled runtime:', args.output)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--inputs', required=True)
    parser.add_argument('--lock', required=True)
    parser.add_argument('--verify-inputs', action='store_true')
    parser.add_argument('--output', type=Path)
    parser.add_argument('--harness', type=Path)
    parser.add_argument('--mke2fs')
    parser.add_argument('--unsquashfs')
    parser.add_argument('--system-mib', type=int, default=1024)
    parser.add_argument('--user-mib', type=int, default=512, help='bundled seed size')
    parser.add_argument('--user-disk-mib', type=int, default=8192, help='sparse size the app grows the disk to')
    parser.add_argument('--memory-mib', type=int, default=2048)
    args = parser.parse_args()
    try:
        lock = json.loads(Path(args.lock).read_text())
        verify_inputs(Path(args.inputs), lock)
        if args.output and args.output.exists():
            raise ValueError('Output already exists; use a new build directory')
        if not 128 <= args.memory_mib <= 2048 or not 128 <= args.system_mib <= 16384 or not 64 <= args.user_mib <= 16384 \
                or not max(512, args.user_mib) <= args.user_disk_mib <= 65536:
            raise ValueError('Unsupported build capacity')
        if not args.verify_inputs:
            build(args, lock)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, str(error) + '\n')

if __name__ == '__main__':
    main()
