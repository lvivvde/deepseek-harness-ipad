// The candidate bridge, run against a stub Swift host and stub official services (#17).
import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import {PassThrough} from 'node:stream';
import path from 'node:path';
import {existsSync, readFileSync} from 'node:fs';
import {fileURLToPath} from 'node:url';
import {candidateIndex, patchWorker} from './prepare.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const bridge = readFileSync(path.join(here, 'candidate-bridge.js'), 'utf8') + '\n' + readFileSync(path.join(here, 'session-recovery.js'), 'utf8');
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
    resolve(request) { return request; }
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
function load(answer, {fetch = async () => 'network', manualTimers = false} = {}) {
  const sent = [];
  // Intervals never fire on their own; a test runs one with `intervals.get(id)()`.
  const intervals = new Map();
  let intervalId = 0, timerId = 0;
  const timers = new Map();
  const context = {Buffer, URL, TextDecoder, TextEncoder, Headers, Response, ReadableStream, DOMException, atob, btoa,
    setTimeout: fn => { if (manualTimers) { timers.set(++timerId, fn); return timerId; } fn(); return 0; }, clearTimeout: id => timers.delete(id), process, fetch, PassThrough,
    setInterval: fn => { intervals.set(++intervalId, fn); return intervalId; }, clearInterval: id => { intervals.delete(id); },
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
  return {self: context, intervals, timers, native: () => JSON.parse(JSON.stringify(sent.filter(x => x.t === 'candidate-native').map(x => x.body))),
    map: entries => vm.runInContext('entries => new Map(entries)', context)(entries)};
}

const host = (projects = []) => body => {
  switch (body.operation) {
    case 'restore': return {snapshot: null, worker: 'w'};
    case 'checkpoint-begin': return {capture: 'c', worker: 'w'};
    case 'checkpoint': return {durable: true, capture: body.capture, worker: body.worker, revision: body.revision};
    case 'projects': return {projects};
    default: return {};
  }
};

test('restore seeds only the Worker home and turns on native project routes', async () => {
  const snapshot = {formatVersion: 1, directories: [{path: '/dsh/home/.config', mode: 0o40755, mtimeMs: 1}],
    files: [{path: '/dsh/home/.config/a', mode: 0o100644, mtimeMs: 1, base64: btoa('x')}]};
  const {self, native} = load(body => body.operation === 'restore' ? {snapshot, worker: 'w'}
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
    const {self} = load(() => ({snapshot, worker: 'w'}));
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

// A Swift host whose terminal reads come from `reads` in order; once they run out a read never answers.
async function terminalBridge(answer = () => ({status: 'WRITTEN', leased: false}), reads = []) {
  const {self, native, map} = load(body => {
    if (body.operation === 'terminal-open') return {pid: 42};
    if (body.operation === 'terminal-write') return answer(body);
    if (body.operation === 'terminal-read') return reads.length ? reads.shift() : new Promise(() => {});
    if (body.operation === 'terminal-inspect') return {foreground: {processGroupId: 42, inputWaiting: true}, activity: {state: 'idle', revision: 5}};
    if (body.operation === 'terminal-close') return {closed: true, released: false};
    return host()(body);
  });
  const {ctx, loader, table} = services(map);
  const vfs = memoryVfs();
  await self.candidateRestore(vfs);
  await self.candidateInstall(ctx, loader, vfs);
  const spec = {argv: ['/bin/bash', '-i'], cwd: '/dsh/workspace/p', cols: 80, rows: 24, terminalType: 'xterm-256color',
    env: {DSH_SESSION_ID: 's'}, shellActivity: true, graceMs: 500};
  return {native, subprocess: table.subprocess, spec};
}
const chunk = (text, next, fields = {}) => ({data: btoa(text), next, dropped: 0, exited: null,
  activity: {state: 'busy', revision: 1}, leased: false, released: false, ...fields});

test('a terminal in a project is a pty shell on Linux whose output ends when the shell exits', async () => {
  const {native, subprocess, spec} = await terminalBridge(undefined,
    [chunk('$ ', 2), chunk('ls\r\n', 6, {released: true}), chunk('', 6, {exited: {code: 0, signal: null}})]);
  assert.ok(native().some(x => x.operation === 'terminals-reset'), 'a new Worker closes the old terminals first');
  // The controller asks for the environment, then resolves the shell it names.
  assert.deepEqual({...await subprocess.terminalEnvironment()}, {platform: 'posix', defaultShell: '/bin/bash'});
  assert.equal(await subprocess.resolveExecutable('/bin/bash'), '/bin/bash');
  await assert.rejects(subprocess.spawnTerminal({...spec, cwd: '/tmp'}), /TERMINAL_OUTSIDE_PROJECT/);
  const handle = await subprocess.spawnTerminal(spec);
  assert.equal(handle.pid, 42);
  const opened = native().find(x => x.operation === 'terminal-open');
  assert.deepEqual(opened, {cwd: '/dsh/workspace/p', argv: ['/bin/bash', '-i'], cols: 80, rows: 24, env: {DSH_SESSION_ID: 's'},
    terminalType: 'xterm-256color', terminalId: opened.terminalId, operation: 'terminal-open'});
  let text = '';
  for await (const data of handle.output) text += Buffer.from(data).toString();
  assert.equal(text, '$ ls\r\n');
  assert.deepEqual({...await handle.done}, {exitCode: 0, signal: null});
  assert.deepEqual(native().filter(x => x.operation === 'terminal-read').map(x => x.offset), [0, 2, 6]);
  assert.equal(native().at(-1).operation, 'terminal-close', 'the exited shell frees its guest slot');
  await assert.rejects(handle.write('x'), /terminal process has exited/);
  assert.deepEqual({...await handle.inspectActivity()}, {state: 'idle', revision: 1});
});

test('a run line waits for another writer and the input after it keeps its order', async () => {
  let busy = 2;
  const {native, subprocess, spec} = await terminalBridge(body => atob(body.data) === '\r' && busy-- > 0
    ? {status: 'REFUSED', reason: 'LEASE_BUSY'} : {status: 'WRITTEN', leased: atob(body.data) === '\r'});
  const handle = await subprocess.spawnTerminal(spec);
  await Promise.all([handle.write('\r'), handle.write(new TextEncoder().encode('x'))]);
  assert.deepEqual(native().filter(x => x.operation === 'terminal-write').map(x => atob(x.data)), ['\r', '\r', '\r', 'x']);
  assert.deepEqual({...await handle.inspectForeground()}, {processGroupId: 42, inputWaiting: true});
  assert.deepEqual({...await handle.inspectActivity()}, {state: 'idle', revision: 5});
  await handle.terminate();
  assert.deepEqual({...await handle.done}, {exitCode: null, signal: 'SIGHUP'});
  assert.equal(native().filter(x => x.operation === 'terminal-close').length, 1);
});

test('a run line another writer never frees, or an unknown writer, fails with its code', async () => {
  const {subprocess, spec} = await terminalBridge(body => ({status: 'REFUSED', reason: atob(body.data) === '\r' ? 'LEASE_BUSY' : 'WRITER_UNKNOWN'}));
  const handle = await subprocess.spawnTerminal(spec);
  await assert.rejects(handle.write('\r'), /LEASE_BUSY/);
  await assert.rejects(handle.write('x'), /WRITER_UNKNOWN/);
});

// The official runner the hook plugins call; it reads a throw or a missing exit code as "no decision".
const hookProtocol = path.join(here, '../../build/test-dependencies/harness/node_modules/@deepseek-ai/dsh-hook-protocol/lib/index.js');
async function runOfficialHook(reply, {cwd = '/dsh/workspace/p/src', abort = false} = {}) {
  const {runHook} = await import(hookProtocol);
  const {self, native, map} = load(body => body.operation === 'execute' ? reply : host()(body));
  const {ctx, loader, table} = services(map);
  const vfs = memoryVfs();
  await self.candidateRestore(vfs);
  await self.candidateInstall(ctx, loader, vfs);
  const controller = new AbortController();
  if (abort) controller.abort();
  const {output} = await runHook(table.shell, {command: 'check-tool', timeoutSec: 5},
    {payload: {hook_event_name: 'PreToolUse', note: "it's", tool_input: {file_path: '/dsh/workspace/p/src/a.js', other: '/dsh/workspace/pp/b'}}, env: {CLAUDE_PROJECT_DIR: '/dsh/workspace/p'}, cwd,
      signal: controller.signal, trailingNewline: true, defaultTimeoutMs: 1000, expectedEventName: 'PreToolUse'}, () => 0);
  return {output, execute: native().find(x => x.operation === 'execute')};
}
const hookSkip = !existsSync(hookProtocol) && 'official hook protocol not installed';

test('a hook in a project runs on Linux with its payload and environment', {skip: hookSkip}, async () => {
  const {output, execute} = await runOfficialHook({status: 'COMPLETED', exitCode: 0, signal: null,
    stdout: '{"decision":"block","reason":"no"}', stderr: ''});
  assert.equal(execute.trigger, 'hook');
  assert.equal(execute.cwd, '/dsh/workspace/p/src');
  assert.equal(execute.timeoutMs, 5000);
  // The guest sees the project at /workspace, in env and payload paths; the payload is replayed on stdin, quotes intact.
  assert.equal(execute.command, "export CLAUDE_PROJECT_DIR='/workspace'\n"
    + `printf '%s' '{"hook_event_name":"PreToolUse","note":"it'\\''s",`
    + `"tool_input":{"file_path":"/workspace/src/a.js","other":"/dsh/workspace/pp/b"}}\n' | (\ncheck-tool\n)\n`);
  assert.equal(output.decision, 'block');
  assert.equal(output.reason, 'no');
});

test('a hook that did not run on Linux blocks with its fixed code', {skip: hookSkip}, async () => {
  for (const [reply, code] of [[{status: 'REFUSED', reason: 'LINUX_PLUGIN_NOT_ENABLED'}, 'LINUX_PLUGIN_NOT_ENABLED'],
    [{status: 'WRITER_UNKNOWN', stdout: '', stderr: ''}, 'WRITER_UNKNOWN'],
    [{status: 'COMPLETED', exitCode: null, signal: 'SIGKILL', stdout: '', stderr: '', timedOut: true}, 'HOOK_TIMEOUT'],
    [{status: 'COMPLETED', exitCode: null, signal: 'SIGKILL', stdout: '', stderr: '', cancelled: true}, 'HOOK_CANCELLED'],
    [{status: 'REFUSED', reason: 'BODY_TOO_LARGE'}, 'BODY_TOO_LARGE'], [{status: 'REFUSED'}, 'REFUSED'],
    [{status: 'CANCELLED_BEFORE_DISPATCH'}, 'CANCELLED_BEFORE_DISPATCH']]) {
    const {output} = await runOfficialHook(reply);
    assert.equal(output.decision, 'block', code);
    assert.equal(output.reason, 'DSH_HOOK_NOT_RUN ' + code);
  }
  const {output, execute} = await runOfficialHook({}, {abort: true});
  assert.equal(execute, undefined, 'an aborted hook is never dispatched');
  assert.equal(output.reason, 'DSH_HOOK_NOT_RUN CANCELLED_BEFORE_DISPATCH');
});

test('a project watch fires when the native store changes and stops when unwatched', async () => {
  let version = 'v1', names = ['a'], duringStat;
  const {self, intervals, map} = load(body => {
    if (body.operation === 'fs' && body.method === 'stat') {
      if (body.args.path.endsWith('/dir')) return {value: {type: 'directory', version: null, mode: 0o40755, size: 0}};
      const value = {type: 'file', version, mode: 0o100644, size: 1};
      const during = duringStat; duringStat = undefined; during?.();
      return {value};
    }
    if (body.operation === 'path') return {value: {dev: 1, ino: 2, size: 0, mtimeNs: 3, ctimeNs: 4}};
    if (body.operation === 'fs' && body.method === 'list')
      return {value: names.map(name => ({name, type: 'file', version: 'x', size: 1, target: '/dsh/workspace/p/dir/' + name}))};
    if (body.operation === 'execute') return {status: 'COMPLETED', exitCode: 0, signal: null, stdout: '', stderr: ''};
    return host()(body);
  });
  const {ctx, loader, LocalFileSystem, table} = services(map);
  const vfs = memoryVfs();
  await self.candidateRestore(vfs);
  await self.candidateInstall(ctx, loader, vfs);
  const fs = new LocalFileSystem();
  const seen = {file: 0, dir: 0};
  const file = await fs.watch({targetKey: '/dsh/workspace/p/a', displayPath: '/dsh/workspace/p/a'}, error => { assert.equal(error, undefined); seen.file++; });
  const dir = await fs.watch({targetKey: '/dsh/workspace/p/dir', displayPath: '/dsh/workspace/p/dir'}, () => { seen.dir++; });
  const [poll] = [...intervals.entries()].find(([, fn]) => fn.name === 'candidatePollWatches');
  await intervals.get(poll)();
  assert.deepEqual(seen, {file: 0, dir: 0}, 'nothing changed');
  version = 'v2';
  await intervals.get(poll)();
  assert.deepEqual(seen, {file: 1, dir: 0});
  // A command on Linux polls at once when it finishes, without waiting for the interval.
  names = ['a', 'b'];
  await table.subprocess.spawn({argv: ['bash', '-c', 'touch dir/b'], cwd: '/dsh/workspace/p', stdio: {stdout: {}, stderr: {}}}).done;
  for (let i = 0; i < 5; i++) await tick();
  assert.deepEqual(seen, {file: 1, dir: 1});
  // A change that lands after a running pass read its target is caught by one more pass.
  duringStat = () => { version = 'v3'; intervals.get(poll)(); };
  await intervals.get(poll)();
  assert.deepEqual(seen, {file: 2, dir: 1});
  file(); dir();
  assert.equal(intervals.has(poll), false, 'the last unwatch stops polling');
  assert.equal(await fs.watch({targetKey: '/tmp/x', displayPath: '/tmp/x'}, () => {}), 'local-watch');
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


test('official flush rejects a memory-only native acknowledgement', async () => {
  const {self, map} = load(body => body.operation === 'restore' ? {snapshot: null, worker: 'w'}
    : body.operation === 'checkpoint-begin' ? {capture: 'c', worker: 'w'}
      : body.operation === 'checkpoint' ? {} : host()(body));
  const {ctx, loader, calls} = services(map);
  const vfs = memoryVfs();
  await self.candidateRestore(vfs);
  await self.candidateInstall(ctx, loader, vfs);
  assert.equal(typeof calls.events['session/flush'], 'function');
  await assert.rejects(calls.events['session/flush'](), /DURABLE_ACK_REFUSED/);
});


test('restore validates every entry before seeding any bytes or directories', async () => {
  const good = {path: '/dsh/home/good', mode: 0o100644, mtimeMs: 1, base64: 'eA=='};
  for (const bad of [{...good, path: '/dsh/home/bad', base64: 'eA'}, {...good},
    {...good, path: '/dsh/home/good/child'}, {...good, path: '/dsh/home/bad', mode: 0o120777},
    {...good, path: '/dsh/home/bad', mtimeMs: -1}, {...good, path: '/dsh/home//bad'}]) {
    const snapshot = {formatVersion: 1, directories: [{path: '/dsh/home/config', mode: 0o40755, mtimeMs: 1}], files: [good, bad]};
    const {self} = load(() => ({snapshot, worker: 'w'})); const vfs = memoryVfs();
    await assert.rejects(self.candidateRestore(vfs), /HOME_(SNAPSHOT|PATH)_REFUSED/);
    assert.equal(vfs.files.size, 0);
    assert.equal(vfs.directories.has('/dsh/home/config'), false);
  }
});

test('a late durable acknowledgement cannot clear an event that arrived during saving', async () => {
  const pending = [];
  const {self, map, native} = load(body => body.operation === 'checkpoint'
    ? new Promise(resolve => pending.push({body, resolve})) : host()(body), {manualTimers: true});
  const {ctx, loader, calls} = services(map); const vfs = memoryVfs();
  await self.candidateRestore(vfs); await self.candidateInstall(ctx, loader, vfs);
  const saving = self.candidateSave();
  for (let i = 0; i < 5; i++) await tick();
  assert.equal(pending.length, 1);
  calls.events['session/event']();
  const first = pending[0]; first.resolve({durable: true, worker: first.body.worker, capture: first.body.capture, revision: first.body.revision});
  for (let i = 0; i < 5; i++) await tick();
  assert.equal(pending.length, 2, 'later event requires a new capture');
  const second = pending[1]; assert.ok(second.body.revision > first.body.revision);
  second.resolve({durable: true, worker: second.body.worker, capture: second.body.capture, revision: second.body.revision});
  await saving;
  assert.equal(native().filter(x => x.operation === 'checkpoint').length, 2);
});

test('failed save stays retryable through both the periodic and manual save paths', async () => {
  let attempts = 0;
  const {self, map, intervals, native} = load(body => {
    if (body.operation === 'checkpoint' && attempts++ === 0) return {error: 'CHECKPOINT_FAILED'};
    return host()(body);
  }, {manualTimers: true});
  const {ctx, loader} = services(map); const vfs = memoryVfs();
  await self.candidateRestore(vfs); await self.candidateInstall(ctx, loader, vfs);
  await assert.rejects(self.candidateSave(), /CHECKPOINT_FAILED/);
  assert.equal(native().filter(x => x.operation === 'session-changed').at(-1).failure, 'CHECKPOINT_FAILED');
  for (const callback of intervals.values()) callback();
  for (let i = 0; i < 5; i++) await tick();
  assert.equal(attempts, 2);
  await self.candidateSave();
  assert.equal(attempts, 3);
});
