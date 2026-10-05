#!/usr/bin/env python3
"""Linux-only write-lease/version/generation probe on real QEMU 9P. No user disk is opened."""
import argparse
import asyncio
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import time
import urllib.error
import uuid

SOURCE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('plan500_sharing', SOURCE.parent / 'plan500-sharing/run.py')
sharing = importlib.util.module_from_spec(spec); spec.loader.exec_module(sharing)
# Reuse the verified initramfs builder and QEMU launcher; pack this directory's init/agent.
sharing.SOURCE = SOURCE
Guest, digest = sharing.Guest, sharing.digest
RPC_ERRORS = (OSError, urllib.error.URLError)


def fingerprint(path):
    if path.is_symlink(): return ['L', os.readlink(path)]
    return ['F', digest(path), path.stat().st_mode & 0o777]


def scan(workspace):
    found = {}
    for directory, folders, files in os.walk(workspace):
        base = Path(directory)
        for name in files + [x for x in folders if (base / x).is_symlink()]:
            path = base / name; relative = str(path.relative_to(workspace))
            if relative == '.plan500-identity' or name.startswith('.plan500-tmp-'): continue
            found[relative] = fingerprint(path)
    return found


def token(entry):
    if entry is None: return None
    return f"{entry['g']}:{hashlib.sha256(json.dumps(entry['fp']).encode()).hexdigest()[:16]}"


