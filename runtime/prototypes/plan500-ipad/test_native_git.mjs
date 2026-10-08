// Differential test: native read-only git against /usr/bin/git on the same repositories.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {spawnSync} from 'node:child_process';
import {createContext, runInContext} from 'node:vm';
import {test, after} from 'node:test';

const GIT = '/usr/bin/git';
const skip = spawnSync(GIT, ['--version']).status === 0 ? false : 'no /usr/bin/git';
const context = createContext({TextEncoder, TextDecoder});
for (const name of ['native-git-objects.js', 'native-git-match.js', 'native-git-xdiff.js', 'native-git.js']) {
  runInContext(fs.readFileSync(new URL(`./web/${name}`, import.meta.url), 'utf8'), context, {filename: name});
}
const native = context.DshNativeGit.run;

// Node fs with lstat reduced to number fields plus nanosecond times, as the iPad bridge gives them.
const low = value => Number(BigInt.asUintN(32, value));
const hostFs = {
  ...fs,
  lstatSync(path) {
    const s = fs.lstatSync(path, {bigint: true});
    return {dev: low(s.dev), ino: low(s.ino), mode: Number(s.mode), uid: Number(s.uid), gid: Number(s.gid), size: Number(s.size),
      mtimeNs: s.mtimeNs, ctimeNs: s.ctimeNs, mtimeMs: Number(s.mtimeMs), ctimeMs: Number(s.ctimeMs)};
  },
};

const root = fs.realpathSync(fs.mkdtempSync(join(tmpdir(), 'native-git-')));
after(() => fs.rmSync(root, {recursive: true, force: true}));
const home = join(root, 'home');
fs.mkdirSync(home);
const base = {PATH: '/usr/bin:/bin', HOME: home, GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: '/dev/null', GIT_ATTR_NOSYSTEM: '1',
  GIT_CONFIG_COUNT: '0', GIT_TERMINAL_PROMPT: '0', GIT_OPTIONAL_LOCKS: '0', LC_ALL: 'C'};
const author = {GIT_AUTHOR_NAME: 't', GIT_AUTHOR_EMAIL: 't@t', GIT_COMMITTER_NAME: 't', GIT_COMMITTER_EMAIL: 't@t',
  GIT_AUTHOR_DATE: '1700000000 +0000', GIT_COMMITTER_DATE: '1700000000 +0000'};

let serial = 0;
/** Plain git for building fixtures. */
function sh(cwd, ...args) {
  const r = spawnSync(GIT, args, {cwd, env: {...base, ...author}, encoding: 'utf8'});
  if (r.status !== 0) throw new Error(`git ${args.join(' ')}: ${r.stderr}`);
  return r.stdout.trim();
}
const write = (dir, name, data, mode) => {
  fs.mkdirSync(join(dir, name, '..'), {recursive: true});
  fs.writeFileSync(join(dir, name), data);
  if (mode !== undefined) fs.chmodSync(join(dir, name), mode);
};
function repo(files = {}, config = {}) {
  const dir = join(root, `r${serial++}`);
  fs.mkdirSync(dir);
  sh(dir, 'init', '-q', '-b', 'main');
  for (const [k, v] of Object.entries({'core.ignorecase': 'false', 'core.precomposeunicode': 'false', ...config})) sh(dir, 'config', k, v);
  for (const [name, data] of Object.entries(files)) write(dir, name, data);
  return dir;
}
const commit = (dir, message = 'c') => {
  sh(dir, 'add', '-A');
  sh(dir, 'commit', '-q', '--allow-empty', '-m', message);
  return sh(dir, 'rev-parse', 'HEAD^{tree}');
};

