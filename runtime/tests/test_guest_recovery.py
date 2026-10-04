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

    def test_git_partial_index_lock_is_preserved_and_new_git_writes_work(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            repository=root / 'projects/demo'
            repository.mkdir(parents=True)
            subprocess.run(['git','init','-q',str(repository)],check=True)
            (repository/'file').write_text('preserved project')
            lock=repository/'.git/index.lock'
            lock.write_bytes(b'partial index from killed writer')
            failed=subprocess.run(['git','-C',str(repository),'add','file'],capture_output=True)
            self.assertNotEqual(failed.returncode,0)
            subprocess.run(['node',str(CLEANUP),'--cold-boot'],env=dict(os.environ,DSH_HOME=str(root/'dsh'),HARNESS_PROJECTS=str(root/'projects')),check=True)
            self.assertFalse(lock.exists())
            preserved=list((repository/'.git').glob('harness-stale-index-*.lock'))
            self.assertEqual(len(preserved),1)
            self.assertEqual(preserved[0].read_bytes(),b'partial index from killed writer')
            subprocess.run(['git','-C',str(repository),'add','file'],check=True)
            self.assertEqual((repository/'file').read_text(),'preserved project')

if __name__ == '__main__':
    unittest.main()
