#!/usr/bin/env python3
"""Read-only preflight for a same-container Harness IPA replacement; never installs."""
import argparse
from datetime import datetime, timedelta, timezone
from fnmatch import fnmatchcase
import hashlib
import json
import os
from pathlib import Path
import plistlib
import posixpath
import re
import shutil
import stat
import subprocess
import tempfile
import zipfile
from xml.parsers.expat import ExpatError


APP = 'org.lvivvde.harness.ipad'


class Failure(Exception):
    pass


class SafeArgumentParser(argparse.ArgumentParser):
    def error(self, message):
        raise Failure('INVALID_ARGUMENTS')


def verified_copy(source, destination, role):
    checksum = Path(str(source) + '.sha256').read_text().split()
    if not checksum or not re.fullmatch(r'[a-fA-F0-9]{64}', checksum[0]):
        raise Failure(role + '_CHECKSUM_INVALID')
    digest = hashlib.sha256()
    with source.open('rb') as original, destination.open('xb') as copy:
        while chunk := original.read(1024 * 1024):
            digest.update(chunk)
            copy.write(chunk)
    if digest.hexdigest() != checksum[0].lower():
        raise Failure(role + '_CHECKSUM_MISMATCH')
    return digest.hexdigest()


def extract_app(ipa, destination):
    with zipfile.ZipFile(ipa) as archive:
        entries = archive.infolist()
        names = [entry.filename.rstrip('/') for entry in entries]
        if (len(entries) > 100000 or len(set(names)) != len(names)
                or sum(entry.file_size for entry in entries) > 3 * 1024 ** 3):
            raise Failure('UNSAFE_IPA_LAYOUT')
        roots = set()
        links = {}
        for entry, name in zip(entries, names):
            parts = name.split('/')
            if (any(part in {'', '.', '..'} for part in parts) or '\\' in name
                    or any(ord(char) < 32 for char in name) or entry.flag_bits & 1
                    or parts[0] != 'Payload'):
                raise Failure('UNSAFE_IPA_LAYOUT')
            if len(parts) == 1 and entry.is_dir():
                continue
            if len(parts) < 2 or not parts[1].endswith('.app'):
                raise Failure('UNSAFE_IPA_LAYOUT')
            root = '/'.join(parts[:2])
            roots.add(root)
            mode = entry.external_attr >> 16
            if stat.S_ISLNK(mode):
                target = archive.read(entry).decode('utf-8')
                resolved = posixpath.normpath(posixpath.join(posixpath.dirname(name), target))
                if (target.startswith('/') or '\\' in target or '\x00' in target
                        or not (resolved == root or resolved.startswith(root + '/'))):
                    raise Failure('UNSAFE_IPA_LINK')
                links[name] = target
            elif stat.S_IFMT(mode) not in {0, stat.S_IFREG, stat.S_IFDIR}:
                raise Failure('UNSAFE_IPA_LAYOUT')
        if len(roots) != 1:
            raise Failure('UNSAFE_IPA_LAYOUT')
        for name in names:
            if any(parent.as_posix() in links for parent in Path(name).parents):
                raise Failure('UNSAFE_IPA_LINK')
        for entry, name in zip(entries, names):
            path = destination / name
            if name in links:
                continue
            if entry.is_dir():
                path.mkdir(parents=True, exist_ok=True)
            else:
                path.parent.mkdir(parents=True, exist_ok=True)
                with archive.open(entry) as source, path.open('xb') as output:
                    shutil.copyfileobj(source, output, 1024 * 1024)
                path.chmod((entry.external_attr >> 16) & 0o777 or 0o600)
        for name, target in links.items():
            path = destination / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.symlink_to(target)
        return destination / roots.pop()


def run_tool(command, output, label):
    try:
        result = subprocess.run(command, capture_output=True, timeout=90, check=False)
    except (OSError, subprocess.TimeoutExpired):
        raise Failure('LOCAL_SIGNING_TOOL_UNAVAILABLE_OR_TIMEOUT') from None
    (output / (label + '-private.log')).write_bytes(result.stdout + result.stderr)
    if result.returncode:
        raise Failure(label.upper() + '_FAILED')
    return result.stdout


