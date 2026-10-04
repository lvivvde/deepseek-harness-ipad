#!/usr/bin/env python3
"""Private device selection/logging; stdout contains fixed diagnostics only."""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess


APP = 'org.lvivvde.harness.ipad'
TARGET = 'DeviceAcceptanceUITests'
CHECKS = {
    'page': 'testInspectExistingPage',
    'settings': 'testReadOnlySettings',
    'short-background': 'testAttachAndShortBackgroundSwitch',
    'session-reply': 'testExistingSessionReplyAfterRecovery',
}


class Failure(Exception):
    pass


def select_device(records, preferred=None):
    candidates = []
    for item in records:
        props = item.get('properties', {})
        hardware = props.get('hardware', item.get('hardwareProperties', {}))
        connection = props.get('connection', item.get('connectionProperties', {}))
        state = connection.get('state', connection.get('tunnelState'))
        if (hardware.get('deviceType') == 'iPad'
                and hardware.get('reality') == 'physical'
                and connection.get('pairingState') == 'paired'
                and state == 'connected'
                and isinstance(item.get('identifier'), str)):
            candidates.append(item)
    if preferred:
        candidates = [item for item in candidates if item['identifier'] == preferred]
    if not candidates:
        raise Failure('NO_CONNECTED_PAIRED_IPAD')
    if len(candidates) != 1:
        raise Failure('MULTIPLE_IPADS_SELECT_WITH_PRIVATE_DEVICE_FILE')
    return candidates[0]


def prepare_test_run(source, destination, check='page'):
    settings = plistlib.loads(source.read_bytes())
    targets = [value for key, value in settings.items()
               if key != '__xctestrun_metadata__' and isinstance(value, dict)]
    if len(targets) != 1 or not targets[0].get('IsUITestBundle'):
        raise Failure('NOT_AN_INDEPENDENT_UI_RUNNER')
    target = targets[0]
    if (Path(target.get('TestHostPath', '')).name != 'DeviceAcceptanceUITests-Runner.app'
            or Path(target.get('TestBundlePath', '')).name != 'DeviceAcceptanceUITests.xctest'):
        raise Failure('NOT_AN_INDEPENDENT_UI_RUNNER')
    def canonical(path):
        return str(Path(path.replace('__TESTHOST__', target.get('TestHostPath', ''))
                       .replace('__TESTROOT__', str(source.resolve().parent))).resolve())
    permitted = {canonical(target.get('TestHostPath', '')),
                 canonical(target.get('TestBundlePath', ''))}
    if (target.get('UITargetAppPath') or
            {canonical(path) for path in target.get('DependentProductPaths', [])} - permitted or
            target.get('TestHostBundleIdentifier') != 'org.lvivvde.harness.acceptance.xctrunner'):
        raise Failure('RUNNER_MUST_NOT_INSTALL_TARGET_APP')
    target['UseUITargetAppProvidedByTests'] = True
    for key in ['EnvironmentVariables', 'TestingEnvironmentVariables']:
        target.setdefault(key, {})['HARNESS_ACCEPTANCE_CHECK'] = check
    # Resolve paths before moving the xctestrun away from Build/Products.
    def resolve(value):
        if isinstance(value, str):
            return value.replace('__TESTROOT__', str(source.resolve().parent))
        if isinstance(value, list):
            return [resolve(item) for item in value]
        if isinstance(value, dict):
            return {key: resolve(item) for key, item in value.items()}
        return value
    destination.write_bytes(plistlib.dumps(resolve(settings)))


def safe_stage(record):
    stage = record.get('stage')
    known = {'booting', 'loadingHarness', 'ready', 'userDataOperationFailed',
             'harnessStopped', 'runtimeExited', 'connectionUnavailable'}
    known.update('recovery:' + name for name in [
        'vmRunning', 'guestResponded', 'clockSynchronized', 'harnessRestarting',
        'harnessRunning', 'forwardRepairing', 'pageReady'])
    known.update('bootFailed:' + name for name in [
        'SYSTEM_MOUNT', 'USER_FSCK', 'USER_MOUNT', 'USER_LAYOUT', 'USER_READONLY',
        'USER_SPACE', 'NETWORK', 'USER_RESTORE', 'USER_LOCKS', 'HARNESS_EXIT'])
    return stage if stage in known else 'UNRECOGNIZED_STAGE'


