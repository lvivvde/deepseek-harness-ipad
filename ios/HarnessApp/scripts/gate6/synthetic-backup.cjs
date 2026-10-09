// Builds a synthetic old-app `/root`, exports it with the old app's own BackupManager.export (node-tar,
// portable) and writes what the migration must produce from it.
//
//   node synthetic-backup.cjs <work> <out> <variant> <npm-root>
//
// variant: base (any file system), case (case-only names; case-sensitive
// file system), unicode (NFC/NFD pair). <out> receives HarnessBackup.tar, its .sha256 sidecar and
// expected.json: every target path outside home/sessions with its type, digest or link target, and the
// mode node-tar recorded. There is no special-file variant: the old exporter stalls on a FIFO or socket
// until BACKUP_TIMEOUT (9 min), so a real backup never holds one; hand-built archives cover them.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const {spawnSync} = require('node:child_process');
const {createRequire} = require('node:module');
const {Writable} = require('node:stream');

const [work, out, variant, npmRoot] = process.argv.slice(2);
const tar = createRequire(path.join(npmRoot, 'package.json'))('tar');
const {BackupManager} = require(path.join(__dirname, '../../../../runtime/guest/backup.cjs'));
const root = path.join(work, 'root');

function file(relative, text, mode = 0o644) {
  fs.mkdirSync(path.dirname(path.join(root, relative)), {recursive: true});
  fs.writeFileSync(path.join(root, relative), text);
  fs.chmodSync(path.join(root, relative), mode);
}
function dir(relative, mode = 0o755) { fs.mkdirSync(path.join(root, relative), {recursive: true}); fs.chmodSync(path.join(root, relative), mode); }
function header(id, cwd) {
  const fields = {createdAt: '2026-09-01T00:00:00.000Z', delegationDepth: 0, id, isSeeded: false, type: 'session', version: 4};
  if (cwd) fields.cwd = cwd;
  return JSON.stringify(fields);
}
const body = '\n{"type":"user","text":"保持 /root/projects/demo"}\n';

fs.rmSync(work, {recursive: true, force: true});
fs.mkdirSync(root, {recursive: true});
file('.harness-layout-version', '1\n');
file('projects/演示/README.md', '# 演示\n');
file('projects/演示/src/main.sh', '#!/bin/sh\necho hi\n', 0o755);
file('projects/演示/private.txt', 'owner only', 0o600);
file('projects/演示/😀 空格.txt', 'emoji and space');
dir('projects/演示/空目录');
dir('projects/demo/empty');
file('projects/demo/a.txt', 'shared inode');
fs.linkSync(path.join(root, 'projects/demo/a.txt'), path.join(root, 'projects/demo/hard.txt'));
fs.symlinkSync('../演示/README.md', path.join(root, 'projects/demo/readme-link'));
fs.symlinkSync('missing/target', path.join(root, 'projects/demo/dangling'));
const deep = 'projects/demo/' + Array.from({length: 6}, (_, index) => '很长的目录名-' + index).join('/') + '/文件.txt';
file(deep, 'long pax path');
file('projects/demo/big.bin', crypto.createHash('sha256').update('seed').digest().toString('hex').repeat(40000));
file('projects/demo/ro/inside.txt', 'read only dir');
fs.chmodSync(path.join(root, 'projects/demo/ro'), 0o555);
file('projects/demo/node_modules/pkg/index.js', 'excluded by export');
file('projects/demo/.cache/x', 'excluded by export');
file('projects/demo/.git-credentials', 'excluded by export');
file('projects/demo/.restore-notes', 'user notes are kept');
file('.dsh/settings.json', '{"theme":"dark"}');
file('.dsh/.credentials.yaml', 'apiKey: synthetic-not-a-key');
file('.dsh/storages/session_projcache/demo.json', '{}');
const log = header('s-1', '/root/projects/demo') + body;
const compressed = spawnSync('zstd', ['-q', '-c'], {input: log});
if (compressed.status !== 0) throw Error('zstd failed');
file('.dsh/sessions/--root-projects-demo--/s-1/session.v4.jsonl.zstd', compressed.stdout);
file('.dsh/sessions/_no-cwd/s-2/session.v4.jsonl', header('s-2') + body);
file('.ssh/id_ed25519', 'synthetic credential');
file('.netrc', 'machine example.invalid password synthetic');
file('.gitconfig', '[user]\n\tname = Synthetic\n');
file('.local/share/notes.txt', 'linux home');
file('.trash/.purging-1/gone.txt', 'excluded by export');
file('.restore-stage-x/left.txt', 'excluded by export');

