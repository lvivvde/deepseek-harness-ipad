// PROTOTYPE: trusted synthetic requests only; not a tool sandbox.
// Write capability exists only inside a leased command's private mount namespace;
// writer liveness is the command's cgroup plus any outside reference to that namespace's mount.
// Unleased commands run as a separate reader uid so they cannot open /proc/<leased>/cwd.
const http = require('node:http');
const fs = require('node:fs');
const cp = require('node:child_process');
const root = '/workspace';
const writable = '/run/ws/rw';
const groups = '/sys/fs/cgroup/plan500';
const published = '/run/plan500';
const token = fs.readFileSync('/run/probe-token', 'utf8').trim();
const identity = fs.readFileSync(root + '/.plan500-identity', 'utf8').trim();
const owner = fs.statSync(writable);
const reader = {uid: 65534, gid: 65534};
const shareDevice = fs.statSync(root).dev;
const mapsDevice = (((shareDevice >> 8) & 0xfff).toString(16).padStart(2, '0') + ':' +
  ((shareDevice & 0xff) | ((shareDevice >> 12) & 0xfff00)).toString(16).padStart(2, '0'));
const allowed = new Set(['/bin/sh', '/usr/bin/git', '/opt/node/bin/node']);
const operations = new Map();
const sockets = new Set();
let epoch = null, lastFence = 0, activeLease = null, generation = 0;

// Runs as root only long enough to join the cgroup and, for a lease, remount the private view rw.
const WRAPPER = `cg=$1; leased=$2; uid=$3; gid=$4; cwd=$5; shift 5
echo $$ > "$cg/cgroup.procs" || exit 120
if [ "$leased" = 1 ]; then
  exec unshare -m --propagation private -- /bin/sh -c 'mount -o remount,bind,rw,nosuid,nodev /workspace || exit 121
    uid=$1; gid=$2; cd -- "$3" || exit 122; shift 3
    exec setpriv --reuid "$uid" --regid "$gid" --clear-groups --no-new-privs -- "$@"' plan500 "$uid" "$gid" "$cwd" "$@"
fi
cd -- "$cwd" || exit 122
exec setpriv --reuid "$uid" --regid "$gid" --clear-groups --no-new-privs -- "$@"`;

const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const populated = dir => { try { return /populated 1/.test(fs.readFileSync(dir + '/cgroup.events', 'utf8')); } catch { return false; } };
const members = dir => { try { return fs.readFileSync(dir + '/cgroup.procs', 'utf8').split('\n').filter(Boolean).length; } catch { return 0; } };
async function drain(dir, ms = 5000) {
  try { fs.writeFileSync(dir + '/cgroup.kill', '1'); } catch {}
  const deadline = Date.now() + ms;
  while (populated(dir) && Date.now() < deadline) await sleep(20);
  return !populated(dir);
}
function publish(entries = []) {
  for (const entry of entries) fs.appendFileSync(published + '/changes.jsonl', JSON.stringify(entry) + '\n');
  fs.writeFileSync(published + '/.generation-tmp', JSON.stringify({generation}));
  fs.renameSync(published + '/.generation-tmp', published + '/generation');
}
// References from outside the lease to a mount that is not in the global namespace can only
// come from a leased namespace (via /proc magic links or fd passing): they outlive the lease.
function mountId(path) {
  let fd;
  try { fd = fs.openSync(path, fs.constants.O_RDONLY | fs.constants.O_NONBLOCK); }
  catch { return null; }
  try { return fs.readFileSync('/proc/self/fdinfo/' + fd, 'utf8').match(/^mnt_id:\s*(\d+)/m)?.[1] ?? null; }
  finally { fs.closeSync(fd); }
}
function leaks() {
  const global = new Set(fs.readFileSync('/proc/self/mountinfo', 'utf8').split('\n').filter(Boolean).map(x => x.split(' ')[0]));
  const found = [];
  for (const pid of fs.readdirSync('/proc').filter(x => /^\d+$/.test(x) && Number(x) !== process.pid)) {
    const base = '/proc/' + pid;
    const foreign = (path, id) => {
      try { if (fs.statSync(path).dev !== shareDevice) return false; } catch { return false; }
      id ??= mountId(path);
      return id !== null && !global.has(id);
    };
    try {
      for (const name of ['cwd', 'root']) if (foreign(base + '/' + name)) found.push({pid: Number(pid), kind: name});
      for (const fd of fs.readdirSync(base + '/fd')) {
        const id = fs.readFileSync(base + '/fdinfo/' + fd, 'utf8').match(/^mnt_id:\s*(\d+)/m)?.[1];
        if (foreign(base + '/fd/' + fd, id)) found.push({pid: Number(pid), kind: 'fd'});
      }
      for (const line of fs.readFileSync(base + '/maps', 'utf8').split('\n')) {
        const field = line.split(/\s+/);
        if (field[3] === mapsDevice && foreign(base + '/map_files/' + field[0])) found.push({pid: Number(pid), kind: 'map'});
      }
    } catch {}
  }
  return found;
}
async function sweep() {
  const found = leaks();
  for (const pid of new Set(found.map(x => x.pid))) try { process.kill(pid, 'SIGKILL'); } catch {}
  const deadline = Date.now() + 5000;
  while (found.length && leaks().length && Date.now() < deadline) await sleep(20);
  return {leaked: found, clean: leaks().length === 0};
}
fs.mkdirSync(groups, {recursive: true});
fs.mkdirSync(published, {recursive: true, mode: 0o755});
publish();

