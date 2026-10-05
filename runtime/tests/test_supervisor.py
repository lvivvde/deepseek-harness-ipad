from pathlib import Path
import subprocess
import unittest

class SupervisorTests(unittest.TestCase):
    def test_only_a_dead_writable_harness_can_restart_and_backup_stops_writers(self):
        result = subprocess.run(['node', str(Path(__file__).with_name('supervisor-integration.cjs'))], capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('PASS:supervisor', result.stdout)

    def test_backup_waits_for_a_slowly_exiting_harness_but_not_for_other_writers(self):
        result = subprocess.run(['node', str(Path(__file__).with_name('supervisor-stop-integration.cjs'))], capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('PASS:supervisor-stop', result.stdout)
