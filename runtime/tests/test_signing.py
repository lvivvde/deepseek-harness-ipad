import hashlib
from datetime import datetime
import json
import os
from pathlib import Path
import plistlib
import subprocess
import stat
import sys
import tempfile
import unittest
import zipfile


SCRIPT = Path(__file__).resolve().parents[1] / 'check-signing.py'


class SigningCLITests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.baseline = self.root / 'baseline.ipa'
        self.candidate = self.root / 'candidate.ipa'
        for path in [self.baseline, self.candidate]:
            path.write_bytes(b'fixture IPA')
            Path(str(path) + '.sha256').write_text(hashlib.sha256(path.read_bytes()).hexdigest())
        self.output = self.root / 'private-output'
        self.calls = self.root / 'external-calls'
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        # Device tools are forbidden at the process boundary, even on failure.
        for name in ['xcrun', 'devicectl', 'xcodebuild']:
            executable = self.bin / name
            executable.write_text('#!' + sys.executable + '\nfrom pathlib import Path\n'
                                  + 'Path(' + repr(str(self.calls)) + ').write_text("device access")\n'
                                  + 'raise SystemExit(99)\n')
            executable.chmod(0o755)
        for name in ['codesign', 'security', 'openssl']:
            executable = self.bin / name
            executable.write_text('#!' + sys.executable + '''
import sys
from pathlib import Path
import plistlib
args = sys.argv[1:]
print('private-signing-secret', file=sys.stderr)
if Path(sys.argv[0]).name == 'security':
    sys.stdout.buffer.write(Path(args[args.index('-i') + 1]).read_bytes())
elif Path(sys.argv[0]).name == 'openssl':
    cert = Path(args[args.index('-in') + 1]).read_bytes().decode()
    print('notBefore=' + (cert.split('|')[2] if len(cert.split('|')) > 2 else 'Jan  1 00:00:00 2020 GMT'))
    print('notAfter=' + cert.split('|')[1])
else:
    app = Path(args[-1])
    if '--verify' in args and (app / 'bad-signature').exists():
        raise SystemExit(1)
    if '--entitlements' in args:
        sys.stdout.buffer.write((app / 'signed-entitlements.plist').read_bytes())
    for arg in args:
        if arg.startswith('--extract-certificates='):
            Path(arg.split('=', 1)[1] + '0').write_bytes((app / 'leaf.der').read_bytes())
''')
            executable.chmod(0o755)

    def ipa(self, path, team='fixture-private-team', prefix='fixture-private-prefix',
            bundle='org.lvivvde.harness.ipad', expires=None, certificate=None, extra=None, devices=None,
            implicit_keychain=False):
        entitlement = {'application-identifier': prefix + '.' + bundle,
                       'com.apple.developer.team-identifier': team,
                       'keychain-access-groups': [prefix + '.' + bundle]}
        certificate = certificate or b'fixture-private-cert|Oct 10 13:11:14 2035 GMT'
        profile = {'TeamIdentifier': [team], 'ApplicationIdentifierPrefix': [prefix],
                   'CreationDate': datetime(2020, 1, 1),
                   'ExpirationDate': expires or datetime(2035, 10, 10, 13, 11, 14),
                   'ProvisionedDevices': devices if devices is not None else ['fixture-private-device'],
                   'DeveloperCertificates': [certificate], 'Entitlements': entitlement}
        signed = dict(entitlement)
        if implicit_keychain:
            signed.pop('keychain-access-groups')
        files = {'Info.plist': plistlib.dumps({'CFBundleIdentifier': bundle}),
                 'embedded.mobileprovision': plistlib.dumps(profile),
                 'signed-entitlements.plist': plistlib.dumps(signed), 'leaf.der': certificate,
                 **(extra or {})}
        with zipfile.ZipFile(path, 'w') as archive:
            for name, data in files.items():
                archive.writestr('Payload/HarnessApp.app/' + name, data)
        Path(str(path) + '.sha256').write_text(hashlib.sha256(path.read_bytes()).hexdigest())

    def run_cli(self, extra_args=()):
        before = {p: p.read_bytes() for p in [self.baseline, self.candidate,
                  Path(str(self.baseline) + '.sha256'), Path(str(self.candidate) + '.sha256')]}
        result = subprocess.run([sys.executable, str(SCRIPT), '--baseline', str(self.baseline),
                                 '--candidate', str(self.candidate), '--output', str(self.output), *extra_args],
                                env={**os.environ, 'PATH': str(self.bin) + os.pathsep + os.environ['PATH']},
                                capture_output=True, text=True)
        self.assertFalse(self.calls.exists(), 'Signing inspection must never invoke device tools')
        for path, content in before.items():
            self.assertEqual(path.read_bytes(), content, 'Inspection must preserve input assets')
        self.assertNotIn(str(self.root), result.stdout + result.stderr)
        self.assertNotIn('fixture-private-', result.stdout + result.stderr)
        self.assertNotIn('private-signing-secret', result.stdout + result.stderr)
        return result

    def test_corrupt_baseline_is_rejected_without_device_access(self):
        Path(str(self.baseline) + '.sha256').write_text('0' * 64)
        result = self.run_cli()
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, 'SIGNING_CHECK:BLOCKED=BASELINE_CHECKSUM_MISMATCH\n')
        self.assertEqual(result.stderr, '')

    def test_different_team_cannot_replace_the_existing_container(self):
        self.ipa(self.baseline)
        self.ipa(self.candidate, team='another-private-team')
        result = self.run_cli()
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, 'SIGNING_CHECK:BLOCKED=SIGNING_IDENTITY_CHANGED\n')

    def test_expired_profile_cannot_be_reported_as_installable(self):
        self.ipa(self.baseline)
        self.ipa(self.candidate, expires=datetime(2020, 1, 1))
        result = self.run_cli()
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, 'SIGNING_CHECK:BLOCKED=CANDIDATE_VALIDITY_TOO_SHORT\n')

    def test_expired_certificate_blocks_a_future_dated_profile(self):
        self.ipa(self.baseline)
        self.ipa(self.candidate, certificate=b'fixture-private-cert|Jan  1 00:00:00 2020 GMT')
        result = self.run_cli()
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, 'SIGNING_CHECK:BLOCKED=CANDIDATE_VALIDITY_TOO_SHORT\n')

    def test_renewal_may_change_certificate_without_changing_the_container(self):
        self.ipa(self.baseline)
        self.ipa(self.candidate, certificate=b'fixture-private-new-cert|Oct 10 13:11:14 2036 GMT',
                 expires=datetime(2036, 10, 10, 13, 11, 14))
        result = self.run_cli()
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, 'SIGNING_CHECK:VALID_UNTIL_UTC=2036-10-10T13:11:14Z\nSIGNING_CHECK:COMPLETE\n')
        summary_text = (self.output / 'summary-safe.json').read_text()
        summary = json.loads(summary_text)
        self.assertTrue(summary['renewalExtended'])
        self.assertFalse(summary['deviceInstallationVerified'])
        self.assertEqual(summary['baselineValidUntilUTC'], '2035-10-10T13:11:14Z')
        self.assertNotIn('fixture-private-', summary_text)
        self.assertEqual(self.output.stat().st_mode & 0o777, 0o700)

    def test_profile_without_the_baseline_device_is_rejected(self):
        self.ipa(self.baseline)
        self.ipa(self.candidate, devices=['another-private-device'])
        result = self.run_cli()
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, 'SIGNING_CHECK:BLOCKED=BASELINE_DEVICES_NOT_PRESERVED\n')

    def test_invalid_signature_is_rejected_without_relaying_tool_output(self):
        self.ipa(self.baseline)
        self.ipa(self.candidate, extra={'bad-signature': b'fixture'})
        result = self.run_cli()
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, 'SIGNING_CHECK:BLOCKED=CANDIDATE_SIGNATURE_FAILED\n')
        self.assertIn('private-signing-secret', (self.output / 'CANDIDATE_signature-private.log').read_text())
        self.assertEqual((self.output / 'CANDIDATE_signature-private.log').stat().st_mode & 0o777, 0o600)

    def test_path_escape_archive_is_rejected_without_writing_outside_output(self):
        self.ipa(self.baseline)
        self.ipa(self.candidate, extra={'../../../escaped': b'fixture'})
        result = self.run_cli()
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, 'SIGNING_CHECK:BLOCKED=UNSAFE_IPA_LAYOUT\n')
        self.assertFalse((self.root / 'escaped').exists())

    def test_candidate_checksum_mismatch_is_rejected(self):
        self.ipa(self.baseline)
        self.ipa(self.candidate)
        Path(str(self.candidate) + '.sha256').write_text('0' * 64)
        result = self.run_cli()
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, 'SIGNING_CHECK:BLOCKED=CANDIDATE_CHECKSUM_MISMATCH\n')

    def test_different_bundle_or_app_prefix_is_rejected(self):
        for options, marker in [({'bundle': 'another.private.app'}, 'CANDIDATE_BUNDLE_ID_CHANGED'),
                                ({'prefix': 'another-private-prefix'}, 'SIGNING_IDENTITY_CHANGED')]:
            with self.subTest(options=options):
                self.ipa(self.baseline)
                self.ipa(self.candidate, **options)
                self.output = self.root / marker
                result = self.run_cli()
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stdout, 'SIGNING_CHECK:BLOCKED=' + marker + '\n')

    def test_malformed_profile_returns_fixed_error_without_traceback(self):
        self.ipa(self.baseline)
        self.ipa(self.candidate, extra={'embedded.mobileprovision': b'<plist>private-signing-secret'})
        result = self.run_cli()
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, 'SIGNING_CHECK:BLOCKED=LOCAL_INPUT_OR_OUTPUT_ERROR\n')
        self.assertEqual(result.stderr, '')

    def test_implicit_default_keychain_group_matches_explicit_app_group(self):
        self.ipa(self.baseline, implicit_keychain=True)
        self.ipa(self.candidate)
        result = self.run_cli()
        self.assertEqual(result.returncode, 0)
        self.assertTrue(json.loads((self.output / 'summary-safe.json').read_text())['sameContainerIdentity'])

    def test_certificate_that_is_not_yet_valid_is_rejected(self):
        self.ipa(self.baseline)
        self.ipa(self.candidate, certificate=b'fixture-private-cert|Oct 10 13:11:14 2036 GMT|Oct 10 13:11:14 2035 GMT')
        result = self.run_cli()
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, 'SIGNING_CHECK:BLOCKED=CANDIDATE_NOT_YET_VALID\n')

    def test_symlink_escape_is_rejected_and_existing_output_is_preserved(self):
        self.ipa(self.baseline)
        self.ipa(self.candidate)
        with zipfile.ZipFile(self.candidate, 'a') as archive:
            entry = zipfile.ZipInfo('Payload/HarnessApp.app/escape-link')
            entry.create_system = 3
            entry.external_attr = (stat.S_IFLNK | 0o777) << 16
            archive.writestr(entry, '../../../outside')
        Path(str(self.candidate) + '.sha256').write_text(hashlib.sha256(self.candidate.read_bytes()).hexdigest())
        result = self.run_cli()
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, 'SIGNING_CHECK:BLOCKED=UNSAFE_IPA_LINK\n')
        sentinel = self.output / 'keep-existing-evidence'
        sentinel.write_bytes(b'keep')
        result = self.run_cli()
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, 'SIGNING_CHECK:BLOCKED=LOCAL_INPUT_OR_OUTPUT_ERROR\n')
        self.assertEqual(sentinel.read_bytes(), b'keep')

    def test_expired_baseline_remains_usable_for_renewal_comparison(self):
        self.ipa(self.baseline, expires=datetime(2020, 10, 10))
        self.ipa(self.candidate)
        result = self.run_cli()
        self.assertEqual(result.returncode, 0)
        self.assertTrue(json.loads((self.output / 'summary-safe.json').read_text())['renewalExtended'])

    def test_invalid_arguments_are_redacted_before_any_output_is_created(self):
        result = self.run_cli(['--min-valid-hours', 'private-signing-secret'])
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, 'SIGNING_CHECK:BLOCKED=INVALID_ARGUMENTS\n')
        self.assertEqual(result.stderr, '')
        self.assertFalse(self.output.exists())


if __name__ == '__main__':
    unittest.main()
