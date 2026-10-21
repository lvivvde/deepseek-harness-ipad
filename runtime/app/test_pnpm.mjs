// The candidate's native pnpm (#23), run against a fixture registry, a memory VFS and a stub package store.
import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import path from 'node:path';
import {createHash} from 'node:crypto';
import {gzipSync} from 'node:zlib';
import {existsSync, readFileSync} from 'node:fs';
import {fileURLToPath} from 'node:url';
import {EventEmitter} from 'node:events';

const here = path.dirname(fileURLToPath(import.meta.url));
const source = readFileSync(path.join(here, 'worker-pnpm.js'), 'utf8');
const profile = '/dsh/home/profiles/preview';

function memoryVfs() {
  const files = new Map(), directories = new Set(['/', '/dsh', '/dsh/home', '/dsh/home/profiles', profile]);
  const parents = p => { for (let d = path.posix.dirname(p); !directories.has(d); d = path.posix.dirname(d)) directories.add(d); };
  return {
    files, directories,
    existsSync: p => files.has(p) || directories.has(p),
    readFileSync: p => { if (!files.has(p)) throw Object.assign(new Error('ENOENT ' + p), {code: 'ENOENT'}); return files.get(p).bytes; },
    writeFileSync: (p, data, {mode = 0o644} = {}) => {
      if (!directories.has(path.posix.dirname(p))) throw Object.assign(new Error('ENOENT ' + p), {code: 'ENOENT'});
      files.set(p, {bytes: typeof data === 'string' ? Buffer.from(data) : Buffer.from(data), mode});
    },
    seed: (p, data, {mode = 0o644} = {}) => { parents(p); files.set(p, {bytes: Buffer.from(data), mode}); },
    mkdirSync: (p, {recursive} = {}) => { if (recursive) parents(p + '/x'); directories.add(p); },
    rmSync: p => {
      for (const key of [...files.keys()]) if (key === p || key.startsWith(p + '/')) files.delete(key);
      for (const key of [...directories]) if (key === p || key.startsWith(p + '/')) directories.delete(key);
    },
  };
}

// A ustar archive of `{path: text}` under `package/`, gzipped as registries serve it.
function tarball(entries) {
  const blocks = [];
  for (const [name, text] of Object.entries(entries)) {
    const body = Buffer.from(text), header = Buffer.alloc(512);
    header.write('package/' + name, 0);
    header.write('0000644\0', 100); header.write('0000000\0', 108); header.write('0000000\0', 116);
    header.write(body.length.toString(8).padStart(11, '0') + '\0', 124);
    header.write('00000000000\0', 136); header.write('        ', 148); header.write('0', 156); header.write('ustar\x0000', 257);
    let sum = 0; for (const byte of header) sum += byte;
    header.write(sum.toString(8).padStart(6, '0') + '\0 ', 148);
    blocks.push(header, body, Buffer.alloc((512 - body.length % 512) % 512));
  }
  blocks.push(Buffer.alloc(1024));
  return gzipSync(Buffer.concat(blocks));
}
const integrity = bytes => 'sha512-' + createHash('sha512').update(bytes).digest('base64');

// `packages[name][version] = {dependencies, files, ...manifest}`; the registry serves packuments and tarballs.
function registry(packages, tags = {}) {
  const tarballs = new Map(), documents = new Map(), requests = [];
  for (const [name, versions] of Object.entries(packages)) {
    const document = {name, 'dist-tags': {latest: tags[name] ?? Object.keys(versions).at(-1)}, versions: {}};
    for (const [version, {files = {}, unpackedSize, ...manifest}] of Object.entries(versions)) {
      const json = {name, version, ...manifest};
      const bytes = tarball({'package.json': JSON.stringify(json), 'index.js': `module.exports = ${JSON.stringify(name + '@' + version)};`, ...files});
      const url = `https://registry.test/${name}/-/${version}.tgz`;
      tarballs.set(url, bytes);
      document.versions[version] = {...json, dist: {tarball: url, integrity: integrity(bytes), unpackedSize: unpackedSize ?? bytes.length * 4}};
    }
    documents.set('https://registry.test/' + (name.startsWith('@') ? '@' + encodeURIComponent(name.slice(1)) : name), document);
  }
  const fetch = async url => {
    requests.push(url);
    if (documents.has(url)) return new Response(JSON.stringify(documents.get(url)), {status: 200});
    if (tarballs.has(url)) return new Response(tarballs.get(url), {status: 200});
    return new Response('{}', {status: 404, statusText: 'Not Found'});
  };
  return {fetch, requests, tarballs};
}

