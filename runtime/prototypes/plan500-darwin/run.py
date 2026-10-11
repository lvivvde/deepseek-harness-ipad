#!/usr/bin/env python3
"""Darwin host write-lease probe: the plan500-lease guest on a macOS APFS 9P share.

`prepare` runs on Linux (it needs the verified initramfs builder); `probe` runs on macOS.
No user disk is opened.
"""
import argparse
import asyncio
import base64
import importlib.util
import json
import os
from pathlib import Path
import platform
import queue
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import traceback
import urllib.error
import uuid

SOURCE = Path(__file__).resolve().parent
LEASE_DIR = SOURCE.parent / 'plan500-lease'
spec = importlib.util.spec_from_file_location('plan500_lease', LEASE_DIR / 'run.py')
lease = importlib.util.module_from_spec(spec); spec.loader.exec_module(lease)
sharing, digest = lease.sharing, lease.digest
GUEST_FILES = ['Image', 'system.raw', 'initramfs.gz']


class GatewayCrashed(Exception): pass


class GatedGuest(sharing.Guest):
    """Puts a connect gate in front of the QEMU host forward. libslirp listens with backlog 1 and
    XNU answers a connection that overflows the accept queue with RST (Linux retransmits instead),
    so concurrent RPC connects reset at random on a Darwin host. The relay opens at most one
    upstream connection at a time and holds the gate until an unauthenticated round trip on it
    (agent answers 403, keep-alive) proves slirp accepted it; the client's bytes then flow over that
    connection unchanged. Failures before that round trip, and resets afterwards, reach the client
    as a reset, so connection loss stays observable."""

    def start(self):
        if getattr(self, 'relay', None) is not None: self.relay.close()
        super().start()
        upstream = self.port
        listener = socket.create_server(('127.0.0.1', 0), backlog=128)
        self.port, self.relay = listener.getsockname()[1], listener
        gate = threading.Lock()

        def reset(sock):  # SHUT_RD wakes the other pump; linger 0 makes close send RST
            for step in [lambda: sock.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack('ii', 1, 0)),
                         lambda: sock.shutdown(socket.SHUT_RD)]:
                try: step()
                except OSError: pass
            sock.close()

        def pump(source, target):
            try:
                while data := source.recv(65536): target.sendall(data)
                target.shutdown(socket.SHUT_WR)
            except OSError: reset(target); reset(source)

        def serve(client):
            try:
                with gate:
                    up = socket.create_connection(('127.0.0.1', upstream), timeout=20)
                    up.sendall(b'GET /plan500-gate HTTP/1.1\r\nHost: guest\r\n\r\n')
                    head = b''
                    while b'\r\n\r\n' not in head:
                        if not (data := up.recv(4096)): raise ConnectionResetError('GATE_EOF')
                        head += data
                    head, body = head.split(b'\r\n\r\n', 1)
                    lengths = [int(x.split(b':')[1]) for x in head.split(b'\r\n') if x.lower().startswith(b'content-length:')]
                    done = (lambda: len(body) >= lengths[0]) if lengths else (lambda: body.endswith(b'0\r\n\r\n'))
                    while not done():
                        if not (data := up.recv(4096)): raise ConnectionResetError('GATE_EOF')
                        body += data
                    assert head.startswith(b'HTTP/1.1 403') and (not lengths or len(body) == lengths[0]), 'GATE_UNEXPECTED'
                    up.settimeout(None)
            except Exception:
                reset(client); return
            back = threading.Thread(target=pump, args=(up, client), daemon=True); back.start()
            pump(client, up); back.join(); up.close(); client.close()

        def accept():
            try:
                while True: threading.Thread(target=serve, args=(listener.accept()[0],), daemon=True).start()
            except OSError: pass

        threading.Thread(target=accept, daemon=True).start()

    def close(self):
        super().close()
        if getattr(self, 'relay', None) is not None: self.relay.close()


