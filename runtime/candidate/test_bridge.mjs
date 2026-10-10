// The candidate bridge, run against a stub Swift host and stub official services (#17).
import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import path from 'node:path';
import {existsSync, readFileSync} from 'node:fs';
import {fileURLToPath} from 'node:url';
import {candidateIndex, patchWorker} from './prepare.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const bridge = readFileSync(path.join(here, 'candidate-bridge.js'), 'utf8');
const tick = () => new Promise(resolve => setImmediate(resolve));

// A Worker VFS with the members the bridge calls.
function memoryVfs(seeded = {}) {
  const files = new Map(Object.entries(seeded).map(([p, text]) => [p, Buffer.from(text)]));
  const directories = new Set(['/dsh', '/dsh/home', '/dsh/workspace']);
  const stat = p => ({isDirectory: () => directories.has(p), mode: directories.has(p) ? 0o40755 : 0o100644, mtimeMs: 1});
  const vfs = {
    files, directories,
    seed: (p, bytes) => files.set(p, Buffer.from(bytes)), seedDirectory: p => directories.add(p),
    statSync: stat, readFileSync: p => files.get(p),
    readdirSync: p => [...new Set([...files.keys(), ...directories].filter(x => path.posix.dirname(x) === p && x !== p)
      .map(x => path.posix.basename(x)))],
    existsSync: p => files.has(p) || directories.has(p),
    mkdirSync: p => directories.add(p), openFileSync: () => 3, renameSync: () => {},
  };
  for (const name of ['writeFileSync', 'appendFileSync', 'linkSync', 'truncateSync', 'chmodSync', 'unlinkSync', 'rmSync', 'mkdtempSync']) vfs[name] = () => {};
  return vfs;
}

// The official services the install hook patches.
function services(map = entries => new Map(entries)) {
  const calls = {workspaces: [], credentials: [], events: {}};
  class Subprocess {
    spawn(spec) { calls.localSpawn = spec; return 'local'; }
    async resolveExecutable(command) { return '/usr/bin/' + command; }
    // The Worker's node:os has no userInfo, as in the official Worker.
    async terminalEnvironment() { throw new TypeError('userInfo is not a function'); }
    async spawnTerminal() { return 'local-pty'; }
  }
  class Shell {
    static decorateResult(result, decorate) { return decorate(result); }
    async execute() { return 'confined'; }
    async executeArgv(spec, argv) { calls.executeArgv = argv; return {exitCode: 0}; }
  }
  const registry = {resolveByPath: async () => undefined, create: async (mount, name) => calls.workspaces.push([mount, name])};
  const table = {subprocess: new Subprocess(), shell: new Shell(), workspaceRegistry: registry,
    credentials: {set: async (...args) => calls.credentials.push(args)}, sessionPersistence: {flush: async () => { calls.flushed = true; }}};
  const ctx = {get: name => table[name], on: (name, listener) => { calls.events[name] = listener; }};
  class LocalFileSystem {}
  for (const name of ['resolve', 'stat', 'lstat', 'readText', 'streamText', 'readBytes', 'readByteRange', 'listDir', 'writeText', 'editText', 'watch']) {
    LocalFileSystem.prototype[name] = async () => 'local-' + name;
  }
  const modules = {'node:path': path, 'node:fs': {constants: {O_WRONLY: 1, O_RDWR: 2, O_CREAT: 64, O_TRUNC: 512, O_APPEND: 1024}},
    '@deepseek-ai/dsh-fs': {FsError: class extends Error { constructor(m, code) { super(m); this.code = code; } }, FsTargetKey: x => x, FsVersion: x => x},
    '@deepseek-ai/dsh-fs-local': {LocalFileSystem}};
  const loader = {requireFrom: () => name => modules[name], staticModules: map([['sharp', () => 'refusing']])};
  return {ctx, loader, calls, table, LocalFileSystem};
}