class Gateway:
    """Stand-in for the Swift workspace gateway: sole issuer of write leases and change generations."""

    def __init__(self, workspace, state, guest):
        self.workspace, self.state_dir, self.guest = workspace, state, guest
        self.file = state / 'gateway.json'; self.drafts = state / 'drafts'
        self.drafts.mkdir(parents=True, exist_ok=True)
        self.lock = threading.RLock(); self.crashed = False; self.guest_ack = 0
        if self.file.exists():
            self.s = json.loads(self.file.read_text())
            # A restarted gateway cannot prove a previous writer is gone.
            if self.s['lease']: self.s['lease']['state'] = 'WRITER_UNKNOWN'
        else:
            self.s = {'epoch': 1, 'generation': 0, 'fence': 0, 'lease': None, 'drafts': [], 'log': [],
                      'versions': {p: {'g': 0, 'fp': fp} for p, fp in scan(workspace).items()}}
        self.persist()

    def persist(self):
        temporary = self.state_dir / '.gateway-tmp'
        with temporary.open('w') as stream:
            json.dump(self.s, stream); stream.flush(); os.fsync(stream.fileno())
        os.replace(temporary, self.file)
        directory = os.open(self.state_dir, os.O_RDONLY); os.fsync(directory); os.close(directory)

    def version(self, path): return token(self.s['versions'].get(path))

    def attach(self):
        bound = self.guest.rpc('/bind', {'epoch': self.s['epoch']})
        self.guest_ack = bound['generation']; self.notify(); return bound

    def notify(self):
        entries = [x for x in self.s['log'] if x['generation'] > self.guest_ack]
        if not entries: return True
        try: self.guest_ack = self.guest.rpc('/notify', {'entries': entries})['generation']; return True
        except RPC_ERRORS: return False

    def commit(self, paths, origin, current=None):
        current = scan(self.workspace) if current is None else current
        self.s['generation'] += 1; generation = self.s['generation']
        for path in paths:
            if path in current: self.s['versions'][path] = {'g': generation, 'fp': current[path]}
            else: self.s['versions'].pop(path, None)
        self.s['log'].append({'generation': generation, 'origin': origin, 'paths': sorted(paths)})
        self.persist(); self.notify(); return generation

    def resolve(self, path):
        target = (self.workspace / path).resolve()
        assert not Path(path).is_absolute() and str(target).startswith(str(self.workspace) + '/'), 'PATH_REFUSED'
        return self.workspace / path

    def write_now(self, path, data, base):
        current = self.s['versions'].get(path)
        if token(current) != base: return {'status': 'CONFLICT', 'reason': 'VERSION', 'current': token(current)}
        target = self.resolve(path)
        disk = fingerprint(target) if target.exists() or target.is_symlink() else None
        if disk != (current['fp'] if current else None):
            # Another host writer bypassed the gateway; record it and refuse to overwrite.
            self.commit([path], 'external')
            return {'status': 'CONFLICT', 'reason': 'EXTERNAL_CHANGE', 'current': self.version(path)}
        target.parent.mkdir(parents=True, exist_ok=True)
        temporary = target.parent / ('.plan500-tmp-' + uuid.uuid4().hex)
        with temporary.open('wb') as stream:
            stream.write(data); stream.flush(); os.fsync(stream.fileno())
        if disk: os.chmod(temporary, disk[2])
        os.replace(temporary, target)
        directory = os.open(target.parent, os.O_RDONLY); os.fsync(directory); os.close(directory)
        self.commit([path], 'native')
        return {'status': 'WRITTEN', 'version': self.version(path)}

    def native_write(self, path, data, base):
        with self.lock:
            assert not self.crashed
            if self.s['lease']:
                identifier = uuid.uuid4().hex; blob = self.drafts / identifier
                with blob.open('wb') as stream:
                    stream.write(data); stream.flush(); os.fsync(stream.fileno())
                self.s['drafts'].append({'id': identifier, 'path': path, 'base': base, 'status': 'HELD'})
                self.persist()
                return {'status': 'DRAFT_HELD', 'draft': identifier}
            return self.write_now(path, data, base)

    def acquire(self, operation):
        with self.lock:
            if self.s['lease']: return None
            self.s['fence'] += 1
            self.s['lease'] = {'op': operation, 'epoch': self.s['epoch'], 'fence': self.s['fence'],
                               'state': 'ACTIVE', 'baseline': scan(self.workspace)}
            self.persist()  # The grant is durable before any request leaves the gateway.
            return dict(self.s['lease'])

    def run_leased(self, operation, argv, timeout=10000, test=None):
        lease = self.acquire(operation)
        if lease is None: return {'status': 'LEASE_BUSY'}
        request = {'id': operation, 'projectId': self.guest.identity, 'argv': argv, 'timeoutMs': timeout,
                   'cwd': '/workspace', 'lease': {'epoch': lease['epoch'], 'fence': lease['fence']}, **(test or {})}
        try: result = self.guest.rpc('/execute', request)
        except urllib.error.HTTPError as error:
            if self.crashed: return {'status': 'CRASHED'}
            # Every agent refusal happens before spawn; nothing can still hold the rw view.
            with self.lock: return {**self.release('REFUSED'), 'refusal': json.load(error)['error']}
        except RPC_ERRORS:
            if self.crashed: return {'status': 'CRASHED'}
            with self.lock: self.s['lease']['state'] = 'WRITER_UNKNOWN'; self.persist()
            return {'status': 'WRITER_UNKNOWN'}
        if self.crashed: return {'status': 'CRASHED'}
        with self.lock:
            if not result.get('writerQuiescent'):
                self.s['lease']['state'] = 'WRITER_UNKNOWN'; self.persist()
                return {'status': 'WRITER_UNKNOWN', 'result': result}
            return {**self.release('COMPLETED'), 'result': result}

    def release(self, reason):
        current = scan(self.workspace); baseline = self.s['lease']['baseline']
        changed = [p for p in set(baseline) | set(current) if baseline.get(p) != current.get(p)]
        fence = self.s['lease']['fence']; self.s['lease'] = None
        generation = self.commit(changed, 'linux', current) if changed else self.s['generation']
        drafts = self.rebase()
        return {'status': 'RELEASED', 'reason': reason, 'fence': fence, 'generation': generation,
                'changed': sorted(changed), 'drafts': drafts}

    def rebase(self):
        outcomes = []
        for draft in [x for x in self.s['drafts'] if x['status'] == 'HELD']:
            result = self.write_now(draft['path'], (self.drafts / draft['id']).read_bytes(), draft['base'])
            draft['status'] = 'APPLIED' if result['status'] == 'WRITTEN' else 'CONFLICT'
            outcomes.append({'path': draft['path'], 'status': draft['status'], 'current': self.version(draft['path'])})
        self.persist(); return outcomes

    def reconcile(self):
        with self.lock:
            lease = self.s['lease']
            if lease is None: return {'status': 'NO_LEASE'}
            if self.guest.process is not None and self.guest.process.poll() is not None:
                # The VM is confirmed gone; the next boot gets a new epoch that old leases cannot use.
                self.s['epoch'] += 1; self.guest_ack = 0
                return self.release('GUEST_TERMINATED')
            try: status = self.guest.rpc('/revoke', {'epoch': lease['epoch'], 'fence': lease['fence']})
            except RPC_ERRORS: return {'status': 'HELD', 'reason': 'UNREACHABLE'}
            if not status['revoked']: return {'status': 'HELD', 'reason': 'WRITER_RUNNING'}
            return {**self.release('RECONCILED'), 'started': status['started']}


