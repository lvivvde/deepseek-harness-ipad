#!/usr/bin/env python3
"""Real-QEMU recovery checks using only fresh, disposable user-disk fixtures.

Run on Linux after building the guest. This never accepts an existing user disk.
"""
import argparse
import hashlib
import json
import re
from pathlib import Path
import socket
import subprocess
import tempfile
import time

def check(guest, name, version, full):
    with tempfile.TemporaryDirectory(prefix='harness-boot-check-') as directory:
        root = Path(directory)
        tree = root / 'seed'
        (tree / 'Documents/Projects').mkdir(parents=True)
        (tree / '.cache/node-compile-cache').mkdir(parents=True)
        (tree / '.harness-layout-version').write_text(str(version) + '\n')
        disk = root / 'user.raw'
        with disk.open('xb') as stream: stream.truncate(64 * 1024 * 1024)
        subprocess.run(['mke2fs', '-q', '-t', 'ext4', '-F', '-m', '0', '-d', str(tree), str(disk)], check=True)
        if full:
            content = root / 'fill'
            content.write_bytes(b'x' * 64 * 1024 * 1024)
            subprocess.run(['debugfs', '-w', '-R', 'write ' + str(content) + ' /full', str(disk)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
        before = hashlib.sha256(disk.read_bytes()).hexdigest()
        channel = root / 'serial.sock'
        arguments = ['qemu-system-aarch64', '-machine', 'virt', '-cpu', 'cortex-a72', '-smp', '1', '-m', '512',
                     '-accel', 'tcg', '-nodefaults', '-display', 'none', '-monitor', 'none',
                     '-serial', 'unix:' + str(channel) + ',server=on,wait=on',
                     '-netdev', 'user,id=net0', '-device', 'virtio-net-pci,netdev=net0,romfile=',
                     '-kernel', str(guest / 'Image'), '-initrd', str(guest / 'initramfs.gz'),
                     '-append', 'console=ttyAMA0 rdinit=/init',
                     '-drive', 'file=' + str(guest / 'system.raw') + ',if=none,id=system,format=raw,readonly=on',
                     '-device', 'virtio-blk-pci,drive=system',
                     '-drive', 'file=' + str(disk) + ',if=none,id=user,format=raw', '-device', 'virtio-blk-pci,drive=user']
        process = subprocess.Popen(arguments, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        connection = socket.socket(socket.AF_UNIX)
        try:
            deadline = time.monotonic() + 60
            while not channel.exists() and process.poll() is None and time.monotonic() < deadline:
                time.sleep(.05)
            connection.connect(str(channel))
            connection.settimeout(1)
            buffer = b''
            while time.monotonic() < deadline:
                try:
                    data = connection.recv(65536)
                    if not data: break
                    buffer += data
                    if re.search(rb'HARNESS_BOOT_ERROR:[A-Z_]+\r?\n', buffer) or b'HARNESS_INIT_READY' in buffer: break
                except socket.timeout: pass
            expected = b'HARNESS_BOOT_ERROR:' + name.encode()
            correct_error = expected in buffer and b'HARNESS_INIT_READY' not in buffer
        finally:
            connection.close()
            process.terminate()
            try: process.wait(timeout=5)
            except subprocess.TimeoutExpired: process.kill(); process.wait()
        unchanged = hashlib.sha256(disk.read_bytes()).hexdigest() == before
        result = dict(case=name, enteredRescue=correct_error, diskUnchanged=unchanged,
                      observedErrors=[item.decode() for item in re.findall(rb'HARNESS_BOOT_ERROR:([A-Z_]+)', buffer)])
        print(json.dumps(result), flush=True)
        return correct_error and (unchanged if not full else True)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('guest', type=Path)
    args = parser.parse_args()
    future = check(args.guest, 'USER_LAYOUT', 2, False)
    full = check(args.guest, 'USER_SPACE', 1, True)
    raise SystemExit(0 if future and full else 1)

if __name__ == '__main__':
    main()
