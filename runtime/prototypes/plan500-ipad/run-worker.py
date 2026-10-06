#!/usr/bin/env python3
"""Prepare the fixed official integrated Worker, then run the macOS seams and real restarts.

Dependencies and raw evidence stay in ignored build/. No credentials, device or signing access.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess

from fault_server import FAKE_KEY, PLACEHOLDER, FaultServer

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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--prepare-only', action='store_true')
    parser.add_argument('--inputs', type=Path)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--only', choices=['gate4'], help='Run one stage while iterating; the full run is the evidence')
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
    sources = [SOURCE / 'Sources' / name for name in ('WorkerHostMain.swift', 'WorkerBridge.swift', 'ResearchApp.swift')]
    sources += sorted(gateway.glob('*.swift'))
    # The host build compiles the plugin into the same module (WorkerBridge guards its import).
    sources += sorted((REPO / 'ios/HarnessApp/Sources/LinuxPlugin').glob('*.swift'))
    # Same for the model gateway; its internal target seam is how this host reaches the local fault server.
    sources += sorted((REPO / 'ios/HarnessApp/Sources/ModelGateway').glob('*.swift'))
    binary = output / 'worker-host'
    with (output / 'compile-private.log').open('w') as log:
        subprocess.run(['xcrun', 'swiftc', '-module-cache-path', str(output / 'swift-cache'),
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
    # #39 gate 4: official Worker parser, retry and cancel over the Swift streaming gateway, against local faults.
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
    assets = ('integration.html', 'worker.js', 'client.js', 'apply-injections.js', 'vfs-image.tar.gz')
    summary = {'passed': True, 'partial': bool(args.only), 'physicalDevice': False, 'results': results, 'modelNetworkVerified': False,
               'sourceSha256': {str(p.relative_to(REPO)): digest(p) for p in sources + list((SOURCE / 'web').iterdir()) + [SOURCE / 'fault_server.py']},
               'workerAssetSha256': {name: digest(web / name) for name in assets},
               'pack': json.loads((worker.OUTPUT / 'pack-safe.json').read_text())}
    (output / 'worker-host-safe.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps({'passed': True, 'results': results, 'physicalDevice': False}))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
