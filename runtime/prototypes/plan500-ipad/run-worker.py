#!/usr/bin/env python3
"""Prepare the fixed official integrated Worker, then run the macOS seams and real restarts.

Dependencies and raw evidence stay in ignored build/. No credentials, device or signing access.
"""
import argparse
import hashlib
import importlib.util
import json
import os
import re
from pathlib import Path
import subprocess

from fault_server import FAKE_KEY, PLACEHOLDER, FaultServer

# The shape of WorkerCoordinator.randomToken() (#39 gate 5).
TOKEN_SHAPE = re.compile(rb'dsh-gate5-[0-9a-f]{48}')

SOURCE = Path(__file__).resolve().parent
REPO = SOURCE.parents[2]
WORKER = SOURCE.parent / 'plan500-worker'
spec = importlib.util.spec_from_file_location('worker_probe', WORKER / 'run.py')
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def prepare():
    harness = worker.OUTPUT / 'harness-dependencies'
    if not harness.is_dir():
        harness = REPO / 'build/test-dependencies/harness'
    worker.dependencies('harness-dependencies', harness, False)
    worker.dependencies('dependencies', worker.OUTPUT / 'dependencies', False)
    env = os.environ.copy()
    env['PLAN500_HARNESS_ROOT'] = str(harness)
    env['DSH_HOME'] = str(worker.OUTPUT / 'scratch-dsh-home')
    with (worker.OUTPUT / 'composed-web.yml').open('w') as config, (worker.OUTPUT / 'config-private.log').open('w') as errors:
        subprocess.run(['node', str(harness / 'node_modules/@deepseek-ai/dsh/lib/bin.js'),
                        '--profile', 'web', '--dump-config'], cwd=REPO, env=env,
                       stdout=config, stderr=errors, timeout=60, check=True)
    worker.run(['node', str(WORKER / 'pack.mjs'), '--zod-cjs', '--webkit-schemas', '--integration'],
               'integration-pack-private.log', env=env)
    worker.run(['node', str(WORKER / 'prepare-web.mjs'), '--integration'], 'integration-prepare-private.log')
    # #39 gate 3: the synthetic project, built with system git; the app recreates it in its own container.
    subprocess.run(['python3', str(SOURCE / 'gate3_fixture.py'), str(worker.OUTPUT / 'web/gate3-fixture.json')], check=True)


def native_modules(output, log):
    """The real store and native tools as their own modules, so the gateway prototype's same-named types do not collide."""
    modules = output / 'native-modules'
    modules.mkdir()
    package = REPO / 'ios/HarnessApp/Sources'
    for name, directory in (('NativeWorkspace', 'Workspace'), ('NativeTools', 'NativeTools')):
        subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-module-name', name, '-emit-library', '-static',
                        '-emit-module', '-emit-module-path', str(modules / f'{name}.swiftmodule'), '-I', str(modules),
                        '-module-cache-path', str(output / 'swift-cache'), *map(str, sorted((package / directory).glob('*.swift'))),
                        '-o', str(modules / f'lib{name}.a')], stdout=log, stderr=subprocess.STDOUT, check=True)
    return ['-I', str(modules), '-L', str(modules), '-lNativeTools', '-lNativeWorkspace']