function parseIndex(buf) {
  if (buf.length < 12) return buf.toString('hex');
  const count = buf.readUInt32BE(8);
  const out = [];
  let at = 12;
  for (let i = 0; i < count; i++) {
    const flags = buf.readUInt16BE(at + 60);
    const start = at + 62 + (flags & 0x4000 ? 2 : 0);
    const end = buf.indexOf(0, start);
    out.push({name: buf.subarray(start, end).toString('latin1'), mode: buf.readUInt32BE(at + 24).toString(8),
      oid: buf.subarray(at + 40, at + 60).toString('hex'), stage: (flags >> 12) & 3, stat: buf.subarray(at, at + 40).toString('hex')});
    at += ((start - at) + (end - start) + 8) & ~7;
  }
  return out;
}
/** Object names in a directory, loose or packed (git streams big files into a pack). */
function objectNames(dir) {
  if (!fs.existsSync(dir)) return [];
  const names = fs.readdirSync(dir).filter(d => /^[0-9a-f]{2}$/.test(d)).flatMap(d => fs.readdirSync(join(dir, d)).map(f => d + f));
  const packs = join(dir, 'pack');
  for (const idx of fs.existsSync(packs) ? fs.readdirSync(packs).filter(n => n.endsWith('.idx')) : []) {
    const buf = fs.readFileSync(join(packs, idx));
    const count = buf.readUInt32BE(8 + 255 * 4);
    for (let i = 0; i < count; i++) names.push(buf.subarray(8 + 1024 + i * 20, 8 + 1024 + (i + 1) * 20).toString('hex'));
  }
  return names.sort();
}
/** Every path under .git with its size and mtime, to prove native git never writes there. */
function snapshot(dir) {
  const out = [];
  const walk = p => {
    const st = fs.lstatSync(p, {bigint: true});
    out.push(`${p} ${st.mode} ${st.size} ${st.mtimeNs}`);
    if (st.isDirectory()) for (const n of fs.readdirSync(p).sort()) walk(join(p, n));
  };
  walk(dir);
  return out.join('\n');
}

/**
 * Run one plugin call through both gits. State (index copy and scratch objects) is cloned per side;
 * the repository itself is shared and must stay untouched by native git.
 */
function both(dir, argv, {cwd = dir, env = {}, stdin, state, gitdir = join(dir, '.git')} = {}) {
  const sides = {};
  const before = snapshot(gitdir);
  for (const side of ['native', 'git']) {
    let sideEnv = {...base, ...env};
    let copy = null;
    if (state) {
      copy = `${state}.${side}`;
      fs.rmSync(copy, {recursive: true, force: true});
      fs.cpSync(state, copy, {recursive: true, preserveTimestamps: true});
      sideEnv = JSON.parse(JSON.stringify(sideEnv).replaceAll(state, copy));
    }
    let r;
    if (side === 'git') {
      const p = spawnSync(GIT, argv, {cwd, env: sideEnv, input: stdin ?? ''});
      r = {exitCode: p.status, stdout: p.stdout, stderr: p.stderr.toString('utf8')};
    } else {
      r = native({argv: ['git', ...argv], cwd, env: sideEnv, stdin}, hostFs);
      r = {...r, stdout: Buffer.from(r.stdout)};
      assert.equal(snapshot(gitdir), before, `native git wrote inside ${gitdir}`);
    }
    const scrub = s => (copy ? s.replaceAll(copy, '<STATE>') : s);
    sides[side] = {exitCode: r.exitCode, stdout: scrub(r.stdout.toString('latin1')), stderr: scrub(r.stderr)};
    if (copy) {
      const index = join(copy, 'index');
      sides[side].index = fs.existsSync(index) ? parseIndex(fs.readFileSync(index)) : null;
      sides[side].objects = objectNames(join(copy, 'objects'));
      sides[side].leftovers = fs.readdirSync(copy).filter(n => n.endsWith('.lock'));
    }
  }
  assert.deepEqual(sides.native, sides.git, `git ${argv.join(' ')}`);
  if (state) {
    fs.rmSync(state, {recursive: true});
    fs.renameSync(`${state}.git`, state);
    fs.rmSync(`${state}.native`, {recursive: true});
  }
  return sides.git;
}

