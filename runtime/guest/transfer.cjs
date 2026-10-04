// Single-project export/import for the iPad host, reachable only through a per-boot token.
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const crypto = require('node:crypto');
const {pipeline} = require('node:stream/promises');
const tar = require('/opt/node/lib/node_modules/npm/node_modules/tar');

const root = process.env.HARNESS_PROJECTS || '/root/projects';
// Same filesystem as the projects, so trashing and restoring are single renames.
const trash = process.env.HARNESS_TRASH || path.join(root, '..', '.trash');
const validTrashId = id => /^\d{13}-[0-9a-f]{8}$/.test(id);
const skipped = new Set(['node_modules', '.cache']);
const token = (fs.readFileSync(process.env.HARNESS_CMDLINE || '/proc/cmdline', 'utf8').match(/(?:^|\s)harness\.transfer=([0-9a-f]{32,})(?:\s|$)/) || [])[1];
// Any single visible path component: Chinese, spaces and symbols are fine; hidden and staging entries are not.
const validName = name => !name.startsWith('.') && !/[\/\x00-\x1f]/.test(name) && Buffer.byteLength(name) <= 200;

function authorized(request) {
  const given = Buffer.from(String(request.headers['x-harness-transfer'] || ''));
  const expected = Buffer.from(token || '');
  return token && given.length === expected.length && crypto.timingSafeEqual(given, expected);
}

function projects() {
  return fs.readdirSync(root, {withFileTypes: true})
    .filter(entry => entry.isDirectory() && validName(entry.name)).map(entry => entry.name).sort();
}

async function exportProject(name, response) {
  if (!projectPath(name)) return send(response, 404, {error: 'PROJECT_NOT_FOUND'});
  response.writeHead(200, {'content-type': 'application/x-tar'});
  // Credentials never live in projects; dependency and cache folders are rebuilt after import.
  const filter = file => !file.split('/').some(part => skipped.has(part));
  await pipeline(tar.c({cwd: root, portable: true, filter}, [name]), response);
}

async function importProject(request, response) {
  const staging = fs.mkdtempSync(path.join(root, '.import-'));
  try {
    // node-tar refuses absolute paths, '..' and writes through symlinks by default.
    await pipeline(request, tar.x({cwd: staging, strict: true, preserveOwner: false}));
    const entries = fs.readdirSync(staging, {withFileTypes: true});
    if (entries.length !== 1 || !entries[0].isDirectory() || !validName(entries[0].name)) {
      return send(response, 422, {error: 'ARCHIVE_LAYOUT'});
    }
    const name = freeName(entries[0].name);
    fs.renameSync(path.join(staging, entries[0].name), path.join(root, name));
    send(response, 201, {name, path: path.join(root, name)});
  } catch {
    send(response, 422, {error: 'ARCHIVE_INVALID'});
  } finally {
    fs.rmSync(staging, {recursive: true, force: true});
  }
}

function projectPath(name) {
  return validName(name) && fs.statSync(path.join(root, name), {throwIfNoEntry: false})?.isDirectory()
    ? path.join(root, name) : undefined;
}

function freeName(base) {
  let name = base;
  for (let suffix = 2; fs.existsSync(path.join(root, name)); suffix++) name = `${base}-${suffix}`;
  return name;
}

async function directoryBytes(directory) {
  let total = 0;
  for (const entry of await fs.promises.readdir(directory, {withFileTypes: true})) {
    const full = path.join(directory, entry.name);
    if (entry.isDirectory()) total += await directoryBytes(full);
    else total += (await fs.promises.lstat(full)).blocks * 512;
  }
  return total;
}

function trashProject(name, response) {
  const source = projectPath(name);
  if (!source) return send(response, 404, {error: 'PROJECT_NOT_FOUND'});
  const id = `${Date.now()}-${crypto.randomBytes(4).toString('hex')}`;
  const entry = path.join(trash, id);
  fs.mkdirSync(entry, {recursive: true});
  const meta = {name, deletedAt: Date.now()};
  fs.writeFileSync(path.join(entry, 'meta.json'), JSON.stringify(meta));
  fs.renameSync(source, path.join(entry, name));
  send(response, 200, {id});
  // Size is informational; walking a large node_modules on TCG must not hold the request.
  directoryBytes(path.join(entry, name))
    .then(bytes => fs.promises.writeFile(path.join(entry, 'meta.json'), JSON.stringify({...meta, bytes})))
    .catch(() => {});
}