// Loads the bridge in a fresh realm; `answer(body)` plays the Swift host.
function load(answer, {fetch = async () => 'network'} = {}) {
  const sent = [];
  const context = {Buffer, URL, TextDecoder, TextEncoder, Headers, Response, ReadableStream, DOMException, atob, btoa,
    setTimeout: fn => { fn(); return 0; }, clearTimeout: () => {}, setInterval: () => 0, process, fetch,
    promises: {readFile: async () => 'vfs'}};
  context.self = context;
  context.globalThis = context;
  context.postMessage = message => {
    sent.push(message);
    if (message.t !== 'candidate-native') return;
    Promise.resolve(answer(message.body)).then(result => context.candidateNativeReply({id: message.id, result}));
  };
  vm.createContext(context);
  vm.runInContext(bridge, context);
  // Plain copies: the bridge's objects come from another realm.
  return {self: context, native: () => JSON.parse(JSON.stringify(sent.filter(x => x.t === 'candidate-native').map(x => x.body))),
    map: entries => vm.runInContext('entries => new Map(entries)', context)(entries)};
}

const host = (projects = []) => body => {
  switch (body.operation) {
    case 'restore': return {snapshot: null};
    case 'projects': return {projects};
    default: return {};
  }
};

test('restore seeds only the Worker home and turns on native project routes', async () => {
  const snapshot = {formatVersion: 1, directories: [{path: '/dsh/home/.config', mode: 0o40755, mtimeMs: 1}],
    files: [{path: '/dsh/home/.config/a', mode: 0o100644, mtimeMs: 1, base64: btoa('x')}]};
  const {self, native} = load(body => body.operation === 'restore' ? {snapshot}
    : {value: btoa('native bytes')});
  const vfs = memoryVfs();
  const base = async () => 'vfs';
  assert.equal(await self.candidateFsRoute('readFile', ['/dsh/workspace/p/a'], base), 'vfs', 'inert before restore');
  await self.candidateRestore(vfs);
  assert.equal(vfs.files.get('/dsh/home/.config/a').toString(), 'x');
  assert.equal(await self.candidateFsRoute('readFile', ['/dsh/home/x'], base), 'vfs');
  assert.equal(String(await self.candidateFsRoute('readFile', ['/dsh/workspace/p/a'], base)), 'native bytes');
  assert.deepEqual(native().at(-1), {operation: 'path', method: 'readFile', args: {path: '/dsh/workspace/p/a'}});
  // Writes into a project go natively; the scratch for workspace changes too.
  await self.candidateFsRoute('writeFile', ['/dsh/tmp/dsh-workspace-changes-1/x', 'y'], base);
  assert.equal(native().at(-1).method, 'writeFile');
});

test('restore refuses a snapshot that leaves the home or carries the credentials', async () => {
  for (const leak of ['/dsh/workspace/p/a', '/dsh/home/../config/x', '/dsh/home/.credentials.yaml']) {
    const snapshot = {formatVersion: 1, directories: [], files: [{path: leak, mode: 0o100644, mtimeMs: 1, base64: ''}]};
    const {self} = load(() => ({snapshot}));
    const vfs = memoryVfs();
    await assert.rejects(self.candidateRestore(vfs), /HOME_PATH_REFUSED/);
    assert.equal(vfs.files.size, 0);
  }
});