/** A plugin session: scratch state seeded from the repo index, as dsh-workspace-changes does. */
function session(dir, {gitdir = join(dir, '.git'), scratch = join(root, `s${serial++}`), excludes = []} = {}) {
  fs.mkdirSync(join(scratch, 'objects'), {recursive: true});
  if (fs.existsSync(join(gitdir, 'index'))) fs.copyFileSync(join(gitdir, 'index'), join(scratch, 'index'));
  const objects = sh(dir, 'rev-parse', '--git-path', 'objects');
  const env = {GIT_INDEX_FILE: join(scratch, 'index'), GIT_OBJECT_DIRECTORY: join(scratch, 'objects'),
    GIT_ALTERNATE_OBJECT_DIRECTORIES: objects.startsWith('/') ? objects : join(dir, objects)};
  const call = (argv, extra = {}) => both(dir, argv, {env, state: scratch, gitdir, ...extra});
  const add = () => call(['add', '--all', '--ignore-errors', ...(excludes.length ? ['--', '.', ...excludes.map(p => `:(exclude)${p}`)] : [])]);
  /** The whole plugin pipeline against a base tree; returns the new tree. */
  const changes = baseTree => {
    both(dir, ['rev-parse', '--show-toplevel', '--absolute-git-dir', '--git-path', 'objects'], {gitdir});
    add();
    const tree = call(['write-tree']).stdout.trim();
    if (baseTree) call(['diff-tree', '-r', '-M', '-z', '--numstat', baseTree, tree]);
    const listed = call(['ls-files', '-z', '--stage']).stdout.split('\0').filter(Boolean);
    for (const line of listed) {
      const [meta, path] = line.split('\t');
      const lsTree = call(['ls-tree', '-z', '-l', tree, '--', path], {env: {...env, GIT_LITERAL_PATHSPECS: '1'}});
      if (meta.startsWith('100') && lsTree.stdout) call(['cat-file', 'blob', meta.split(' ')[1]]);
    }
    return tree;
  };
  return {env, scratch, call, add, changes};
}

test('plugin pipeline over Chinese paths, symlinks, binary, large and executable files', {skip}, () => {
  const dir = repo({'a.txt': 'one\ntwo\n', '中文/文件.md': '你好\n世界\n', 'bin.dat': Buffer.from([0, 1, 2, 3, 0]), 'sub/deep/x.js': 'x\n'},
    {'core.bigFileThreshold': '2k'});
  fs.symlinkSync('a.txt', join(dir, 'link'));
  const base = commit(dir);
  write(dir, 'a.txt', 'one\nTWO\nthree\n');
  write(dir, '中文/新的 文件.txt', '新\n');
  write(dir, 'big.txt', 'line\n'.repeat(1000));
  write(dir, 'run.sh', '#!/bin/sh\n', 0o755);
  fs.rmSync(join(dir, 'bin.dat'));
  fs.rmSync(join(dir, 'link'));
  fs.symlinkSync('中文/文件.md', join(dir, 'link'));
  fs.renameSync(join(dir, 'sub/deep/x.js'), join(dir, 'sub/y.js'));
  session(dir).changes(base);
});

test('ignore rules, the scratch exclude inside an ignored directory, and check-ignore', {skip}, () => {
  const dir = repo({'.gitignore': '*.log\n!keep.log\nbuild/\n/root-only\nnode_modules\n.dsh/\n', 'src/.gitignore': 'gen-*\n!gen-ok\n',
    'tracked.log': 'x\n'});
  sh(dir, 'add', '-f', 'tracked.log');
  write(dir, '.git/info/exclude', 'secret*\n');
  const base = commit(dir);
  for (const name of ['a.log', 'keep.log', 'build/out.o', 'root-only', 'src/root-only', 'src/gen-1', 'src/gen-ok', 'secret.txt',
    'node_modules/m/index.js', 'dir with space/f', 'tracked.log', '.dsh/scratch/x']) write(dir, name, `${name}\n`);
  const s = session(dir, {scratch: join(dir, '.dsh', 'scratch', 's'), excludes: ['.dsh/scratch']});
  s.changes(base);
  const paths = ['a.log', 'keep.log', 'build', 'build/out.o', 'build/missing', 'root-only', 'src/root-only', 'src/gen-1', 'src/gen-ok',
    'secret.txt', 'node_modules', 'node_modules/m/index.js', 'dir with space/f', 'tracked.log', 'nope', '.dsh/scratch/x', 'src', '中文.log'];
  s.call(['check-ignore', '-z', '--stdin'], {stdin: paths.join('\0') + '\0'});
  s.call(['check-ignore', '-z', '--stdin'], {stdin: 'src/gen-ok\0'});
});

