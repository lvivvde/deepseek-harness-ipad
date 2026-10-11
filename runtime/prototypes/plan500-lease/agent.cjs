// PROTOTYPE: trusted synthetic requests only; not a tool sandbox.
// Write capability exists only inside a leased command's private mount namespace;
// writer liveness is the command's cgroup plus any outside reference to that namespace's mount.
// Unleased commands run as a separate reader uid so they cannot open /proc/<leased>/cwd.
// An interactive terminal keeps its own mount namespace, read-only until a lease remounts it rw;
// the lease ends only once the shell is back at an idle prompt and the view is remounted ro.
const http = require('node:http');
const fs = require('node:fs');
const cp = require('node:child_process');
const crypto = require('node:crypto');
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
// Per-request secrets that reach only the command's environment: never echoed, logged or kept.
const secretNames = new Set(['DSH_GIT_TOKEN']);
// Commands stop at this length; the native transport waits longer than this.
const maxTimeoutMs = 60000;
const sockets = new Set();
let epoch = null, lastFence = 0, activeLease = null, generation = 0;
const terminals = new Map();
const terminalRoot = '/run/plan500-term';
const shells = new Set(['/bin/bash', '/bin/sh']);
const terminalSignals = new Set(['SIGINT', 'SIGTERM', 'SIGKILL', 'SIGTSTP', 'SIGHUP']);
const maxTerminals = 16, maxTerminalBuffer = 1 << 20, maxTerminalRead = 65536, maxTerminalWrite = 49152;
// Fences a terminal has already given back, so a retried unlease or close is idempotent.
const releasedFences = new Set();

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
// A terminal starts in a private namespace that inherits the read-only workspace view.
const TERMINAL_WRAPPER = `cg=$1; uid=$2; gid=$3; cwd=$4; command=$5
echo $$ > "$cg/cgroup.procs" || exit 120
exec unshare -m --propagation private -- /bin/sh -c 'cd -- "$3" || exit 122
  exec setpriv --reuid "$1" --regid "$2" --clear-groups --no-new-privs -- script -q -e -E always -c "$4" /dev/null' plan500 "$uid" "$gid" "$cwd" "$command"`;
// A model command joined to a leased terminal runs in that terminal's (rw) namespace.
const JOINED_WRAPPER = `cg=$1; pid=$2; uid=$3; gid=$4; cwd=$5; shift 5
echo $$ > "$cg/cgroup.procs" || exit 120
exec nsenter -t "$pid" -m -r -- /bin/sh -c 'cd -- "$3" || exit 122; uid=$1; gid=$2; shift 3
  exec setpriv --reuid "$uid" --regid "$gid" --clear-groups --no-new-privs -- "$@"' plan500 "$uid" "$gid" "$cwd" "$@"`;