async def until(predicate, timeout=8, step=.02):
    deadline = time.monotonic() + timeout
    while not predicate():
        if time.monotonic() > deadline: raise RuntimeError('FIXTURE_TIMEOUT')
        await asyncio.sleep(step)


async def probe(guest, state):
    checks, semantics, timings = [], [], {}; guest.checks = checks; guest.semantics = semantics
    def check(name, passed, detail=None):
        checks.append({'name': name, 'passed': bool(passed), 'detail': detail})
        if not passed: raise AssertionError(name + ': ' + json.dumps(detail, ensure_ascii=False, default=str)[:600])
    def observe(name, compatible, detail):
        semantics.append({'name': name, 'compatible': bool(compatible), 'detail': detail})
    ws = guest.workspace
    def execute(argv, owner=False, timeout=10000):
        request = {'id': uuid.uuid4().hex, 'projectId': guest.identity, 'argv': argv, 'timeoutMs': timeout,
                   'cwd': '/workspace', 'asOwner': owner}
        return asyncio.to_thread(guest.rpc, '/execute', request)
    run = lambda source, **kw: execute(['/bin/sh', '-c', source], **kw)
    async def lease(gateway, source, operation=None, timeout=10000, test=None):
        return await asyncio.to_thread(gateway.run_leased, operation or uuid.uuid4().hex,
                                       ['/bin/sh', '-c', source], timeout, test)
    def refused(request):
        try: guest.rpc('/execute', request)
        except urllib.error.HTTPError as error: return error.code, json.load(error)['error']
        return 200, None

    (ws / 'src').mkdir(); (ws / 'src/app.js').write_text('base-app'); (ws / 'notes.md').write_text('base-notes')
    gateway = Gateway(ws, state, guest)
    ready = await guest.open()
    check('ready: 9P exposed read-only nosuid, cgroup.kill, owner/reader uids and userns disabled',
          ready['workspaceReadOnly'] and 'nosuid' in ready['mountOptions'].split(',') and ready['cgroupKill']
          and ready['commandUid'] == os.getuid() and ready['readerUid'] == 65534 and ready['userNamespaces'] == 0, ready)
    gateway.attach()

    result = await run('printf x > notes.md', owner=True)
    check('unleased write is refused by the kernel even as the owner uid', result['code'] != 0 and 'Read-only' in result['stderr']
          and (ws / 'notes.md').read_text() == 'base-notes', result)
    result = await run('cat notes.md; id -u')
    check('unleased reader uid can read the workspace', result['code'] == 0 and result['stdout'] == 'base-notes65534\n', result)
    escapes = {
        'remount': 'mount -o remount,rw /workspace', 'privateShare': 'cat /run/ws/rw/notes.md',
        'userNamespace': 'unshare -Urm true', 'cgroupEscape': 'echo $$ > /sys/fs/cgroup/cgroup.procs'}
    outcomes = {}
    for name, source in escapes.items():
        result = await run(source, owner=True); outcomes[name] = {'code': result['code'], 'stderr': result['stderr'][-160:]}
    check('owner uid cannot remount, reach the rw share, create user namespaces or leave its cgroup',
          all(x['code'] != 0 for x in outcomes.values()), outcomes)

    v0 = gateway.version('notes.md')
    first = gateway.native_write('notes.md', b'native-A', v0); second = gateway.native_write('notes.md', b'native-B', v0)
    create = gateway.native_write('notes.md', b'native-C', None)
    check('native CAS: stale base and create-over-existing conflict without overwrite',
          first['status'] == 'WRITTEN' and second['status'] == 'CONFLICT' and create['status'] == 'CONFLICT'
          and (ws / 'notes.md').read_text() == 'native-A', [first, second, create])

    g0 = gateway.s['generation']
    consumer = ("const f=require('fs');const g0=Number(process.argv[1]);f.writeFileSync('/tmp/consumer-ready','1');"
                "const t0=Date.now();(function poll(){const s=JSON.parse(f.readFileSync('/run/plan500/generation','utf8'));"
                "if(s.generation>g0){const e=f.readFileSync('/run/plan500/changes.jsonl','utf8').trim().split('\\n').map(JSON.parse)"
                ".filter(x=>x.generation>g0);console.log(JSON.stringify({generation:s.generation,paths:e.flatMap(x=>x.paths),"
                "content:f.readFileSync('notes.md','utf8'),waitedMs:Date.now()-t0}));return}"
                "if(Date.now()-t0>8000){console.log('{\"timeout\":true}');return}setTimeout(poll,25)})()")
    task = asyncio.create_task(guest.execute(['/opt/node/bin/node', '-e', consumer, str(g0)]))
    for _ in range(200):
        if (await run('test -e /tmp/consumer-ready'))['code'] == 0: break
        await asyncio.sleep(.02)
    written = gateway.native_write('notes.md', b'native-D', gateway.version('notes.md'))
    seen = json.loads((await task)['stdout'])
    timings['guestGenerationPollMs'] = seen.get('waitedMs')
    check('guest generation poll observes native write with path and content', written['status'] == 'WRITTEN'
          and seen.get('generation') == gateway.s['generation'] and seen.get('paths') == ['notes.md']
          and seen.get('content') == 'native-D', seen)

    v_app, v_notes = gateway.version('src/app.js'), gateway.version('notes.md')
    task = asyncio.create_task(lease(gateway, 'printf guest-change > src/app.js; sleep 1.2'))
    await until(lambda: (ws / 'src/app.js').read_text() == 'guest-change')
    held = [gateway.native_write('src/app.js', b'native-app', v_app), gateway.native_write('notes.md', b'native-notes', v_notes)]
    check('native edits during a Linux lease become held drafts', all(x['status'] == 'DRAFT_HELD' for x in held)
          and (ws / 'notes.md').read_text() == 'native-D' and (ws / 'src/app.js').read_text() == 'guest-change', held)
    released = await task
    drafts = {x['path']: x['status'] for x in released.get('drafts', [])}
    check('release rescans Linux changes into one generation and rebases drafts',
          released['status'] == 'RELEASED' and released['changed'] == ['src/app.js']
          and drafts == {'src/app.js': 'CONFLICT', 'notes.md': 'APPLIED'}
          and (ws / 'src/app.js').read_text() == 'guest-change' and (ws / 'notes.md').read_text() == 'native-notes'
          and gateway.guest_ack == gateway.s['generation'], released)

    git = "git -c safe.directory=/workspace -c user.name=Prototype -c user.email=prototype@example.invalid"
    released = await lease(gateway, f'{git} init -q && {git} add -A && {git} commit -qm init')
    check('real Git transaction under lease commits and reports .git changes',
          released['status'] == 'RELEASED' and released['result']['code'] == 0
          and any(p.startswith('.git/') for p in released['changed']), {k: released.get(k) for k in ['status', 'result']})
    result = await run(f'{git} log --oneline')
    check('read-only Git history works outside a lease', result['code'] == 0 and 'init' in result['stdout'])
    result = await run(f'{git} status --porcelain')
    observe('git status runs in the read-only view', result['code'] == 0, {'code': result['code'], 'stderr': result['stderr'][-300:]})

    old_fence = released['fence']
    stale = refused({'id': uuid.uuid4().hex, 'projectId': guest.identity, 'argv': ['/bin/sh', '-c', 'touch stale-effect'],
                     'timeoutMs': 1000, 'cwd': '/workspace', 'lease': {'epoch': gateway.s['epoch'], 'fence': old_fence}})
    epoch = refused({'id': uuid.uuid4().hex, 'projectId': guest.identity, 'argv': ['/bin/sh', '-c', 'touch epoch-effect'],
                     'timeoutMs': 1000, 'cwd': '/workspace', 'lease': {'epoch': gateway.s['epoch'] + 7, 'fence': 10 ** 6}})
    check('agent rejects reused fence and foreign epoch without effects',
          stale == (409, 'LEASE_STALE') and epoch == (409, 'LEASE_EPOCH_MISMATCH')
          and not (ws / 'stale-effect').exists() and not (ws / 'epoch-effect').exists(), [stale, epoch])

    released = await lease(gateway, "setsid sh -c 'echo $$ > /sys/fs/cgroup/cgroup.procs 2>/dev/null; "
                           "while :; do echo x >> daemon-writes; sleep .05; done' </dev/null >/dev/null 2>&1 & sleep .3")
    size = (ws / 'daemon-writes').stat().st_size; await asyncio.sleep(1)
    check('escaped setsid writer is killed before lease release; no later writes',
          released['status'] == 'RELEASED' and released['result']['stragglersKilled'] >= 1
          and (ws / 'daemon-writes').stat().st_size == size and size > 0, released.get('result'))

    released = await lease(gateway, 'printf a > timed; sleep 5; printf b >> timed', timeout=400)
    check('timeout kills the lease cgroup, then releases with partial effects reported',
          released['status'] == 'RELEASED' and released['result']['timeout'] and (ws / 'timed').read_text() == 'a'
          and 'timed' in released['changed'], released.get('result'))
    operation = uuid.uuid4().hex
    task = asyncio.create_task(lease(gateway, 'touch cancel-ready; sleep 5; touch cancel-late', operation))
    await until(lambda: (ws / 'cancel-ready').exists())
    await asyncio.to_thread(guest.rpc, '/cancel', {'id': operation})
    released = await task
    check('cancel kills the lease cgroup before release', released['status'] == 'RELEASED'
          and released['result']['cancelled'] and not (ws / 'cancel-late').exists(), released.get('result'))

    await run("setsid sh -c 'while :; do (printf y >> bg-write) 2>>/tmp/bg-err; sleep .1; done' </dev/null >/dev/null 2>&1 &", owner=True)
    released = await lease(gateway, 'sleep .6; printf leased > during-bg')
    errors = (await run('cat /tmp/bg-err'))['stdout']
    check('long-running unleased process stays read-only while another command holds the lease',
          released['status'] == 'RELEASED' and not (ws / 'bg-write').exists() and (ws / 'during-bg').exists()
          and 'Read-only' in errors, errors[-200:])

    # A same-uid outside process can walk /proc/<leased>/cwd into the private rw mount and keep the fd.
    async def magic_link(tag, owner, test=None):
        attacker = (f"setsid sh -c 'while [ ! -s /tmp/lpid-{tag} ]; do sleep .02; done; pid=$(cat /tmp/lpid-{tag}); "
                    f"if true 2>/dev/null 3>>/proc/$pid/cwd/leak-{tag}; then exec 3>>/proc/$pid/cwd/leak-{tag}; "
                    f"echo opened > /tmp/lres-{tag}; while :; do echo x >&3; sleep .05; done; "
                    f"else echo denied > /tmp/lres-{tag}; fi' </dev/null >/dev/null 2>&1 &")
        await run(attacker, owner=owner)
        released = await lease(gateway, f'echo $$ > /tmp/lpid-{tag}; i=0; while [ ! -s /tmp/lres-{tag} ] && [ $i -lt 100 ]; '
                               'do sleep .05; i=$((i+1)); done; sleep .5', test=test)
        outcome = (await run(f'cat /tmp/lres-{tag}'))['stdout'].strip()
        return released, outcome
    released, outcome = await magic_link('reader', False)
    check('reader uid cannot open the leased namespace through /proc/<pid>/cwd',
          released['status'] == 'RELEASED' and outcome == 'denied' and not (ws / 'leak-reader').exists(), outcome)
    released, outcome = await magic_link('owner', True)
    leak = ws / 'leak-owner'
    observe('same-uid unleased process cannot write through /proc/<leased>/cwd during the lease',
            not leak.exists(), {'outcome': outcome, 'capturedByRelease': 'leak-owner' in released.get('changed', [])})
    size = leak.stat().st_size if leak.exists() else 0; await asyncio.sleep(1)
    check('release sweep kills outside holders of the leased mount; no writes after release',
          released['status'] == 'RELEASED' and outcome == 'opened' and size > 0
          and any(x['kind'] == 'fd' for x in released['result']['leakedKilled']) and leak.stat().st_size == size,
          released.get('result', {}).get('leakedKilled'))
    released, outcome = await magic_link('control', True, {'testSkipSweep': True})
    leak = ws / 'leak-control'; released_size = leak.stat().st_size
    await asyncio.sleep(1); later_size = leak.stat().st_size
    cleanup = await lease(gateway, 'true')
    swept_size = leak.stat().st_size; await asyncio.sleep(.5)
    check('negative control: without the sweep the leaked fd keeps writing after release; next sweep stops it',
          released['status'] == 'RELEASED' and outcome == 'opened' and released['result']['leakedKilled'] == []
          and later_size > released_size and any(x['kind'] == 'fd' for x in cleanup['result']['leakedKilled'])
          and leak.stat().st_size == swept_size,
          {'released': released_size, 'oneSecondLater': later_size, 'cleanup': cleanup['result']['leakedKilled']})

    v_notes = gateway.version('notes.md')
    task = asyncio.create_task(lease(gateway, 'for i in 1 2 3 4 5 6 7 8; do echo $i >> disconnected; sleep .15; done'))
    await until(lambda: (ws / 'disconnected').exists())
    await asyncio.to_thread(guest.rpc, '/test/sever', {'ms': 1500})
    lost = await task; during = gateway.reconcile()
    draft = gateway.native_write('notes.md', b'after-disconnect', v_notes)
    check('RPC loss mid-lease keeps the lease held and drafts native edits', lost['status'] == 'WRITER_UNKNOWN'
          and during == {'status': 'HELD', 'reason': 'UNREACHABLE'} and draft['status'] == 'DRAFT_HELD'
          and gateway.s['lease'] is not None, [lost, during, draft])
    for _ in range(100):
        released = gateway.reconcile()
        if released['status'] == 'RELEASED': break
        await asyncio.sleep(.1)
    check('reconcile after reconnect releases only when the writer finished',
          released['status'] == 'RELEASED' and (ws / 'disconnected').read_text().split() == list('12345678')
          and 'disconnected' in released['changed'] and released['drafts'] == [
              {'path': 'notes.md', 'status': 'APPLIED', 'current': gateway.version('notes.md')}], released)

    v_notes = gateway.version('notes.md')
    task = asyncio.create_task(lease(gateway, 'touch restart-ready; sleep 1; printf done > restart-effect'))
    await until(lambda: (ws / 'restart-ready').exists())
    gateway.crashed = True
    gateway = Gateway(ws, state, guest); gateway.attach()
    draft = gateway.native_write('notes.md', b'after-restart', v_notes)
    persisted = json.loads((state / 'gateway.json').read_text())
    during = gateway.reconcile()
    check('restarted gateway treats a persisted lease as unknown writer and persists drafts',
          gateway.s['lease']['state'] == 'WRITER_UNKNOWN' and draft['status'] == 'DRAFT_HELD'
          and during == {'status': 'HELD', 'reason': 'WRITER_RUNNING'}
          and any(x['status'] == 'HELD' for x in persisted['drafts']), [draft, during])
    await task
    released = gateway.reconcile()
    check('restarted gateway releases after the old writer finishes and applies the draft',
          released['status'] == 'RELEASED' and (ws / 'restart-effect').read_text() == 'done'
          and (ws / 'notes.md').read_text() == 'after-restart', released)

    lost = gateway.acquire('lost-in-flight'); gateway.crashed = True
    gateway = Gateway(ws, state, guest); gateway.attach()
    released = gateway.reconcile()
    late = refused({'id': 'lost-in-flight', 'projectId': guest.identity, 'argv': ['/bin/sh', '-c', 'touch late-effect'],
                    'timeoutMs': 1000, 'cwd': '/workspace', 'lease': {'epoch': lost['epoch'], 'fence': lost['fence']}})
    check('revoke fences a granted-but-unsent lease; the delayed request has no effect',
          released['status'] == 'RELEASED' and released['started'] is False and late == (409, 'LEASE_STALE')
          and not (ws / 'late-effect').exists(), [released, late])

    base = gateway.version('notes.md'); (ws / 'notes.md').write_text('files-app-edit')
    result = gateway.native_write('notes.md', b'mine', base)
    check('host writer bypassing the gateway is detected as a conflict, not overwritten',
          result['reason'] == 'EXTERNAL_CHANGE' and (ws / 'notes.md').read_text() == 'files-app-edit'
          and gateway.s['log'][-1]['origin'] == 'external', result)

    task = asyncio.create_task(lease(gateway, 'printf partial > crash-effect; sleep 5; printf late >> crash-effect'))
    await until(lambda: (ws / 'crash-effect').exists())
    guest.process.kill(); guest.process.wait(timeout=10)
    lost = await task; old_epoch = gateway.s['epoch']
    released = gateway.reconcile()
    check('VM exit is the only way an unreachable writer is released; epoch advances',
          lost['status'] == 'WRITER_UNKNOWN' and released['reason'] == 'GUEST_TERMINATED'
          and gateway.s['epoch'] == old_epoch + 1 and 'crash-effect' in released['changed']
          and (ws / 'crash-effect').read_text() == 'partial', released)
    guest.close(); guest.ready = None
    await guest.open(); gateway.attach()
    old = refused({'id': uuid.uuid4().hex, 'projectId': guest.identity, 'argv': ['/bin/sh', '-c', 'touch old-epoch-effect'],
                   'timeoutMs': 1000, 'cwd': '/workspace', 'lease': {'epoch': old_epoch, 'fence': 10 ** 6}})
    released = await lease(gateway, 'printf rebooted > reboot-effect')
    published = json.loads((await run('cat /run/plan500/generation'))['stdout'])
    check('after reboot old-epoch leases fail, new leases work and the guest catches up to the generation',
          old == (409, 'LEASE_EPOCH_MISMATCH') and released['status'] == 'RELEASED' and guest.launches == 2
          and not (ws / 'old-epoch-effect').exists() and published['generation'] == gateway.s['generation'], [old, published])
    guest.close()
    return {'completed': True, 'model': guest.model, 'checks': checks, 'semantics': semantics, 'timings': timings,
            'generation': gateway.s['generation'], 'epoch': gateway.s['epoch'], 'fence': gateway.s['fence']}