test('attributes, CRLF conversion and safecrlf warnings', {skip}, () => {
  for (const config of [{}, {'core.autocrlf': 'true'}, {'core.autocrlf': 'input'}, {'core.eol': 'crlf'}, {'core.safecrlf': 'warn', 'core.autocrlf': 'true'}]) {
    const dir = repo({'.gitattributes': '*.txt text\n*.crlf text eol=crlf\n*.lf eol=lf\n*.bin binary\n*.nodiff -diff\nauto/** text=auto\n*.raw -text\n',
      'old.txt': 'a\r\nb\r\n', 'auto/had-cr.c': 'x\r\ny\n'}, config);
    const base = commit(dir);
    const files = {'a.txt': 'a\r\nb\r\n', 'b.crlf': 'a\nb\n', 'c.lf': 'a\r\nb\r\n', 'd.bin': 'a\r\n\0', 'e.nodiff': 'text\n', 'f.raw': 'x\r\n',
      'g.other': 'mixed\r\nline\n', 'auto/x.c': 'x\r\ny\r\n', 'auto/bin.c': 'x\0\r\n', 'auto/had-cr.c': 'x\r\ny\r\nz\n', 'old.txt': 'a\nb\nc\n'};
    for (const [name, data] of Object.entries(files)) write(dir, name, data);
    session(dir).changes(base);
  }
});

test('exact, inexact and limited rename detection', {skip}, () => {
  const lines = n => Array.from({length: n}, (_, i) => `line ${i} of a reasonably long file body\n`).join('');
  const dir = repo({'a/same.txt': lines(20), 'b/dup1.txt': 'dup\n', 'b/dup2.txt': 'dup\n', 'c/edit.txt': lines(40), 'd/base.md': lines(30),
    'e/gone.txt': lines(10), 'crlf.txt': lines(12).replaceAll('\n', '\r\n')});
  const base = commit(dir);
  fs.mkdirSync(join(dir, 'moved'));
  fs.renameSync(join(dir, 'a/same.txt'), join(dir, 'moved/same.txt'));
  fs.mkdirSync(join(dir, 'x'));
  fs.renameSync(join(dir, 'b/dup1.txt'), join(dir, 'x/dup1.txt'));
  write(dir, 'x/dup3.txt', 'dup\n');
  write(dir, 'y/edit.txt', lines(40).replace('line 7', 'LINE 7').replace('line 30', 'changed'));
  fs.rmSync(join(dir, 'c/edit.txt'));
  write(dir, 'z/base.md', lines(25) + 'new tail\n');
  fs.rmSync(join(dir, 'd/base.md'));
  fs.rmSync(join(dir, 'e/gone.txt'));
  write(dir, 'crlf2.txt', lines(12));
  fs.rmSync(join(dir, 'crlf.txt'));
  session(dir).changes(base);
  sh(dir, 'config', 'diff.renameLimit', '1');
  session(dir).changes(base);
});

test('nested repositories, gitlinks and unmerged entries', {skip}, () => {
  const dir = repo({'f.txt': 'base\n'});
  const inner = join(dir, 'inner');
  fs.mkdirSync(inner);
  sh(inner, 'init', '-q');
  write(inner, 'g.txt', 'g\n');
  commit(inner);
  const base = commit(dir);
  sh(dir, 'checkout', '-q', '-b', 'other');
  write(dir, 'f.txt', 'other\n');
  commit(dir);
  sh(dir, 'checkout', '-q', 'main');
  write(dir, 'f.txt', 'main\n');
  commit(dir);
  spawnSync(GIT, ['merge', 'other'], {cwd: dir, env: {...base, ...author}});
  write(inner, 'g.txt', 'changed\n');
  commit(inner);
  const empty = join(dir, 'emptyrepo');
  fs.mkdirSync(empty);
  sh(empty, 'init', '-q');
  const s = session(dir);
  assert.match(s.call(['ls-files', '-z', '--stage']).stdout, / [123]\tf\.txt\0/);
  assert.match(s.call(['write-tree']).stderr, /f\.txt: unmerged/);
  assert.match(s.add().stderr, /embedded git repository|does not have a commit/);
  s.changes(base);
});