test('install registers the open projects and checkpoints the home without the credentials', async () => {
  const projects = [{id: 'a', name: 'Alpha', mount: '/dsh/workspace/alpha', open: true},
    {id: 'b', name: 'Beta', mount: '/dsh/workspace/beta', open: false}];
  const {self, native, map} = load(host(projects));
  const {ctx, loader, calls} = services(map);
  const vfs = memoryVfs({'/dsh/home/settings.json': '{}', '/dsh/home/.credentials.yaml': 'secret'});
  await self.candidateRestore(vfs);
  // A project opened before the install is queued, not lost.
  self.candidateProjectOpened({id: 'c', name: 'Gamma', mount: '/dsh/workspace/gamma', open: true});
  await self.candidateInstall(ctx, loader, vfs);
  assert.deepEqual(calls.workspaces, [['/dsh/workspace/alpha', 'Alpha'], ['/dsh/workspace/gamma', 'Gamma']]);
  assert.deepEqual(calls.credentials, [['DEEPSEEK_API_KEY', 'candidate-native-placeholder']]);
  assert.equal(loader.staticModules.get('sharp')().name, 'candidateSharp');
  calls.events['session/event']();
  for (let i = 0; i < 5; i++) await tick();
  assert.equal(calls.flushed, true);
  const checkpoint = native().find(x => x.operation === 'checkpoint').snapshot;
  assert.deepEqual(checkpoint.files.map(x => x.path), ['/dsh/home/settings.json']);
  // A later open registers at once.
  self.candidateProjectOpened({id: 'd', name: 'Delta', mount: '/dsh/workspace/delta', open: true});
  for (let i = 0; i < 5; i++) await tick();
  assert.deepEqual(calls.workspaces.at(-1), ['/dsh/workspace/delta', 'Delta']);
});

test('a shell command in a project runs on Linux and a cancel reaches the same operation', async () => {
  let release;
  const {self, native, map} = load(body => {
    if (body.operation === 'execute') return new Promise(resolve => { release = resolve; });
    return host()(body);
  });
  const {ctx, loader, calls, table} = services(map);
  const vfs = memoryVfs();
  await self.candidateRestore(vfs);
  await self.candidateInstall(ctx, loader, vfs);
  // The official bash tool's confinement is skipped in a project: the VM is the isolation.
  assert.equal(await table.shell.execute({workdir: '/tmp', command: 'ls'}), 'confined');
  const decorated = await table.shell.execute({workdir: '/dsh/workspace/p', command: 'ls', sandboxPolicy: {mode: 'workspace-write'}});
  assert.deepEqual([...calls.executeArgv], ['bash', '-c', 'ls']);
  assert.deepEqual({...decorated.sandbox}, {mode: 'workspace-write', denied: false});
  assert.equal(table.subprocess.spawn({argv: ['bash', '-c', 'ls'], cwd: '/tmp'}), 'local');

  const controller = new AbortController();
  const running = table.subprocess.spawn({argv: ['bash', '-c', 'make'], cwd: '/dsh/workspace/p/src', signal: controller.signal,
    stdio: {stdout: {maxBytes: 4}, stderr: {}}});
  await tick();
  const execute = native().find(x => x.operation === 'execute');
  assert.deepEqual({...execute, operationId: undefined},
    {operation: 'execute', operationId: undefined, command: 'make', cwd: '/dsh/workspace/p/src', timeoutMs: 600000, trigger: 'shell'});
  controller.abort();
  await tick();
  assert.equal(native().find(x => x.operation === 'cancel').operationId, execute.operationId);
  release({status: 'COMPLETED', exitCode: null, signal: null, stdout: 'abcdef', stderr: 'e'});
  assert.deepEqual({...await running.done}, {exitCode: null, signal: 'SIGKILL'});
  assert.deepEqual({...running.collected.stdout.readFrom(0)}, {text: 'cdef', nextOffset: 6, lossy: true});
  assert.equal(running.collected.stderr.readFrom(0).text, 'e');
});

test('a refused or unknown-writer command fails with its fixed code', async () => {
  for (const [reply, code] of [[{status: 'REFUSED', reason: 'LINUX_PREPARING'}, 'LINUX_PREPARING'],
    [{status: 'WRITER_UNKNOWN', stdout: 'partial', stderr: ''}, 'WRITER_UNKNOWN']]) {
    const {self, map} = load(body => body.operation === 'execute' ? reply : host()(body));
    const {ctx, loader, table} = services(map);
    const vfs = memoryVfs();
    await self.candidateRestore(vfs);
    await self.candidateInstall(ctx, loader, vfs);
    const running = table.subprocess.spawn({argv: ['bash', '-c', 'x'], cwd: '/dsh/workspace/p', stdio: {stdout: {}, stderr: {}}});
    await assert.rejects(running.done, new RegExp(code));
  }
});