def git_diff_agrees(tree, changes):
    """The turn's change summary (native git) against system git on the same native workspace.

    The turn touched files that matched HEAD before it, so each line count equals `git diff HEAD`;
    an untracked file is diffed against /dev/null. Read only: optional locks stay off.
    """
    env = {**os.environ, 'GIT_OPTIONAL_LOCKS': '0', 'GIT_CONFIG_NOSYSTEM': '1', 'HOME': str(tree)}
    def numstat(*args):
        out = subprocess.run(['git', '-c', 'core.quotepath=false', *args], cwd=tree, env=env, capture_output=True, text=True)
        added, deleted, _ = out.stdout.split('\t', 2)
        return int(added), int(deleted)
    tracked = set(subprocess.run(['git', 'ls-files', '-z'], cwd=tree, env=env, capture_output=True, text=True, check=True).stdout.split('\0'))
    for entry in changes['files']:
        path = entry['path']
        expected = numstat('diff', '--numstat', 'HEAD', '--', path) if path in tracked else numstat('diff', '--no-index', '--numstat', '--', '/dev/null', path)
        if expected != (entry['added'], entry['deleted']):
            return False
    return len(changes['files']) > 0 and changes['added'] == sum(x['added'] for x in changes['files'])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--prepare-only', action='store_true')
    parser.add_argument('--inputs', type=Path)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--only', choices=['gate3', 'gate4', 'gate5', 'gate5-push-dry'], help='Run one stage while iterating; the full run is the evidence')
    args = parser.parse_args()
    prepare()
    web = worker.OUTPUT / 'web'
    if args.prepare_only:
        print('INTEGRATED_WORKER_PREPARED')
        return 0
    if not args.inputs or not args.output:
        parser.error('--inputs and --output are required for host checks')
    output = args.output.resolve()
    if not output.is_relative_to(REPO / 'build'):
        parser.error('output must be in ignored build/')
    output.mkdir(parents=True, exist_ok=False)
    gateway = SOURCE.parent / 'plan500-darwin/gateway/Sources/Plan500Gateway'
    sources = [SOURCE / 'Sources' / name for name in ('WorkerHostMain.swift', 'WorkerBridge.swift', 'ResearchApp.swift',
                                                      'NativeToolsBridge.swift', 'Gate5Review.swift')]
    sources += sorted(gateway.glob('*.swift'))
    # The host build compiles the plugin into the same module (WorkerBridge guards its import).
    sources += sorted((REPO / 'ios/HarnessApp/Sources/LinuxPlugin').glob('*.swift'))
    # Same for the model gateway; its internal target seam is how this host reaches the local fault server.
    sources += sorted((REPO / 'ios/HarnessApp/Sources/ModelGateway').glob('*.swift'))
    binary = output / 'worker-host'
    with (output / 'compile-private.log').open('w') as log:
        linked = native_modules(output, log)
        subprocess.run(['xcrun', 'swiftc', '-module-cache-path', str(output / 'swift-cache'), *linked,
                        *map(str, sources), '-o', str(binary)], stdout=log, stderr=subprocess.STDOUT, check=True)
    results = []
    for model in ('none', 'mapped-xattr') if not args.only else ():
        project = output / model
        for stage, receipt in (('first', 'worker-safe.json'), ('resume', 'worker-resume-safe.json')):
            with (output / f'{model}-{stage}-private.log').open('w') as log:
                code = subprocess.run([str(binary), str(args.inputs.resolve()), str(web), str(project), model, stage],
                                      stdout=log, stderr=subprocess.STDOUT, timeout=780).returncode
            data = json.loads((project / receipt).read_text())
            if code or not data['passed'] or data['physicalDevice']:
                raise RuntimeError('HOST_SEAM_FAILED')
            results.append({'model': model, 'stage': stage, 'checks': len(data['checks']), 'passed': True})
    # #39 gate 2 missing branch: injected in this research host only, on a fresh project; QEMU must never start.
    if not args.only:
        project = output / 'gate2-missing'
        with (output / 'gate2-missing-private.log').open('w') as log:
            code = subprocess.run([str(binary), str(args.inputs.resolve()), str(web), str(project), 'none', 'gate2-missing'],
                                  stdout=log, stderr=subprocess.STDOUT, timeout=780).returncode
        data = json.loads((project / 'gate2-missing-safe.json').read_text())
        if code or not data['passed'] or data['vmStarts'] != 0 or data['linuxAvailabilityDetected'] != 'available':
            raise RuntimeError('GATE2_MISSING_FAILED')
        results.append({'model': 'none', 'stage': 'gate2-missing', 'checks': len(data['checks']), 'passed': True})
    # #39 gate 3: the official file, search and change tools over the native workspace; model turns scripted locally.
    if args.only in (None, 'gate3'):
        project = output / 'gate3'
        with FaultServer() as server, (output / 'gate3-private.log').open('w') as log:
            code = subprocess.run([str(binary), str(args.inputs.resolve()), str(web), str(project), 'none', 'gate3', server.url],
                                  stdout=log, stderr=subprocess.STDOUT, timeout=780).returncode
            wire = server.summary()
        text = (project / 'gate3-safe.json').read_text()
        data = json.loads(text)
        wire_ok = wire['fakeKeyOnEveryRequest'] and wire['placeholderNeverSent'] and wire['workerCredentialsDropped']
        if code or not data['passed'] or not wire_ok or data['vmStarts'] != 0 or FAKE_KEY in text or PLACEHOLDER in text:
            raise RuntimeError('GATE3_TOOLS_FAILED')
        if not git_diff_agrees(project / 'gate3/workspace', data['gate3']['changes']):
            raise RuntimeError('GATE3_CHANGES_DISAGREE_WITH_GIT')
        results.append({'model': 'none', 'stage': 'gate3', 'checks': len(data['checks']) + 1, 'passed': True})
    # #39 gate 4: official Worker parser, retry and cancel over the Swift streaming gateway, against local faults.
    if args.only in (None, 'gate4'):
        project = output / 'gate4'
        with FaultServer() as server, (output / 'gate4-private.log').open('w') as log:
            code = subprocess.run([str(binary), str(args.inputs.resolve()), str(web), str(project), 'none', 'gate4', server.url],
                                  stdout=log, stderr=subprocess.STDOUT, timeout=780).returncode
            wire = server.summary()
        (output / 'gate4-wire-safe.json').write_text(json.dumps(wire, indent=2) + '\n')
        text = (project / 'gate4-safe.json').read_text()
        data = json.loads(text)
        wire_ok = all(wire[k] for k in ('countsMatch', 'fakeKeyOnEveryRequest', 'placeholderNeverSent', 'workerCredentialsDropped',
                                         'cancelPeerClosed', 'cancelToolNeverSent'))
        if code or not data['passed'] or not wire_ok or data['vmStarts'] != 0 or FAKE_KEY in text or PLACEHOLDER in text:
            raise RuntimeError('GATE4_FAULTS_FAILED')
        results.append({'model': 'none', 'stage': 'gate4', 'checks': len(data['checks']), 'passed': True, 'wire': wire})
    # #39 gate 5: Git writes and hooks on Linux under the lease, native read-only review; then the two refusal branches.
    if args.only in (None, 'gate5'):
        for stage, receipt in (('gate5', 'gate5-safe.json'), ('gate5-unavailable', 'gate5-unavailable-safe.json'),
                               ('gate5-prepare-failed', 'gate5-prepare-failed-safe.json')):
            project = output / stage
            with (output / f'{stage}-private.log').open('w') as log:
                code = subprocess.run([str(binary), str(args.inputs.resolve()), str(web), str(project), 'none', stage],
                                      stdout=log, stderr=subprocess.STDOUT, timeout=780).returncode
            data = json.loads((project / receipt).read_text())
            starts = 1 if stage == 'gate5' else 0
            # The app scans its own project root; this covers the host's log outside it. The run's token
            # is random and never shown here, so any string of its shape fails the stage.
            leaked = TOKEN_SHAPE.search((output / f'{stage}-private.log').read_bytes())
            if code or not data['passed'] or data['vmStarts'] != starts or data['gitTokenPersisted'] is not False or leaked:
                raise RuntimeError('GATE5_FAILED ' + stage)
            results.append({'model': 'none', 'stage': stage, 'checks': len(data['checks']), 'passed': True, 'gate5': data['gate5']})
    # #39 gate 5 push without a token against the public repository: needs github.com, so it runs only on request.
    # Both pushes must stop at authentication, before pre-push, and nothing may reach the remote.
    if args.only == 'gate5-push-dry':
        project = output / 'gate5-push-dry'
        with (output / 'gate5-push-dry-private.log').open('w') as log:
            code = subprocess.run([str(binary), str(args.inputs.resolve()), str(web), str(project), 'none', 'gate5-push-dry'],
                                  stdout=log, stderr=subprocess.STDOUT, timeout=780).returncode
        data = json.loads((project / 'gate5-push-dry-safe.json').read_text())
        if code or not data['passed'] or data['gitTokenPersisted'] is not False:
            raise RuntimeError('GATE5_PUSH_DRY_FAILED')
        results.append({'model': 'none', 'stage': 'gate5-push-dry', 'checks': len(data['checks']), 'passed': True, 'gate5Push': data['gate5Push']})
    assets = ('integration.html', 'worker.js', 'client.js', 'apply-injections.js', 'vfs-image.tar.gz')
    summary = {'passed': True, 'partial': bool(args.only), 'physicalDevice': False, 'results': results, 'modelNetworkVerified': False,
               'sourceSha256': {str(p.relative_to(REPO)): digest(p) for p in sources + list((SOURCE / 'web').iterdir())
                                 + [SOURCE / 'fault_server.py', SOURCE / 'gate3_fixture.py', SOURCE / 'git_http_fixture.cjs']},
               'workerAssetSha256': {name: digest(web / name) for name in assets},
               'pack': json.loads((worker.OUTPUT / 'pack-safe.json').read_text())}
    (output / 'worker-host-safe.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps({'passed': True, 'results': results, 'physicalDevice': False}))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