function load(fetch, prelude = '') {
  const vfs = memoryVfs(), store = new Map(), logs = [];
  const native = async (operation, fields) => {
    if (operation === 'package-put') {
      assert.equal(integrity(Buffer.from(fields.base64, 'base64')), fields.integrity);
      store.set(fields.integrity, fields.base64); return {stored: true};
    }
    if (operation === 'package-get') {
      if (!store.has(fields.integrity)) { const error = new Error('PACKAGE_MISSING'); error.code = 'PACKAGE_MISSING'; throw error; }
      return {base64: store.get(fields.integrity)};
    }
    if (operation === 'package-keep') { for (const key of [...store.keys()]) if (!fields.integrities.includes(key)) store.delete(key); return {}; }
    throw new Error('unexpected ' + operation);
  };
  const context = {fetch, Response, Blob, DecompressionStream, TextDecoder, TextEncoder, AbortSignal, crypto, atob, btoa, URL,
    vfsRef: () => vfs, native, logs, Uint8Array, JSON, Promise, Map, Set, setTimeout, clearTimeout, console};
  context.self = context;
  context.spawn = (program, args, options) => {
    const child = new EventEmitter();
    Object.assign(child, {pid: 7, stdout: new EventEmitter(), stderr: new EventEmitter(), kill: () => true});
    queueMicrotask(async () => {
      if (program !== 'pnpm') return child.emit('error', Object.assign(new Error(`spawn ${program} ENOENT`), {code: 'ENOENT'}));
      const result = await context.exposed.pnpm.prepare(args, {cwd: options.cwd, filesystem: {}});
      if (result.stdout) child.stdout.emit('data', Buffer.from(result.stdout));
      if (result.stderr) child.stderr.emit('data', Buffer.from(result.stderr));
      child.stdout.emit('end'); child.stderr.emit('end');
      child.emit('exit', result.exitCode, null); child.emit('close', result.exitCode, null);
    });
    return child;
  };
  vm.createContext(context);
  vm.runInContext(`
const candidateHome = '/dsh/home';
const EXECUTABLES = new Map();
function launcherExit(exitCode, stdout = '', stderr = '') { return {kind: 'exit', exitCode, stdout, stderr}; }
// The Worker's child_process spawn as far as execa uses it: virtual executables answer, others are missing.
function spawn$1(program, args, options) { return self.spawn(program, args, options); }
const requireActiveVfs = () => self.vfsRef();
const requireActiveModuleLoader = () => ({internal: {resolveSync: (specifier, parentURL) => {
  if (specifier === 'present/package.json') return {url: 'file:///dsh/home/node_modules/present/package.json', parentURL};
  if (['node:path', 'node:fs', 'node:fs/promises', 'node:http'].includes(specifier)) return {format: 'builtin', url: specifier};
  throw new Error('webworker modules: cannot resolve "' + specifier + '"');
}}});
const candidateNative = (operation, fields) => self.native(operation, fields);
const candidateLog = event => self.logs.push(event);
const candidateBytes = base64 => Uint8Array.from(atob(base64), x => x.charCodeAt(0));
function candidateBase64(bytes) {
  let text = '';
  for (let i = 0; i < bytes.length; i += 0x8000) text += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
  return btoa(text);
}
${prelude}
${source}
self.exposed = {pnpm: EXECUTABLES.get('pnpm'), candidateSatisfies, candidatePick, candidateExeca, candidateEventsOnce, candidateModulePaths, candidateResolveResource};
`, context);
  const pnpm = (...args) => context.exposed.pnpm.prepare(args, {cwd: profile, filesystem: {}});
  const text = file => vfs.files.get(file) && Buffer.from(vfs.files.get(file).bytes).toString();
  return {vfs, store, logs, pnpm, text, exposed: context.exposed, restore: () => context.candidateRestorePackages(vfs)};
}