function execute(request) {
  const lease = request.lease ?? null;
  const signature = JSON.stringify({projectId: request.projectId, argv: request.argv,
    cwd: request.cwd, timeoutMs: request.timeoutMs, lease, asOwner: request.asOwner, skipSweep: request.testSkipSweep});
  if (operations.has(request.id)) {
    const previous = operations.get(request.id);
    if (previous.signature !== signature) throw new Error('OPERATION_ID_CONFLICT');
    return previous.promise;
  }
  if (request.projectId !== identity) throw new Error('PROJECT_ID_MISMATCH');
  if (lease) {
    if (epoch === null) throw new Error('EPOCH_UNBOUND');
    if (lease.epoch !== epoch) throw new Error('LEASE_EPOCH_MISMATCH');
    if (activeLease) throw new Error('LEASE_BUSY');
    if (!Number.isInteger(lease.fence) || lease.fence <= lastFence) throw new Error('LEASE_STALE');
  }
  if (!Array.isArray(request.argv) || !allowed.has(request.argv[0]) ||
      !request.argv.every(x => typeof x === 'string') || request.argv.length > 100)
    throw new Error('ARGV_REFUSED');
  const cwd = fs.realpathSync(request.cwd ?? root);
  if (cwd !== root && !cwd.startsWith(root + '/')) throw new Error('CWD_REFUSED');
  const group = groups + '/op-' + request.id.replace(/[^A-Za-z0-9_-]/g, '_');
  fs.mkdirSync(group);
  if (lease) { lastFence = lease.fence; activeLease = {fence: lease.fence, id: request.id}; }
  // PROTOTYPE: asOwner reproduces the vulnerable same-uid configuration for unleased commands.
  const user = lease || request.asOwner === true ? owner : reader;
  const operation = {id: request.id, signature, group, cancelled: false, lease};
  operations.set(request.id, operation);
  operation.promise = new Promise(resolve => {
    let stdout = '', stderr = '', timeout = false;
    const child = cp.spawn('/bin/sh', ['-c', WRAPPER, 'plan500', group, lease ? '1' : '0',
      String(user.uid), String(user.gid), cwd, ...request.argv], {
      cwd: '/', detached: true, env: {PATH: '/opt/node/bin:/usr/bin:/bin', HOME: '/tmp', LANG: 'C.UTF-8'},
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    const closed = new Promise(done => child.on('close', done));
    child.stdout.on('data', data => { stdout = (stdout + data).slice(-65536); });
    child.stderr.on('data', data => { stderr = (stderr + data).slice(-65536); });
    child.on('error', error => { stderr += String(error); });
    const timer = setTimeout(() => { timeout = true; drain(group); },
      Math.max(10, Math.min(request.timeoutMs ?? 10000, 15000)));
    child.on('exit', (code, signal) => (async () => {
      clearTimeout(timer);
      let stragglers = 0, quiescent = null, leaked = [];
      if (lease) {
        // The main process exiting does not end the write capability: every member must be gone.
        const grace = Date.now() + 300;
        while (populated(group) && Date.now() < grace) await sleep(20);
        if (populated(group)) { stragglers = members(group); quiescent = await drain(group); }
        else quiescent = true;
        // PROTOTYPE negative control: testSkipSweep shows what outlives the lease without the sweep.
        if (quiescent && request.testSkipSweep !== true) { const swept = await sweep(); leaked = swept.leaked; quiescent = swept.clean; }
        if (quiescent) { activeLease = null; try { fs.rmdirSync(group); } catch {} }
      }
      await Promise.race([closed, sleep(1000)]);
      child.stdout.destroy(); child.stderr.destroy();
      operation.result = {id: request.id, projectId: identity, code, signal, stdout, stderr,
        cancelled: operation.cancelled, timeout, lease, stragglersKilled: stragglers, leakedKilled: leaked,
        writerQuiescent: quiescent};
      resolve(operation.result);
    })().catch(error => resolve({id: request.id, error: String(error), lease, writerQuiescent: false})));
  });
  return operation.promise;
}

function revoke(input) {
  if (epoch === null || input.epoch !== epoch) throw new Error('LEASE_EPOCH_MISMATCH');
  if (activeLease && activeLease.fence === input.fence)
    return {revoked: false, running: true, populated: populated(operations.get(activeLease.id).group)};
  // Any request still in flight with this fence is refused from now on.
  lastFence = Math.max(lastFence, input.fence);
  const operation = [...operations.values()].find(x => x.lease && x.lease.fence === input.fence);
  return {revoked: true, lastFence, started: Boolean(operation), result: operation?.result ?? null};
}

function sever(ms) {
  server.close(() => setTimeout(() => server.listen(4500, '0.0.0.0'), ms));
  for (const socket of sockets) socket.destroy();
}

const server = http.createServer(async (request, response) => {
  const reply = (status, value, then) => {
    response.writeHead(status, {'content-type': 'application/json'});
    response.end(JSON.stringify(value), then);
  };
  if (request.headers.authorization !== 'Bearer ' + token) return reply(403, {error: 'AUTH_REFUSED'});
  try {
    if (request.url === '/ready') {
      const mount = fs.readFileSync('/proc/mounts', 'utf8').split('\n').map(x => x.split(' ')).find(x => x[1] === root);
      if (!mount || mount[2] !== '9p') throw new Error('WORKSPACE_NOT_9P');
      let userNamespaces = null;
      try { userNamespaces = Number(fs.readFileSync('/proc/sys/user/max_user_namespaces', 'utf8')); } catch {}
      return reply(200, {protocol: 1, projectId: identity, mount: '9p', node: process.version,
        git: cp.execFileSync('/usr/bin/git', ['--version'], {encoding: 'utf8'}).trim(),
        workspaceReadOnly: mount[3].split(',').includes('ro'), cgroupKill: fs.existsSync(groups + '/cgroup.kill'),
        commandUid: owner.uid, commandGid: owner.gid, readerUid: reader.uid, userNamespaces, epoch, lastFence, generation,
        mountOptions: mount[3]});
    }
    let body = '';
    for await (const chunk of request) { body += chunk; if (body.length > 131072) throw new Error('BODY_TOO_LARGE'); }
    const input = JSON.parse(body);
    if (request.url === '/bind') {
      if (!Number.isInteger(input.epoch)) throw new Error('EPOCH_REFUSED');
      if (epoch !== null && epoch !== input.epoch) throw new Error('EPOCH_CONFLICT');
      epoch = input.epoch;
      return reply(200, {epoch, lastFence, generation});
    }
    if (request.url === '/notify') {
      const fresh = (input.entries ?? []).filter(x => Number.isInteger(x.generation) && x.generation > generation)
        .sort((a, b) => a.generation - b.generation);
      if (fresh.length) { generation = fresh.at(-1).generation; publish(fresh); }
      return reply(200, {generation});
    }
    if (request.url === '/revoke') return reply(200, revoke(input));
    if (request.url === '/test/sever') {
      // PROTOTYPE fault injection: drop every RPC connection while commands keep running.
      return reply(200, {severing: input.ms}, () => sever(Math.min(Math.max(input.ms, 10), 5000)));
    }
    if (typeof input.id !== 'string' || input.id.length > 100) throw new Error('ID_REFUSED');
    if (request.url === '/execute') return reply(200, await execute(input));
    if (request.url === '/cancel') {
      const operation = operations.get(input.id);
      if (!operation) throw new Error('OPERATION_NOT_FOUND');
      operation.cancelled = true; drain(operation.group); return reply(200, {cancelled: true});
    }
    reply(404, {error: 'ROUTE_REFUSED'});
  } catch (error) { reply(409, {error: String(error.message)}); }
});
server.on('connection', socket => { sockets.add(socket); socket.on('close', () => sockets.delete(socket)); });
server.listen(4500, '0.0.0.0', () => console.log('PLAN500_RPC_READY'));
