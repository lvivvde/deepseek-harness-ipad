"""Negative input guards: do not substitute a production/user disk or an unverified executor."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('ipad_build', Path(__file__).with_name('build.py'))
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)


class InputGuards(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        root = Path(self.temporary.name)
        self.inputs = root / 'inputs'; self.inputs.mkdir()
        self.executor = root / 'executor'; self.executor.mkdir()
        self.manifest = {'files': {}, 'leaseSourceSha256': {}}
        for name in build.FILES:
            (self.inputs / name).write_bytes(('synthetic-' + name).encode())
            self.manifest['files'][name] = build.digest(self.inputs / name)
        for name in ('init.sh', 'agent.cjs'):
            self.manifest['leaseSourceSha256'][name] = build.digest(build.SOURCE.parent / 'plan500-lease' / name)
        (self.inputs / 'token-private').write_text('synthetic-token-for-testing')
        self.framework = self.executor / 'Frameworks/qemu-aarch64-softmmu.framework'
        self.framework.mkdir(parents=True)
        self.binary = self.framework / 'qemu-aarch64-softmmu'; self.binary.write_bytes(b'synthetic-executor')
        (self.executor / 'frameworks.json').write_text(json.dumps({'frameworks': [
            {'framework': self.framework.name, 'sha256': build.digest(self.binary)}]}))
        self.save()

    def save(self):
        (self.inputs / 'inputs.json').write_text(json.dumps(self.manifest))

    def testUserDiskInManifestIsRefusedBeforeOpeningIt(self):
        # Deliberately no user.raw file: a FileNotFoundError would reveal that it was opened.
        self.manifest['files']['user.raw'] = 'untrusted'; self.save()
        with self.assertRaisesRegex(ValueError, 'PROBE_INPUT_SET_REFUSED'):
            build.validate(self.inputs, self.executor)

    def testChangedGuestInputIsRefused(self):
        (self.inputs / 'system.raw').write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError, 'PROBE_INPUT_HASH_MISMATCH'):
            build.validate(self.inputs, self.executor)

    def testPreparedGuestMustMatchCommittedAgent(self):
        self.manifest['leaseSourceSha256']['agent.cjs'] = 'changed'; self.save()
        with self.assertRaisesRegex(ValueError, 'GUEST_SOURCE_CHANGED'):
            build.validate(self.inputs, self.executor)

    def testTamperedExecutorAndUnexpectedFrameworkAreRefused(self):
        self.binary.write_bytes(b'tampered')
        with self.assertRaisesRegex(ValueError, 'EXECUTOR_HASH_MISMATCH'):
            build.validate(self.inputs, self.executor)
        (self.executor / 'Frameworks/unexpected.framework').mkdir()
        with self.assertRaisesRegex(ValueError, 'EXECUTOR_CLOSURE_REFUSED'):
            build.validate(self.inputs, self.executor)


if __name__ == '__main__':
    unittest.main()
