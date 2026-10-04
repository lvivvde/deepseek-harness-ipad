import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('device_acceptance', Path(__file__).parents[1] / 'device-acceptance.py')
device = importlib.util.module_from_spec(spec)
spec.loader.exec_module(device)


def ipad(identifier='fixture-device', **connection):
    return {'identifier': identifier, 'properties': {
        'hardware': {'deviceType': 'iPad', 'reality': 'physical'},
        'connection': {'state': 'connected', 'pairingState': 'paired', **connection}}}


class DeviceAcceptanceTests(unittest.TestCase):
    def test_single_paired_physical_ipad(self):
        self.assertEqual(device.select_device([ipad()])['identifier'], 'fixture-device')

    def test_ambiguous_devices_require_private_selection(self):
        with self.assertRaisesRegex(device.Failure, 'MULTIPLE_IPADS'):
            device.select_device([ipad('first'), ipad('second')])
        self.assertEqual(device.select_device([ipad('first'), ipad('second')], 'second')['identifier'], 'second')

    def test_selected_device_must_still_be_connected(self):
        with self.assertRaisesRegex(device.Failure, 'NO_CONNECTED'):
            device.select_device([ipad(state='disconnected')], 'fixture-device')

    def test_unpaired_or_simulator_cannot_be_selected(self):
        simulated = ipad()
        simulated['properties']['hardware']['reality'] = 'simulated'
        with self.assertRaises(device.Failure):
            device.select_device([simulated, ipad(pairingState='unpaired')])

    def test_legacy_xcode_device_shape(self):
        self.assertEqual(device.select_device([{'identifier': 'fixture-device',
            'hardwareProperties': {'deviceType': 'iPad', 'reality': 'physical'},
            'connectionProperties': {'tunnelState': 'connected', 'pairingState': 'paired'}}])['identifier'], 'fixture-device')

    def test_modern_disconnected_state_overrides_legacy(self):
        item = ipad(state='disconnected')
        item['connectionProperties'] = {'tunnelState': 'connected', 'pairingState': 'paired'}
        with self.assertRaises(device.Failure):
            device.select_device([item])

    def runner(self):
        return {'DeviceAcceptanceUITests': {'IsUITestBundle': True,
            'TestHostBundleIdentifier': 'org.lvivvde.harness.acceptance.xctrunner',
            'TestHostPath': '__TESTROOT__/DeviceAcceptanceUITests-Runner.app',
            'TestBundlePath': '__TESTHOST__/PlugIns/DeviceAcceptanceUITests.xctest',
            'DependentProductPaths': ['__TESTROOT__/DeviceAcceptanceUITests-Runner.app',
                '__TESTROOT__/DeviceAcceptanceUITests-Runner.app/PlugIns/DeviceAcceptanceUITests.xctest']}}

    def prepare(self, settings):
        with tempfile.TemporaryDirectory() as path:
            root = Path(path)
            source = root / 'source.xctestrun'
            source.write_bytes(plistlib.dumps(settings))
            destination = root / 'moved.xctestrun'
            device.prepare_test_run(source, destination)
            return plistlib.loads(destination.read_bytes())['DeviceAcceptanceUITests']

    def test_independent_runner_keeps_only_runner_products(self):
        settings = self.prepare(self.runner())
        self.assertTrue(settings['UseUITargetAppProvidedByTests'])
        self.assertEqual(settings['EnvironmentVariables']['HARNESS_ACCEPTANCE_CHECK'], 'page')
        self.assertNotIn('__TESTROOT__', settings['TestHostPath'])

    def test_formal_app_dependency_is_rejected(self):
        for field in ['UITargetAppPath', 'DependentProductPaths']:
            settings = self.runner()
            settings['DeviceAcceptanceUITests'][field] = ('__TESTROOT__/HarnessApp.app' if field == 'UITargetAppPath'
                else ['__TESTROOT__/HarnessApp.app'])
            with self.assertRaisesRegex(device.Failure, 'MUST_NOT_INSTALL_TARGET_APP'):
                self.prepare(settings)

    def test_wrong_runner_or_multiple_targets_rejected(self):
        settings = self.runner()
        settings['DeviceAcceptanceUITests']['TestHostBundleIdentifier'] = device.APP
        with self.assertRaises(device.Failure):
            self.prepare(settings)
        settings = self.runner()
        settings['DeviceAcceptanceUITests']['TestHostPath'] = '__TESTROOT__/HarnessApp.app'
        with self.assertRaises(device.Failure):
            self.prepare(settings)
        settings = self.runner()
        settings['SecondTarget'] = dict(settings['DeviceAcceptanceUITests'])
        with self.assertRaises(device.Failure):
            self.prepare(settings)

    def test_status_does_not_relay_unknown_or_secret_values(self):
        self.assertEqual(device.safe_stage({'stage': 'recovery:pageReady'}), 'recovery:pageReady')
        self.assertEqual(device.safe_stage({'stage': 'secret-marker-value'}), 'UNRECOGNIZED_STAGE')

    def test_failure_classifier_returns_only_fixed_reason(self):
        with tempfile.TemporaryDirectory() as path:
            log = Path(path) / 'private.log'
            log.write_text('Private device and account values\nTimed out while enabling automation mode')
            self.assertEqual(device.classify_log(log), 'UI_AUTOMATION_AUTHORIZATION_TIMEOUT')


if __name__ == '__main__':
    unittest.main()