async def main(args):
    output = Path(tempfile.mkdtemp(prefix='plan500-lease-', dir=args.scratch))
    token, inputs = sharing.build(args.runtime, args.modloop, output)
    results = []
    for model in args.models:
        guest = Guest(args.runtime, output, token, model)
        state = output / ('gateway-' + model); state.mkdir()
        try: results.append(await probe(guest, state))
        except Exception as error:
            results.append({'completed': False, 'model': model, 'error': f'{type(error).__name__}: {error}',
                            'checks': getattr(guest, 'checks', []), 'semantics': getattr(guest, 'semantics', [])})
        finally: guest.close()
    report = {'completed': all(x['completed'] for x in results), 'platform': 'Linux QEMU 9P',
              'qemu': subprocess.check_output(['qemu-system-aarch64', '--version'], text=True).splitlines()[0],
              'inputs': inputs, 'models': results, 'iPadVerified': False, 'DarwinVerified': False, 'swiftGateway': False,
              'sourceSha256': {p.name: digest(p) for p in SOURCE.iterdir() if p.is_file()},
              'sharedSourceSha256': digest(SOURCE.parent / 'plan500-sharing/run.py')}
    (output / 'result-safe.json').write_text(json.dumps(report, indent=2, ensure_ascii=False) + '\n')
    print(json.dumps({'completed': report['completed'], 'models': [{'model': r['model'], 'completed': r['completed'],
                     'passed': sum(c['passed'] for c in r['checks']), 'error': r.get('error')} for r in results],
                      'receipt': str(output / 'result-safe.json')}, ensure_ascii=False), flush=True)
    return 0 if report['completed'] else 1


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runtime', type=Path, required=True)
    parser.add_argument('--modloop', type=Path, required=True)
    parser.add_argument('--scratch', type=Path, default=Path('/var/tmp'))
    parser.add_argument('--models', nargs='+', choices=['mapped-xattr', 'none'], default=['none', 'mapped-xattr'])
    raise SystemExit(asyncio.run(main(parser.parse_args())))
