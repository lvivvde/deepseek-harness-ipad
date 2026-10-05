#!/usr/bin/env python3
"""Linux-only, real QEMU/9P/RPC probe. No existing user disk is opened."""
import argparse
import asyncio
import ctypes
import fcntl
import gzip
import hashlib
import json
import os
from pathlib import Path
import secrets
import shutil
import socket
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.request
import uuid

SOURCE = Path(__file__).resolve().parent
REPO = SOURCE.parents[2]


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def build(runtime, modloop, output):
    lock = json.loads((REPO / 'runtime/inputs.lock.json').read_text())
    item = next(x for x in lock['inputs'] if x['file'] == 'modloop-virt')
    assert digest(modloop) == item['sha256'], 'MODLOOP_HASH_MISMATCH'
    receipt = json.loads((runtime / 'build-receipt.json').read_text())
    for name in ['Image', 'initramfs.gz', 'system.raw']:
        assert digest(runtime / name) == receipt['files'][name]['sha256'], 'RUNTIME_HASH_MISMATCH'
    init = output / 'initroot'; init.mkdir()
    with gzip.open(runtime / 'initramfs.gz', 'rb') as stream:
        subprocess.run(['cpio', '-idm', '--quiet'], input=stream.read(), cwd=init, check=True)
    modules = output / 'modules'
    subprocess.run(['unsquashfs', '-no-progress', '-d', str(modules), str(modloop)],
                   stdout=subprocess.DEVNULL, check=True)
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

    for basename in ['virtio_blk.ko', 'virtio_net.ko', 'ext4.ko', 'overlay.ko', '9p.ko', '9pnet_virtio.ko']:
        collect(next(name for name in dependencies if name.endswith('/' + basename)))
    target = init / 'usr/lib/modules' / release
    for name in selected:
        (target / name).parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(tree / name, target / name)
    # Keep all dependency rows: base initramfs also contains modules used below.
    shutil.copyfile(tree / 'modules.dep', target / 'modules.dep')
    shutil.copyfile(SOURCE / 'init.sh', init / 'init'); (init / 'init').chmod(0o755)
    shutil.copyfile(SOURCE / 'agent.cjs', init / 'probe-agent.cjs')
    token = secrets.token_hex(24)
    (init / 'probe-token').write_text(token)
    names = '\n'.join(str(p.relative_to(init)) for p in sorted(init.rglob('*'))) + '\n'
    packed = subprocess.run(['cpio', '-o', '-H', 'newc', '--quiet'], input=names.encode(),
                            stdout=subprocess.PIPE, cwd=init, check=True).stdout
    image = output / 'initramfs.gz'; image.write_bytes(gzip.compress(packed, mtime=0))
    return token, {'kernel': release, 'runtimeFiles': receipt['files'],
                   'modloopSha256': item['sha256'], 'addedModules': sorted(selected),
                   'probeInitramfsSha256': digest(image)}


