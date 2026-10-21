#!/usr/bin/env python3
"""Read-only iPad connection probe; stdout contains fixed diagnostics only."""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import subprocess


APP = 'org.lvivvde.harness.candidate'


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
                # A cabled iPad lists as disconnected until devicectl first opens its tunnel.
                and (state == 'connected' or connection.get('transportType') == 'wired')
                and isinstance(item.get('identifier'), str)):
            candidates.append(item)
    if preferred:
        candidates = [item for item in candidates if item['identifier'] == preferred]
    if not candidates:
        raise Failure('NO_CONNECTED_PAIRED_IPAD')
    if len(candidates) != 1:
        raise Failure('MULTIPLE_IPADS_SELECT_WITH_PRIVATE_DEVICE_FILE')
    return candidates[0]


def classify_log(log):
    text = log.read_text(errors='replace')
    for marker, fragments in [
        ('APP_SLOT_FULL', ['maximum number of', 'Maximum number of']),
        ('DEVICE_LOCKED', ['device is locked', 'Device is locked']),
        ('CLI_SIGNING_ACCOUNT_UNAVAILABLE', ['No Accounts']),
        ('PROFILE_MISSING', ['No profiles for']),
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
                   'appInstalled': any(item.get('bundleIdentifier') == APP
                                       for item in apps.get('apps', []))}
        (self.output / 'probe-safe.json').write_text(json.dumps(summary, indent=2))
        print('DEVICE:CONNECTED_PAIRED_IPAD', flush=True)
        print('DEVICE:LOCKED' if summary['passcodeRequired'] else
              'DEVICE:UNLOCKED' if summary['passcodeRequired'] is False else
              'DEVICE:LOCK_STATE_UNKNOWN', flush=True)
        print('DEVICE:APP_INSTALLED' if summary['appInstalled'] else
              'DEVICE:APP_NOT_INSTALLED', flush=True)
        return identifier, summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['probe'])
    parser.add_argument('--output', type=Path, help='New private output directory, preferably under build/')
    parser.add_argument('--device-file', type=Path, help='Private JSON with identifier; needed only for multiple iPads')
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    output = args.output or repo / 'build/device-acceptance' / datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
    os.umask(0o077)
    try:
        Session(output).probe(args.device_file)
        return 0
    except (Failure, OSError, ValueError, KeyError, TypeError, AttributeError) as error:
        marker = str(error) if isinstance(error, Failure) else 'LOCAL_CONFIGURATION_OR_OUTPUT_ERROR'
        print('DEVICE:BLOCKED=' + marker, flush=True)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
