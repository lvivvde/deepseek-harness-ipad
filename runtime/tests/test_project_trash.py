import os
import importlib.util
from pathlib import Path
import shutil
import subprocess
import unittest

MODULES = Path(os.environ.get('HARNESS_TEST_MODULES', '/private/tmp/ipad-runtime-harness/node_modules'))
SCRIPT = Path(__file__).with_name('project-trash-integration.mjs')


@unittest.skipUnless(shutil.which('node') and shutil.which('npm') and (MODULES / '@deepseek-ai/dsh-workspace/lib/index.js').exists(),
                     'Prepare the pinned Harness dependencies and set HARNESS_TEST_MODULES to run the official registry integration')
class ProjectTrashTests(unittest.TestCase):
    def run_case(self, mode):
        result = subprocess.run(['node', str(SCRIPT), mode],
                                env=dict(os.environ, HARNESS_TEST_MODULES=str(MODULES),
                                         HARNESS_NPM_ROOT=str(Path(shutil.which('npm')).resolve().parents[1])),
                                capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('PASS:' + mode, result.stdout)

    def test_deleting_project_retires_sidebar_and_old_conversations(self):
        self.run_case('delete')

    def test_emptying_pre_fix_trash_retires_old_sidebar_registration(self):
        self.run_case('legacy')

    def test_registry_failure_preserves_project_data(self):
        self.run_case('unavailable')

    def test_purging_old_trash_preserves_new_workspace_with_same_name(self):
        self.run_case('reused-name')

    def test_runtime_patch_registers_the_lifecycle_plugin_in_official_composition(self):
        spec = importlib.util.spec_from_file_location('runtime_builder', SCRIPT.parents[1] / 'build-runtime.py')
        builder = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(builder)
        result = subprocess.run(['node', str(SCRIPT), 'composition'],
                                env=dict(os.environ, HARNESS_TEST_MODULES=str(MODULES),
                                         HARNESS_IPAD_PATCH=builder.ipad_profile_patch()),
                                capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('PASS:composition', result.stdout)