class Guest:
    def __init__(self, runtime, output, token, model):
        self.output, self.token, self.model = output, token, model
        self.workspace = output / ('workspace-' + model); self.workspace.mkdir()
        self.identity = uuid.uuid4().hex
        (self.workspace / '.plan500-identity').write_text(self.identity)
        self.process = None; self.launches = 0
        self.ready = None
        self.log = None
        self.console = None
        self.reader = None
        self.runtime = runtime

    def start(self):
        self.launches += 1
        port = socket.socket(); port.bind(('127.0.0.1', 0)); self.port = port.getsockname()[1]; port.close()
        self.console, serial = socket.socketpair()
        self.log = (self.output / (self.model + '-serial-private.log')).open('wb')
        error = (self.output / (self.model + '-qemu-private.log')).open('wb')
        command = ['qemu-system-aarch64', '-machine', 'virt', '-cpu', 'cortex-a72', '-smp', '1',
                   '-m', '1024', '-accel', 'tcg', '-nodefaults', '-display', 'none', '-monitor', 'none',
                   '-chardev', f'socket,id=serial,fd={serial.fileno()}', '-serial', 'chardev:serial',
                   '-kernel', str(self.runtime / 'Image'), '-initrd', str(self.output / 'initramfs.gz'),
                   '-append', 'console=ttyAMA0 rdinit=/init',
                   '-drive', f'file={self.runtime}/system.raw,if=none,id=system,format=raw,readonly=on',
                   '-device', 'virtio-blk-pci,drive=system',
                   '-netdev', f'user,id=net,restrict=on,hostfwd=tcp:127.0.0.1:{self.port}-:4500',
                   '-device', 'virtio-net-pci,netdev=net,romfile=',
                   '-fsdev', f'local,id=workspace,path={self.workspace},security_model={self.model},writeout=immediate',
                   '-device', 'virtio-9p-pci,fsdev=workspace,mount_tag=workspace']
        self.process = subprocess.Popen(command, pass_fds=(serial.fileno(),),
                                        stdout=subprocess.DEVNULL, stderr=error)
        error.close(); serial.close()

        def drain():
            try:
                while data := self.console.recv(65536): self.log.write(data); self.log.flush()
            except OSError: pass

        self.reader = threading.Thread(target=drain, daemon=True); self.reader.start()

    def rpc(self, route, body=None):
        request = urllib.request.Request(f'http://127.0.0.1:{self.port}' + route,
                    data=None if body is None else json.dumps(body).encode(),
                    headers={'Authorization': 'Bearer ' + self.token, 'content-type': 'application/json'})
        with urllib.request.urlopen(request, timeout=2 if route == '/ready' else 25) as response: return json.load(response)

    async def prepare(self):
        self.start()
        started = time.monotonic()
        while time.monotonic() - started < 90:
            if self.process.poll() is not None: raise RuntimeError('QEMU_EXITED')
            if b'Kernel panic' in (self.output / (self.model + '-serial-private.log')).read_bytes(): raise RuntimeError('GUEST_INIT_FAILED')
            try:
                result = await asyncio.to_thread(self.rpc, '/ready')
                assert result['projectId'] == self.identity and result['protocol'] == 1 and result['mount'] == '9p'
                assert result['node'].startswith('v24.') and result['git'].startswith('git version ')
                return {**result, 'readyMs': round((time.monotonic() - started) * 1000)}
            except (OSError, urllib.error.URLError): await asyncio.sleep(.1)
        raise RuntimeError('READY_TIMEOUT')

    def open(self):
        if self.ready is None: self.ready = asyncio.create_task(self.prepare())
        return self.ready

    async def execute(self, argv, operation=None, timeout=10000, cwd='/workspace', project=None):
        request = {'id': operation or uuid.uuid4().hex, 'projectId': project or self.identity,
                   'argv': argv, 'timeoutMs': timeout, 'cwd': cwd}
        return await asyncio.to_thread(self.rpc, '/execute', request)

    async def shell(self, source, **kwargs):
        return await self.execute(['/bin/sh', '-c', source], **kwargs)

    async def git(self, *arguments):
        return await self.execute(['/usr/bin/git', '-c', 'safe.directory=/workspace', *arguments])

    def close(self):
        if self.process is not None and self.process.poll() is None:
            self.process.kill(); self.process.wait(timeout=10)
        if self.console is not None: self.console.close()
        if self.reader is not None: self.reader.join(timeout=2)
        if self.log is not None: self.log.close()


class Gate:
    def __init__(self, guest, expected=None):
        self.guest, self.expected = guest, expected or guest.identity
        self.closed = False; self.operations = {}; self.close_event = asyncio.Event()

    def close(self):
        self.closed = True; self.close_event.set()

    def request(self, operation, argv, timeout=90):
        if operation in self.operations: return self.operations[operation]

        async def run():
            if self.closed: raise RuntimeError('PROJECT_CLOSED')
            async def prepare(): return await asyncio.shield(self.guest.open())
            preparation = asyncio.create_task(prepare())
            closing = asyncio.create_task(self.close_event.wait())
            try:
                done, _ = await asyncio.wait([preparation, closing], timeout=timeout,
                                             return_when=asyncio.FIRST_COMPLETED)
                if closing in done or self.closed: raise RuntimeError('PROJECT_CLOSED')
                if preparation not in done: raise asyncio.TimeoutError()
                result = preparation.result()
            finally:
                for task in [preparation, closing]:
                    if not task.done(): task.cancel()
                await asyncio.gather(preparation, closing, return_exceptions=True)
            if result['projectId'] != self.expected: raise RuntimeError('PROJECT_ID_MISMATCH')
            # Revalidate the real RPC before each side effect, including after disconnect.
            live = await asyncio.to_thread(self.guest.rpc, '/ready')
            if live['projectId'] != self.expected: raise RuntimeError('PROJECT_ID_MISMATCH')
            return await self.guest.execute(argv, operation=operation)

        task = asyncio.create_task(run()); task.add_done_callback(lambda t: t.exception() if not t.cancelled() else None); self.operations[operation] = task
        return task


