import os
from pathlib import Path
import shutil
import subprocess
import unittest

class BackupTests(unittest.TestCase):
    def test_full_data_roundtrip_exclusions_rollback_and_interrupted_restore(self):
        result=subprocess.run(['node',str(Path(__file__).with_name('backup-integration.cjs'))],env=dict(os.environ,HARNESS_NPM_ROOT=str(Path(shutil.which('npm')).resolve().parents[1])),capture_output=True,text=True,timeout=20)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('PASS:backup',result.stdout)
