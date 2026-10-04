import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
MODULES = Path(os.environ.get('HARNESS_TEST_MODULES', '/private/tmp/ipad-runtime-harness/node_modules'))
spec = importlib.util.spec_from_file_location('builder', ROOT / 'build-runtime.py')
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)

@unittest.skipUnless((MODULES / '@deepseek-ai/dsh-client-ui-sidebar-terminal').exists(), 'Pinned official client dependencies required')
class ClientBridgeTests(unittest.TestCase):
    def test_bridge_calls_official_sidebar_and_cleans_up(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory)
            for package in ['dsh-client-ui-sidebar-terminal', 'dsh-client-ui-sidebar-browser']:
                shutil.copytree(MODULES / '@deepseek-ai' / package, target / 'node_modules/@deepseek-ai' / package)
            builder.patch_client_bridges(target)
            text = (target / 'node_modules/@deepseek-ai/dsh-client-ui-sidebar-browser/lib/client.js').read_text()
            seam = text.split("ctx.effect(() => {\n                const open = value =>", 1)[1].split("}, 'ipad.sidebar-preview');", 1)[0]
            script = """
                const assert = require('node:assert/strict');
                let dispose, opened;
                global.window = {}; global.document = {activeElement: {}};
                const ctx = {sidebarRight: {
                  commandTarget: () => ({paneId: 'live-pane'}),
                  openTab: (kind, options) => {opened = {kind, options};}
                }};
                dispose = (() => { const open = value =>""" + seam + """})();
                assert.equal(window.harnessOpenSidebarPreview('http://127.0.0.1:5173/'), true);
                assert.deepEqual(opened, {kind:'browser', options:{paneId:'live-pane', params:{url:'http://127.0.0.1:5173/'}}});
                assert.equal(window.harnessOpenSidebarPreview('https://example.com/'), false);
                ctx.sidebarRight.commandTarget = () => undefined;
                assert.equal(window.harnessOpenSidebarPreview('http://127.0.0.1:5173/'), false);
                dispose(); assert.equal(window.harnessOpenSidebarPreview, undefined);
            """
            subprocess.run(['node', '-e', script], check=True)

    def test_terminal_auxiliary_input_preserves_ime_and_uses_actual_model_input(self):
        swift = (ROOT.parent / 'ios/HarnessApp/Sources/Native/TerminalKeyRow.swift').read_text()
        bridge = swift.split('static let bridgeScript = """', 1)[1].split('"""', 1)[0]
        script = """
            const assert = require('node:assert/strict');
            const listeners = {}, inputs = [], states = [];
            const root = {harnessTerminalInput: data => inputs.push(data)};
            global.window = {webkit:{messageHandlers:{terminalState:{postMessage: state => states.push(state)}}}};
            global.document = {activeElement:{closest: () => root}, addEventListener:(name, fn) => {listeners[name] = fn;}};
        """ + bridge + """
            assert.equal(window.harnessSendTerminal('\\x1b[A'), true);
            window.harnessStickyControl = true;
            let prevented = false;
            listeners.beforeinput({data:'c', inputType:'insertText', preventDefault:() => {prevented=true;}});
            assert.equal(inputs.at(-1), '\\x03'); assert.equal(prevented, true);
            listeners.compositionstart();
            window.harnessStickyControl = true;
            assert.equal(window.harnessSendTerminal('\\t'), false);
            listeners.beforeinput({data:'中', isComposing:true, inputType:'insertText', preventDefault:() => {throw Error('IME intercepted');}});
            assert.equal(inputs.length, 2);
            listeners.compositionend();
            document.activeElement = {closest:() => null};
            assert.equal(window.harnessSendTerminal('/'), false);
        """
        subprocess.run(['node', '-e', script], check=True)