class SwiftGateway:
    """Drives the Swift gateway process with the Python Gateway's interface, so lease.probe runs unchanged.

    `crashed = True` is a real SIGKILL; in-flight calls then return CRASHED. The VM owner (this harness)
    tells reconcile whether QEMU has exited, as QemuBridge would on iPad."""
    binary = None
    live = []

    def __init__(self, workspace, state, guest):
        self.guest = guest
        self.stderr = (state.parent / f'{state.name}-swift-stderr-private.log').open('ab')
        self.process = subprocess.Popen([str(self.binary), '--workspace', str(workspace), '--state', str(state),
                                         '--identity', guest.identity], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=self.stderr)
        self.pending, self.lock, self.next, self.dead = {}, threading.Lock(), 0, False
        ready = queue.Queue(); self.pending['ready'] = ready
        threading.Thread(target=self.read, daemon=True).start()
        message = ready.get(timeout=30)
        if not message.get('ready'): raise GatewayCrashed('SWIFT_GATEWAY_START_FAILED')
        SwiftGateway.live.append(self)

    def read(self):
        for line in self.process.stdout:
            message = json.loads(line)
            target = self.pending.pop('ready' if 'ready' in message else message.get('id'), None)
            if target is not None: target.put(message)
        with self.lock:
            self.dead = True
            for target in self.pending.values(): target.put({'dead': True})
            self.pending.clear()

    def call(self, method, **params):
        answer = queue.Queue()
        with self.lock:
            if self.dead: raise GatewayCrashed(method)
            self.next += 1; identifier = self.next; self.pending[identifier] = answer
            self.process.stdin.write(json.dumps({'id': identifier, 'method': method, 'params': params}).encode() + b'\n')
            self.process.stdin.flush()
        message = answer.get()
        if message.get('dead'): raise GatewayCrashed(method)
        if 'error' in message: raise RuntimeError(f'{method}: {message["error"]}')
        return message['result']

    @property
    def s(self): return self.call('state')['s']

    @property
    def guest_ack(self): return self.call('state')['guestAck']

    @property
    def crashed(self): return self.dead

    @crashed.setter
    def crashed(self, value):
        if value: self.process.kill(); self.process.wait(timeout=10)

    def attach(self): return self.call('attach', port=self.guest.port, token=self.guest.token)
    def version(self, path): return self.call('version', path=path)['version']
    def acquire(self, operation): return self.call('acquire', operation=operation)

    def native_write(self, path, data, base):
        return self.call('nativeWrite', path=path, data=base64.b64encode(data).decode(), base=base)

    def run_leased(self, operation, argv, timeout=10000, test=None):
        started = time.monotonic()
        try: return self.call('runLeased', operation=operation, argv=argv, timeout=timeout, test=test or {})
        except GatewayCrashed:
            # A killed Python gateway's thread keeps the RPC open until the guest command ends; a killed Swift
            # process cannot. The agent enforces the timeout without the connection, so waiting it out (plus a
            # grace for cgroup.kill and the sweep) bounds when the old writer has stopped, without touching state.
            time.sleep(max(0, started + timeout / 1000 + 2 - time.monotonic()))
            return {'status': 'CRASHED'}

    def reconcile(self):
        process = self.guest.process
        return self.call('reconcile', vmExited=process is not None and process.poll() is not None)

    @classmethod
    def close_all(cls):
        for gateway in cls.live:
            if gateway.process.poll() is None: gateway.process.stdin.close(); gateway.process.wait(timeout=10)
            gateway.stderr.close()
        cls.live = []


def build_swift():
    package = SOURCE / 'gateway'
    subprocess.run(['swift', 'build', '-c', 'release', '--package-path', str(package)], check=True, stdout=subprocess.DEVNULL)
    binary = Path(subprocess.check_output(['swift', 'build', '-c', 'release', '--package-path', str(package), '--show-bin-path'],
                                          text=True).strip()) / 'plan500-gateway'
    return binary, digest(binary)


