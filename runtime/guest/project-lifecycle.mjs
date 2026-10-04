import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';

// A host plugin: registry mutations stay in the owning dsh process and publish
// the official feed. Never rewrite its JSON storage from the transfer process.
export const name = 'ipad-project-lifecycle';
export const inject = ['workspaceRegistry', 'sessionPersistence'];

export function createLifecycleServer(registry, projectsRoot = '/root/projects', listSessions = async () => []) {
  const canonicalRoot = fs.realpathSync(projectsRoot);
  let tail = Promise.resolve();
  return http.createServer((request, response) => {
    const operation = async () => {
      if (request.method !== 'POST' || request.url !== '/retire') {
        response.writeHead(404).end(); return;
      }
      let size = 0;
      const chunks = [];
      for await (const chunk of request) {
        size += chunk.length;
        if (size > 4096) throw new Error('REQUEST_LIMIT');
        chunks.push(chunk);
      }
      const {name, before} = JSON.parse(Buffer.concat(chunks).toString());
      if (typeof name !== 'string' || !name || name.startsWith('.') || /[/\x00-\x1f]/.test(name) ||
          (before !== undefined && !Number.isFinite(before))) throw new Error('INVALID_PROJECT');
      const project = path.join(canonicalRoot, name);
      const requestedProject = path.join(projectsRoot, name);
      const workspaces = registry.list().filter(workspace =>
        (workspace.path === project || workspace.path.startsWith(project + path.sep)) &&
        (before === undefined || Date.parse(workspace.createdAt) <= before));
      // Capture membership before any rename makes the directory unavailable.
      // Archival is durable before stop requests; the official pre-step gate
      // then prevents an old conversation from recreating the project.
      const ids = new Set(workspaces.flatMap(workspace => workspace.sessionIds));
      // Pre-fix trash can be loaded after a cold boot, where a missing cwd
      // filters membership out of workspace.sessionIds. Stored headers remain
      // authoritative and let us archive those conversations too.
      for (const {header} of await listSessions()) {
        if (typeof header.cwd === 'string' &&
            [project, requestedProject].some(directory => header.cwd === directory || header.cwd.startsWith(directory + path.sep)) &&
            (before === undefined || header.createdAt <= before)) ids.add(header.id);
      }
      for (const id of ids) await registry.archiveSession(id, {stopActivity: true});
      for (const workspace of workspaces) {
        await registry.delete(workspace.id);
      }
      response.writeHead(200, {'content-type': 'application/json'});
      response.end(JSON.stringify({retired: workspaces.length}));
    };
    tail = tail.then(operation).catch(() => {
      if (!response.headersSent) response.writeHead(503, {'content-type': 'application/json'});
      response.end('{"error":"WORKSPACE_UNAVAILABLE"}');
    });
  });
}

export async function apply(ctx) {
  const socket = '/run/harness-workspaces.sock';
  // /run is a fresh tmpfs on every boot. A live peer is never unlinked.
  const server = createLifecycleServer(ctx.workspaceRegistry, '/root/projects', async () => {
    const stored = await ctx.sessionPersistence.list();
    const live = ctx.get('sessions')?.list().map(session => ({header: session.header})) ?? [];
    return [...stored, ...live];
  });
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(socket, () => {
      fs.chmodSync(socket, 0o600);
      resolve();
    });
  });
  ctx.effect(() => () => new Promise(resolve => server.close(() => {
    fs.rmSync(socket, {force: true});
    resolve();
  })), 'ipad-project-lifecycle.socket');
}
