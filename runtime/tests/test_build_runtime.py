import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

BUILDER = Path(__file__).resolve().parents[1] / 'build-runtime.py'

class RuntimeBuildTests(unittest.TestCase):
    def test_corrupt_locked_input_is_rejected_before_building(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'Image').write_bytes(b'corrupted kernel')
            lock = root / 'lock.json'
            lock.write_text(json.dumps({'inputs': [{'file': 'Image', 'sha256': hashlib.sha256(b'known kernel').hexdigest()}]}))
            result = subprocess.run([sys.executable, str(BUILDER), '--inputs', str(root), '--lock', str(lock), '--verify-inputs'], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Input digest mismatch: Image', result.stderr)

    def test_build_never_replaces_an_existing_output_or_user_seed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            lock = root / 'lock.json'
            lock.write_text(json.dumps({'inputs': []}))
            output = root / 'Guest'
            output.mkdir()
            seed = output / 'user-seed.raw'
            seed.write_bytes(b'preserve this disk')
            result = subprocess.run([sys.executable, str(BUILDER), '--inputs', str(root), '--lock', str(lock), '--output', str(output)], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Output already exists', result.stderr)
            self.assertEqual(seed.read_bytes(), b'preserve this disk')

if __name__ == '__main__':
    unittest.main()