function trashItems() {
  if (!fs.existsSync(trash)) return [];
  return fs.readdirSync(trash).filter(validTrashId).flatMap(id => {
    try {
      const {name, deletedAt, bytes} = JSON.parse(fs.readFileSync(path.join(trash, id, 'meta.json'), 'utf8'));
      return validName(name) ? [{id, name, deletedAt, bytes}] : [];
    } catch { return []; }
  }).sort((a, b) => b.deletedAt - a.deletedAt);
}

function trashEntry(id) {
  if (!validTrashId(id)) return undefined;
  try {
    const {name} = JSON.parse(fs.readFileSync(path.join(trash, id, 'meta.json'), 'utf8'));
    return validName(name) && fs.existsSync(path.join(trash, id, name)) ? {name, dir: path.join(trash, id)} : undefined;
  } catch { return undefined; }
}

function restoreItem(id, response) {
  const entry = trashEntry(id);
  if (!entry) return send(response, 404, {error: 'TRASH_NOT_FOUND'});
  const name = freeName(entry.name);
  fs.renameSync(path.join(entry.dir, entry.name), path.join(root, name));
  fs.rmSync(entry.dir, {recursive: true, force: true});
  send(response, 200, {name, path: path.join(root, name)});
}

// Purging renames first so the item leaves the list at once; removal continues in the background
// and any leftover `.purging-*` is finished on the next start.
function purge(ids, response) {
  for (const id of ids) {
    const target = path.join(trash, `.purging-${id}`);
    fs.renameSync(path.join(trash, id), target);
  }
  send(response, 200, {purged: ids.length});
  sweep();
}

function sweep() {
  if (!fs.existsSync(trash)) return;
  for (const leftover of fs.readdirSync(trash).filter(name => name.startsWith('.purging-'))) {
    fs.promises.rm(path.join(trash, leftover), {recursive: true, force: true}).catch(() => {});
  }
}

function send(response, status, body) {
  if (response.headersSent) return response.destroy();
  response.writeHead(status, {'content-type': 'application/json'});
  response.end(JSON.stringify(body));
}

const server = http.createServer(async (request, response) => {
  if (!authorized(request)) return send(response, 403, {error: 'FORBIDDEN'});
  const url = new URL(request.url, 'http://transfer');
  const exportMatch = url.pathname.match(/^\/projects\/([^/]+)\/archive$/);
  const projectMatch = url.pathname.match(/^\/projects\/([^/]+)$/);
  const trashMatch = url.pathname.match(/^\/trash\/([^/]+?)(\/restore)?$/);
  try {
    if (request.method === 'GET' && url.pathname === '/projects') return send(response, 200, {projects: projects()});
    if (request.method === 'GET' && exportMatch) return await exportProject(decodeURIComponent(exportMatch[1]), response);
    if (request.method === 'POST' && url.pathname === '/projects/import') return await importProject(request, response);
    if (request.method === 'DELETE' && projectMatch) return trashProject(decodeURIComponent(projectMatch[1]), response);
    if (request.method === 'GET' && url.pathname === '/trash') return send(response, 200, {items: trashItems()});
    if (request.method === 'DELETE' && url.pathname === '/trash') return purge(trashItems().map(item => item.id), response);
    if (request.method === 'POST' && trashMatch?.[2]) return restoreItem(trashMatch[1], response);
    if (request.method === 'DELETE' && trashMatch && !trashMatch[2]) {
      return trashEntry(trashMatch[1]) ? purge([trashMatch[1]], response) : send(response, 404, {error: 'TRASH_NOT_FOUND'});
    }
    send(response, 404, {error: 'NOT_FOUND'});
  } catch {
    send(response, 500, {error: 'TRANSFER_FAILED'});
  }
});

if (require.main === module) {
  if (!token) { console.log('HARNESS_TRANSFER_DISABLED'); return; }
  fs.mkdirSync(root, {recursive: true});
  sweep();
  server.listen(Number(process.env.HARNESS_TRANSFER_PORT || 3002), process.env.HARNESS_TRANSFER_HOST || '10.0.2.15',
    () => console.log('HARNESS_TRANSFER_READY'));
}
module.exports = {server};
