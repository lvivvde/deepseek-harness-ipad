#!/usr/bin/env python3
"""Gate 6 synthetic matrix: archives from the old app's own exporter, migrated by `migration-crash-probe`.

Exports run on macOS (host node + npm's node-tar) and in Lima on case-sensitive ext4 with the guest
image's own node and node-tar (a read-only loop mount of a copy of system.raw). Every row checks the
target against expected.json or checks that it is untouched. Only counts, digests and outcomes go to the
receipt; raw trees stay in a temporary directory that is removed afterwards.

    python3 synthetic-matrix.py <receipt.json>
"""
import hashlib
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
PACKAGE = HERE.parents[1]
REPO = PACKAGE.parents[1]
LIMA = 'ubuntu'
LIMA_ROOT = '/var/tmp/gate6-matrix'
LIMA_SYSTEM = '/var/tmp/ipad-bundled-guest-storage-v6/system.raw'
STAGES = ['digest', 'plan', 'extract#1', 'extract#4', 'verify', 'sessions#1', 'sessions#2', 'marker', 'switching', 'switched']


def sha256(path):
    digest = hashlib.sha256()
    with open(path, 'rb') as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b''):
            digest.update(chunk)
    return digest.hexdigest()


def lima(script, **kwargs):
    return subprocess.run(['limactl', 'shell', LIMA, '--', 'bash', '-c', script], capture_output=True, check=True, **kwargs)


def export_mac(variant, out):
    npm = Path(shutil.which('npm')).resolve().parents[1]
    work = Path(tempfile.mkdtemp(prefix='gate6-work-'))
    try:
        result = subprocess.run(['node', HERE / 'synthetic-backup.cjs', work, out, variant, npm], capture_output=True, text=True)
    finally:
        shutil.rmtree(work, ignore_errors=True)
    return result.stdout.strip() or result.stderr.strip()


def export_lima(variant, out):
    script = HERE / 'synthetic-backup.cjs'
    mount = f'{LIMA_ROOT}/mnt'
    lima(f'set -e; mkdir -p {mount}; cd {LIMA_ROOT}; [ -f system.raw ] || cp {LIMA_SYSTEM} system.raw; '
         f'mountpoint -q {mount} || sudo mount -o ro,noload,loop system.raw {mount}')
    remote = f'{LIMA_ROOT}/out-{variant}'
    result = subprocess.run(['limactl', 'shell', LIMA, '--', 'bash', '-c',
                             f'rm -rf {remote}; chmod -R u+w {LIMA_ROOT}/work-{variant} 2>/dev/null; rm -rf {LIMA_ROOT}/work-{variant}; {mount}/opt/node/bin/node {script} {LIMA_ROOT}/work-{variant} {remote} {variant} '
                             f'{mount}/opt/node/lib/node_modules/npm; status=$?; chmod -R u+w {LIMA_ROOT}/work-{variant}; rm -rf {LIMA_ROOT}/work-{variant}; exit $status'],
                            capture_output=True, text=True)
    line = result.stdout.strip() or result.stderr.strip()
    if result.returncode == 0:
        out.mkdir(parents=True, exist_ok=True)
        for name in ['HarnessBackup.tar', 'HarnessBackup.tar.sha256', 'expected.json']:
            (out / name).write_bytes(lima(f'cat {remote}/{name}').stdout)
    return line


class Matrix:
    def __init__(self, probe, scratch):
        self.probe, self.scratch, self.rows = probe, scratch, []

    def case(self, name):
        root = self.scratch / name
        (root / 'data').mkdir(parents=True)
        return root / 'data' / 'UserData'

    def run(self, source, target, *extra, checksum=None):
        result = subprocess.run([self.probe, source / 'HarnessBackup.tar', checksum or source / 'HarnessBackup.tar.sha256', target, *extra],
                                capture_output=True, text=True, timeout=300)
        return result.returncode, result.stdout.strip()

    def record(self, name, ok, **details):
        self.rows.append({'case': name, 'ok': bool(ok), **details})
        print(('PASS ' if ok else 'FAIL ') + name + ' ' + json.dumps(details, ensure_ascii=False))

    def untouched(self, target):
        return not target.exists() and not [p for p in target.parent.iterdir() if p.name.startswith('.migration-stage-')]