test('an interactive terminal is refused with its fixed code instead of crashing', async () => {
  const {self, map} = load(host());
  const {ctx, loader, table} = services(map);
  const vfs = memoryVfs();
  await self.candidateRestore(vfs);
  await self.candidateInstall(ctx, loader, vfs);
  // The terminal controller asks for the environment before it resolves a shell.
  await assert.rejects(table.subprocess.terminalEnvironment(), /TERMINAL_UNSUPPORTED/);
  for (const cwd of ['/dsh/workspace/p', '/tmp']) {
    await assert.rejects(table.subprocess.spawnTerminal({argv: ['/bin/sh'], cwd}), /TERMINAL_UNSUPPORTED/);
  }
});

test('project writes through the Worker VFS are refused; other paths are untouched', async () => {
  const {self, map} = load(host());
  const {ctx, loader} = services(map);
  const vfs = memoryVfs();
  await self.candidateRestore(vfs);
  await self.candidateInstall(ctx, loader, vfs);
  assert.throws(() => vfs.writeFileSync('/dsh/workspace/p/a', 'x'), {code: 'EROFS'});
  assert.throws(() => vfs.renameSync('/dsh/tmp/a', '/dsh/workspace/p/a'), {code: 'EROFS'});
  assert.throws(() => vfs.openFileSync('/dsh/workspace/p/a', 'w'), {code: 'EROFS'});
  vfs.writeFileSync('/dsh/home/a', 'x');
  assert.equal(vfs.openFileSync('/dsh/workspace/p/a', 'r'), 3);
});

test('only the official messages endpoint is streamed through Swift', async () => {
  let chunks = [btoa('data: 1\n\n')];
  const {self, native} = load(body => {
    if (body.operation === 'model-open') return {status: 200, headers: {'content-type': 'text/event-stream'}};
    if (body.operation === 'model-read') return chunks.length ? {chunk: chunks.shift()} : {done: true};
    return {};
  });
  assert.equal(await self.fetch('https://example.com/x'), 'network');
  const response = await self.fetch('https://api.deepseek.com/anthropic/v1/messages',
    {method: 'POST', headers: {'x-api-key': 'candidate-native-placeholder'}, body: '{}'});
  assert.equal(response.status, 200);
  assert.equal(await response.text(), 'data: 1\n\n');
  const open = native().find(x => x.operation === 'model-open');
  assert.equal(open.body, '{}');
  const {self: failing} = load(body => body.operation === 'model-open' ? {failure: 'MODEL_KEY_MISSING'} : {});
  await assert.rejects(failing.fetch('https://api.deepseek.com/anthropic/v1/messages', {body: '{}'}),
    error => error.name === 'TypeError' && /MODEL_KEY_MISSING/.test(error.message));
});

test('the index runs the connector before the official entry', () => {
  const html = '<head>\n    <script type="module" crossorigin src="./assets/index-X.js"></script>\n</head>';
  const page = candidateIndex(html);
  assert.ok(page.indexOf('importmap') < page.indexOf('connector.js'));
  assert.ok(page.indexOf('connector.js') < page.indexOf('index-X.js'));
  assert.throws(() => candidateIndex('<head></head>'), /Upstream anchor changed/);
});

const official = path.join(here, '../../build/prototypes/plan500-worker/dependencies/node_modules/@deepseek-ai/dsh-experimental-webworker-runtime/lib/worker.js');
test('every Worker anchor occurs exactly once in the fixed official Worker', {skip: !existsSync(official) && 'official Worker not prepared'}, () => {
  const patched = patchWorker(readFileSync(official, 'utf8'), '// bridge');
  for (const hook of ['candidateRestore?.(mounted)', 'candidateInstall?.(ctx, loader, mounted)', 'self.candidateFsRoute(name, args, base)',
    'copyFile: () => promises.copyFile']) assert.equal(patched.split(hook).length, 2, hook);
  assert.ok(patched.indexOf('candidateRestore') < patched.indexOf('setActiveVfs(mounted);'));
  assert.throws(() => patchWorker('nothing', ''), /Upstream anchor changed/);
});
