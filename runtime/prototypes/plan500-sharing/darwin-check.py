#!/usr/bin/env python3
"""Check one Darwin SDK prerequisite; never build/install or execute an iOS app."""
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

SOURCE = Path(__file__).resolve().parent
OUTPUT = SOURCE.parents[2] / 'build/prototypes/plan500-sharing'


def main():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    scratch = Path(tempfile.mkdtemp(prefix='darwin-api-', dir=OUTPUT))
    results = {}
    for sdk in ['macosx', 'iphoneos']:
        sdk_path = subprocess.check_output(['xcrun', '--sdk', sdk, '--show-sdk-path'], text=True).strip()
        version = subprocess.check_output(['xcrun', '--sdk', sdk, '--show-sdk-version'], text=True).strip()
        results[sdk] = {'sdkVersion': version}
        for private in [False, True]:
            name = 'explicitPrivateDeclaration' if private else 'publicHeaders'
            product = scratch / (sdk + '-' + name)
            command = ['xcrun', '--sdk', sdk, 'clang', '-isysroot', sdk_path, '-Werror',
                       str(SOURCE / 'darwin-api.c'), '-o', str(product)]
            if private: command += ['-DPLAN500_PRIVATE_DECL']
            if sdk == 'iphoneos':
                command += ['-target', 'arm64-apple-ios16.0', '-DPLAN500_LIBRARY', '-dynamiclib']
            built = subprocess.run(command, text=True, capture_output=True)
            entry = {'compiledAndLinked': built.returncode == 0}
            if built.returncode:
                entry['undeclaredFunction'] = 'undeclared function' in built.stderr
                (scratch / (sdk + '-' + name + '-private.log')).write_text(built.stderr)
            elif sdk == 'macosx' and private:
                native = scratch / 'own-workspace'; native.mkdir()
                ran = subprocess.run([str(product), str(native)], cwd=scratch,
                                     text=True, capture_output=True)
                entry['isolatedMacRunPassed'] = (ran.returncode == 0 and
                    (native / 'darwin-api-sentinel').read_text() == 'own scratch directory\n' and
                    not (scratch / 'darwin-api-sentinel').exists())
            results[sdk][name] = entry
    report = {'results': results, 'publicApiSuitabilityVerified': False,
              'Qemu9PBackendVerified': False, 'iPadVerified': False,
              'sourceSha256': hashlib.sha256((SOURCE / 'darwin-api.c').read_bytes()).hexdigest()}
    (OUTPUT / 'darwin-api-safe.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