test('ranges resolve as node-semver does', () => {
  const {exposed: {candidateSatisfies: ok}} = load(async () => {});
  const cases = [
    ['1.2.3', '^1.0.0', true], ['2.0.0', '^1.0.0', false], ['0.2.5', '^0.2.1', true], ['0.3.0', '^0.2.1', false],
    ['0.0.3', '^0.0.3', true], ['0.0.4', '^0.0.3', false], ['1.2.9', '~1.2.3', true], ['1.3.0', '~1.2.3', false],
    ['1.9.0', '1.x', true], ['2.0.0', '1.x', false], ['3.1.0', '*', true], ['1.2.0', '>=1.0.0 <1.3.0', true],
    ['1.3.0', '>=1.0.0 <1.3.0', false], ['2.5.0', '^1.0.0 || ^2.0.0', true], ['1.5.0', '1.0.0 - 1.5.0', true],
    ['1.5.9', '1.0.0 - 1.5', true], ['1.6.0', '1.0.0 - 1.5', false], ['1.6.0', '1.0.0 - 1.5.0', false], ['2.0.0-beta.1', '^1.0.0', false],
    ['1.0.0-beta.2', '^1.0.0-beta.1', true], ['1.0.1-beta.1', '^1.0.0-beta.1', false], ['1.0.0', '1.0.0', true],
    ['1.0.0', '>= 1.0.0', true], ['4.0.0', '>3', true], ['3.9.0', '>3', false], ['3.0.0', '<=3', true], ['3.9.9', '<=3', true],
  ];
  for (const [version, range, expected] of cases) assert.equal(ok(version, range), expected, `${version} ${range}`);
});

test('add installs a plugin and its dependencies, records them and the store keeps exactly their tarballs', async () => {
  const fixture = registry({
    'dsh-demo': {'1.0.0': {dependencies: {left: '^1.0.0'}, dsh: {bundle: {}}}, '1.1.0': {dependencies: {left: '^1.0.0', right: '^2.0.0'}, dsh: {bundle: {}}}},
    left: {'1.0.0': {}, '1.2.0': {dependencies: {right: '^1.0.0'}}},
    right: {'1.0.0': {}, '2.0.0': {}},
  });
  const app = load(fixture.fetch);
  assert.equal((await app.pnpm('config', 'get', 'registry')).stdout, 'https://registry.npmjs.org/\n');
  const added = await app.pnpm('add', 'dsh-demo@1.0.0', '--registry=https://registry.test');
  assert.equal(added.exitCode, 0, added.stderr);
  assert.deepEqual(JSON.parse(app.text(profile + '/package.json')).dependencies, {'dsh-demo': '1.0.0'});
  assert.equal(app.text(profile + '/node_modules/dsh-demo/index.js'), 'module.exports = "dsh-demo@1.0.0";');
  assert.equal(app.text(profile + '/node_modules/left/index.js'), 'module.exports = "left@1.2.0";');
  assert.equal(app.text(profile + '/node_modules/right/index.js'), 'module.exports = "right@1.0.0";');
  assert.equal(app.store.size, 3);

  // Upgrade: dsh-demo now needs right@2 while left keeps right@1, so right@1 nests under left.
  const upgraded = await app.pnpm('add', 'dsh-demo', '--registry=https://registry.test');
  assert.equal(upgraded.exitCode, 0, upgraded.stderr);
  assert.deepEqual(JSON.parse(app.text(profile + '/package.json')).dependencies, {'dsh-demo': '^1.1.0'});
  assert.equal(app.text(profile + '/node_modules/dsh-demo/index.js'), 'module.exports = "dsh-demo@1.1.0";');
  assert.equal(app.text(profile + '/node_modules/right/index.js'), 'module.exports = "right@2.0.0";');
  assert.equal(app.text(profile + '/node_modules/left/node_modules/right/index.js'), 'module.exports = "right@1.0.0";');
  const lock = JSON.parse(app.text(profile + '/candidate-lock.json'));
  assert.deepEqual(Object.keys(lock.packages).sort(), ['node_modules/dsh-demo', 'node_modules/left', 'node_modules/left/node_modules/right', 'node_modules/right']);
  assert.equal(app.store.size, 4);

  const removed = await app.pnpm('remove', 'dsh-demo');
  assert.equal(removed.exitCode, 0, removed.stderr);
  assert.equal(JSON.parse(app.text(profile + '/package.json')).dependencies, undefined);
  assert.ok(![...app.vfs.files.keys()].some(file => file.includes('/node_modules/')));
  assert.equal(app.store.size, 0);
});