async def wait_file(path, timeout=8):
    deadline = time.monotonic() + timeout
    while not path.exists():
        if time.monotonic() > deadline: raise RuntimeError('FIXTURE_TIMEOUT')
        await asyncio.sleep(.02)


async def probe(guest):
    checks, semantics = [], []; guest.checks = checks; guest.semantics = semantics
    def check(name, passed, detail=None):
        checks.append({'name': name, 'passed': bool(passed), 'detail': detail})
        if not passed: raise AssertionError(name)
    def observe(name, compatible, detail):
        semantics.append({'name': name, 'compatible': bool(compatible), 'detail': detail})

    gate = Gate(guest); ready = guest.open(); guest.open()
    command = ['/bin/sh', '-c', 'echo once >> gate-effect']
    queued = gate.request('queued', command)
    check('duplicate requests share preparation and one queued operation', gate.request('queued', command) is queued)
    cancelled = gate.request('cancelled', ['/bin/sh', '-c', 'touch cancelled-effect']); cancelled.cancel()
    timed = gate.request('timed', ['/bin/sh', '-c', 'touch timed-effect'], timeout=.02)
    closing = Gate(guest); closed = closing.request('closed', ['/bin/sh', '-c', 'touch closed-effect']); await asyncio.sleep(0); closing.close()
    (guest.workspace / 'native-draft').write_text('原生编辑仍继续')
    check('host action continues during real guest boot', not ready.done() and not (guest.workspace / 'gate-effect').exists())
    try: await timed
    except asyncio.TimeoutError: pass
    else: raise AssertionError('timeout did not reject')
    try: await closed
    except RuntimeError as error: check('project close returns while actual preparation is still pending', not ready.done() and str(error) == 'PROJECT_CLOSED')
    else: raise AssertionError('closed operation ran')
    metadata = await ready
    check('ready verifies real 9P identity, Node, Git and authenticated RPC', guest.launches == 1, metadata)
    check('queued operation automatically runs once after real readiness', (await queued)['code'] == 0 and (guest.workspace / 'gate-effect').read_text() == 'once\n')
    try: await closed
    except RuntimeError as error: check('project close prevents queued execution', str(error) == 'PROJECT_CLOSED')
    else: raise AssertionError('closed operation ran')
    check('cancelled and expired requests never replay at readiness', not any((guest.workspace / name).exists() for name in ['cancelled-effect', 'timed-effect', 'closed-effect']))
    try: await guest.execute(['/bin/sh', '-c', 'touch id-conflict-effect'], operation='queued')
    except urllib.error.HTTPError as error:
        check('RPC rejects changed payload under an existing operation ID', error.code == 409 and not (guest.workspace / 'id-conflict-effect').exists())
    else: raise AssertionError('conflicting operation ID accepted')
    replay = await guest.execute(command, operation='queued')
    check('real guest RPC deduplicates retries after completion', replay['code'] == 0 and (guest.workspace / 'gate-effect').read_text() == 'once\n')
    mismatch = Gate(guest, expected='wrong-project')
    try: await mismatch.request('wrong', ['/bin/sh', '-c', 'touch wrong-effect'])
    except RuntimeError as error: check('workspace identity mismatch prevents effects', str(error) == 'PROJECT_ID_MISMATCH' and not (guest.workspace / 'wrong-effect').exists())
    else: raise AssertionError('wrong project ran')
    for path, name in [('中文.txt', '中文文件')]:
        host = guest.workspace / path; host.write_text('host-created')
        result = await guest.shell("cat '中文.txt'; printf guest-edited > '中文.txt'")
        check(name + ' host create and guest read/write', result['stdout'] == 'host-created' and host.read_text() == 'guest-edited')
        host.rename(guest.workspace / 'renamed.txt')
        result = await guest.shell('test ! -e 中文.txt && mv renamed.txt guest-renamed.txt')
        check('bidirectional rename', result['code'] == 0 and (guest.workspace / 'guest-renamed.txt').exists())
        result = await guest.shell('rm guest-renamed.txt; echo created > guest-created.txt')
        check('guest delete/create visible to host', result['code'] == 0 and not (guest.workspace / 'guest-renamed.txt').exists() and (guest.workspace / 'guest-created.txt').read_text() == 'created\n')
        (guest.workspace / 'guest-created.txt').unlink()
        check('host delete visible to guest', (await guest.shell('test ! -e guest-created.txt'))['code'] == 0)
    (guest.workspace / 'atomic').write_text('old')
    old = (guest.workspace / 'atomic').open()
    result = await guest.shell('printf new > .atomic-tmp; mv .atomic-tmp atomic')
    check('guest atomic replace preserves open host inode', result['code'] == 0 and old.read() == 'old' and (guest.workspace / 'atomic').read_text() == 'new'); old.close()
    script = "const f=require('fs');const fd=f.openSync('atomic','r');f.writeFileSync('atomic-ready','1');setTimeout(()=>{console.log(JSON.stringify({old:f.readFileSync(fd,'utf8'),now:f.readFileSync('atomic','utf8')}))},500)"
    task = asyncio.create_task(guest.execute(['/opt/node/bin/node', '-e', script])); await wait_file(guest.workspace / 'atomic-ready')
    (guest.workspace / '.host-tmp').write_text('host-new'); os.replace(guest.workspace / '.host-tmp', guest.workspace / 'atomic')
    values = json.loads((await task)['stdout'])
    check('host atomic replace preserves open guest inode', values == {'old': 'new', 'now': 'host-new'})
    await guest.shell('printf value > executable; chmod 755 executable; ln -s executable guest-link')
    mode = (guest.workspace / 'executable').stat().st_mode & 0o777
    link = guest.workspace / 'guest-link'
    observe('guest executable mode is ordinary host mode', mode == 0o755, {'hostMode': oct(mode), 'hostXattrs': os.listxattr(guest.workspace / 'executable')})
    observe('guest symlink is ordinary host symlink', link.is_symlink(), {'hostSymlink': link.is_symlink(), 'hostBytes': link.read_text()})
    (guest.workspace / 'host-link').symlink_to('executable')
    result = await guest.shell('test -L host-link && test "$(cat host-link)" = value')
    observe('host symlink read equivalently in guest', result['code'] == 0, {'code': result['code']})
    await guest.git('init', '-q')
    (guest.workspace / 'git-value').write_text('tracked')
    lock = guest.workspace / '.git/index.lock'; lock.write_text('host-held')
    result = await guest.git('add', 'git-value')
    check('real Git refuses host-owned index.lock before mutation', result['code'] != 0 and not (guest.workspace / '.git/index').exists() and lock.read_text() == 'host-held')
    lock.unlink(); check('real Git succeeds after lock release', (await guest.git('add', 'git-value'))['code'] == 0)
    await guest.shell('printf guest-held > .git/index.lock')
    try: fd = os.open(lock, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError: check('host exclusive create sees guest index.lock', True)
    else: os.close(fd); raise AssertionError('host bypassed guest lock')
    await guest.shell('rm .git/index.lock')
    hook = guest.workspace / '.git/hooks/pre-commit'; hook.write_text('#!/bin/sh\necho called > /workspace/pre-commit-called\nexit 37\n'); hook.chmod(0o755)
    result = await guest.git('-c', 'user.name=Prototype', '-c', 'user.email=prototype@example.invalid', 'commit', '-qm', 'blocked')
    # mapped-xattr may hide the native chmod from guest: measure rather than assert hook semantics.
    head = await guest.git('rev-parse', '--verify', 'HEAD')
    observe('native executable hook blocks real Git commit', result['code'] != 0 and head['code'] != 0 and (guest.workspace / 'pre-commit-called').exists(), {'commitCode': result['code'], 'headExists': head['code'] == 0, 'hookExecuted': (guest.workspace / 'pre-commit-called').exists()})
    lockfile = guest.workspace / 'flock'; lockfile.write_text('')
    with lockfile.open('r+') as stream:
        fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        result = await guest.shell('flock -n flock -c true')
        observe('host flock prevents guest flock', result['code'] != 0, {'guestCode': result['code']})
        fcntl.flock(stream, fcntl.LOCK_UN)
        fcntl.lockf(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        result = await guest.shell('flock -n flock -c true')
        observe('host POSIX lock prevents guest flock', result['code'] != 0, {'guestCode': result['code']})
    (guest.workspace / 'guest-flock-held').unlink(missing_ok=True)
    locking = asyncio.create_task(guest.shell('flock flock -c "touch guest-flock-held; sleep 1"'))
    await wait_file(guest.workspace / 'guest-flock-held')
    with lockfile.open('r+') as stream:
        blocked = False
        try: fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError: blocked = True
        else: fcntl.flock(stream, fcntl.LOCK_UN)
        observe('guest flock prevents host flock', blocked, {'hostBlocked': blocked})
    await locking
    (guest.workspace / 'poll-host').write_text('old')
    polling = asyncio.create_task(guest.shell('echo ready > poll-ready; i=0; while test "$i" -lt 50; do test "$(cat poll-host)" = new && exit 0; sleep .02; i=$((i+1)); done; exit 1'))
    await wait_file(guest.workspace / 'poll-ready'); (guest.workspace / 'poll-host').write_text('new')
    check('explicit guest polling observes host edit', (await polling)['code'] == 0)
    watch = "const f=require('fs');let n=0;try{const w=f.watch('.',(e,name)=>{if(String(name)==='watch-host-write')n++});f.writeFileSync('watch-ready','1');setTimeout(()=>{w.close();console.log(JSON.stringify({events:n}))},700)}catch(e){console.log(JSON.stringify({error:e.code}))}"
    task = asyncio.create_task(guest.execute(['/opt/node/bin/node', '-e', watch]))
    for _ in range(80):
        if task.done() or (guest.workspace / 'watch-ready').exists(): break
        await asyncio.sleep(.02)
    await asyncio.sleep(.1); (guest.workspace / 'watch-host-write').write_text('changed')
    result = json.loads((await task)['stdout'])
    observe('guest fs.watch observes host changes', result.get('events', 0) > 0, result)
    timed_result = await guest.shell('sleep 3; touch timeout-effect', timeout=100)
    check('actual RPC timeout kills command before later effects', timed_result['timeout'] and not (guest.workspace / 'timeout-effect').exists())
    operation = uuid.uuid4().hex
    running = asyncio.create_task(guest.shell('touch running-ready; sleep 3; touch cancelled-running-effect', operation=operation))
    await wait_file(guest.workspace / 'running-ready')
    await asyncio.to_thread(guest.rpc, '/cancel', {'id': operation})
    result = await running
    check('actual RPC cancellation prevents remaining effects', result['cancelled'] and not (guest.workspace / 'cancelled-running-effect').exists())
    guest.close()
    try: await gate.request('disconnected', ['/bin/sh', '-c', 'touch disconnected-effect'])
    except (OSError, urllib.error.URLError): check('RPC disconnect blocks effects without replay or VM restart', not (guest.workspace / 'disconnected-effect').exists() and guest.launches == 1)
    else: raise AssertionError('disconnected operation ran')
    return {'completed': True, 'model': guest.model, 'checks': checks, 'semantics': semantics,
            'allSharedSemanticsCompatible': all(x['compatible'] for x in semantics)}


async def main(args):
    output = Path(tempfile.mkdtemp(prefix='plan500-sharing-', dir=args.scratch))
    token, inputs = build(args.runtime, args.modloop, output)
    results = []
    for model in args.models:
        guest = Guest(args.runtime, output, token, model)
        try: results.append(await probe(guest))
        except Exception as error:
            results.append({'completed': False, 'model': model, 'error': str(error), 'checks': getattr(guest, 'checks', []), 'semantics': getattr(guest, 'semantics', [])})
        finally: guest.close()
    report = {'completed': all(x['completed'] for x in results), 'platform': 'Linux QEMU 9P',
              'qemu': subprocess.check_output(['qemu-system-aarch64', '--version'], text=True).splitlines()[0],
              'inputs': inputs, 'models': results, 'iPadVerified': False, 'DarwinVerified': False,
              'sourceSha256': {p.name: digest(p) for p in SOURCE.iterdir() if p.is_file()}}
    (output / 'result-safe.json').write_text(json.dumps(report, indent=2, ensure_ascii=False) + '\n')
    print(json.dumps({'completed': report['completed'], 'models': [{'model': r['model'], 'completed': r['completed'],
                     'error': r.get('error'), 'semantics': r.get('allSharedSemanticsCompatible')} for r in results],
                      'receipt': str(output / 'result-safe.json')}), flush=True)
    return 0 if report['completed'] else 1


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runtime', type=Path, required=True)
    parser.add_argument('--modloop', type=Path, required=True)
    parser.add_argument('--scratch', type=Path, default=Path('/var/tmp'))
    parser.add_argument('--models', nargs='+', choices=['mapped-xattr', 'none'], default=['mapped-xattr', 'none'])
    raise SystemExit(asyncio.run(main(parser.parse_args())))