if (variant === 'case') {
  file('projects/demo/Readme.txt', 'upper');
  file('projects/demo/readme.TXT', 'lower');
} else if (variant === 'unicode') {
  file('projects/demo/café.txt', 'composed');
  file('projects/demo/café.txt', 'decomposed');
} else if (variant !== 'base') throw Error('unknown variant ' + variant);

// The target the migration must produce, outside home/sessions (checked through the report).
const credentials = new Set(['.dsh/.credentials.yaml', '.netrc', '.npmrc', '.pypirc', '.ssh', '.gnupg', '.docker/config.json', '.config/gh/hosts.yml']);
const skipped = new Set(['node_modules', '.cache', '.git-credentials']);
function mapped(relative) {
  const [top, ...rest] = relative.split('/');
  if (top === 'projects') return relative;
  if (top === '.dsh') return ['home', ...rest].join('/');
  return 'linux-home/' + relative;
}
const expected = {};
const sources = {};
const inodes = {};
function walk(relative) {
  for (const name of fs.readdirSync(path.join(root, relative))) {
    const child = relative ? relative + '/' + name : name;
    const parts = child.split('/');
    if (parts.some(part => skipped.has(part)) || (!relative && name.startsWith('.restore-')) || child.startsWith('.trash/.purging-')) continue;
    if ([...credentials].some(entry => child === entry || child.startsWith(entry + '/'))) continue;
    if (child === '.harness-layout-version' || child.startsWith('.dsh/storages/session_projcache') || child.startsWith('.dsh/sessions')) continue;
    const info = fs.lstatSync(path.join(root, child));
    const target = mapped(child);
    sources[target] = child;
    if (info.isDirectory()) { expected[target] = {type: 'directory', mode: (info.mode & 0o777) | 0o700}; walk(child); }
    else if (info.isSymbolicLink()) expected[target] = {type: 'symlink', link: fs.readlinkSync(path.join(root, child))};
    else if (info.isFile()) {
      expected[target] = {type: 'file', mode: (info.mode & 0o777) | 0o600,
        sha256: crypto.createHash('sha256').update(fs.readFileSync(path.join(root, child))).digest('hex')};
      if (info.nlink > 1) (inodes[info.ino] ||= []).push(target);
    }
  }
}
walk('');
for (const [top, value] of [['home', {type: 'directory', mode: 0o755}], ['linux-home', {type: 'directory', mode: 0o755}]]) expected[top] ||= value;

fs.mkdirSync(out, {recursive: true});
const archive = path.join(out, 'HarnessBackup.tar');
const chunks = [];
const manager = new BackupManager({root, tar,
  coordinator: {pause: async () => 'lease', resume: async () => {}},
  freeze: async () => async () => {}});
manager.export(new Writable({write(chunk, _encoding, callback) { chunks.push(chunk); callback(); }})).then(() => {
  const data = Buffer.concat(chunks);
  fs.writeFileSync(archive, data);
  // Modes as node-tar recorded them (portable mode normalises them), read back with node-tar itself.
  const modes = {};
  tar.t({file: archive, sync: true, onentry: entry => {
    const name = entry.path.replace(/\/$/, '');
    modes[name] = entry.type === 'Link' ? modes[entry.linkpath] : entry.mode;
  }});
  for (const [target, node] of Object.entries(expected)) {
    if (!sources[target] || node.type === 'symlink') continue;
    node.mode = (modes[sources[target]] & 0o777) | (node.type === 'directory' ? 0o700 : 0o600);
  }
  fs.writeFileSync(archive + '.sha256', crypto.createHash('sha256').update(data).digest('hex') + '  HarnessBackup.tar\n');
  fs.writeFileSync(path.join(out, 'expected.json'), JSON.stringify({variant, expected, hardlinks: Object.values(inodes)}, null, 1));
  fs.chmodSync(path.join(root, 'projects/demo/ro'), 0o755);
  console.log('EXPORTED ' + variant + ' ' + data.length);
  process.exit(0);
}, error => { console.log('EXPORT_FAILED ' + variant + ' ' + (error.code || error.message)); process.exit(3); });