test('view prints the requested fields of the resolved version as JSON', async () => {
  const app = load(registry({'dsh-demo': {'1.0.0': {description: 'one', dsh: {bundle: {x: 1}}}, '2.0.0': {description: 'two'}}}).fetch);
  const viewed = await app.pnpm('view', 'dsh-demo@^1', 'name', 'version', 'dsh', '--json', '--registry=https://registry.test/');
  assert.equal(viewed.exitCode, 0, viewed.stderr);
  assert.deepEqual(JSON.parse(viewed.stdout), {name: 'dsh-demo', version: '1.0.0', dsh: {bundle: {x: 1}}});
  const missing = await app.pnpm('view', 'nope', 'name', '--json', '--registry=https://registry.test/');
  assert.equal(missing.exitCode, 1);
  assert.match(missing.stderr, /ERR_PNPM_FETCH_404/);
  const none = await app.pnpm('view', 'dsh-demo@^9', 'name', '--registry=https://registry.test/');
  assert.match(none.stderr, /ERR_PNPM_NO_MATCHING_VERSION/);
});

test('the unpacked tree comes back from the store after a Worker restart', async () => {
  const app = load(registry({'dsh-demo': {'1.0.0': {dependencies: {left: '1.0.0'}}}, left: {'1.0.0': {}}}).fetch);
  assert.equal((await app.pnpm('add', 'dsh-demo', '--registry=https://registry.test')).exitCode, 0);
  // The checkpoint keeps package.json and the lock but not node_modules.
  app.vfs.rmSync(profile + '/node_modules');
  await app.restore();
  assert.equal(app.text(profile + '/node_modules/dsh-demo/index.js'), 'module.exports = "dsh-demo@1.0.0";');
  assert.equal(app.text(profile + '/node_modules/left/index.js'), 'module.exports = "left@1.0.0";');
  // A tarball missing from the store leaves just that package out.
  app.vfs.rmSync(profile + '/node_modules');
  app.store.delete([...app.store.keys()][0]);
  await app.restore();
  assert.equal(app.logs.filter(entry => entry.event === 'package-restore-failed').length, 1);
});

test('install scripts, native binaries, oversized trees and git specs are refused with a reason and change nothing', async () => {
  const app = load(registry({
    scripted: {'1.0.0': {scripts: {postinstall: 'node build.js'}}},
    native: {'1.0.0': {os: ['darwin']}},
    portable: {'1.0.0': {os: ['darwin', 'linux', 'win32'], cpu: ['!arm']}},
    huge: {'1.0.0': {unpackedSize: 40 << 20}},
    platform: {'1.0.0': {optionalDependencies: {'platform-darwin': '1.0.0'}}},
    'platform-darwin': {'1.0.0': {os: ['darwin']}},
  }).fetch);
  const scripted = await app.pnpm('add', 'scripted', '--registry=https://registry.test');
  assert.match(scripted.stderr, /ERR_PNPM_IGNORED_BUILDS .*Ignored build scripts: scripted/);
  assert.match((await app.pnpm('add', 'native', '--registry=https://registry.test')).stderr, /ERR_PNPM_UNSUPPORTED_PLATFORM/);
  assert.equal((await app.pnpm('add', 'portable', '--registry=https://registry.test')).exitCode, 0);
  await app.pnpm('remove', 'portable');
  assert.match((await app.pnpm('add', 'huge', '--registry=https://registry.test')).stderr, /ERR_PNPM_TOO_LARGE .*40 MB/);
  assert.match((await app.pnpm('add', 'github:owner/repo')).stderr, /ERR_PNPM_UNSUPPORTED_SPEC .*git/);
  assert.match((await app.pnpm('add', 'owner/repo')).stderr, /ERR_PNPM_UNSUPPORTED_SPEC/);
  assert.equal(JSON.parse(app.text(profile + '/package.json')).dependencies, undefined);
  // An optional platform package is skipped rather than refusing its parent.
  const platform = await app.pnpm('add', 'platform', '--registry=https://registry.test');
  assert.equal(platform.exitCode, 0, platform.stderr);
  assert.match(platform.stdout, /skipping optional platform package platform-darwin/);
  // pnpm runs only in the plugin profile.
  const elsewhere = await load(async () => {}).exposed.pnpm.prepare(['add', 'x'], {cwd: '/dsh/workspace/a', filesystem: {}});
  assert.match(elsewhere.stderr, /ERR_PNPM_UNSUPPORTED_COMMAND/);
});