test('packed objects, a linked worktree and a subdirectory cwd', {skip}, () => {
  const dir = repo({'p/one.txt': 'one\n', 'p/two.txt': 'two\n'.repeat(50)});
  const first = commit(dir);
  write(dir, 'p/two.txt', 'two\n'.repeat(49) + 'three\n');
  commit(dir);
  sh(dir, 'gc', '-q');
  const wt = join(root, `wt${serial++}`);
  sh(dir, 'worktree', 'add', '-q', wt);
  write(wt, 'p/one.txt', 'one changed\n');
  write(wt, 'new.txt', 'n\n');
  const gitdir = sh(wt, 'rev-parse', '--absolute-git-dir');
  session(wt, {gitdir}).changes(first);
  session(dir).changes(first);
  both(dir, ['rev-parse', '--show-toplevel', '--absolute-git-dir', '--git-path', 'objects'], {cwd: join(dir, 'p')});
  both(wt, ['rev-parse', '--show-toplevel', '--absolute-git-dir', '--git-path', 'objects'], {cwd: join(wt, 'p'), gitdir});
});

test('rev-parse -q --verify HEAD: unborn, branch, detached, packed refs and a linked worktree', {skip}, () => {
  const verify = ['rev-parse', '-q', '--verify', 'HEAD'];
  const dir = repo({'f.txt': 'f\n', 'sub/g.txt': 'g\n'});
  assert.equal(both(dir, verify).exitCode, 1);  // unborn branch: no output, exit 1
  commit(dir);
  assert.equal(both(dir, verify).exitCode, 0);
  both(dir, verify, {cwd: join(dir, 'sub')});
  commit(dir, 'second');
  sh(dir, 'pack-refs', '--all');
  assert.equal(fs.existsSync(join(dir, '.git/refs/heads/main')), false);
  assert.equal(both(dir, verify).exitCode, 0);
  sh(dir, 'checkout', '-q', '--detach', 'HEAD~1');
  assert.equal(both(dir, verify).stdout, sh(dir, 'rev-parse', 'HEAD') + '\n');
  sh(dir, 'symbolic-ref', 'HEAD', 'refs/heads/topic');
  assert.equal(both(dir, verify).exitCode, 1);  // HEAD names a branch that does not exist
  sh(dir, 'checkout', '-q', 'main');
  const wt = join(root, `wt${serial++}`);
  sh(dir, 'worktree', 'add', '-q', '-b', 'side', wt, 'HEAD~1');
  const gitdir = sh(wt, 'rev-parse', '--absolute-git-dir');
  assert.equal(both(wt, verify, {gitdir}).stdout, sh(wt, 'rev-parse', 'HEAD') + '\n');
});

test('lock conflicts, unreadable files and missing objects', {skip}, () => {
  const dir = repo({'ok.txt': 'ok\n', 'locked.txt': 'l\n'});
  const base = commit(dir);
  const s = session(dir);
  write(s.scratch, 'index.lock', '');
  assert.match(s.add().stderr, /Unable to create '<STATE>\/index\.lock': File exists/);
  s.call(['write-tree']);
  fs.rmSync(join(s.scratch, 'index.lock'));
  write(dir, 'locked.txt', 'secret\n', 0o000);
  write(dir, 'new-unreadable.txt', 'n\n', 0o000);
  try {
    assert.match(s.add().stderr, /Permission denied/);
  } finally {
    fs.chmodSync(join(dir, 'locked.txt'), 0o644);
    fs.chmodSync(join(dir, 'new-unreadable.txt'), 0o644);
  }
  const missing = '0123456789012345678901234567890123456789';
  s.call(['cat-file', 'blob', missing]);
  s.call(['ls-tree', '-z', '-l', missing, '--', 'ok.txt']);
  s.call(['ls-tree', '-z', '-l', base, '--', 'nope.txt']);
  s.call(['diff-tree', '-r', '-M', '-z', '--numstat', base, missing]);
});

