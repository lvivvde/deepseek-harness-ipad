// Real official registry + durable JSON storage + the actual transfer HTTP API.
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {createRequire} from 'node:module';
import {pathToFileURL} from 'node:url';
import {createLifecycleServer} from '../guest/project-lifecycle.mjs';

const modules = process.env.HARNESS_TEST_MODULES;
const load = name => import(pathToFileURL(path.join(modules, '@deepseek-ai', name, 'lib/index.js')));
const {Context} = await load('cordis');
const {Storage} = await load('dsh-storage');
const {JsonStorageBackend} = await load('dsh-storage-json');
const {DomainFacility} = await load('dsh-storage-domain');
const {WorkspaceRegistry} = await load('dsh-workspace');
const root = await fs.mkdtemp(path.join(os.tmpdir(), 'trash-regression-'));
const projects = path.join(root, 'projects');
const project = path.join(projects, '字体');
const token = '0123456789abcdef0123456789abcdef'; // Test fixture, never a device credential.
const socket = path.join(root, 'registry.sock');
const headers = [{id: 'old-conversation', cwd: project, createdAt: 1}];
let transfer, lifecycle, backend;
try {
  await fs.mkdir(project, {recursive: true});
  await fs.writeFile(path.join(project, 'keep.txt'), 'project-data');
  const cmdline = path.join(root, 'cmdline');
  await fs.writeFile(cmdline, `harness.transfer=${token}`);
  Object.assign(process.env, {
    HARNESS_PROJECTS: projects, HARNESS_CMDLINE: cmdline, HARNESS_WORKSPACE_SOCKET: socket,
  });
  const ctx = new Context();
  let activeContext = ctx;
  new Storage(ctx);
  backend = new JsonStorageBackend(path.join(root, 'state'));
  ctx.storage.backend.register('json', backend);
  ctx.provide('storageDomain', new DomainFacility(ctx, {backend: 'json'}));
  ctx.provide('sessionPersistence', {list: async () => headers.map(header => ({header}))});
  await ctx.plugin(WorkspaceRegistry);
  let registry = ctx.workspaceRegistry;
  const changes = [];
  ctx.on('domain/changed', change => changes.push(change));
  const initialWorkspace = registry.list()[0];
  await fs.mkdir(path.join(projects, 'unrelated'));
  const unrelated = await registry.create(path.join(projects, 'unrelated'));
  lifecycle = createLifecycleServer(registry, projects, async () => headers.map(header => ({header})));
  await new Promise(resolve => lifecycle.listen(socket, resolve));
  transfer = createRequire(import.meta.url)('../guest/transfer.cjs').server;
  await new Promise(resolve => transfer.listen(0, '127.0.0.1', resolve));
  const origin = `http://127.0.0.1:${transfer.address().port}`;
  const call = async (method, route) => {
    const response = await fetch(origin + route, {method, headers: {'X-Harness-Transfer': token}});
    return {status: response.status, body: await response.json()};
  };
  const mode = process.argv[2];
  if (mode === 'delete') {
    const result = await call('DELETE', '/projects/' + encodeURIComponent('字体'));
    assert.equal(result.status, 200);
    assert.equal(registry.get(initialWorkspace.id), undefined, 'deleted project must leave the official sidebar');
    assert.ok(registry.archivedSessionIds.includes('old-conversation'), 'old conversations must be blocked before moving files');
    assert.ok(changes.some(change => change.domain === 'workspace' && change.table === 'workspaces' &&
      change.operation === 'deleted' && change.key === initialWorkspace.id), 'official sidebar subscribers must receive the removal');
    assert.equal(registry.get(unrelated.id)?.path, unrelated.path);
    const listing = await call('GET', '/trash');
    assert.equal(listing.body.items.length, 1);
    const id = listing.body.items[0].id;
    assert.equal(await fs.readFile(path.join(root, '.trash', id, '字体', 'keep.txt'), 'utf8'), 'project-data');
    assert.equal((await call('DELETE', '/trash')).status, 200);
    assert.deepEqual((await call('GET', '/trash')).body.items, []);
    assert.equal(registry.get(initialWorkspace.id), undefined);
  } else if (mode === 'legacy') {
    const id = '1791095339992-acd6a38b';
    const entry = path.join(root, '.trash', id);
    await fs.mkdir(entry, {recursive: true});
    await fs.writeFile(path.join(entry, 'meta.json'), JSON.stringify({name: '字体', deletedAt: Date.now() + 1000}));
    await fs.rename(project, path.join(entry, '字体'));
    // Cold boot with a missing project: the official membership projection is
    // empty, even though the persisted conversation still refers to that path.
    await new Promise(resolve => lifecycle.close(resolve));
    await ctx.storageDomain.closeAll();
    await backend.close();
    activeContext = new Context();
    new Storage(activeContext);
    backend = new JsonStorageBackend(path.join(root, 'state'));
    activeContext.storage.backend.register('json', backend);
    activeContext.provide('storageDomain', new DomainFacility(activeContext, {backend: 'json'}));
    activeContext.provide('sessionPersistence', {list: async () => headers.map(header => ({header}))});
    await activeContext.plugin(WorkspaceRegistry);
    registry = activeContext.workspaceRegistry;
    assert.deepEqual(registry.get(initialWorkspace.id).sessionIds, []);
    lifecycle = createLifecycleServer(registry, projects, async () => headers.map(header => ({header})));
    await new Promise(resolve => lifecycle.listen(socket, resolve));
    const result = await call('DELETE', '/trash');
    assert.equal(result.status, 200);
    assert.equal(registry.get(initialWorkspace.id), undefined, 'purging pre-fix trash must also remove old sidebar registrations');
    assert.ok(registry.archivedSessionIds.includes('old-conversation'), 'missing directories must not lose recorded session membership');
  } else if (mode === 'unavailable') {
    await new Promise(resolve => lifecycle.close(resolve));
    lifecycle = undefined;
    const result = await call('DELETE', '/projects/' + encodeURIComponent('字体'));
    assert.equal(result.status, 503, 'do not move a project when the official registry cannot acknowledge retirement');
    assert.equal(await fs.readFile(path.join(project, 'keep.txt'), 'utf8'), 'project-data');
    assert.ok(registry.get(initialWorkspace.id));
  } else if (mode === 'reused-name') {
    const id = '1791095339992-acd6a38b';
    const entry = path.join(root, '.trash', id);
    await fs.mkdir(path.join(entry, '字体'), {recursive: true});
    await fs.writeFile(path.join(entry, 'meta.json'), JSON.stringify({name: '字体', deletedAt: 0}));
    assert.equal((await call('DELETE', '/trash')).status, 200);
    assert.ok(registry.get(initialWorkspace.id), 'a newer workspace with the same name must survive');
    assert.equal(await fs.readFile(path.join(project, 'keep.txt'), 'utf8'), 'project-data');
  }
  await activeContext.storageDomain.closeAll();
  await backend.close();
  // Reopen through the official public registry API: no direct reads of its storage files.
  const reopened = new Context();
  new Storage(reopened);
  backend = new JsonStorageBackend(path.join(root, 'state'));
  reopened.storage.backend.register('json', backend);
  reopened.provide('storageDomain', new DomainFacility(reopened, {backend: 'json'}));
  reopened.provide('sessionPersistence', {list: async () => headers.map(header => ({header}))});
  await reopened.plugin(WorkspaceRegistry);
  if (mode === 'delete' || mode === 'legacy') {
    assert.equal(reopened.workspaceRegistry.get(initialWorkspace.id), undefined);
    assert.ok(reopened.workspaceRegistry.archivedSessionIds.includes('old-conversation'));
  }
  await reopened.storageDomain.closeAll();
  console.log(`PASS:${mode}`);
} finally {
  if (transfer) await new Promise(resolve => transfer.close(resolve));
  if (lifecycle) await new Promise(resolve => lifecycle.close(resolve));
  await backend?.close();
  await fs.rm(root, {recursive: true, force: true});
}