def check_tree(target, source):
    """Differences between the migrated tree and expected.json, plus the session conversion."""
    spec = json.loads((source / 'expected.json').read_text())
    expected, problems, seen = spec['expected'], [], {}
    for directory, names, files in os.walk(target):
        for name in names + files:
            full = Path(directory) / name
            relative = str(full.relative_to(target))
            if relative == '.migration.json' or relative == 'home/sessions' or relative.startswith('home/sessions/'):
                continue
            info = full.lstat()
            node = {'mode': stat.S_IMODE(info.st_mode)}
            if stat.S_ISDIR(info.st_mode):
                node['type'] = 'directory'
            elif stat.S_ISLNK(info.st_mode):
                node = {'type': 'symlink', 'link': os.readlink(full)}
            elif stat.S_ISREG(info.st_mode):
                node.update(type='file', sha256=sha256(full))
            else:
                node['type'] = 'other'
            seen[relative] = node
    for path in sorted(set(seen) | set(expected)):
        if seen.get(path) != expected.get(path):
            problems.append(path)
    for group in spec['hardlinks']:
        if len({(target / path).lstat().st_ino for path in group}) != 1:
            problems.append('hardlink ' + group[0])
    log = target / 'home/sessions/--dsh-workspace-demo--/s-1/session.v4.jsonl'
    header, _, rest = log.read_bytes().partition(b'\n') if log.exists() else (b'{}', b'', b'')
    if json.loads(header).get('cwd') != '/dsh/workspace/demo' or rest != '{"type":"user","text":"保持 /root/projects/demo"}\n'.encode():
        problems.append('session s-1')
    if (target / 'home/sessions/--root-projects-demo--').exists() or not (target / 'home/sessions/_no-cwd/s-2/session.v4.jsonl').exists():
        problems.append('session layout')
    return problems, len(seen)