test('a tarball whose bytes do not match the registry integrity is refused', async () => {
  const fixture = registry({'dsh-demo': {'1.0.0': {}}});
  for (const url of fixture.tarballs.keys()) fixture.tarballs.set(url, tarball({'package.json': '{"name":"dsh-demo","version":"1.0.0"}', 'index.js': 'evil'}));
  const app = load(fixture.fetch);
  const result = await app.pnpm('add', 'dsh-demo', '--registry=https://registry.test');
  assert.match(result.stderr, /ERR_PNPM_TARBALL_INTEGRITY/);
  assert.equal(app.text(profile + '/node_modules/dsh-demo/index.js'), undefined);
});

// Real community plugins from npmjs; network only, so off unless asked.
test('a plugin whose entry statically imports a builtin the Worker lacks is refused with the builtin named and changes nothing', async () => {
  const app = load(registry({
    upstream: {'1.0.0': {type: 'module', exports: {'.': './lib/index.js'}, files: {
      'lib/index.js': "import {fetchUpstream} from './fetch.js';\nexport {fetchUpstream};\n",
      'lib/fetch.js': "import https from 'node:https';\nimport {join} from 'node:path';\nexport * from 'tls';\nexport const fetchUpstream = () => https;\n",
    }}},
    guarded: {'1.0.0': {type: 'module', main: 'index.js', files: {
      'index.js': "import {readFileSync} from 'node:fs';\nexport const load = () => import('node:https');\n",
      'cli.js': "import net from 'node:net';\n",
    }}},
  }).fetch);
  const refused = await app.pnpm('add', 'upstream', '--registry=https://registry.test');
  assert.match(refused.stderr, /ERR_PNPM_UNSUPPORTED_PLATFORM .*upstream needs node:https; upstream needs node:tls, which the plugin Worker does not provide/);
  assert.equal(app.vfs.files.has(profile + '/node_modules/upstream/package.json'), false);
  assert.equal(app.store.size, 0);
  assert.equal(JSON.parse(app.text(profile + '/package.json') ?? '{}').dependencies, undefined);
  // Dynamic imports may be guarded and files the entry never reaches are not loaded.
  const guarded = await app.pnpm('add', 'guarded', '--registry=https://registry.test');
  assert.equal(guarded.exitCode, 0, guarded.stderr);
});

test('the official plugin manager reaches pnpm through execa, buffered or streamed', async () => {
  const {exposed, text} = load(registry({'dsh-plugin-a': {'1.0.0': {}}}).fetch);
  const execa = exposed.candidateExeca;
  const registryAnswer = await execa('pnpm', ['config', 'get', 'registry'], {cwd: profile, reject: false, stdin: 'ignore'});
  assert.equal(registryAnswer.exitCode, 0);
  assert.equal(registryAnswer.stdout, 'https://registry.npmjs.org/');
  const child = execa('pnpm', ['add', 'dsh-plugin-a', '--registry=https://registry.test/'], {cwd: profile, reject: false, buffer: false, stdout: 'pipe', stderr: 'pipe'});
  assert.equal(child.nodeChildProcess.pid, child.pid);
  const exited = exposed.candidateEventsOnce(child.nodeChildProcess, 'exit').then(([code]) => code);
  let printed = '';
  for await (const chunk of child.stdout) printed += chunk.toString();
  for await (const chunk of child.stderr) printed += chunk.toString();
  assert.equal(await exited, 0);
  assert.equal((await child).exitCode, 0);
  assert.match(printed, /\+ dsh-plugin-a 1\.0\.0/);
  assert.equal(JSON.parse(text(profile + '/package.json')).dependencies['dsh-plugin-a'], '^1.0.0');
  const failed = await execa('pnpm', ['add', 'dsh-plugin-missing', '--registry=https://registry.test/'], {cwd: profile, reject: false});
  assert.equal(failed.exitCode, 1);
  assert.match(failed.stderr, /ERR_PNPM_FETCH_404/);
  const missing = execa('git', ['ls-remote', 'x'], {reject: false});
  await assert.rejects(exposed.candidateEventsOnce(missing.nodeChildProcess, 'exit'), error => error.code === 'ENOENT');
  const git = await missing;
  assert.equal(git.exitCode, undefined);
  assert.equal(git.code, 'ENOENT');
  await assert.rejects(execa('git', ['ls-remote', 'x']), error => error.code === 'ENOENT' && error.failed);
});