def inspect(source, output, role):
    with tempfile.TemporaryDirectory(dir=output) as temporary:
        directory = Path(temporary)
        ipa = directory / 'verified.ipa'
        digest = verified_copy(source, ipa, role)
        app = extract_app(ipa, directory / 'unpacked')
        info = plistlib.loads((app / 'Info.plist').read_bytes())
        if info.get('CFBundleIdentifier') != APP:
            raise Failure(role + '_BUNDLE_ID_CHANGED')
        run_tool(['codesign', '--verify', '--deep', '--strict', str(app)], output, role + '_signature')
        signed = plistlib.loads(run_tool(['codesign', '-d', '--entitlements', ':-', str(app)],
                                        output, role + '_entitlements'))
        profile = plistlib.loads(run_tool(['security', 'cms', '-D', '-i', str(app / 'embedded.mobileprovision')],
                                         output, role + '_profile'))
        team = signed.get('com.apple.developer.team-identifier')
        identifier = signed.get('application-identifier')
        # Without an explicit group, iOS uses the application identifier.
        # Preserve order: the first group is the default for new keychain items.
        groups = signed.get('keychain-access-groups', [identifier])
        permitted = profile.get('Entitlements', {})
        prefixes = profile.get('ApplicationIdentifierPrefix', [])
        if (not isinstance(team, str) or not team or team not in profile.get('TeamIdentifier', [])
                or permitted.get('com.apple.developer.team-identifier') != team
                or identifier not in [prefix + '.' + APP for prefix in prefixes]
                or not fnmatchcase(identifier, permitted.get('application-identifier', ''))
                or not isinstance(groups, list) or not groups or not all(isinstance(g, str) for g in groups)
                or not all(any(fnmatchcase(group, pattern) for pattern in permitted.get('keychain-access-groups', []))
                           for group in groups)):
            raise Failure(role + '_SIGNING_METADATA_INVALID')
        expires = profile.get('ExpirationDate')
        created = profile.get('CreationDate')
        if not isinstance(expires, datetime) or not isinstance(created, datetime):
            raise Failure(role + '_SIGNING_METADATA_INVALID')
        devices = profile.get('ProvisionedDevices')
        if not isinstance(devices, list) or not devices or not all(isinstance(d, str) and d for d in devices):
            raise Failure(role + '_DEVELOPMENT_PROFILE_REQUIRED')
        certificate_prefix = directory / 'certificate-'
        run_tool(['codesign', '-d', '--extract-certificates=' + str(certificate_prefix), str(app)],
                 output, role + '_certificate')
        leaf = Path(str(certificate_prefix) + '0')
        if leaf.read_bytes() not in profile.get('DeveloperCertificates', []):
            raise Failure(role + '_CERTIFICATE_NOT_IN_PROFILE')
        dates = dict(line.split('=', 1) for line in run_tool(
            ['openssl', 'x509', '-inform', 'DER', '-in', str(leaf), '-noout', '-dates'],
            output, role + '_certificate_expiry').decode('ascii').strip().splitlines())
        certificate_expires = datetime.strptime(dates['notAfter'], '%b %d %H:%M:%S %Y GMT').replace(tzinfo=timezone.utc)
        certificate_starts = datetime.strptime(dates['notBefore'], '%b %d %H:%M:%S %Y GMT').replace(tzinfo=timezone.utc)
        if max(created.replace(tzinfo=timezone.utc), certificate_starts) > datetime.now(timezone.utc):
            raise Failure(role + '_NOT_YET_VALID')
        return {'identity': (team, identifier, groups), 'sha256': digest,
                'expires': min(expires.replace(tzinfo=timezone.utc), certificate_expires),
                'devices': set(devices)}


def main():
    parser = SafeArgumentParser(description=__doc__)
    parser.add_argument('--baseline', required=True, type=Path)
    parser.add_argument('--candidate', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path, help='New private local directory')
    parser.add_argument('--min-valid-hours', type=int, default=24,
                        help='Required candidate validity remaining (default 24 hours)')
    os.umask(0o077)
    try:
        args = parser.parse_args()
        if args.min_valid_hours < 0 or args.min_valid_hours > 8760:
            raise Failure('INVALID_MIN_VALID_HOURS')
        args.output.mkdir(parents=True, exist_ok=False, mode=0o700)
        baseline = inspect(args.baseline, args.output, 'BASELINE')
        candidate = inspect(args.candidate, args.output, 'CANDIDATE')
        if candidate['identity'] != baseline['identity']:
            raise Failure('SIGNING_IDENTITY_CHANGED')
        if not baseline['devices'].issubset(candidate['devices']):
            raise Failure('BASELINE_DEVICES_NOT_PRESERVED')
        if candidate['expires'] <= datetime.now(timezone.utc) + timedelta(hours=args.min_valid_hours):
            raise Failure('CANDIDATE_VALIDITY_TOO_SHORT')
        valid_until = candidate['expires'].strftime('%Y-%m-%dT%H:%M:%SZ')
        summary = {'baselineSHA256': baseline['sha256'], 'candidateSHA256': candidate['sha256'],
                   'baselineValidUntilUTC': baseline['expires'].strftime('%Y-%m-%dT%H:%M:%SZ'),
                   'candidateValidUntilUTC': valid_until,
                   'checkedAtUTC': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
                   'sameContainerIdentity': True, 'deviceInstallationVerified': False,
                   'renewalExtended': candidate['expires'] > baseline['expires']}
        (args.output / 'summary-safe.json').write_text(json.dumps(summary, indent=2) + '\n')
        print('SIGNING_CHECK:VALID_UNTIL_UTC=' + valid_until)
        print('SIGNING_CHECK:COMPLETE')
        return 0
    except (Failure, OSError, ValueError, TypeError, KeyError, AttributeError,
            plistlib.InvalidFileException, zipfile.BadZipFile, ExpatError,
            RuntimeError, NotImplementedError) as error:
        marker = str(error) if isinstance(error, Failure) else 'LOCAL_INPUT_OR_OUTPUT_ERROR'
        print('SIGNING_CHECK:BLOCKED=' + marker)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
