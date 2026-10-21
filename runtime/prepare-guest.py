#!/usr/bin/env python3
"""Build the App's Linux guest inputs from the system disk build (`build-runtime.py`). Linux only.

The guest boots the same kernel and read-only `system.raw`; its initramfs is the system build's
BusyBox initramfs plus the 9P, overlay and virtio modules from the pinned modloop, with
`guest-agent/init.sh` as `/init`, `guest-agent/agent.cjs`, and a random token per build.
Usage: python3 runtime/prepare-guest.py --runtime DIR --modloop FILE --out DIR
Writes Image, system.raw, initramfs.gz, inputs.json and the 0600 `token-private` that
`make app` / `make ipad` check. Never print or commit the token.
"""
import argparse
import gzip
import hashlib
import json
from pathlib import Path
import secrets
import shutil
import subprocess
import sys

SOURCE = Path(__file__).resolve().parent
AGENT = SOURCE / 'guest-agent'
FILES = ['Image', 'system.raw', 'initramfs.gz']
MODULES = ['virtio_blk.ko', 'virtio_net.ko', 'ext4.ko', 'overlay.ko', '9p.ko', '9pnet_virtio.ko']


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def initramfs(runtime, modloop, work):
    lock = json.loads((SOURCE / 'inputs.lock.json').read_text())
    item = next(x for x in lock['inputs'] if x['file'] == 'modloop-virt')
    if digest(modloop) != item['sha256']: raise SystemExit('MODLOOP_HASH_MISMATCH')
    receipt = json.loads((runtime / 'build-receipt.json').read_text())
    for name in ['Image', 'initramfs.gz', 'system.raw']:
        if digest(runtime / name) != receipt['files'][name]['sha256']: raise SystemExit('RUNTIME_HASH_MISMATCH')
    init = work / 'initroot'; init.mkdir()
    with gzip.open(runtime / 'initramfs.gz', 'rb') as stream:
        subprocess.run(['cpio', '-idm', '--quiet'], input=stream.read(), cwd=init, check=True)
    modules = work / 'modules'
    subprocess.run(['unsquashfs', '-no-progress', '-d', str(modules), str(modloop)], stdout=subprocess.DEVNULL, check=True)
    release = lock['kernelRelease']
    tree = modules / 'modules' / release
    dependencies = {}
    for line in (tree / 'modules.dep').read_text().splitlines():
        name, deps = line.split(':', 1); dependencies[name] = deps.split()
    selected = set()

    def collect(name):
        if name in selected: return
        selected.add(name)
        for child in dependencies[name]: collect(child)

    for basename in MODULES:
        collect(next(name for name in dependencies if name.endswith('/' + basename)))
    target = init / 'usr/lib/modules' / release
    for name in selected:
        (target / name).parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(tree / name, target / name)
    # Keep all dependency rows: the base initramfs also loads modules of its own.
    shutil.copyfile(tree / 'modules.dep', target / 'modules.dep')
    shutil.copyfile(AGENT / 'init.sh', init / 'init'); (init / 'init').chmod(0o755)
    shutil.copyfile(AGENT / 'agent.cjs', init / 'probe-agent.cjs')
    token = secrets.token_hex(24)
    (init / 'probe-token').write_text(token)
    names = '\n'.join(str(p.relative_to(init)) for p in sorted(init.rglob('*'))) + '\n'
    packed = subprocess.run(['cpio', '-o', '-H', 'newc', '--quiet'], input=names.encode(),
                            stdout=subprocess.PIPE, cwd=init, check=True).stdout
    image = work / 'initramfs.gz'; image.write_bytes(gzip.compress(packed, mtime=0))
    return token, {'kernel': release, 'runtimeFiles': receipt['files'], 'modloopSha256': item['sha256'],
                   'addedModules': sorted(selected), 'probeInitramfsSha256': digest(image)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runtime', type=Path, required=True, help='output of build-runtime.py')
    parser.add_argument('--modloop', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    output = args.out; output.mkdir(parents=True)
    work = output / 'work'; work.mkdir()
    token, inputs = initramfs(args.runtime, args.modloop, work)
    shutil.copyfile(work / 'initramfs.gz', output / 'initramfs.gz')
    for name in ['Image', 'system.raw']: shutil.copyfile(args.runtime / name, output / name)
    shutil.rmtree(work)
    (output / 'token-private').write_text(token); (output / 'token-private').chmod(0o600)
    manifest = {'inputs': inputs, 'files': {name: digest(output / name) for name in FILES},
                'leaseSourceSha256': {name: digest(AGENT / name) for name in ['init.sh', 'agent.cjs']}}
    (output / 'inputs.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(json.dumps({'prepared': str(output), 'files': manifest['files']}))
    return 0


if __name__ == '__main__':
    sys.exit(main())
