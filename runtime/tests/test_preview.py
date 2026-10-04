import os
from pathlib import Path
import shutil
import subprocess
import unittest


@unittest.skipUnless(shutil.which('node'), 'Node is required for the guest preview HTTP integration')
class PreviewTests(unittest.TestCase):
    def test_discovery_http_and_websocket_share_loopback_forwarding(self):
        script = Path(__file__).with_name('preview-integration.cjs')
        result = subprocess.run(['node', str(script)], capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('PREVIEW_OK', result.stdout)