const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const populated = dir => { try { return /populated 1/.test(fs.readFileSync(dir + '/cgroup.events', 'utf8')); } catch { return false; } };
const pids = dir => { try { return fs.readFileSync(dir + '/cgroup.procs', 'utf8').split('\n').filter(Boolean).map(Number); } catch { return []; } };
const members = dir => pids(dir).length;
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
// A live terminal's namespace is not a leak: its write capability ends by remounting it ro.
function terminalMounts() {
  const ids = [];
  for (const terminal of terminals.values()) if (!terminal.exit)
    try { ids.push(...fs.readFileSync('/proc/' + terminal.child.pid + '/mountinfo', 'utf8').split('\n').filter(Boolean).map(x => x.split(' ')[0])); } catch {}
  return ids;
}
function leaks() {
  const global = new Set(fs.readFileSync('/proc/self/mountinfo', 'utf8').split('\n').filter(Boolean).map(x => x.split(' ')[0]));
  for (const id of terminalMounts()) global.add(id);
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

function secretsOf(request) {
  const given = request.secretEnv ?? {};
  if (typeof given !== 'object' || given === null || Array.isArray(given)) throw new Error('SECRET_REFUSED');
  for (const [name, value] of Object.entries(given))
    if (!secretNames.has(name) || typeof value !== 'string' || !/^[\x21-\x7e]{1,512}$/.test(value)) throw new Error('SECRET_REFUSED');
  return given;
}

function execute(request) {
  const lease = request.lease ?? null;
  const secrets = secretsOf(request);
  // A retry must carry the same secrets; only their digest is kept.
  const secret = crypto.createHash('sha256').update(JSON.stringify(Object.entries(secrets).sort())).digest('hex');
  const join = request.join ?? null;
  const signature = JSON.stringify({projectId: request.projectId, argv: request.argv,
    cwd: request.cwd, timeoutMs: request.timeoutMs, lease, asOwner: request.asOwner, skipSweep: request.testSkipSweep, secret, join});
  if (operations.has(request.id)) {
    const previous = operations.get(request.id);
    if (previous.signature !== signature) throw new Error('OPERATION_ID_CONFLICT');
    return previous.promise;
  }
  if (request.projectId !== identity) throw new Error('PROJECT_ID_MISMATCH');
  const terminal = join === null ? null : terminals.get(join);
  if (join !== null) {
    // Joining shares the running terminal's lease instead of taking a new one.
    if (!lease || epoch === null || lease.epoch !== epoch) throw new Error('LEASE_EPOCH_MISMATCH');
    if (!terminal || terminal.exit) throw new Error('TERMINAL_NOT_FOUND');
    if (activeLease?.terminal !== join || activeLease.fence !== lease.fence) throw new Error('LEASE_STALE');
  } else if (lease) {
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
  if (lease && !terminal) { lastFence = lease.fence; activeLease = {fence: lease.fence, id: request.id}; }
  // PROTOTYPE: asOwner reproduces the vulnerable same-uid configuration for unleased commands.
  const user = lease || request.asOwner === true ? owner : reader;
  const operation = {id: request.id, signature, group, cancelled: false, lease, join};
  operations.set(request.id, operation);
  operation.promise = new Promise(resolve => {
    let stdout = '', stderr = '', timeout = false;
    const argv = terminal
      ? ['-c', JOINED_WRAPPER, 'plan500', group, String(terminal.child.pid), String(user.uid), String(user.gid), cwd, ...request.argv]
      : ['-c', WRAPPER, 'plan500', group, lease ? '1' : '0', String(user.uid), String(user.gid), cwd, ...request.argv];
    const child = cp.spawn('/bin/sh', argv, {
      cwd: '/', detached: true, env: {PATH: '/opt/node/bin:/usr/bin:/bin', HOME: '/tmp', LANG: 'C.UTF-8', ...secrets},
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    const closed = new Promise(done => child.on('close', done));
    child.stdout.on('data', data => { stdout = (stdout + data).slice(-65536); });
    child.stderr.on('data', data => { stderr = (stderr + data).slice(-65536); });
    child.on('error', error => { stderr += String(error); });
    const timer = setTimeout(() => { timeout = true; drain(group); },
      Math.max(10, Math.min(request.timeoutMs ?? 10000, maxTimeoutMs)));
    child.on('exit', (code, signal) => (async () => {
      clearTimeout(timer);
      let stragglers = 0, quiescent = null, leaked = [];
      if (lease) {
        // The main process exiting does not end the write capability: every member must be gone.
        const grace = Date.now() + 300;
        while (populated(group) && Date.now() < grace) await sleep(20);
        if (populated(group)) { stragglers = members(group); quiescent = await drain(group); }
        else quiescent = true;
        // A joined command's view stays with the terminal, which still holds the lease.
        if (terminal) { try { fs.rmdirSync(group); } catch {} }
        else {
        // PROTOTYPE negative control: testSkipSweep shows what outlives the lease without the sweep.
        if (quiescent && request.testSkipSweep !== true) { const swept = await sweep(); leaked = swept.leaked; quiescent = swept.clean; }
        if (quiescent) { activeLease = null; try { fs.rmdirSync(group); } catch {} }
        }
      }
      await Promise.race([closed, sleep(1000)]);
      child.stdout.destroy(); child.stderr.destroy();
      operation.result = {id: request.id, projectId: identity, code, signal, stdout, stderr,
        cancelled: operation.cancelled, timeout, lease, stragglersKilled: stragglers, leakedKilled: leaked,
        writerQuiescent: quiescent, joined: Boolean(terminal)};
      resolve(operation.result);
    })().catch(error => resolve({id: request.id, error: String(error), lease, writerQuiescent: false})));
  });
  return operation.promise;
}

async function revoke(input) {
  if (epoch === null || input.epoch !== epoch) throw new Error('LEASE_EPOCH_MISMATCH');
  // A terminal lease is revoked by ending the terminal: the native side no longer knows its writer.
  if (activeLease?.terminal !== undefined && activeLease.fence === input.fence) {
    const terminal = terminals.get(activeLease.terminal);
    if (terminal) await closeTerminal(terminal, 0); else activeLease = null;
    if (activeLease?.fence === input.fence) return {revoked: false, running: true, populated: true};
  }
  if (activeLease && activeLease.fence === input.fence)
    return {revoked: false, running: true, populated: populated(operations.get(activeLease.id).group)};
  // Any request still in flight with this fence is refused from now on.
  lastFence = Math.max(lastFence, input.fence);
  const operation = [...operations.values()].find(x => x.lease && x.lease.fence === input.fence && !x.join);
  return {revoked: true, lastFence, started: Boolean(operation) || releasedFences.has(input.fence), result: operation?.result ?? null};
}

// Interactive terminals: a pty from util-linux script, read by long-poll over absolute byte offsets.
const quote = value => "'" + value.replace(/'/g, "'\\''") + "'";
const bounded = (value, low, high, fallback) => value === undefined ? fallback
  : Number.isInteger(value) && value >= low && value <= high ? value : (() => { throw new Error('SIZE_REFUSED'); })();
function stat(pid) {
  try {
    const text = fs.readFileSync('/proc/' + pid + '/stat', 'utf8');
    const rest = text.slice(text.lastIndexOf(')') + 2).split(' ');
    return {state: rest[0], ppid: Number(rest[1]), pgrp: Number(rest[2]), tty: Number(rest[4]), tpgid: Number(rest[5])};
  } catch { return null; }
}
function terminalOf(input) {
  const terminal = terminals.get(input.id);
  if (!terminal) throw new Error('TERMINAL_NOT_FOUND');
  return terminal;
}
function wake(terminal) { for (const waiter of terminal.waiters.splice(0)) waiter(); }
// Bash reports its prompt transitions as pid:sequence:state, as the official shell integration does.
const BASH_RC = (state, guards) => [
  "PS1='\\w\\$ '",
  '[[ ! -r ~/.bashrc ]] || builtin source ~/.bashrc',
  '__dsh_shell_pid=$BASHPID; __dsh_shell_sequence=0',
  '__dsh_shell_idle() {',
  '  local result=$?',
  '  if [[ $BASHPID == "$__dsh_shell_pid" ]]; then',
  '    (( ++__dsh_shell_sequence ))',
  '    local activity=idle',
  `    builtin trap -p >| ${guards}`,
  `    [[ ! -s ${guards} ]] || activity=unknown`,
  `    builtin printf '%s:%s:%s\\n' "$BASHPID" "$__dsh_shell_sequence" "$activity" >| ${state}`,
  '  fi',
  '  return "$result"',
  '}',
  'if [[ $(declare -p PROMPT_COMMAND 2>/dev/null) == "declare -a "* ]]; then',
  '  PROMPT_COMMAND+=(__dsh_shell_idle)',
  'else',
  `  PROMPT_COMMAND="\${PROMPT_COMMAND}"$'\\n'"__dsh_shell_idle"`,
  'fi',
  `PS0+=${quote(`$(builtin printf '%s:%s:busy' "$__dsh_shell_pid" "$__dsh_shell_sequence" >| ${state})`)}`,
  ''].join('\n');
function shellState(terminal) {
  if (!terminal.directory) return 'unknown';
  let record = '';
  try { record = fs.readFileSync(terminal.directory + '/state', 'utf8'); } catch {}
  if (record !== terminal.observed) { terminal.observed = record; terminal.shellRevision++; }
  const match = /^(\d+):(\d+):(idle|busy)\n?$/.exec(record);
  return record === terminal.invalidated || match?.[1] !== String(terminal.shellPid) ? 'unknown' : match[3];
}
function invalidate(terminal) {
  if (!terminal.directory) return;
  try { terminal.invalidated = fs.readFileSync(terminal.directory + '/state', 'utf8'); } catch { terminal.invalidated = ''; }
  terminal.shellRevision++;
}
function activity(terminal) {
  let state = 'unknown';
  if (terminal.exit) state = populated(terminal.group) ? 'busy' : 'idle';
  else {
    const others = pids(terminal.group).filter(pid => pid !== terminal.child.pid && pid !== terminal.shellPid);
    const tpgid = stat(terminal.shellPid)?.tpgid;
    const shell = shellState(terminal);
    if (others.length) state = 'busy';
    else if (tpgid > 0) state = tpgid === terminal.shellPid ? shell : 'busy';
  }
  const key = terminal.shellRevision + ':' + state;
  if (key !== terminal.activityKey) { terminal.activityKey = key; terminal.activityRevision++; }
  return {state, revision: terminal.activityRevision};
}
const joinedRunning = fence => [...operations.values()].some(x => x.join && x.lease?.fence === fence && !x.result);
function leaseOf(terminal) {
  return activeLease?.terminal === terminal.id ? activeLease : null;
}
function releasable(terminal) {
  const lease = leaseOf(terminal);
  if (!lease || joinedRunning(lease.fence)) return false;
  if (terminal.exit) return true;
  const current = activity(terminal);
  return current.state === 'idle' && current.revision !== terminal.refusedRevision;
}
function summary(terminal) {
  return {activity: activity(terminal), leased: Boolean(leaseOf(terminal)), releasable: releasable(terminal)};
}
function remount(terminal, mode) {
  return new Promise(resolve => cp.execFile('nsenter', ['-t', String(terminal.child.pid), '-m', '-r', '--',
    'mount', '-o', 'remount,bind,' + mode + ',nosuid,nodev', root],
  {timeout: 5000, env: {PATH: '/usr/bin:/bin:/usr/sbin:/sbin'}}, error => resolve(!error)));
}
function terminalDevice(pid) {
  // Seen from the agent's chroot, a link in the terminal's namespace carries the namespace root (/rootfs).
  try { const number = /(?:^|\/)dev\/pts\/(\d+)$/.exec(fs.readlinkSync('/proc/' + pid + '/fd/0'))?.[1]; return number ? '/dev/pts/' + number : null; }
  catch { return null; }
}
// Whether any thread of the foreground group is blocked reading the terminal (arm64 syscall numbers).
function inputWaiting(terminal, pgid) {
  if (process.arch !== 'arm64') return false;
  const device = terminalDevice(terminal.shellPid);
  if (!device) return false;
  const memory = (pid, address, length) => {
    let fd;
    try { fd = fs.openSync('/proc/' + pid + '/mem', 'r'); const buffer = Buffer.alloc(length);
      return buffer.subarray(0, fs.readSync(fd, buffer, 0, length, address)); }
    catch { return Buffer.alloc(0); } finally { if (fd !== undefined) fs.closeSync(fd); }
  };
  for (const pid of fs.readdirSync('/proc').filter(x => /^\d+$/.test(x)).map(Number)) {
    if (stat(pid)?.pgrp !== pgid || terminalDevice(pid) !== device) continue;
    let tids = [];
    try { tids = fs.readdirSync('/proc/' + pid + '/task'); } catch {}
    for (const tid of tids) {
      let fields;
      try { fields = fs.readFileSync('/proc/' + pid + '/task/' + tid + '/syscall', 'utf8').trim().split(/\s+/); } catch { continue; }
      if (fields[0] === 'running' || fields[0] === '-1') continue;
      const number = Number(fields[0]), args = fields.slice(1, 7).map(x => Number.parseInt(x, 16));
      if ((number === 63 || number === 65) && args[0] === 0) return true;
      if (number === 72 && args[1] !== 0 && (memory(pid, args[1], 8)[0] ?? 0) % 2 === 1) return true;
      if (number === 73) {
        const fds = memory(pid, args[0], Math.min(args[1], 1024) * 8);
        for (let at = 0; at + 8 <= fds.length; at += 8) if (fds.readInt32LE(at) === 0 && (fds.readInt16LE(at + 4) & 1)) return true;
      }
      if (number === 22 || number === 441) try {
        if (fs.readFileSync('/proc/' + pid + '/task/' + tid + '/fdinfo/' + args[0], 'utf8').split('\n').some(x => /^tfd:\s+0\b/.test(x.trim()))) return true;
      } catch {}
    }
  }
  return false;
}

async function openTerminal(input) {
  const signature = JSON.stringify([input.projectId, input.argv, input.cwd, input.cols, input.rows, input.env, input.terminalType, input.shellActivity]);
  const previous = terminals.get(input.id);
  if (previous) { if (previous.signature !== signature) throw new Error('OPERATION_ID_CONFLICT'); return previous.opened; }
  if (input.projectId !== identity) throw new Error('PROJECT_ID_MISMATCH');
  if (terminals.size >= maxTerminals) throw new Error('TERMINAL_LIMIT');
  const argv = input.argv;
  if (!Array.isArray(argv) || !shells.has(argv[0]) || !argv.every(x => typeof x === 'string' && !x.includes('\0')) || argv.length > 32)
    throw new Error('ARGV_REFUSED');
  const cwd = fs.realpathSync(input.cwd ?? root);
  if (cwd !== root && !cwd.startsWith(root + '/')) throw new Error('CWD_REFUSED');
  const cols = bounded(input.cols, 1, 1000, 80), rows = bounded(input.rows, 1, 1000, 24);
  const type = input.terminalType ?? 'xterm-256color';
  if (typeof type !== 'string' || !/^[A-Za-z0-9._+-]{1,64}$/.test(type)) throw new Error('TERMINAL_TYPE_REFUSED');
  const extra = input.env ?? {};
  if (typeof extra !== 'object' || extra === null || Array.isArray(extra) ||
      !Object.entries(extra).every(([name, value]) => /^DSH_[A-Z0-9_]{1,64}$/.test(name) && typeof value === 'string' && value.length <= 4096 && !value.includes('\0')))
    throw new Error('ENV_REFUSED');
  const safe = input.id.replace(/[^A-Za-z0-9_-]/g, '_');
  const tracked = input.shellActivity === true && argv.length === 2 && argv[1] === '-i' && argv[0] === '/bin/bash';
  let directory = null, command;
  if (tracked) {
    fs.mkdirSync(terminalRoot, {recursive: true, mode: 0o711});
    directory = terminalRoot + '/' + safe;
    fs.mkdirSync(directory, {mode: 0o700});
    fs.chownSync(directory, owner.uid, owner.gid);
    fs.writeFileSync(directory + '/bashrc', BASH_RC(quote(directory + '/state'), quote(directory + '/guards')), {mode: 0o600, flag: 'wx'});
    fs.chownSync(directory + '/bashrc', owner.uid, owner.gid);
    command = '/bin/bash --rcfile ' + quote(directory + '/bashrc') + ' -i';
  } else command = argv.map(quote).join(' ');
  command = `stty rows ${rows} cols ${cols} 2>/dev/null; exec ${command}`;
  const group = groups + '/term-' + safe;
  fs.mkdirSync(group);
  const child = cp.spawn('/bin/sh', ['-c', TERMINAL_WRAPPER, 'plan500', group, String(owner.uid), String(owner.gid), cwd, command], {
    cwd: '/', detached: true, stdio: ['pipe', 'pipe', 'pipe'],
    env: {PATH: '/opt/node/bin:/usr/bin:/bin', HOME: '/tmp', LANG: 'C.UTF-8', TERM: type, SHELL: '/bin/bash', ...extra},
  });
  const terminal = {id: input.id, signature, child, group, directory, shellPid: null, buffer: Buffer.alloc(0), base: 0,
    closed: false, exit: null, waiters: [], shellRevision: 0, observed: '', invalidated: undefined,
    activityKey: '', activityRevision: 0, refusedRevision: -1, stderr: ''};
  terminals.set(input.id, terminal);
  child.stdin.on('error', () => {});
  child.stderr.on('data', data => { terminal.stderr = (terminal.stderr + data).slice(-4096); });
  child.stdout.on('data', data => {
    terminal.buffer = Buffer.concat([terminal.buffer, data]);
    // Backpressure reaches the pty instead of dropping output the reader has not seen.
    if (terminal.buffer.length > maxTerminalBuffer) child.stdout.pause();
    wake(terminal);
  });
  child.stdout.on('close', () => { terminal.closed = true; wake(terminal); });
  child.on('error', () => {});
  child.on('exit', (code, signal) => (async () => {
    await Promise.race([new Promise(done => child.stdout.closed ? done() : child.stdout.on('close', done)), sleep(1000)]);
    terminal.closed = true;
    await drain(group);
    terminal.exit = {code, signal};
    wake(terminal);
  })());
  const deadline = Date.now() + 5000;
  while (!terminal.shellPid && !terminal.exit && Date.now() < deadline) {
    terminal.shellPid = pids(group).find(pid => stat(pid)?.ppid === child.pid) ?? null;
    if (!terminal.shellPid) await sleep(20);
  }
  if (!terminal.shellPid) { await closeTerminal(terminal, 0); throw new Error('TERMINAL_START_FAILED'); }
  terminal.opened = {id: input.id, pid: terminal.shellPid, shellActivity: tracked};
  return terminal.opened;
}

async function writeTerminal(input) {
  const terminal = terminalOf(input);
  if (terminal.exit || terminal.closing) throw new Error('TERMINAL_EXITED');
  const data = Buffer.from(typeof input.data === 'string' ? input.data : '', 'base64');
  if (data.length > maxTerminalWrite) throw new Error('WRITE_TOO_LARGE');
  const lease = input.lease ?? null;
  if (lease && !(leaseOf(terminal)?.fence === lease.fence)) {
    if (epoch === null) throw new Error('EPOCH_UNBOUND');
    if (lease.epoch !== epoch) throw new Error('LEASE_EPOCH_MISMATCH');
    if (activeLease) throw new Error('LEASE_BUSY');
    if (!Number.isInteger(lease.fence) || lease.fence <= lastFence) throw new Error('LEASE_STALE');
    // Held before the remount, so a concurrent lease is refused; the fence is spent either way.
    lastFence = lease.fence; activeLease = {fence: lease.fence, terminal: terminal.id};
    if (!await remount(terminal, 'rw')) { activeLease = null; throw new Error('REMOUNT_FAILED'); }
  }
  invalidate(terminal);
  await new Promise(done => terminal.child.stdin.write(data, done));
  return {written: data.length, leased: Boolean(leaseOf(terminal))};
}

async function readTerminal(input) {
  const terminal = terminalOf(input);
  const offset = Number.isInteger(input.offset) && input.offset >= 0 ? input.offset : terminal.base;
  const deadline = Date.now() + bounded(input.waitMs, 0, 20000, 0);
  const end = () => terminal.base + terminal.buffer.length;
  const leased = () => Boolean(leaseOf(terminal));
  // While leased, wake every 100 ms so the native side can release as soon as the prompt is idle.
  while (offset >= end() && !(terminal.closed && terminal.exit) && Date.now() < deadline && !(leased() && releasable(terminal)))
    await new Promise(done => { const timer = setTimeout(done, leased() ? 100 : deadline - Date.now()); terminal.waiters.push(() => { clearTimeout(timer); done(); }); });
  const start = Math.min(Math.max(offset, terminal.base), end());
  // The reader has seen everything before its offset; drop it and let a paused pty continue.
  if (start > terminal.base) { terminal.buffer = terminal.buffer.subarray(start - terminal.base); terminal.base = start; }
  if (terminal.buffer.length <= maxTerminalBuffer && terminal.child.stdout.isPaused()) terminal.child.stdout.resume();
  const data = terminal.buffer.subarray(0, maxTerminalRead);
  const next = terminal.base + data.length;
  const drained = next >= end() && terminal.closed && terminal.exit;
  return {data: data.toString('base64'), offset: start, next, dropped: start - offset,
    exited: drained ? terminal.exit : null, ...summary(terminal)};
}

async function resizeTerminal(input) {
  const terminal = terminalOf(input);
  if (terminal.exit) throw new Error('TERMINAL_EXITED');
  const cols = bounded(input.cols, 1, 1000, undefined), rows = bounded(input.rows, 1, 1000, undefined);
  const device = terminalDevice(terminal.shellPid);
  if (!device || cols === undefined || rows === undefined) throw new Error('RESIZE_REFUSED');
  await new Promise((resolve, reject) => cp.execFile('stty', ['-F', device, 'rows', String(rows), 'cols', String(cols)],
    {timeout: 5000}, error => error ? reject(new Error('RESIZE_FAILED')) : resolve()));
  return {cols, rows};
}

function signalTerminal(input) {
  const terminal = terminalOf(input);
  if (terminal.exit) throw new Error('TERMINAL_EXITED');
  if (!terminalSignals.has(input.signal)) throw new Error('SIGNAL_REFUSED');
  const tpgid = stat(terminal.shellPid)?.tpgid;
  if (!(tpgid > 0)) throw new Error('FOREGROUND_UNKNOWN');
  if (input.signal === 'SIGKILL' && tpgid === terminal.shellPid) throw new Error('SHELL_KILL_REFUSED');
  invalidate(terminal);
  process.kill(-tpgid, input.signal);
  return {processGroupId: tpgid};
}

function inspectTerminal(input) {
  const terminal = terminalOf(input);
  const tpgid = terminal.exit ? 0 : stat(terminal.shellPid)?.tpgid;
  return {foreground: tpgid > 0 ? {processGroupId: tpgid, inputWaiting: inputWaiting(terminal, tpgid)} : null, ...summary(terminal)};
}

// Ends a terminal lease whose writers are all gone: the namespace is dead or remounted read-only.
async function releaseTerminalLease(terminal, fence) {
  for (const operation of operations.values()) if (operation.join === terminal.id && operation.lease?.fence === fence && !operation.result) {
    operation.cancelled = true; drain(operation.group);
  }
  await Promise.race([Promise.all([...operations.values()].filter(x => x.join === terminal.id).map(x => x.promise)), sleep(6000)]);
  const swept = terminal.exit ? await sweep() : {clean: true};
  if (!swept.clean || joinedRunning(fence)) return false;
  activeLease = null; releasedFences.add(fence);
  return true;
}

async function unleaseTerminal(input) {
  const terminal = terminals.get(input.id);
  const lease = terminal && leaseOf(terminal);
  if (!lease || lease.fence !== input.fence) {
    if (releasedFences.has(input.fence)) return {writerQuiescent: true};
    throw new Error('LEASE_STALE');
  }
  if (joinedRunning(lease.fence)) return {writerQuiescent: false, reason: 'JOINED_RUNNING'};
  if (!terminal.exit) {
    const current = activity(terminal);
    if (current.state !== 'idle') return {writerQuiescent: false, reason: 'BUSY'};
    // Remounting read-only fails while any file is open for writing through this view.
    if (!await remount(terminal, 'ro')) { terminal.refusedRevision = current.revision; return {writerQuiescent: false, reason: 'WRITERS_OPEN'}; }
  }
  return {writerQuiescent: await releaseTerminalLease(terminal, lease.fence)};
}

async function closeTerminal(terminal, graceMs) {
  terminal.closing = true;
  if (!terminal.exit) {
    for (const pid of [terminal.shellPid, stat(terminal.shellPid)?.tpgid]) if (pid > 0) try { process.kill(-pid, 'SIGHUP'); } catch {}
    try { terminal.child.stdin.end(); } catch {}
    const deadline = Date.now() + graceMs;
    while (!terminal.exit && Date.now() < deadline) await sleep(20);
  }
  await drain(terminal.group);
  const deadline = Date.now() + 2000;
  while (!terminal.exit && Date.now() < deadline) await sleep(20);
  // A shell that outlives the hang-up still writes through its view: nothing may be released.
  if (!terminal.exit) { terminal.closing = false; return {closed: false, releasedFence: null}; }
  const lease = leaseOf(terminal);
  const released = lease ? await releaseTerminalLease(terminal, lease.fence) : null;
  if (lease && !released) return {closed: false, releasedFence: null};
  terminals.delete(terminal.id);
  try { fs.rmdirSync(terminal.group); } catch {}
  if (terminal.directory) fs.rmSync(terminal.directory, {recursive: true, force: true});
  wake(terminal);
  return {closed: true, releasedFence: lease ? lease.fence : null};
}

const terminalRoutes = {
  open: openTerminal,
  write: writeTerminal,
  read: readTerminal,
  resize: resizeTerminal,
  signal: signalTerminal,
  inspect: inspectTerminal,
  unlease: unleaseTerminal,
  // A repeated close whose first answer was lost still reports the fence that close released.
  close: input => terminals.has(input.id) ? closeTerminal(terminalOf(input), bounded(input.graceMs, 0, 5000, 1000))
    : {closed: true, releasedFence: releasedFences.has(input.fence) ? input.fence : null},
};

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
        terminal: fs.existsSync('/dev/pts/ptmx'),
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
    if (request.url === '/revoke') return reply(200, await revoke(input));
    if (request.url === '/test/sever') {
      // PROTOTYPE fault injection: drop every RPC connection while commands keep running.
      return reply(200, {severing: input.ms}, () => sever(Math.min(Math.max(input.ms, 10), 5000)));
    }
    if (typeof input.id !== 'string' || input.id.length > 100) throw new Error('ID_REFUSED');
    if (request.url === '/execute') return reply(200, await execute(input));
    if (request.url.startsWith('/terminal/')) {
      const route = terminalRoutes[request.url.slice('/terminal/'.length)];
      if (route) return reply(200, await route(input));
    }
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