test('modules inside the home search node_modules upward before the image', () => {
  const {exposed} = load(registry({}).fetch);
  assert.deepEqual([...exposed.candidateModulePaths(profile + '/node_modules/left/node_modules/right/lib')], [
    profile + '/node_modules/left/node_modules/right/lib/node_modules', profile + '/node_modules/left/node_modules/right/node_modules',
    profile + '/node_modules/left/node_modules', profile + '/node_modules', '/dsh/home/profiles/node_modules', '/dsh/home/node_modules']);
  assert.deepEqual([...exposed.candidateModulePaths(profile)], [profile + '/node_modules', '/dsh/home/profiles/node_modules', '/dsh/home/node_modules']);
  assert.deepEqual([...exposed.candidateModulePaths('/dsh/node_modules/x')], []);
});

test('plugin metadata resolves through the Worker loader and reports misses as missing', () => {
  const {exposed} = load(registry({}).fetch);
  assert.equal(exposed.candidateResolveResource('present/package.json', 'file:///dsh/home/package.json'), 'file:///dsh/home/node_modules/present/package.json');
  assert.throws(() => exposed.candidateResolveResource('absent/locale/en.json', 'file:///dsh/home/package.json'), error => error.code === 'MODULE_NOT_FOUND');
});

const workerDependencies = path.join(here, '../../build/worker-dependencies');
const loweringSkip = !existsSync(path.join(workerDependencies, 'node_modules/acorn')) && 'official worker runtime not installed';
test('installed ES modules are lowered for the Worker loader; the stored tarball stays as published', {skip: loweringSkip}, async () => {
  const {loweringSource} = await import('./prepare.mjs');
  const prelude = loweringSource(workerDependencies, path.join(workerDependencies, 'node_modules/@deepseek-ai/dsh-experimental-webworker-runtime/lib'));
  const fixture = registry({'dsh-esm': {'1.0.0': {type: 'module', files: {'index.js': "import {join} from 'node:path';\nexport const name = 'esm';\nexport function apply() { return join('a', 'b'); }\n"}}}});
  const app = load(fixture.fetch, prelude);
  const added = await app.pnpm('add', 'dsh-esm', '--registry=https://registry.test');
  assert.equal(added.exitCode, 0, added.stderr);
  const body = app.text(profile + '/node_modules/dsh-esm/index.js');
  assert.doesNotMatch(body, /^\s*(import|export)\b/m);
  const module = {exports: {}};
  new Function('exports', 'require', 'module', body)(module.exports, id => ({join: (...parts) => parts.join('/')}), module);
  assert.equal(module.exports.name, 'esm');
  assert.equal(module.exports.apply(), 'a/b');
  assert.deepEqual([...app.store.values()], [...fixture.tarballs.values()].map(bytes => bytes.toString('base64')));
});

test('community plugins install from npmjs', {skip: !process.env.HARNESS_LIVE_REGISTRY && 'set HARNESS_LIVE_REGISTRY=1'}, async () => {
  for (const [spec, expectation] of [['@jonathanleelx/dsh-balance', /Done/], ['dsh-free-search', /Done/], ['dsh-cost-meter', /Done/],
    ['@liustack/modsearch', /Done/], ['dsh-pet', /ERR_PNPM_TOO_LARGE|ERR_PNPM_IGNORED_BUILDS|ERR_PNPM_UNSUPPORTED_PLATFORM/]]) {
    const app = load(fetch);
    const result = await app.pnpm('add', spec);
    console.log(spec, result.exitCode, (result.stdout + result.stderr).trim().split('\n').slice(-2).join(' | '));
    assert.match(result.stdout + result.stderr, expectation);
    if (result.exitCode === 0) {
      const name = spec;
      const manifest = JSON.parse(app.text(`${profile}/node_modules/${name}/package.json`));
      assert.ok(manifest.dsh?.bundle, `${spec} declares dsh.bundle`);
    }
  }
});