def main():
    receipt = Path(sys.argv[1])
    subprocess.run(['swift', 'build', '--package-path', PACKAGE, '--product', 'migration-crash-probe'], check=True, capture_output=True)
    probe = Path(subprocess.run(['swift', 'build', '--package-path', PACKAGE, '--show-bin-path'], check=True, capture_output=True,
                                text=True).stdout.strip()) / 'migration-crash-probe'
    work = Path(tempfile.mkdtemp(prefix='gate6-matrix-'))
    matrix = Matrix(probe, work / 'runs')
    try:
        sources, exports = {}, {}
        for where, variant in [('mac', 'base'), ('lima', 'base'), ('lima', 'case'), ('lima', 'unicode')]:
            out = work / f'{where}-{variant}'
            exports[f'{where}-{variant}'] = (export_mac if where == 'mac' else export_lima)(variant, out)
            if (out / 'HarnessBackup.tar').exists():
                sources[f'{where}-{variant}'] = out
        archive_digests = {name: sha256(path / 'HarnessBackup.tar') for name, path in sources.items()}

        for name in ['mac-base', 'lima-base']:
            if name not in sources:
                matrix.record(name + ' export', False, export=exports[name])
                continue
            source = sources[name]
            target = matrix.case(name)
            status, output = matrix.run(source, target)
            problems, entries = check_tree(target, source) if status == 0 else (['not migrated'], 0)
            report = json.loads((target / '.migration.json').read_text()) if status == 0 else {}
            credentials = sorted(report.get('credentialsExcluded', []))
            ok = (status == 0 and not problems and credentials == ['.dsh/.credentials.yaml', '.netrc', '.ssh', '.ssh/id_ed25519']
                  and report.get('cacheEntriesExcluded', 0) >= 1 and report.get('sessions') == 2 and report.get('sessionsDecompressed') == 1
                  and report.get('archiveSha256') == (source / 'HarnessBackup.tar.sha256').read_text()[:64])
            details = {'export': exports[name], 'result': output, 'entries': entries, 'problems': problems[:5],
                       'credentialsExcluded': len(credentials), 'specialSkipped': report.get('specialSkipped', []),
                       'manifestSha256': report.get('manifestSha256')}
            matrix.record(name + ' migrates', ok, **details)
            again = matrix.run(source, target)
            matrix.record(name + ' rerun is a no-op', again == (0, 'RESULT already') and check_tree(target, source)[0] == [], result=again[1])
        if 'mac-base' in sources and 'lima-base' in sources:
            manifests = [json.loads((work / 'runs' / name / 'data/UserData/.migration.json').read_text())['manifestSha256'] for name in ['mac-base', 'lima-base']]
            matrix.record('macOS and Linux exports give the same manifest', manifests[0] == manifests[1])

        for name, code in [('lima-case', 'NAME_CONFLICT'), ('lima-unicode', 'NAME_CONFLICT')]:
            if name not in sources:
                matrix.record(name + ' export', False, export=exports[name])
                continue
            target = matrix.case(name)
            result = matrix.run(sources[name], target)
            matrix.record(name + ' is refused', result == (1, 'ERROR ' + code) and matrix.untouched(target), export=exports[name], result=result[1])

        base = sources['lima-base']
        damaged = work / 'damaged'
        damaged.mkdir()
        good = base / 'HarnessBackup.tar.sha256'
        data = bytearray((base / 'HarnessBackup.tar').read_bytes())

        def damaged_case(name, payload, sidecar, code):
            folder = damaged / name
            folder.mkdir()
            (folder / 'HarnessBackup.tar').write_bytes(payload)
            (folder / 'HarnessBackup.tar.sha256').write_text(sidecar if sidecar is not None else hashlib.sha256(payload).hexdigest() + '  HarnessBackup.tar\n')
            target = matrix.case(name)
            result = matrix.run(folder, target)
            matrix.record(name, result == (1, 'ERROR ' + code) and matrix.untouched(target), result=result[1])
            retry = matrix.run(base, target)
            matrix.record(name + ' then retry with the good backup', retry[0] == 0 and check_tree(target, base)[0] == [], result=retry[1])

        flipped = bytearray(data)
        flipped[len(flipped) // 2] ^= 0xFF
        damaged_case('wrong sidecar digest', bytes(data), '0' * 64 + '  HarnessBackup.tar\n', 'DIGEST_MISMATCH')
        damaged_case('flipped byte under the original sidecar', bytes(flipped), good.read_text(), 'DIGEST_MISMATCH')
        damaged_case('sidecar not a digest', bytes(data), 'not a digest\n', 'CHECKSUM_FILE_INVALID')
        damaged_case('truncated archive with its own digest', bytes(data[:len(data) // 3]), None, 'ARCHIVE_CORRUPT')
        header = bytearray(data)
        header[0] ^= 0x01
        damaged_case('header checksum broken with its own digest', bytes(header), None, 'ARCHIVE_CORRUPT')

        # Real ENOSPC: a small disk image filled until the extraction cannot fit, then space is freed.
        image = work / 'small.dmg'
        mount = work / 'small'
        subprocess.run(['hdiutil', 'create', '-size', '8m', '-fs', 'HFS+', '-volname', 'gate6', image], check=True, capture_output=True)
        subprocess.run(['hdiutil', 'attach', '-nobrowse', '-mountpoint', mount, image], check=True, capture_output=True)
        try:
            (mount / 'data').mkdir()
            free = shutil.disk_usage(mount).free
            filler = mount / 'filler'
            filler.write_bytes(b'\0' * max(0, free - 1_000_000))
            target = mount / 'data' / 'UserData'
            full = matrix.run(base, target, 'nospacecheck')
            ok = full == (1, 'ERROR INSUFFICIENT_SPACE') and not target.exists() and not [p for p in (mount / 'data').iterdir() if p.name.startswith('.migration-stage-')]
            matrix.record('ENOSPC during extraction', ok, result=full[1])
            checked = matrix.run(base, target)
            matrix.record('space check refuses before writing', checked == (1, 'ERROR INSUFFICIENT_SPACE') and not target.exists(), result=checked[1])
            filler.unlink()
            # 8 MiB cannot also hold the 64 MiB reserve: the retry skips the space check once space is free.
            retry = matrix.run(base, target, 'nospacecheck')
            matrix.record('ENOSPC retry after freeing space', retry[0] == 0 and check_tree(target, base)[0] == [], result=retry[1])
        finally:
            subprocess.run(['hdiutil', 'detach', mount], capture_output=True)

        reference = json.loads((work / 'runs/lima-base/data/UserData/.migration.json').read_text())
        for point in STAGES:
            target = matrix.case('kill-' + point.replace('#', '-'))
            killed = matrix.run(base, target, point)
            # A killed run leaves its stage behind; the retry removes it.
            before = not target.exists() if point != 'switched' else (target / '.migration.json').exists()
            retry = matrix.run(base, target)
            again = matrix.run(base, target)
            marker = json.loads((target / '.migration.json').read_text()) if target.exists() else {}
            ok = (killed[0] == -9 and killed[1] == 'KILL ' + point and before and retry[0] == 0 and again == (0, 'RESULT already')
                  and marker == reference and check_tree(target, base)[0] == []
                  and not [p for p in target.parent.iterdir() if p.name.startswith('.migration-stage-')])
            matrix.record('killed at ' + point, ok, retry=retry[1])

        target = matrix.case('busy')
        holder = subprocess.Popen([probe, base / 'HarnessBackup.tar', base / 'HarnessBackup.tar.sha256', target, 'hold'], stdout=subprocess.PIPE, text=True)
        try:
            held = holder.stdout.readline().strip()
            second = matrix.run(base, target)
        finally:
            holder.kill()
            holder.wait()
        after = matrix.run(base, target)
        matrix.record('second process is busy while the first migrates', held == 'HOLD' and second == (1, 'ERROR MIGRATION_BUSY')
                      and after[0] == 0, result=second[1], after=after[1])

        target = matrix.case('existing')
        target.mkdir()
        (target / 'keep.txt').write_text('new app data')
        result = matrix.run(base, target)
        matrix.record('existing target is never overwritten', result == (1, 'ERROR TARGET_EXISTS') and (target / 'keep.txt').read_text() == 'new app data'
                      and sorted(p.name for p in target.iterdir()) == ['keep.txt'], result=result[1])

        target = work / 'runs/lima-base/data/UserData'
        edited = target / 'projects/demo/a.txt'
        edited.write_text('changed after migration')
        (target / 'projects/demo/new.txt').write_text('created after migration')
        result = matrix.run(base, target)
        matrix.record('rerun keeps changes made after migration', result == (0, 'RESULT already') and edited.read_text() == 'changed after migration'
                      and (target / 'projects/demo/new.txt').exists(), result=result[1])

        unchanged = all(sha256(path / 'HarnessBackup.tar') == archive_digests[name] for name, path in sources.items())
        matrix.record('source archives unchanged by every run', unchanged)
        summary = {'rows': len(matrix.rows), 'passed': sum(row['ok'] for row in matrix.rows), 'exports': exports,
                   'archives': {name: {'sha256': digest, 'bytes': (sources[name] / 'HarnessBackup.tar').stat().st_size} for name, digest in archive_digests.items()},
                   'nodeTar': {'mac': subprocess.run(['node', '-p', f"require('{Path(shutil.which('npm')).resolve().parents[1]}/node_modules/tar/package.json').version"],
                                                     capture_output=True, text=True).stdout.strip()},
                   'cases': matrix.rows}
        receipt.parent.mkdir(parents=True, exist_ok=True)
        receipt.write_text(json.dumps(summary, ensure_ascii=False, indent=1) + '\n')
        print(f"{summary['passed']}/{summary['rows']} passed")
        return 0 if summary['passed'] == summary['rows'] else 1
    finally:
        for directory, names, _ in os.walk(work):
            for name in names:
                os.chmod(Path(directory) / name, 0o755)
        shutil.rmtree(work, ignore_errors=True)
        subprocess.run(['limactl', 'shell', LIMA, '--', 'bash', '-c', f'rm -rf {LIMA_ROOT}/out-* {LIMA_ROOT}/work-*; '
                        f'sudo umount {LIMA_ROOT}/mnt 2>/dev/null; rm -f {LIMA_ROOT}/system.raw'], capture_output=True)


if __name__ == '__main__':
    sys.exit(main())