def prepare(args):
    output = args.out; output.mkdir(parents=True)
    work = output / 'work'; work.mkdir()
    token, inputs = sharing.build(args.runtime, args.modloop, work)
    shutil.copyfile(work / 'initramfs.gz', output / 'initramfs.gz')
    for name in ['Image', 'system.raw']: shutil.copyfile(args.runtime / name, output / name)
    shutil.rmtree(work)
    (output / 'token-private').write_text(token); (output / 'token-private').chmod(0o600)
    manifest = {'inputs': inputs, 'files': {name: digest(output / name) for name in GUEST_FILES},
                'leaseSourceSha256': {p.name: digest(p) for p in LEASE_DIR.iterdir() if p.is_file()},
                'sharedSourceSha256': digest(SOURCE.parent / 'plan500-sharing/run.py')}
    (output / 'inputs.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(json.dumps({'prepared': str(output), 'files': manifest['files']}))
    return 0


def case_sensitive(path):
    probe = Path(tempfile.mkdtemp(dir=path))
    try:
        (probe / 'a').write_text('a')
        return not (probe / 'A').exists()
    finally: shutil.rmtree(probe)


class Volume:
    """Optional case-sensitive APFS sparse image, the default on iPadOS data volumes."""
    def __init__(self, kind, scratch):
        self.kind, self.scratch, self.mount = kind, scratch, None

    def __enter__(self):
        if self.kind == 'default': return self.scratch
        self.image = Path(tempfile.mkdtemp(prefix='plan500-volume-', dir=self.scratch))
        sparse = self.image / 'cs.sparseimage'; self.mount = self.image / 'mnt'; self.mount.mkdir()
        subprocess.run(['hdiutil', 'create', '-quiet', '-size', '4g', '-type', 'SPARSE', '-fs', 'Case-sensitive APFS',
                        '-volname', 'plan500cs', str(sparse)], check=True)
        subprocess.run(['hdiutil', 'attach', '-quiet', '-nobrowse', '-owners', 'on', '-mountpoint', str(self.mount),
                        str(sparse)], check=True)
        return self.mount

    def __exit__(self, *_):
        if self.mount is not None:
            subprocess.run(['hdiutil', 'detach', '-quiet', '-force', str(self.mount)], check=False)
            shutil.rmtree(self.image, ignore_errors=True)


async def darwin_semantics(guest, state):
    """Observations specific to a Darwin host directory; not required checks."""
    semantics = []; ws = guest.workspace
    gateway = lease.Gateway(ws, state, guest)
    await guest.open(); gateway.attach()

    async def leased(source):
        return await asyncio.to_thread(gateway.run_leased, uuid.uuid4().hex, ['/bin/sh', '-c', source], 20000)

    def observe(name, compatible, detail):
        semantics.append({'name': name, 'compatible': bool(compatible), 'detail': detail})

    released = await leased('printf a > CaseName; printf b > casename; ls | grep -ci casename')
    names = sorted(p.name for p in ws.iterdir() if p.name.lower() == 'casename')
    observe('guest can create names differing only by case', released['result']['stdout'].strip() == '2' and len(names) == 2,
            {'guestCount': released['result']['stdout'].strip(), 'hostNames': names, 'code': released['result']['code']})

    nfc, nfd = 'café-nfc', 'café-nfd'
    released = await leased(f"printf c > '{nfc}'; printf d > '{nfd}'; ls | grep -c caf")
    host = sorted(p.name.encode().hex() for p in ws.iterdir() if p.name.startswith('caf'))
    observe('guest NFC and NFD names stay distinct and byte-preserved on the host',
            released['result']['stdout'].strip() == '2' and host == sorted([nfc.encode().hex(), nfd.encode().hex()]),
            {'guestCount': released['result']['stdout'].strip(), 'hostHex': host})

    released = await leased('mkdir -p meta && printf x > meta/run.sh && chmod 755 meta/run.sh && ln -s run.sh meta/link')
    script, link = ws / 'meta/run.sh', ws / 'meta/link'
    observe('guest chmod and symlink are ordinary host mode and symlink',
            released['result']['code'] == 0 and script.stat().st_mode & 0o777 == 0o755 and link.is_symlink(),
            {'mode': oct(script.stat().st_mode & 0o777), 'symlink': link.is_symlink(),
             'xattrs': subprocess.run(['xattr', str(script)], capture_output=True, text=True).stdout.split()})
    (ws / 'host-exec.sh').write_text('#!/bin/sh\necho host-exec\n'); (ws / 'host-exec.sh').chmod(0o755)
    os.symlink('host-exec.sh', ws / 'host-link')
    result = await asyncio.to_thread(guest.rpc, '/execute', {'id': uuid.uuid4().hex, 'projectId': guest.identity,
        'argv': ['/bin/sh', '-c', 'test -x host-exec.sh && readlink host-link && ./host-link'], 'timeoutMs': 5000, 'cwd': '/workspace'})
    observe('host mode and symlink are seen by the guest', result['code'] == 0 and result['stdout'] == 'host-exec.sh\nhost-exec\n',
            {'code': result['code'], 'stdout': result['stdout'], 'stderr': result['stderr'][-200:]})

    # Darwin QEMU creates both through mknod / bind after pthread_fchdir_np (private API). In passthrough and
    # none it then runs fchmodat_nofollow, which has no O_PATH on Darwin and opens the new node: a FIFO is closed
    # as a special file (ENXIO, CVE-2023-2861) and a socket cannot be opened (EOPNOTSUPP), so the node is unlinked.
    # The gateway scan reads regular files only, so whatever was created is removed inside the same lease.
    released = await leased('mkfifo fifo && test -p fifo; r=$?; ls -l fifo 2>&1; rm -f fifo; exit $r')
    observe('guest can create a FIFO on the share', released['result']['code'] == 0,
            {'code': released['result']['code'], 'stdout': released['result']['stdout'][-200:],
             'stderr': released['result']['stderr'][-300:]})
    released = await leased("/opt/node/bin/node -e \"const s=require('net').createServer().on('error',e=>{console.error(e.code);"
                            "process.exit(3)}).listen('sock',()=>{console.log(require('fs').statSync('sock').isSocket()?"
                            "'listening':'not-a-socket');s.close()})\"; r=$?; rm -f sock; exit $r")
    observe('guest can listen on a Unix socket on the share',
            released['result']['code'] == 0 and 'listening' in released['result']['stdout'],
            {'code': released['result']['code'], 'stdout': released['result']['stdout'][-200:],
             'stderr': released['result']['stderr'][-300:]})

    released = await leased("printf one > held; exec 3<held; printf two > held.tmp && mv held.tmp held; cat <&3; cat held")
    observe('rename over a file keeps the open fd on the old inode', released['result']['stdout'] == 'onetwo',
            {'stdout': released['result']['stdout'], 'code': released['result']['code']})

    released = await leased('i=0; while [ $i -lt 400 ]; do printf $i > f$i; i=$((i+1)); done')
    started = time.monotonic(); count = sum(1 for p in ws.iterdir() if p.name.startswith('f'))
    observe('400 small guest writes are all visible on the host after release', count == 400 and len(released['changed']) >= 400,
            {'hostCount': count, 'changed': len(released['changed']), 'scanMs': round((time.monotonic() - started) * 1000)})
    guest.close()
    return semantics


async def terminal_contract(guest, state):
    """Interactive terminal (#17): read-only until a lease, model commands join it, release only at an idle prompt."""
    checks = []; guest.checks = checks; ws = guest.workspace

    def check(name, passed, detail=None):
        checks.append({'name': name, 'passed': bool(passed), 'detail': detail})
        if not passed: raise AssertionError(name + ': ' + json.dumps(detail, ensure_ascii=False, default=str)[:600])

    def rpc(route, body):
        try: return 200, guest.rpc(route, body)
        except urllib.error.HTTPError as error: return error.code, json.load(error)

    class Terminal:
        def __init__(self, cols=80, rows=24, argv=('/bin/bash', '-i')):
            self.id = 'term-' + uuid.uuid4().hex[:12]; self.offset = 0; self.text = ''; self.last = None
            self.opened = guest.rpc('/terminal/open', {'id': self.id, 'projectId': guest.identity, 'argv': list(argv),
                                    'cwd': '/workspace', 'cols': cols, 'rows': rows, 'shellActivity': True,
                                    'env': {'DSH_SESSION_ID': 'probe'}})

        def read(self, wait=500):
            answer = guest.rpc('/terminal/read', {'id': self.id, 'offset': self.offset, 'waitMs': wait})
            self.offset = answer['next']; self.text += base64.b64decode(answer['data']).decode(errors='replace')
            self.last = answer; return answer

        async def until(self, predicate, timeout=15):
            deadline = time.monotonic() + timeout
            while True:
                answer = await asyncio.to_thread(self.read)
                if predicate(answer): return answer
                if time.monotonic() > deadline: raise AssertionError(f'TERMINAL_TIMEOUT: {self.text[-300:]!r} {answer}')

        def write(self, data, lease=None):
            body = {'id': self.id, 'data': base64.b64encode(data.encode()).decode()}
            if lease: body['lease'] = {'epoch': lease['epoch'], 'fence': lease['fence']}
            return rpc('/terminal/write', body)

        def idle(self, answer): return answer['activity']['state'] == 'idle' and not answer['data']

        async def leased(self, gateway, data):
            lease = gateway.acquire('terminal:' + self.id)
            status, answer = self.write(data, lease)
            assert status == 200 and answer['leased'], answer
            return lease

        async def release(self, gateway, lease, timeout=20):
            await self.until(lambda x: x['releasable'], timeout)
            status, answer = rpc('/terminal/unlease', {'id': self.id, 'fence': lease['fence']})
            if status == 200 and answer['writerQuiescent']:
                with gateway.lock: return {**gateway.release('COMPLETED'), 'unlease': answer}
            return {'status': 'HELD', 'unlease': answer}

    gateway = lease.Gateway(ws, state, guest)
    ready = await guest.open(); gateway.attach()
    check('ready: devpts is mounted for terminals', ready.get('terminal') is True, ready)

    term = Terminal()
    await term.until(lambda x: term.text.rstrip().endswith('$') and x['activity']['state'] == 'idle')
    check('bash -i opens on a pty at /workspace and reports an idle prompt',
          term.opened['pid'] > 0 and term.opened['shellActivity'] and '/workspace$' in term.text and not term.last['leased'],
          {'opened': term.opened, 'tail': term.text[-120:], 'activity': term.last['activity']})

    term.write('printf x > unleased; mount -o remount,rw /workspace; echo done-$?\r')
    await term.until(lambda x: 'done-' in term.text and term.idle(x))
    check('an unleased terminal command cannot write the workspace or remount it',
          'Read-only file system' in term.text and 'done-0' not in term.text and not (ws / 'unleased').exists(), term.text[-300:])

    term.write('stty size; tty\r')
    await term.until(lambda x: '/dev/pts/' in term.text and term.idle(x))
    status, resized = rpc('/terminal/resize', {'id': term.id, 'cols': 101, 'rows': 31})
    term.text = ''; term.write('stty size\r')
    await term.until(lambda x: '31 101' in term.text and term.idle(x))
    check('resize reaches the pty', status == 200 and '31 101' in term.text, {'resized': resized, 'tail': term.text[-80:]})

    term.text = ''
    lease_ = await term.leased(gateway, 'printf one > from-terminal; echo wrote-$?\r')
    released = await term.release(gateway, lease_)
    # The idle state is written before the echoed output has crossed the pty, so read on to the prompt.
    await term.until(lambda x: 'wrote-' in term.text and term.idle(x))
    check('a leased line writes through the terminal view and releases at the idle prompt',
          released['status'] == 'RELEASED' and 'from-terminal' in released['changed']
          and (ws / 'from-terminal').read_text() == 'one' and 'wrote-0' in term.text, {'released': released, 'tail': term.text[-200:]})
    term.write('printf again > from-terminal\r')
    await term.until(lambda x: term.idle(x) and 'again' in term.text and term.text.rstrip().endswith('$'))
    check('after release the terminal view is read-only again', (ws / 'from-terminal').read_text() == 'one'
          and 'Read-only file system' in term.text, term.text[-200:])

    term.text = ''
    lease_ = await term.leased(gateway, 'sleep 6; printf done > slept\r')
    await term.until(lambda x: x['activity']['state'] == 'busy', 5)
    status, busy = await asyncio.to_thread(rpc, '/execute', {'id': uuid.uuid4().hex, 'projectId': guest.identity,
        'argv': ['/bin/sh', '-c', 'true'], 'timeoutMs': 1000, 'cwd': '/workspace', 'lease': {'epoch': lease_['epoch'], 'fence': lease_['fence'] + 1}})
    check('a separate lease is refused while a terminal command holds it', status == 409 and busy['error'] == 'LEASE_BUSY', busy)
    status, joined = await asyncio.to_thread(rpc, '/execute', {'id': uuid.uuid4().hex, 'projectId': guest.identity,
        'argv': ['/bin/sh', '-c', 'printf model > joined; sleep 30 & echo bg'], 'timeoutMs': 5000, 'cwd': '/workspace',
        'lease': {'epoch': lease_['epoch'], 'fence': lease_['fence']}, 'join': term.id})
    check('a model command joins the running terminal lease and writes; its stragglers are stopped',
          status == 200 and joined['joined'] and joined['code'] == 0 and joined['writerQuiescent'] and joined['stragglersKilled'] >= 1, joined)
    early = rpc('/terminal/unlease', {'id': term.id, 'fence': lease_['fence']})
    released = await term.release(gateway, lease_)
    check('release waits for the terminal command; joined and terminal writes both land',
          early[1].get('reason') == 'BUSY' and released['status'] == 'RELEASED'
          and {'joined', 'slept'} <= set(released['changed']), {'early': early, 'released': released})

    term.text = ''
    lease_ = await term.leased(gateway, 'exec 3>held; echo opened\r')
    await term.until(lambda x: 'opened' in term.text and x['activity']['state'] == 'idle')
    status, refused = rpc('/terminal/unlease', {'id': term.id, 'fence': lease_['fence']})
    answer = await asyncio.to_thread(term.read, 300)
    check('an idle prompt that still holds a file open for writing keeps the lease',
          status == 200 and refused == {'writerQuiescent': False, 'reason': 'WRITERS_OPEN'} and answer['leased'] and not answer['releasable'],
          {'refused': refused, 'answer': {k: answer[k] for k in ['leased', 'releasable', 'activity']}})
    term.write('exec 3>&-\r', lease_)
    released = await term.release(gateway, lease_)
    check('closing the writer lets the same lease release', released['status'] == 'RELEASED', released)

    term.text = ''
    lease_ = await term.leased(gateway, 'cat\r')
    await term.until(lambda x: x['activity']['state'] == 'busy', 5)
    await asyncio.sleep(.3)
    inspected = guest.rpc('/terminal/inspect', {'id': term.id})
    _, interrupted = rpc('/terminal/signal', {'id': term.id, 'signal': 'SIGINT'})
    released = await term.release(gateway, lease_)
    check('inspect sees the foreground job waiting for input and SIGINT reaches it',
          inspected['foreground']['processGroupId'] != term.opened['pid'] and inspected['foreground']['inputWaiting']
          and interrupted['processGroupId'] == inspected['foreground']['processGroupId'] and released['status'] == 'RELEASED',
          {'inspected': inspected, 'interrupted': interrupted, 'released': released['status']})
    status, refusal = rpc('/terminal/signal', {'id': term.id, 'signal': 'SIGKILL'})
    check('SIGKILL to the shell itself is refused', status == 409 and refusal['error'] == 'SHELL_KILL_REFUSED', refusal)

    released = await asyncio.to_thread(gateway.run_leased, uuid.uuid4().hex, ['/bin/sh', '-c', 'printf y > op-file'], 5000)
    answer = await asyncio.to_thread(term.read, 0)
    check('another leased command sweeps leaks without killing the open terminal',
          released['status'] == 'RELEASED' and not released['result']['leakedKilled'] and answer['exited'] is None
          and answer['activity']['state'] == 'idle', {'released': released, 'answer': answer})

    term.text = ''
    lease_ = await term.leased(gateway, 'sleep 30\r')
    await term.until(lambda x: x['activity']['state'] == 'busy', 5)
    revoked = guest.rpc('/revoke', {'epoch': lease_['epoch'], 'fence': lease_['fence']})
    status, gone = rpc('/terminal/read', {'id': term.id, 'offset': 0})
    with gateway.lock: gateway.release('RECONCILED')
    check('revoking a terminal lease ends that terminal', revoked['revoked'] and status == 409 and gone['error'] == 'TERMINAL_NOT_FOUND',
          {'revoked': revoked, 'read': gone})

    term = Terminal(argv=('/bin/bash', '-i'))
    await term.until(lambda x: term.idle(x) and term.text.rstrip().endswith('$'))
    lease_ = await term.leased(gateway, 'printf bye > exiting; (sleep 30 &); exit 3\r')
    answer = await term.until(lambda x: x['exited'] is not None)
    released = await term.release(gateway, lease_)
    closed = guest.rpc('/terminal/close', {'id': term.id, 'graceMs': 100})
    check('shell exit reports its code, leftovers are drained, and the lease releases',
          answer['exited'] == {'code': 3, 'signal': None} and released['status'] == 'RELEASED' and 'exiting' in released['changed']
          and closed['closed'], {'exited': answer['exited'], 'released': released, 'closed': closed})

    term = Terminal()
    await term.until(lambda x: term.idle(x) and term.text.rstrip().endswith('$'))
    lease_ = await term.leased(gateway, 'sleep 30\r')
    closed = guest.rpc('/terminal/close', {'id': term.id, 'graceMs': 200})
    if closed['releasedFence'] == lease_['fence']:
        with gateway.lock: gateway.release('COMPLETED')
    check('closing a busy leased terminal ends it and gives the lease back', closed == {'closed': True, 'releasedFence': lease_['fence']}, closed)

    plain = rpc('/terminal/open', {'id': 'bad', 'projectId': guest.identity, 'argv': ['/usr/bin/python3'], 'cwd': '/workspace'})
    outside = rpc('/terminal/open', {'id': 'bad2', 'projectId': guest.identity, 'argv': ['/bin/bash', '-i'], 'cwd': '/tmp'})
    check('only allowed shells inside the workspace can open a terminal',
          plain[1].get('error') == 'ARGV_REFUSED' and outside[1].get('error') == 'CWD_REFUSED', [plain, outside])
    guest.close()
    return {'checks': checks, 'completed': all(x['passed'] for x in checks)}


async def run_probe(args):
    if platform.system() != 'Darwin': raise SystemExit('probe runs on macOS')
    manifest = json.loads((args.inputs / 'inputs.json').read_text())
    for name, expected in manifest['files'].items(): assert digest(args.inputs / name) == expected, 'INPUT_HASH_MISMATCH'
    current = {p.name: digest(p) for p in LEASE_DIR.iterdir() if p.is_file()}
    for name in ['init.sh', 'agent.cjs']:
        assert current[name] == manifest['leaseSourceSha256'][name], 'GUEST_SOURCE_CHANGED_SINCE_PREPARE'
    token = (args.inputs / 'token-private').read_text().strip()
    swift = None
    if args.gateway == 'swift':
        SwiftGateway.binary, binarySha = build_swift(); lease.Gateway = SwiftGateway
        swift = {'binarySha256': binarySha, 'swift': subprocess.check_output(['swift', '--version'], text=True,
                 stderr=subprocess.STDOUT).splitlines()[0],
                 'sourceSha256': {str(p.relative_to(SOURCE / 'gateway')): digest(p) for p in sorted((SOURCE / 'gateway').rglob('*'))
                                  if p.is_file() and not any(x.startswith('.') for x in p.relative_to(SOURCE / 'gateway').parts)}}
    results = []
    with Volume(args.volume, args.scratch) as root:
        output = Path(tempfile.mkdtemp(prefix='plan500-darwin-', dir=root))
        os.symlink(args.inputs.resolve() / 'initramfs.gz', output / 'initramfs.gz')
        caseSensitive = case_sensitive(output)
        for model in args.models:
            entry = {'model': model}
            for phase in args.phases:
                guest = GatedGuest(args.inputs.resolve(), output, token, f'{model}-{phase}')
                guest.model = model
                state = output / f'gateway-{model}-{phase}'; state.mkdir()
                try:
                    if phase == 'contract': entry.update(await lease.probe(guest, state))
                    elif phase == 'darwin': entry['darwinSemantics'] = await darwin_semantics(guest, state)
                    else: entry['terminal'] = await terminal_contract(guest, state)
                except Exception as error:
                    entry['completed'] = False; entry.setdefault('errors', []).append(f'{phase}: {type(error).__name__}: {error}')
                    (output / f'{model}-{phase}-traceback-private.log').write_text(traceback.format_exc())
                    entry.setdefault('checks', getattr(guest, 'checks', [])); entry.setdefault('semantics', getattr(guest, 'semantics', []))
                finally:
                    guest.close(); SwiftGateway.close_all()
                    for kind in ['serial', 'qemu']:  # both phases share the model's log names; keep each phase's copy
                        log = output / f'{model}-{kind}-private.log'
                        if log.exists(): log.rename(output / f'{model}-{phase}-{kind}-private.log')
            entry['completed'] = entry.get('completed', 'contract' not in args.phases) and not entry.get('errors')
            results.append(entry)
        report = {'completed': all(x['completed'] for x in results), 'platform': 'macOS QEMU 9P (Darwin local fsdev)',
                  'host': {'macOS': platform.mac_ver()[0], 'machine': platform.machine(), 'volume': args.volume,
                           'caseSensitive': caseSensitive},
                  'qemu': subprocess.check_output(['qemu-system-aarch64', '--version'], text=True).splitlines()[0],
                  'gateway': args.gateway, 'swift': swift, 'inputs': manifest, 'models': results,
                  'DarwinVerified': True, 'iPadVerified': False, 'swiftGateway': args.gateway == 'swift',
                  'sourceSha256': {p.name: digest(p) for p in SOURCE.iterdir() if p.is_file()}, 'leaseSourceSha256': current}
        receipt = args.scratch / f'plan500-darwin-{args.volume}-{args.gateway}-result-safe.json'
        receipt.write_text(json.dumps(report, indent=2, ensure_ascii=False) + '\n')
        if args.keep and args.volume != 'default':
            # The sparse image is always detached and removed, so private logs are copied out first.
            kept = args.scratch / f'{output.name}-kept'
            shutil.copytree(output, kept, symlinks=True)
            print(json.dumps({'kept': str(kept)}), flush=True)
        if not args.keep or args.volume != 'default': shutil.rmtree(output, ignore_errors=True)
    print(json.dumps({'completed': report['completed'], 'volume': args.volume, 'gateway': args.gateway, 'caseSensitive': caseSensitive,
                      'models': [{'model': r['model'], 'completed': r['completed'], 'passed': sum(c['passed'] for c in r.get('checks', [])),
                                  'terminalPassed': sum(c['passed'] for c in r.get('terminal', {}).get('checks', [])),
                                  'errors': r.get('errors')} for r in results], 'receipt': str(receipt)}, ensure_ascii=False), flush=True)
    return 0 if report['completed'] else 1


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    p = sub.add_parser('prepare'); p.add_argument('--runtime', type=Path, required=True)
    p.add_argument('--modloop', type=Path, required=True); p.add_argument('--out', type=Path, required=True)
    p = sub.add_parser('probe'); p.add_argument('--inputs', type=Path, required=True)
    p.add_argument('--scratch', type=Path, required=True)
    p.add_argument('--volume', choices=['default', 'case-sensitive'], default='case-sensitive')
    p.add_argument('--models', nargs='+', choices=['mapped-xattr', 'none'], default=['none', 'mapped-xattr'])
    p.add_argument('--gateway', choices=['python', 'swift'], default='python')
    p.add_argument('--phases', nargs='+', choices=['contract', 'darwin', 'terminal'], default=['contract', 'darwin', 'terminal'])
    p.add_argument('--keep', action='store_true')
    args = parser.parse_args()
    sys.exit(prepare(args) if args.command == 'prepare' else asyncio.run(run_probe(args)))
