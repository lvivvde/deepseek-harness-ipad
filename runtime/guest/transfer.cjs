// Single-project export/import for the iPad host, reachable only through a per-boot token.
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const crypto = require('node:crypto');
const {pipeline} = require('node:stream/promises');
const tar = require('/opt/node/lib/node_modules/npm/node_modules/tar');

const root = process.env.HARNESS_PROJECTS || '/root/projects';
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
  if (!validName(name) || !fs.statSync(path.join(root, name), {throwIfNoEntry: false})?.isDirectory()) {
    return send(response, 404, {error: 'PROJECT_NOT_FOUND'});
  }
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
    let name = entries[0].name;
    for (let suffix = 2; fs.existsSync(path.join(root, name)); suffix++) name = `${entries[0].name}-${suffix}`;
    fs.renameSync(path.join(staging, entries[0].name), path.join(root, name));
    send(response, 201, {name, path: path.join(root, name)});
  } catch {
    send(response, 422, {error: 'ARCHIVE_INVALID'});
  } finally {
    fs.rmSync(staging, {recursive: true, force: true});
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
  try {
    if (request.method === 'GET' && url.pathname === '/projects') return send(response, 200, {projects: projects()});
    if (request.method === 'GET' && exportMatch) return await exportProject(decodeURIComponent(exportMatch[1]), response);
    if (request.method === 'POST' && url.pathname === '/projects/import') return await importProject(request, response);
    send(response, 404, {error: 'NOT_FOUND'});
  } catch {
    send(response, 500, {error: 'TRANSFER_FAILED'});
  }
});

if (require.main === module) {
  if (!token) { console.log('HARNESS_TRANSFER_DISABLED'); return; }
  fs.mkdirSync(root, {recursive: true});
  server.listen(Number(process.env.HARNESS_TRANSFER_PORT || 3002), process.env.HARNESS_TRANSFER_HOST || '10.0.2.15',
    () => console.log('HARNESS_TRANSFER_READY'));
}
module.exports = {server};