def classify_log(log):
    text = log.read_text(errors='replace')
    for marker, fragments in [
        ('RUNNER_APP_SLOT_FULL', ['maximum number of', 'Maximum number of']),
        ('UI_AUTOMATION_AUTHORIZATION_TIMEOUT', ['Timed out while enabling automation mode']),
        ('DEVICE_LOCKED', ['device is locked', 'Device is locked']),
        ('CLI_SIGNING_ACCOUNT_UNAVAILABLE', ['No Accounts']),
        ('RUNNER_PROFILE_MISSING', ['No profiles for']),
    ]:
        if any(fragment in text for fragment in fragments):
            return marker
    return 'COMMAND_FAILED_SEE_PRIVATE_LOG'


class Session:
    def __init__(self, output):
        self.output = output.resolve()
        self.output.mkdir(parents=True, exist_ok=False, mode=0o700)

    def run(self, command, label, timeout=60):
        log = self.output / (label + '-private.log')
        try:
            with log.open('w') as stream:
                result = subprocess.run(command, stdout=stream, stderr=subprocess.STDOUT,
                                        timeout=timeout, check=False)
        except subprocess.TimeoutExpired:
            raise Failure('COMMAND_TIMEOUT') from None
        except OSError:
            raise Failure('LOCAL_TOOL_UNAVAILABLE') from None
        if result.returncode:
            raise Failure(classify_log(log))
        return log

    def device_json(self, command, label):
        target = self.output / (label + '-private.json')
        self.run(['xcrun', 'devicectl', *command, '--timeout', '30',
                  '--json-output', str(target)], label, timeout=45)
        try:
            return json.loads(target.read_text())['result']
        except (OSError, ValueError, KeyError):
            raise Failure('UNEXPECTED_DEVICE_JSON') from None

    def probe(self, device_file):
        preferred = None
        if device_file:
            try:
                preferred = json.loads(device_file.read_text())['identifier']
                if not isinstance(preferred, str) or not preferred:
                    raise ValueError()
            except (OSError, ValueError, KeyError):
                raise Failure('INVALID_PRIVATE_DEVICE_FILE') from None
        record = self.device_json(['list', 'devices'], 'devices')
        selected = select_device(record.get('devices', []), preferred)
        (self.output / 'selected-device-private.json').write_text(json.dumps(selected))
        identifier = selected['identifier']
        lock = self.device_json(['device', 'info', 'lockState', '--device', identifier], 'lock')
        apps = self.device_json(['device', 'info', 'apps', '--device', identifier,
                                 '--bundle-id', APP], 'apps')
        summary = {'connectedPairedIpad': True,
                   'passcodeRequired': lock.get('passcodeRequired'),
                   'harnessInstalled': any(item.get('bundleIdentifier') == APP
                                           for item in apps.get('apps', []))}
        (self.output / 'probe-safe.json').write_text(json.dumps(summary, indent=2))
        print('DEVICE_ACCEPTANCE:CONNECTED_PAIRED_IPAD', flush=True)
        print('DEVICE_ACCEPTANCE:LOCKED' if summary['passcodeRequired'] else
              'DEVICE_ACCEPTANCE:UNLOCKED' if summary['passcodeRequired'] is False else
              'DEVICE_ACCEPTANCE:LOCK_STATE_UNKNOWN', flush=True)
        print('DEVICE_ACCEPTANCE:HARNESS_INSTALLED' if summary['harnessInstalled'] else
              'DEVICE_ACCEPTANCE:HARNESS_NOT_INSTALLED', flush=True)
        return identifier, summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['probe', 'status', 'build', 'run'])
    parser.add_argument('--output', type=Path, help='New private output directory, preferably under build/')
    parser.add_argument('--device-file', type=Path, help='Private JSON with identifier; needed only for multiple iPads')
    parser.add_argument('--signing-file', type=Path, help='Private build settings JSON; omitted means unsigned compile only')
    parser.add_argument('--xctestrun', type=Path, help='Signed independent runner from build-for-testing')
    parser.add_argument('--check', choices=CHECKS, default='page')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    output = args.output or root.parents[1] / 'build/device-acceptance' / datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
    os.umask(0o077)
    try:
        session = Session(output)
        if args.action == 'build':
            command = ['xcodebuild', '-project', str(root / 'UITests/DeviceAcceptance/DeviceAcceptance.xcodeproj'),
                       '-scheme', 'DeviceAcceptance', 'build-for-testing', '-sdk', 'iphoneos',
                       '-destination', 'generic/platform=iOS', '-derivedDataPath', str(session.output / 'derived')]
            if args.signing_file:
                settings = json.loads(args.signing_file.read_text())
                allowed = {'DEVELOPMENT_TEAM', 'PROVISIONING_PROFILE_SPECIFIER', 'CODE_SIGN_STYLE'}
                if (not isinstance(settings, dict) or not settings.get('DEVELOPMENT_TEAM')
                        or set(settings) - allowed or not all(isinstance(v, str) and v for v in settings.values())):
                    raise Failure('INVALID_PRIVATE_SIGNING_SETTINGS')
                command.extend(key + '=' + value for key, value in settings.items())
            else:
                command.append('CODE_SIGNING_ALLOWED=NO')
            session.run(command, 'build', timeout=600)
            runs = list((session.output / 'derived/Build/Products').glob('*.xctestrun'))
            if len(runs) != 1:
                raise Failure('RUNNER_TEST_CONFIGURATION_MISSING')
            print('DEVICE_ACCEPTANCE:SIGNED_BUILD_COMPLETE' if args.signing_file else
                  'DEVICE_ACCEPTANCE:UNSIGNED_BUILD_ONLY', flush=True)
            return 0
        identifier, summary = session.probe(args.device_file)
        if args.action == 'probe':
            return 0
        if not summary['harnessInstalled']:
            raise Failure('HARNESS_NOT_INSTALLED')
        if summary['passcodeRequired'] is not False:
            raise Failure('DEVICE_LOCKED_OR_LOCK_STATE_UNKNOWN')
        if args.action == 'status':
            destination = session.output / 'runtime-status-private.json'
            session.run(['xcrun', 'devicectl', 'device', 'copy', 'from', '--device', identifier,
                         '--domain-type', 'appDataContainer', '--domain-identifier', APP,
                         '--source', 'Library/Application Support/HarnessRuntime/RuntimeStatus.json',
                         '--destination', str(destination), '--timeout', '30'], 'status', timeout=45)
            stage = safe_stage(json.loads(destination.read_text()))
            print('DEVICE_ACCEPTANCE:RECORDED_STAGE=' + stage, flush=True)
            return 0
        if not args.xctestrun:
            raise Failure('SIGNED_XCTESTRUN_REQUIRED')
        prepared = session.output / 'independent.xctestrun'
        prepare_test_run(args.xctestrun, prepared, args.check)
        log = session.run(['xcodebuild', 'test-without-building', '-xctestrun', str(prepared),
                           '-destination', 'platform=iOS,id=' + identifier,
                           '-only-testing:' + TARGET + '/AcceptanceUITests/' + CHECKS[args.check],
                           '-resultBundlePath', str(session.output / 'checks.xcresult')], 'ui-test', timeout=600)
        text = log.read_text(errors='replace')
        completion = {'page': 'existingPageInteractive', 'settings': 'settingsEntriesPresent=true',
                      'short-background': 'existingInputValueEqual=true',
                      'session-reply': 'existingSessionExpectedReplySeen'}[args.check]
        if 'HARNESS_UI_SAFE:' + completion not in text:
            if 'skipped' in text and 'HARNESS_UI_' in text:
                print('DEVICE_ACCEPTANCE:CHECK_SKIPPED=' + args.check, flush=True)
                return 2
            raise Failure('CHECK_NOT_EXECUTED_OR_COMPLETION_MARKER_MISSING')
        # Whitelist only bounded markers; never relay arbitrary XCTest output.
        for line in text.splitlines():
            if re.fullmatch(r'HARNESS_UI_SAFE:[A-Za-z0-9_= .\-]+', line):
                print(line, flush=True)
        print('DEVICE_ACCEPTANCE:CHECK_COMPLETE=' + args.check, flush=True)
        return 0
    except (Failure, OSError, ValueError, KeyError, TypeError, AttributeError, plistlib.InvalidFileException) as error:
        marker = str(error) if isinstance(error, Failure) else 'LOCAL_CONFIGURATION_OR_OUTPUT_ERROR'
        print('DEVICE_ACCEPTANCE:BLOCKED=' + marker, flush=True)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