test('seeded fuzz of ignore patterns through add and check-ignore', {skip}, () => {
  let seed = 39;
  const rand = n => {
    seed = (Math.imul(seed, 1103515245) + 12345) >>> 0;
    return seed % n;
  };
  const pick = list => list[rand(list.length)];
  const parts = ['a', 'b', 'log', '中', 'x y', '.hidden', 'deep'];
  const patterns = ['*.log', '!*.log', 'a/', '/b', '**/deep', 'a/**', '!a/b', '中*', '[ab]', 'x?y', '\\!x', '#c', 'deep/', '!deep/',
    '*', '!a', 'b/*/c', '/**/a', 'log/', 'a\\ ', '?'];
  const outcomes = new Set();
  for (let round = 0; round < 25; round++) {
    const ignore = Array.from({length: 1 + rand(5)}, () => pick(patterns)).join('\n') + '\n';
    const paths = new Set();
    for (let k = 0; k < 8; k++) paths.add(Array.from({length: 1 + rand(3)}, () => pick(parts)).join('/') + (rand(3) ? '' : '.log'));
    const files = {'.gitignore': ignore};
    const sorted = [...paths].sort();
    for (const path of sorted) {
      if (sorted.some(other => other.startsWith(`${path}/`))) continue;
      files[path] = `${path}\n`;
    }
    const dir = repo(files);
    write(dir, 'sub/.gitignore', pick(patterns) + '\n');
    write(dir, 'sub/a.log', 'x\n');
    const s = session(dir);
    s.add();
    const r = s.call(['check-ignore', '-z', '--stdin'], {stdin: [...sorted, 'sub/a.log', 'sub', 'a', 'deep/none'].join('\0') + '\0'});
    outcomes.add(r.exitCode);
  }
  assert.deepEqual([...outcomes].sort(), [0, 1]);
});

test('unsupported requests fail closed with exit 128', {skip}, () => {
  const dir = repo({'f.txt': 'f\n', 'sub/g.txt': 'g\n'});
  const tree = commit(dir);
  const s = session(dir);
  const refuse = (argv, opts = {}) => {
    const r = native({argv: ['git', ...argv], cwd: opts.cwd ?? dir, env: {...base, ...s.env, ...opts.env}}, hostFs);
    const label = `${argv.join(' ')} ${JSON.stringify(opts)}`;
    assert.equal(r.exitCode, 128, label);
    assert.match(r.stderr, /^fatal: native git: unsupported: /, label);
  };
  refuse(['add', '--all', '--ignore-errors'], {cwd: join(dir, 'sub')});
  refuse(['add', '--all', '--ignore-errors', '--', '*.txt']);
  refuse(['add', '--all', '--ignore-errors', '--', '.', ':(exclude)s*']);
  refuse(['add', '-A']);
  refuse(['commit', '-m', 'x']);
  refuse(['rev-parse', '--verify', 'HEAD']);
  refuse(['rev-parse', '-q', '--verify', 'main']);
  refuse(['ls-tree', '-z', '-l', 'HEAD', '--', 'f.txt']);
  refuse(['cat-file', 'blob', 'HEAD:f.txt']);
  refuse(['diff-tree', '-r', '-M', '-z', '--numstat', 'HEAD', tree]);
  refuse(['write-tree'], {env: {GIT_INDEX_FILE: undefined}});
  refuse(['write-tree'], {env: {GIT_OBJECT_DIRECTORY: join(dir, '.git', 'objects')}});
  refuse(['add', '--all', '--ignore-errors'], {env: {GIT_INDEX_FILE: join(dir, '.git', 'index')}});
  fs.mkdirSync(join(dir, 'sub', 'objects'));
  refuse(['add', '--all', '--ignore-errors'], {env: {GIT_OBJECT_DIRECTORY: join(dir, 'sub', 'objects')}});
  refuse(['write-tree'], {env: {GIT_DIR: join(dir, '.git')}});
  refuse(['write-tree'], {env: {GIT_CONFIG_GLOBAL: join(home, 'config')}});
  refuse(['write-tree'], {env: {GIT_CONFIG_COUNT: '1', GIT_CONFIG_KEY_0: 'core.autocrlf', GIT_CONFIG_VALUE_0: 'true'}});
  sh(dir, 'config', 'filter.lfs.clean', 'cat');
  write(dir, '.gitattributes', '*.bin filter=lfs\n');
  write(dir, 'x.bin', 'x\n');
  refuse(['add', '--all', '--ignore-errors']);
  assert.deepEqual(fs.readdirSync(join(dir, 'sub', 'objects')), []);
});
