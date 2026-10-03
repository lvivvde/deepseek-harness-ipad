import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

CLEANUP = Path(__file__).resolve().parents[1] / 'guest/clean-locks.cjs'

@unittest.skipUnless(shutil.which('node'), 'Node is required for the real guest recovery script')
class GuestRecoveryTests(unittest.TestCase):
    def test_cold_boot_removes_old_harness_lock_even_when_pid_was_reused(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            lock = home / 'config.json.lock'
            lock.write_text(str(os.getpid()) + '\n')
            state = home / 'config.json'
            state.write_text('{"preserve":true}')
            other = home / 'unrelated.lock'
            other.write_text('user-owned-lock-format')
            subprocess.run(['node', str(CLEANUP), '--cold-boot'], env=dict(os.environ, DSH_HOME=directory), check=True)
            self.assertFalse(lock.exists())
            self.assertEqual(state.read_text(), '{"preserve":true}')
            self.assertEqual(other.read_text(), 'user-owned-lock-format')

if __name__ == '__main__':
    unittest.main()
