#!/usr/bin/env python3
"""Exercise the production row menu in an isolated, unsigned Simulator app."""
import argparse
import platform
import plistlib
import shutil
import subprocess
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--simulator', required=True, help='A booted iPad Simulator UUID')
    parser.add_argument('--output', required=True, type=Path, help='New output directory')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    shutil.copytree(root / 'UITests/NativeMenu', output / 'fixture')
    fixture = output / 'fixture'
    source = (root / 'Sources/Native/ProjectTransferView.swift').read_text()
    start = source.index('private struct ProjectRowMenu:')
    end = source.index('\nstruct DocumentExporter:', start)
    # Copy the actual production widget, including its UIKit representable.
    # This avoids booting QEMU or accessing any Harness user data in the fixture.
    with (fixture / 'Fixture.swift').open('a') as stream:
        stream.write(source[start:end].replace('private struct ProjectRowMenu:', 'struct ProjectRowMenu:', 1))
    app = fixture / 'NativeMenuFixture.app'
    app.mkdir()
    app_info = {
        'CFBundleExecutable': 'NativeMenuFixture',
        'CFBundleIdentifier': 'org.lvivvde.harness.acceptance.menu-fixture',
        'CFBundleName': 'NativeMenuFixture', 'CFBundlePackageType': 'APPL',
        'CFBundleShortVersionString': '1.0', 'CFBundleVersion': '1',
        'LSRequiresIPhoneOS': True, 'MinimumOSVersion': '16.0',
        'UIDeviceFamily': [2], 'UILaunchScreen': {},
        'UISupportedInterfaceOrientations': ['UIInterfaceOrientationPortrait',
                                            'UIInterfaceOrientationLandscapeLeft',
                                            'UIInterfaceOrientationLandscapeRight'],
    }
    (app / 'Info.plist').write_bytes(plistlib.dumps(app_info))
    sdk = subprocess.check_output(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'], text=True).strip()
    architecture = 'arm64' if platform.machine() == 'arm64' else 'x86_64'
    derived = output / 'derived'
    with (output / 'build.log').open('w') as log:
        def run(command):
            subprocess.run(command, check=True, stdout=log, stderr=subprocess.STDOUT)
        run(['xcrun', 'swiftc', '-parse-as-library', '-sdk', sdk, '-target', architecture + '-apple-ios16.0-simulator',
             str(fixture / 'Fixture.swift'), '-o', str(app / 'NativeMenuFixture')])
        run(['xcrun', 'simctl', 'install', args.simulator, str(app)])
        run(['xcodebuild', '-project', str(fixture / 'NativeMenu.xcodeproj'), '-scheme', 'NativeMenu',
             'build-for-testing', '-sdk', 'iphonesimulator', '-destination', 'generic/platform=iOS Simulator',
             '-derivedDataPath', str(derived), 'CODE_SIGNING_ALLOWED=NO'])
    test_run, = (derived / 'Build/Products').glob('*.xctestrun')
    settings = plistlib.loads(test_run.read_bytes())
    for name, target in settings.items():
        if name != '__xctestrun_metadata__' and isinstance(target, dict):
            target['UseUITargetAppProvidedByTests'] = True
    test_run.write_bytes(plistlib.dumps(settings))
    with (output / 'test.log').open('w') as log:
        completed = subprocess.run([
            'xcodebuild', 'test-without-building', '-xctestrun', str(test_run),
            '-destination', 'platform=iOS Simulator,id=' + args.simulator,
            '-resultBundlePath', str(output / 'menus.xcresult'),
        ], stdout=log, stderr=subprocess.STDOUT)
    print('NATIVE_MENU_SCREENSHOT_TEST_EXIT', completed.returncode)
    return completed.returncode


if __name__ == '__main__':
    raise SystemExit(main())
