#!/usr/bin/env python3
"""Package a signed, complete HarnessApp.app into a local development IPA."""
import argparse
import os
from pathlib import Path
import plistlib
import stat
import subprocess
import tempfile
import zipfile

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    if args.output.exists():
        parser.error('Output already exists; use a new IPA filename')
    info = plistlib.loads((args.app / 'Info.plist').read_bytes())
    if info['CFBundleIdentifier'] != 'org.lvivvde.harness.ipad':
        parser.error('Expected the independent Harness App')
    validator = Path(__file__).resolve().parent.parent / 'ios/HarnessApp/scripts/validate-runtime.py'
    subprocess.run(['python3', str(validator), str(args.app / 'Runtime')], check=True)
    if not (args.app / 'embedded.mobileprovision').is_file():
        parser.error('A development provisioning profile is required')
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(args.app)], check=True)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=args.output.parent, suffix='.ipa.tmp', delete=False) as temporary:
        path = Path(temporary.name)
    try:
        with zipfile.ZipFile(path, 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
            for file in sorted(args.app.rglob('*')):
                relative = 'Payload/' + args.app.name + '/' + file.relative_to(args.app).as_posix()
                if file.is_symlink():
                    entry = zipfile.ZipInfo(relative)
                    entry.create_system = 3
                    entry.external_attr = (stat.S_IFLNK | 0o777) << 16
                    archive.writestr(entry, os.readlink(file))
                elif file.is_file():
                    archive.write(file, relative)
        # An exclusive destination prevents overwriting a concurrent packaging result.
        os.link(path, args.output)
    finally:
        path.unlink(missing_ok=True)
    print('Packaged local development IPA:', args.output, 'bytes:', args.output.stat().st_size)

if __name__ == '__main__':
    main()
