// Real pinned Worker VFS + official JSONL flush -> the production Swift handler -> a new Worker.
import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import {readFileSync, mkdtempSync, rmSync, writeFileSync, symlinkSync, mkdirSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {resolve, join} from 'node:path';
import {spawn} from 'node:child_process';
import {createInterface} from 'node:readline';
import {gunzipSync} from 'node:zlib';
import {patchWorker} from './prepare.mjs';

const repo = resolve(import.meta.dirname, '../..');
const probe = process.env.HOME_RECOVERY_PROBE ?? join(repo, 'ios/HarnessApp/.build/debug/home-recovery-probe');
const official = readFileSync(join(repo, 'build/prototypes/plan500-worker/dependencies/node_modules/@deepseek-ai/dsh-experimental-webworker-runtime/lib/worker.js'), 'utf8');
const image = gunzipSync(readFileSync(join(repo, 'build/candidate/CandidateWeb/vfs-image.tar.gz')));
const bridge = readFileSync(join(import.meta.dirname, 'candidate-bridge.js'), 'utf8') + '\n' + readFileSync(join(import.meta.dirname, 'session-recovery.js'), 'utf8');
function native(root) {
  const child = spawn(probe, [root], {stdio: ['pipe', 'pipe', 'inherit']});
  const pending = [];
  createInterface({input: child.stdout}).on('line', line => pending.shift()?.resolve(JSON.parse(line)));
  child.on('exit', () => { for (const p of pending.splice(0)) p.reject(new Error('PROBE_EXITED')); });
  return {child, call: body => new Promise((resolve, reject) => { pending.push({resolve, reject}); child.stdin.write(JSON.stringify(body) + '\n'); }), close: () => child.kill()};
}
async function worker(host) {
  let timerId = 0; const timers = new Map();
  const cancelTimer = id => { clearTimeout(timers.get(id)); clearInterval(timers.get(id)); timers.delete(id); };
  const c = {console, TextDecoder, TextEncoder, URL, Headers, Response, Request, ReadableStream, WritableStream,
    TransformStream, AbortController, AbortSignal, DOMException, atob, btoa, crypto: globalThis.crypto,
    setTimeout: (...a) => { timers.set(++timerId, setTimeout(...a).unref()); return timerId; }, clearTimeout: cancelTimer,
    setInterval: (...a) => { timers.set(++timerId, setInterval(...a).unref()); return timerId; }, clearInterval: cancelTimer, queueMicrotask, performance, fetch};
  c.self = c; c.addEventListener = () => {};
  c.postMessage = message => {
    if (message.t === 'candidate-native') host.call(message.body).then(result => c.candidateNativeReply({id: message.id, result}));
  };
  vm.createContext(c);
  vm.runInContext(patchWorker(official, bridge) + '\nself.runtime={loadVfsImage,WorkerModuleLoader,setActiveVfs,setActiveModuleLoader,installProcessGlobal,createNodeBuiltins,REPLACED_PREFIXES};', c);
  const r = c.runtime;
  r.installProcessGlobal({cwd: '/dsh', env: {DSH_HOME: '/dsh/home', HOME: '/dsh/home'}});
  const vfs = r.loadVfsImage(image);
  await c.candidateRestore(vfs);
  r.setActiveVfs(vfs);
  const loader = new r.WorkerModuleLoader({vfs, root: '/dsh', staticModules: {...r.createNodeBuiltins(), 'node:process': () => c.process, process: () => c.process}, staticModulePrefixes: r.REPLACED_PREFIXES});
  r.setActiveModuleLoader(loader);
  const require = loader.requireFrom('/dsh/config');
  const ctx = new (require('@deepseek-ai/cordis').Context)();
  const persistence = new (require('@deepseek-ai/dsh-session-persistence-jsonl').default)(ctx, {root: '/dsh/home/sessions', compression: 'none'});
  // Other tools are outside this test's seam. The persistence, event bus, fs and module loader are real.
  class Subprocess { spawn() {} resolveExecutable() {} terminalEnvironment() {} spawnTerminal() {} }
  class Shell { resolve() {} execute() {} executeArgv() {} }
  const extras = {subprocess: new Subprocess(), shell: new Shell(), credentials: {set: async () => {}}, workspaceRegistry: {resolveByPath: async () => true}};
  const adapted = {get: name => name === 'sessionPersistence' ? persistence : extras[name], on: ctx.on.bind(ctx)};
  await c.candidateInstall(adapted, loader, vfs);
  return {self: c, vfs, persistence, ctx, close: () => { for (const id of timers.keys()) cancelTimer(id); }};
}

test('real official flush and Worker bytes survive Swift storage and a new Worker', async () => {
  const root = mkdtempSync(join(tmpdir(), 'home-roundtrip-')); const host = native(root);
  try {
    const first = await worker(host);
    first.vfs.seedDirectory('/dsh/home/test', {mode: 0o40700, mtimeMs: 1234});
    first.vfs.seed('/dsh/home/test/binary', new Uint8Array([0, 255, 128, 10]), {mode: 0o100600, mtimeMs: 2345});
    first.vfs.seed('/dsh/home/test/text', new TextEncoder().encode('会话\n'), {mode: 0o100640, mtimeMs: 3456});
    first.vfs.seed('/dsh/home/.credentials.yaml', new TextEncoder().encode('must stay out'));
    await first.persistence.create({version: 4, id: 'recovery-test', createdAt: 1, isSeeded: false});
    assert.equal([...first.vfs.files.keys()].some(x => x.endsWith('session.v4.jsonl')), false, 'create is still buffered');
    await first.self.candidateSave();
    assert.equal((await host.call({operation: 'status'})).session.phase, 'SAVED');
    first.vfs.writeFileSync('/dsh/home/settings.json', '{}');
    assert.equal((await host.call({operation: 'status'})).session.phase, 'UNSAVED', 'non-session VFS mutations also become dirty');
    await first.self.candidateSave();
    const sessionPath = [...first.vfs.files.keys()].find(x => x.endsWith('session.v4.jsonl'));
    const sessionBytes = Array.from(first.vfs.readFileSync(sessionPath));
    assert.ok(sessionBytes.length > 0, 'production flush materialized the header');
    first.close();
    await host.call({operation: 'probe-restart'});
    const second = await worker(host);
    assert.deepEqual(Array.from(second.vfs.readFileSync('/dsh/home/test/binary')), [0, 255, 128, 10]);
    assert.equal(new TextDecoder().decode(second.vfs.readFileSync('/dsh/home/test/text')), '会话\n');
    assert.equal(second.vfs.statSync('/dsh/home/test/text').mode, 0o100640);
    assert.equal(second.vfs.statSync('/dsh/home/test/text').mtimeMs, 3456);
    assert.equal(second.vfs.statSync('/dsh/home/test').mode, 0o40700);
    assert.deepEqual(Array.from(second.vfs.readFileSync(sessionPath)), sessionBytes);
    assert.equal((await second.persistence.stat('recovery-test')).header.createdAt, 1);
    assert.equal(second.vfs.existsSync('/dsh/home/.credentials.yaml'), false);
    second.close();
  } finally { host.close(); rmSync(root, {recursive: true, force: true}); }
});

const home = text => ({formatVersion: 1, directories: [{path: '/dsh/home', mode: 0o40755, mtimeMs: 1}],
  files: [{path: '/dsh/home/a', mode: 0o100644, mtimeMs: 1, base64: Buffer.from(text).toString('base64')}]});
async function save(host, worker, revision, snapshot) {
  const ticket = await host.call({operation: 'checkpoint-begin', worker, revision});
  return host.call({operation: 'checkpoint', worker, revision, capture: ticket.capture, snapshot});
}

test('crash at each durable replacement stage keeps a complete restorable copy', async () => {
  for (const skip of [0, 1, 2]) for (const stage of ['beforeTemp', 'halfWritten', 'beforeSync', 'beforeRename', 'afterRename']) {
    const root = mkdtempSync(join(tmpdir(), 'home-crash-')); let host = native(root);
    try {
      const {worker} = await host.call({operation: 'restore'});
      assert.equal((await save(host, worker, 1, home('old'))).durable, true);
      await host.call({operation: 'probe-fault', point: 'checkpoint.' + stage, crash: true, skip});
      await assert.rejects(save(host, worker, 2, home('new')), /PROBE_EXITED/);
      host = native(root);
      const restored = await host.call({operation: 'restore'});
      const expected = skip === 2 || (skip === 1 && stage === 'afterRename') ? 'new' : 'old';
      assert.equal(Buffer.from(restored.snapshot.files[0].base64, 'base64').toString(), expected, `${skip}:${stage}`);
    } finally { host.close(); rmSync(root, {recursive: true, force: true}); }
  }
});

test('explicit fresh start cannot resurrect a higher-sequence preserved checkpoint', async () => {
  const root = mkdtempSync(join(tmpdir(), 'home-fresh-')); const host = native(root);
  try {
    let restored = await host.call({operation: 'restore'});
    for (let i = 1; i <= 3; i++) assert.equal((await save(host, restored.worker, i, home('old'))).durable, true);
    writeFileSync(join(root, 'home-current.json'), JSON.stringify({formatVersion: 3, body: '', checksum: ''}));
    await host.call({operation: 'probe-restart'});
    assert.equal((await host.call({operation: 'restore'})).error, 'RECOVERY_BLOCKED');
    assert.equal((await host.call({operation: 'session-fresh'})).fresh, true);
    restored = await host.call({operation: 'restore'});
    assert.equal(restored.snapshot, null);
    assert.equal((await save(host, restored.worker, 1, home('fresh'))).durable, true);
    await host.call({operation: 'probe-restart'});
    restored = await host.call({operation: 'restore'});
    assert.equal(Buffer.from(restored.snapshot.files[0].base64, 'base64').toString(), 'fresh');
  } finally { host.close(); rmSync(root, {recursive: true, force: true}); }
});

test('save failures remain unsaved and retry keeps the last durable copy', async () => {
  for (const stage of ['beforeTemp', 'halfWritten', 'beforeSync', 'beforeRename', 'afterRename']) {
    const root = mkdtempSync(join(tmpdir(), 'home-failure-')); const host = native(root);
    try {
      const {worker} = await host.call({operation: 'restore'});
      await save(host, worker, 1, home('old'));
      await host.call({operation: 'probe-fault', point: 'checkpoint.' + stage, skip: 1});
      assert.equal((await save(host, worker, 2, home('new'))).error, 'CHECKPOINT_FAILED');
      let status = (await host.call({operation: 'status'})).session;
      assert.equal(status.phase, 'UNSAVED'); assert.equal(status.failure, 'CHECKPOINT_FAILED'); assert.ok(status.savedAt);
      await host.call({operation: 'probe-fault', point: null});
      assert.equal((await save(host, worker, 2, home('new'))).durable, true);
      status = (await host.call({operation: 'status'})).session;
      assert.equal(status.phase, 'SAVED'); assert.equal(status.failure, null);
    } finally { host.close(); rmSync(root, {recursive: true, force: true}); }
  }
});

test('an old Worker and a reused capture cannot overwrite newer home or clear a newer revision', async () => {
  const root = mkdtempSync(join(tmpdir(), 'home-races-')); const host = native(root);
  try {
    const old = (await host.call({operation: 'restore'})).worker;
    const stale = await host.call({operation: 'checkpoint-begin', worker: old, revision: 1});
    const current = (await host.call({operation: 'restore'})).worker;
    assert.equal((await host.call({operation: 'checkpoint', worker: old, revision: 1, capture: stale.capture, snapshot: home('old')})).error, 'STALE_WORKER');
    const ticket = await host.call({operation: 'checkpoint-begin', worker: current, revision: 1});
    await host.call({operation: 'session-changed', worker: current, revision: 2});
    const body = {operation: 'checkpoint', worker: current, revision: 1, capture: ticket.capture, snapshot: home('current')};
    assert.equal((await host.call(body)).durable, true);
    assert.equal((await host.call({operation: 'status'})).session.phase, 'UNSAVED');
    assert.equal((await host.call(body)).error, 'CAPTURE_REFUSED');
    assert.equal((await host.call({operation: 'session-changed', worker: old, revision: 100})).error, 'STALE_WORKER');
    assert.equal((await save(host, current, 2, home('latest'))).durable, true);
    assert.equal((await host.call({operation: 'status'})).session.phase, 'SAVED');
  } finally { host.close(); rmSync(root, {recursive: true, force: true}); }
});

test('legacy home migrates only after a verified save; missing or unreadable used storage blocks', async () => {
  const root = mkdtempSync(join(tmpdir(), 'home-legacy-')); const host = native(root);
  try {
    const legacy = JSON.stringify(home('legacy'));
    writeFileSync(join(root, 'worker-home.json'), legacy);
    const restored = await host.call({operation: 'restore'});
    assert.equal(restored.diagnosis, 'LEGACY_CHECKPOINT');
    assert.equal((await save(host, restored.worker, 1, home('new'))).durable, true);
    assert.equal(readFileSync(join(root, 'worker-home.json'), 'utf8'), legacy);
    await host.call({operation: 'probe-restart'});
    assert.equal((await host.call({operation: 'restore'})).diagnosis, null);
    rmSync(join(root, 'home-current.json')); rmSync(join(root, 'home-previous.json')); rmSync(join(root, 'worker-home.json'));
    await host.call({operation: 'probe-restart'});
    assert.equal((await host.call({operation: 'restore'})).error, 'RECOVERY_BLOCKED');
  } finally { host.close(); rmSync(root, {recursive: true, force: true}); }
});

test('used storage never silently falls back to retained legacy; an unreadable entry blocks', async () => {
  const root = mkdtempSync(join(tmpdir(), 'home-read-')); const host = native(root);
  try {
    writeFileSync(join(root, 'worker-home.json'), JSON.stringify(home('legacy')));
    const restored = await host.call({operation: 'restore'});
    await save(host, restored.worker, 1, home('modern'));
    rmSync(join(root, 'home-current.json')); rmSync(join(root, 'home-previous.json'));
    await host.call({operation: 'probe-restart'});
    assert.equal((await host.call({operation: 'restore'})).error, 'RECOVERY_BLOCKED');
  } finally { host.close(); rmSync(root, {recursive: true, force: true}); }
});


test('unreadable checkpoint and failed quarantine preserve evidence and block startup', async () => {
  for (const kind of ['dangling', 'directory', 'quarantine']) {
    const root = mkdtempSync(join(tmpdir(), 'home-unreadable-')); const host = native(root);
    try {
      if (kind === 'dangling') symlinkSync(join(root, 'missing'), join(root, 'home-current.json'));
      else if (kind === 'directory') mkdirSync(join(root, 'home-current.json'));
      else { writeFileSync(join(root, 'home-current.json'), 'corrupt'); writeFileSync(join(root, 'home-quarantine'), 'not a directory'); }
      assert.equal((await host.call({operation: 'restore'})).error, 'RECOVERY_BLOCKED');
      assert.equal((await host.call({operation: 'status'})).session.phase, 'BLOCKED');
      if (kind === 'quarantine') assert.equal(readFileSync(join(root, 'home-current.json'), 'utf8'), 'corrupt');
    } finally { host.close(); rmSync(root, {recursive: true, force: true}); }
  }
});
