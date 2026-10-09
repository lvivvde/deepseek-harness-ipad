// Test-only smart-HTTP Git remote (#39 gate 5) behind basic auth. It serves the stateless RPC of
// `git upload-pack` and `git receive-pack` itself, so it needs only git (the Linux guest image has
// no git-http-backend).
// Usage: node git_http_fixture.cjs <project-root> <port-file>
// The only accepted password is DSH_GIT_TOKEN from this process's environment; it is removed from
// the environment at once, so git never sees it, and nothing here logs a request.
// GET /__stats (no auth) answers {authorized, refused, pushes} counts.
'use strict';
const http = require('node:http');
const cp = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');
const zlib = require('node:zlib');

const [root, portFile] = process.argv.slice(2);
const token = process.env.DSH_GIT_TOKEN ?? '';
delete process.env.DSH_GIT_TOKEN;
const stats = {authorized: 0, refused: 0, pushes: 0};
const SERVICES = new Set(['git-upload-pack', 'git-receive-pack']);

function credentials(header) {
  if (!header?.startsWith('Basic ')) return null;
  const text = Buffer.from(header.slice(6), 'base64').toString('utf8');
  const at = text.indexOf(':');
  return at < 0 ? null : {user: text.slice(0, at), password: text.slice(at + 1)};
}

// A bare repository directly under the project root, named by the first path component.
function repository(name) {
  if (!/^[A-Za-z0-9._-]+\.git$/.test(name)) return null;
  const dir = path.join(root, name);
  return fs.existsSync(path.join(dir, 'HEAD')) ? dir : null;
}

const pkt = text => (text.length + 4).toString(16).padStart(4, '0') + text;

function serve(request, response, service, dir, advertise) {
  const env = {PATH: process.env.PATH, HOME: process.env.HOME ?? '/tmp', GIT_CONFIG_NOSYSTEM: '1',
    GIT_PROTOCOL: request.headers['git-protocol'] ?? ''};
  const args = [service.slice(4), '--stateless-rpc', ...(advertise ? ['--advertise-refs'] : []), dir];
  const child = cp.spawn('git', args, {env, stdio: ['pipe', 'pipe', 'ignore']});
  response.writeHead(200, {'content-type': `application/x-${service}-${advertise ? 'advertisement' : 'result'}`,
    'cache-control': 'no-cache'});
  // Protocol v0 starts the advertisement with the service line; v2 (GIT_PROTOCOL) does not.
  if (advertise && !/version=2/.test(env.GIT_PROTOCOL)) response.write(pkt(`# service=${service}\n`) + '0000');
  child.stdout.pipe(response);
  if (advertise) child.stdin.end();
  else {
    if (service === 'git-receive-pack') stats.pushes++;
    const body = request.headers['content-encoding'] === 'gzip' ? request.pipe(zlib.createGunzip()) : request;
    body.pipe(child.stdin);
  }
}

const server = http.createServer((request, response) => {
  const url = new URL(request.url, 'http://fixture');
  if (url.pathname === '/__stats') { response.writeHead(200, {'content-type': 'application/json'}); return response.end(JSON.stringify(stats)); }
  const given = credentials(request.headers.authorization);
  if (!token || !given || given.password !== token) {
    if (given) stats.refused++;
    response.writeHead(401, {'www-authenticate': 'Basic realm="fixture"'});
    return response.end();
  }
  stats.authorized++;
  const parts = url.pathname.split('/').filter(Boolean);
  const dir = parts.length >= 2 ? repository(parts[0]) : null;
  const rest = parts.slice(1).join('/');
  const service = rest === 'info/refs' ? url.searchParams.get('service') : rest;
  if (!dir || !SERVICES.has(service) || (rest === 'info/refs') !== (request.method === 'GET')) {
    response.writeHead(404);
    return response.end();
  }
  serve(request, response, service, dir, rest === 'info/refs');
});
server.listen(0, '127.0.0.1', () => fs.writeFileSync(portFile, String(server.address().port)));
process.on('SIGTERM', () => process.exit(0));
