"""Candidate App build guards: only verified guest inputs and the prepared web root go into the bundle."""
import importlib.util
import json
from pathlib import Path
import plistlib
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('candidate_build', Path(__file__).with_name('build.py'))
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)


class Guards(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        root = Path(self.temporary.name)
        self.inputs = root / 'inputs'; self.inputs.mkdir()
        self.manifest = {'files': {}, 'leaseSourceSha256': {}}
        for name in build.FILES:
            (self.inputs / name).write_bytes(('synthetic-' + name).encode())
            self.manifest['files'][name] = build.digest(self.inputs / name)
        for name in ('init.sh', 'agent.cjs'):
            self.manifest['leaseSourceSha256'][name] = build.digest(build.LEASE / name)
        (self.inputs / 'token-private').write_text('synthetic-token-for-testing')
        self.save()
        self.web = root / 'web'; self.web.mkdir()
        files = {}
        for name in ('index.html', 'worker.js', 'connector.js', *build.GIT_SCRIPTS):
            (self.web / name).write_text('synthetic ' + name)
            files[name] = build.digest(self.web / name)
        (self.web / 'candidate-receipt.json').write_text(json.dumps({'files': files}))

    def save(self):
        (self.inputs / 'inputs.json').write_text(json.dumps(self.manifest))

    def testVerifiedInputsAndWebPass(self):
        self.assertEqual(build.validate_inputs(self.inputs)['files'], self.manifest['files'])
        self.assertIn('worker.js', build.validate_web(self.web)['files'])

    def testExtraGuestDiskIsRefused(self):
        self.manifest['files']['user.raw'] = 'untrusted'; self.save()
        with self.assertRaisesRegex(ValueError, 'INPUT_SET_REFUSED'):
            build.validate_inputs(self.inputs)

    def testChangedGuestInputIsRefused(self):
        (self.inputs / 'system.raw').write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError, 'INPUT_HASH_MISMATCH'):
            build.validate_inputs(self.inputs)

    def testPreparedGuestMustMatchCommittedAgent(self):
        self.manifest['leaseSourceSha256']['agent.cjs'] = 'changed'; self.save()
        with self.assertRaisesRegex(ValueError, 'GUEST_SOURCE_CHANGED'):
            build.validate_inputs(self.inputs)

    def testMalformedTokenIsRefused(self):
        (self.inputs / 'token-private').write_text('short')
        with self.assertRaisesRegex(ValueError, 'TOKEN_FORMAT_REFUSED'):
            build.validate_inputs(self.inputs)

    def testChangedWebFileIsRefused(self):
        (self.web / 'worker.js').write_text('changed')
        with self.assertRaisesRegex(ValueError, 'WEB_HASH_MISMATCH'):
            build.validate_web(self.web)

    def testWebWithoutTheBridgeIsRefused(self):
        receipt = json.loads((self.web / 'candidate-receipt.json').read_text())
        del receipt['files']['connector.js']
        (self.web / 'candidate-receipt.json').write_text(json.dumps(receipt))
        with self.assertRaisesRegex(ValueError, 'WEB_SET_REFUSED'):
            build.validate_web(self.web)

    def testOutputOutsideIgnoredBuildIsRefused(self):
        with self.assertRaisesRegex(ValueError, 'OUTPUT_MUST_BE_IN_IGNORED_BUILD'):
            build.check_output(Path(self.temporary.name) / 'app')

    def testGeneratedProjectIsTheSeparateUnsignedMacApp(self):
        xcode = build.project(Path(self.temporary.name) / 'out', 'macosx')
        project = plistlib.loads((xcode / 'project.pbxproj').read_bytes())
        objects = project['objects'].values()
        settings = next(o['buildSettings'] for o in objects if o['isa'] == 'XCBuildConfiguration')
        self.assertEqual(settings['PRODUCT_BUNDLE_IDENTIFIER'], 'org.lvivvde.harness.candidate')
        self.assertEqual(settings['SDKROOT'], 'macosx')
        self.assertEqual(sorted(o['productName'] for o in objects if o['isa'] == 'XCSwiftPackageProductDependency'),
                         ['HarnessCandidate', 'ModelGateway'])
        sources = sorted(p.name for p in (xcode.parent / 'Sources').iterdir())
        self.assertEqual(sources, sorted(p.name for p in build.APP_SOURCES.glob('*.swift')))

        info = plistlib.loads((xcode.parent / 'Info.plist').read_bytes())
        self.assertEqual(info['NSPrincipalClass'], 'NSApplication')

    def testGeneratedIPadProjectEmbedsTheExecutor(self):
        xcode = build.project(Path(self.temporary.name) / 'out', 'iphoneos')
        objects = plistlib.loads((xcode / 'project.pbxproj').read_bytes())['objects'].values()
        settings = next(o['buildSettings'] for o in objects if o['isa'] == 'XCBuildConfiguration')
        self.assertEqual(settings['PRODUCT_BUNDLE_IDENTIFIER'], 'org.lvivvde.harness.candidate')
        self.assertEqual((settings['SDKROOT'], settings['TARGETED_DEVICE_FAMILY']), ('iphoneos', '2'))
        self.assertIn('@executable_path/Frameworks', settings['LD_RUNPATH_SEARCH_PATHS'])
        info = plistlib.loads((xcode.parent / 'Info.plist').read_bytes())
        self.assertTrue(info['LSRequiresIPhoneOS'])
        self.assertNotIn('NSPrincipalClass', info)
        script = next(o['shellScript'] for o in objects if o['isa'] == 'PBXShellScriptBuildPhase')
        self.assertIn('CANDIDATE_EXECUTOR', script)

    def executor(self, names=('qemu-aarch64-softmmu.framework', 'slirp.0.framework')):
        executor = Path(self.temporary.name) / 'executor'
        records = []
        for name in names:
            folder = executor / 'Frameworks' / name; folder.mkdir(parents=True)
            binary = folder / name.removesuffix('.framework'); binary.write_bytes(name.encode())
            records.append({'framework': name, 'sha256': build.digest(binary)})
        (executor / 'frameworks.json').write_text(json.dumps({'frameworks': records}))
        return executor

    def testVerifiedExecutorPasses(self):
        self.assertEqual(len(build.validate_executor(self.executor())), 2)

    def testExecutorWithoutQemuIsRefused(self):
        with self.assertRaisesRegex(ValueError, 'EXECUTOR_CLOSURE_REFUSED'):
            build.validate_executor(self.executor(('slirp.0.framework',)))

    def testExecutorWithAnUnlistedFrameworkIsRefused(self):
        executor = self.executor()
        (executor / 'Frameworks/extra.framework').mkdir()
        with self.assertRaisesRegex(ValueError, 'EXECUTOR_CLOSURE_REFUSED'):
            build.validate_executor(executor)

    def testChangedExecutorIsRefused(self):
        executor = self.executor()
        (executor / 'Frameworks/slirp.0.framework/slirp.0').write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError, 'EXECUTOR_HASH_MISMATCH'):
            build.validate_executor(executor)

    def testSigningSettingsAreLimitedToTheTeamAndProfile(self):
        path = Path(self.temporary.name) / 'signing.json'
        path.write_text(json.dumps({'DEVELOPMENT_TEAM': 'TEAM'}))
        self.assertEqual(build.signing_settings(path), ['DEVELOPMENT_TEAM=TEAM'])
        path.write_text(json.dumps({'DEVELOPMENT_TEAM': 'TEAM', 'OTHER_LDFLAGS': '-x'}))
        with self.assertRaisesRegex(ValueError, 'SIGNING_SETTINGS_REFUSED'):
            build.signing_settings(path)


if __name__ == '__main__':
    unittest.main()
