// PROTOTYPE: trusted synthetic requests only. This is not a tool sandbox.
const http = require('node:http');
const fs = require('node:fs');
const cp = require('node:child_process');
const root = '/workspace';
const token = fs.readFileSync('/run/probe-token', 'utf8').trim();
const identity = fs.readFileSync(root + '/.plan500-identity', 'utf8').trim();
const operations = new Map();
const events = [];
const allowed = new Set(['/bin/sh', '/usr/bin/git', '/opt/node/bin/node']);

function kill(operation) {
  if (!operation.child || operation.child.exitCode !== null) return;
  try { process.kill(-operation.child.pid, 'SIGKILL'); } catch {}
}
function execute(request) {
  const signature = JSON.stringify({projectId: request.projectId, argv: request.argv,
    cwd: request.cwd, timeoutMs: request.timeoutMs});
  if (operations.has(request.id)) {
    const previous = operations.get(request.id);
    if (previous.signature !== signature) throw new Error('OPERATION_ID_CONFLICT');
    return previous.promise;
  }
  if (request.projectId !== identity) throw new Error('PROJECT_ID_MISMATCH');
  if (!Array.isArray(request.argv) || !allowed.has(request.argv[0]) ||
      !request.argv.every(x => typeof x === 'string') || request.argv.length > 100)
    throw new Error('ARGV_REFUSED');
  const cwd = fs.realpathSync(request.cwd ?? root);
  if (cwd !== root && !cwd.startsWith(root + '/')) throw new Error('CWD_REFUSED');
  const operation = {id: request.id, signature, child: undefined, cancelled: false};
  // Install the operation before spawning, so retries join the same promise.
  operations.set(request.id, operation);
  operation.promise = new Promise(resolve => {
    events.push({id: request.id, phase: 'start'});
    let stdout = '', stderr = '', timeout = false;
    const child = operation.child = cp.spawn(request.argv[0], request.argv.slice(1), {
      cwd, detached: true, env: {PATH: '/opt/node/bin:/usr/bin:/bin', HOME: '/tmp', LANG: 'C.UTF-8'},
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    child.stdout.on('data', data => { stdout = (stdout + data).slice(-65536); });
    child.stderr.on('data', data => { stderr = (stderr + data).slice(-65536); });
    const timer = setTimeout(() => { timeout = true; kill(operation); },
      Math.max(10, Math.min(request.timeoutMs ?? 10000, 15000)));
    child.on('error', error => { stderr += String(error); });
    child.on('close', (code, signal) => {
      clearTimeout(timer);
      const result = {id: request.id, projectId: identity, code, signal, stdout, stderr,
        cancelled: operation.cancelled, timeout};
      events.push({id: request.id, phase: 'end', code, cancelled: operation.cancelled, timeout});
      resolve(result);
    });
  });
  return operation.promise;
}

const server = http.createServer(async (request, response) => {
  const reply = (status, value) => { response.writeHead(status, {'content-type': 'application/json'}); response.end(JSON.stringify(value)); };
  if (request.headers.authorization !== 'Bearer ' + token) return reply(403, {error: 'AUTH_REFUSED'});
  try {
    if (request.url === '/ready') {
      const mount = fs.readFileSync('/proc/mounts', 'utf8').split('\n').find(line => line.split(' ')[1] === root);
      if (!mount || mount.split(' ')[2] !== '9p') throw new Error('WORKSPACE_NOT_9P');
      return reply(200, {protocol: 1, projectId: identity, mount: '9p', node: process.version,
        git: cp.execFileSync('/usr/bin/git', ['--version'], {encoding: 'utf8'}).trim()});
    }
    let body = '';
    for await (const chunk of request) { body += chunk; if (body.length > 131072) throw new Error('BODY_TOO_LARGE'); }
    const input = JSON.parse(body);
    if (typeof input.id !== 'string' || input.id.length > 100) throw new Error('ID_REFUSED');
    if (request.url === '/execute') return reply(200, await execute(input));
    if (request.url === '/cancel') {
      const operation = operations.get(input.id);
      if (!operation) throw new Error('OPERATION_NOT_FOUND');
      operation.cancelled = true; kill(operation); return reply(200, {cancelled: true});
    }
    if (request.url === '/events') return reply(200, {events});
    reply(404, {error: 'ROUTE_REFUSED'});
  } catch (error) { reply(409, {error: String(error.message)}); }
});
server.listen(4500, '0.0.0.0', () => console.log('PLAN500_RPC_READY'));
