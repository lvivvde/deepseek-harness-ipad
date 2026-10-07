#!/usr/bin/env python3
"""Build the #39 gate 3 synthetic project with system git and write it as one manifest.

The research app recreates this tree in its own container; no user project is ever read.
Covers bytes, Chinese paths, a symlink, an executable bit, large and binary files, .gitignore,
CRLF, and a working tree that differs from HEAD (modify, delete, rename, untracked).
"""
import base64
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import zlib

LARGE_ROWS = 200_000


def png(width, height, rgb):
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
    rows = b''.join(b'\x00' + bytes(rgb) * width for _ in range(height))
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(rows)) + chunk(b'IEND', b''))


def git(root, *args):
    env = {'PATH': os.environ['PATH'], 'HOME': str(root), 'GIT_CONFIG_NOSYSTEM': '1', 'LC_ALL': 'C',
           'GIT_AUTHOR_NAME': 'Gate Three', 'GIT_AUTHOR_EMAIL': 'gate3@example.invalid',
           'GIT_COMMITTER_NAME': 'Gate Three', 'GIT_COMMITTER_EMAIL': 'gate3@example.invalid',
           'GIT_AUTHOR_DATE': '2026-10-01T00:00:00Z', 'GIT_COMMITTER_DATE': '2026-10-01T00:00:00Z'}
    subprocess.run(['git', *args], cwd=root, env=env, check=True, stdout=subprocess.DEVNULL)


def build(root):
    files = {
        '.gitignore': b'*.log\nbuild/\n',
        'README.md': '# 演示\r\nline two\r\n'.encode(),
        'src/中文/文件.md': '中文内容\n第二行 GATE3_NEEDLE\n'.encode(),
        'src/main.js': b'export const answer = 42;\n// GATE3_NEEDLE in code\n',
        'bin.dat': bytes(range(256)) * 4,
        'tool.sh': b'#!/bin/sh\necho gate3\n',
        'large.txt': ''.join(f'row {i:06d} alpha\n' for i in range(LARGE_ROWS)).encode(),
        'image.png': png(4, 4, (200, 30, 30)),
        'deleted.txt': b'removed in the working tree\n',
        'moved-from.txt': b'renamed in the working tree\n',
        'staged.txt': b'staged before the turn\n',
    }
    for name, data in files.items():
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
    (root / 'tool.sh').chmod(0o755)
    os.symlink('src/中文/文件.md', root / 'link')
    git(root, 'init', '--quiet', '--template=', '-b', 'main')
    for key, value in (('core.ignorecase', 'false'), ('core.precomposeunicode', 'false'), ('core.autocrlf', 'false'),
                       ('core.filemode', 'true'), ('core.symlinks', 'true')):
        git(root, 'config', key, value)
    git(root, 'add', '-A')
    git(root, 'commit', '--quiet', '-m', 'gate 3 fixture')
    # Pre-turn working tree state the change summary must see through.
    (root / 'deleted.txt').unlink()
    (root / 'moved-from.txt').rename(root / 'moved-to.txt')
    (root / 'staged.txt').write_bytes(b'staged before the turn, changed\n')
    git(root, 'add', 'staged.txt')
    (root / 'untracked.txt').write_bytes(b'untracked before the turn\n')
    (root / 'debug.log').write_bytes(b'ignored GATE3_NEEDLE\n')
    (root / 'build').mkdir()
    (root / 'build/out.txt').write_bytes(b'ignored output GATE3_NEEDLE\n')


def manifest(root):
    entries = []
    for directory, names, files in os.walk(root):
        names.sort(); files.sort()
        base = Path(directory)
        for name in list(names):
            path = base / name
            relative = str(path.relative_to(root))
            if path.is_symlink():
                entries.append({'path': relative, 'type': 'symlink', 'target': os.readlink(path)})
                names.remove(name)
            else:
                entries.append({'path': relative, 'type': 'dir', 'mode': path.stat().st_mode & 0o777})
        for name in files:
            path = base / name
            relative = str(path.relative_to(root))
            if path.is_symlink():
                entries.append({'path': relative, 'type': 'symlink', 'target': os.readlink(path)})
            else:
                entries.append({'path': relative, 'type': 'file', 'mode': path.stat().st_mode & 0o777,
                                'data': base64.b64encode(path.read_bytes()).decode()})
    return {'version': 1, 'entries': entries}


def main():
    if len(sys.argv) != 2:
        raise SystemExit('usage: gate3_fixture.py OUTPUT.json')
    with tempfile.TemporaryDirectory() as scratch:
        root = Path(scratch) / 'project'
        root.mkdir()
        build(root)
        Path(sys.argv[1]).write_text(json.dumps(manifest(root)) + '\n')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
