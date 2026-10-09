// #39 gate 5: Linux-path Git transactions and the hook executor, run against the host's git and
// the official dsh-hook-protocol runHook. The same file runs on macOS and in a Linux VM.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {spawn, spawnSync} from 'node:child_process';
import {createContext, runInContext} from 'node:vm';
import {test, after} from 'node:test';

const here = new URL('.', import.meta.url).pathname;
const context = createContext({crypto: globalThis.crypto});
for (const name of ['git-write.js', 'hook-shell.js'])
  runInContext(fs.readFileSync(join(here, 'web', name), 'utf8'), context, {filename: name});
const {DshGitWrite, DshHookShell} = context;

const protocolPath = process.env.DSH_HOOK_PROTOCOL ?? join(here, '../../../build/prototypes/plan500-worker/harness-dependencies/node_modules/@deepseek-ai/dsh-hook-protocol/lib/index.js');
const protocol = fs.existsSync(protocolPath) ? await import(protocolPath) : null;

const root = fs.realpathSync(fs.mkdtempSync(join(tmpdir(), 'git-write-')));
after(() => fs.rmSync(root, {recursive: true, force: true}));
const home = join(root, 'home');
fs.mkdirSync(home);
// The Linux agent's fixed environment, with global and system config kept out as on the guest.
const leaseEnv = {PATH: '/usr/bin:/bin', HOME: home, LANG: 'C.UTF-8', GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: '/dev/null'};
const identity = {name: 'Gate Five', email: 'g5@example.invalid'};

let serial = 0;
function sh(cwd, ...args) {
  const out = spawnSync('git', args, {cwd, env: {...leaseEnv, GIT_AUTHOR_NAME: 't', GIT_AUTHOR_EMAIL: 't@t',
    GIT_COMMITTER_NAME: 't', GIT_COMMITTER_EMAIL: 't@t'}, encoding: 'utf8'});
  assert.equal(out.status, 0, `git ${args.join(' ')}: ${out.stderr}`);
  return out.stdout;
}
function repo() {
  const dir = join(root, `r${++serial}`);
  fs.mkdirSync(dir);
  sh(dir, 'init', '-q', '-b', 'main');
  fs.writeFileSync(join(dir, 'a.txt'), 'one\n');
  sh(dir, 'add', 'a.txt');
  sh(dir, 'commit', '-q', '-m', 'base');
  return dir;
}
function hook(dir, name, body, hooksDir = join(dir, '.git/hooks')) {
  fs.mkdirSync(hooksDir, {recursive: true});
  fs.writeFileSync(join(hooksDir, name), '#!/bin/sh\n' + body + '\n', {mode: 0o755});
}
const head = dir => sh(dir, 'rev-parse', 'HEAD').trim();

/** Runs one transaction the way the Linux agent does: /bin/sh -c in the work tree, fixed env. */
function transact(dir, argv, {secretEnv = {}, options = {}} = {}) {
  const planned = DshGitWrite.plan(argv, {identity, ...options});
  if (planned.refused) return {report: {outcome: 'blocked', reason: planned.refused}, planned};
  const out = spawnSync('/bin/sh', ['-c', planned.command], {cwd: dir, env: {...leaseEnv, ...secretEnv}, encoding: 'utf8'});
  const answer = {status: 'RELEASED', reason: 'COMPLETED', result: {code: out.status, stdout: out.stdout, stderr: out.stderr}};
  return {report: DshGitWrite.report(answer, planned.nonce), planned, out};
}

test('pre-commit failure writes no commit and names the hook', () => {
  const dir = repo(); const before = head(dir);
  hook(dir, 'pre-commit', 'echo lint failed >&2; exit 1');
  fs.writeFileSync(join(dir, 'a.txt'), 'two\n');
  const {report} = transact(dir, ['commit', '-am', 'blocked']);
  assert.equal(report.outcome, 'failed');
  assert.equal(report.blockedBy, 'pre-commit');
  assert.equal(head(dir), before);
  assert.deepEqual([...report.events], ['start git', 'start pre-commit', 'end pre-commit 1', 'end git 1']);
  assert.match(report.stderr, /lint failed/);
});

test('commit-msg failure writes no commit', () => {
  const dir = repo(); const before = head(dir);
  hook(dir, 'pre-commit', 'exit 0');
  hook(dir, 'commit-msg', 'grep -q "^JIRA-" "$1" || { echo needs ticket >&2; exit 1; }');
  fs.writeFileSync(join(dir, 'a.txt'), 'two\n');
  const {report} = transact(dir, ['commit', '-am', 'no ticket']);
  assert.equal(report.outcome, 'failed');
  assert.equal(report.blockedBy, 'commit-msg');
  assert.equal(head(dir), before);
  assert.deepEqual([...report.events], ['start git', 'start pre-commit', 'end pre-commit 0', 'start commit-msg', 'end commit-msg 1', 'end git 1']);
});

test('hooks that change the index and the message shape the commit', () => {
  const dir = repo();
  hook(dir, 'pre-commit', 'echo generated > gen.txt && git add gen.txt');
  hook(dir, 'prepare-commit-msg', 'printf "prepared\\n\\n" | cat - "$1" > "$1.tmp" && mv "$1.tmp" "$1"');
  hook(dir, 'commit-msg', 'printf "\\nSigned-off-by: Hook <h@h>\\n" >> "$1"');
  hook(dir, 'post-commit', 'exit 0');
  fs.writeFileSync(join(dir, 'a.txt'), 'two\n');
  const {report} = transact(dir, ['commit', '-am', 'feature']);
  assert.equal(report.outcome, 'completed');
  assert.deepEqual([...report.postHookFailures], []);
  assert.deepEqual(sh(dir, 'show', '--name-only', '--format=', 'HEAD').trim().split('\n').sort(), ['a.txt', 'gen.txt']);
  const message = sh(dir, 'log', '-1', '--format=%B');
  assert.match(message, /^prepared\n\nfeature\n/);
  assert.match(message, /Signed-off-by: Hook <h@h>/);
  assert.equal(sh(dir, 'log', '-1', '--format=%an <%ae>').trim(), 'Gate Five <g5@example.invalid>');
  assert.deepEqual([...report.events], ['start git', 'start pre-commit', 'end pre-commit 0', 'start prepare-commit-msg',
    'end prepare-commit-msg 0', 'start commit-msg', 'end commit-msg 0', 'start post-commit', 'end post-commit 0', 'end git 0']);
});

test('post-commit failure keeps the commit and is reported', () => {
  const dir = repo(); const before = head(dir);
  hook(dir, 'post-commit', 'echo notify failed >&2; exit 3');
  fs.writeFileSync(join(dir, 'a.txt'), 'two\n');
  const {report} = transact(dir, ['commit', '-am', 'kept']);
  assert.equal(report.outcome, 'completed');
  assert.notEqual(head(dir), before);
  assert.deepEqual(JSON.parse(JSON.stringify(report.postHookFailures)), [{name: 'post-commit', code: 3}]);
});

test('core.hooksPath is respected, including a relative one', () => {
  const dir = repo(); const before = head(dir);
  sh(dir, 'config', 'core.hooksPath', '.githooks');
  hook(dir, 'pre-commit', 'exit 7', join(dir, '.githooks'));
  hook(dir, 'pre-commit', 'exit 0');  // the default directory is not used once hooksPath is set
  fs.writeFileSync(join(dir, 'a.txt'), 'two\n');
  const {report} = transact(dir, ['commit', '-am', 'x']);
  assert.equal(report.blockedBy, 'pre-commit');
  assert.ok(report.events.includes('end pre-commit 7'));
  assert.equal(head(dir), before);
});

test('non-executable hooks stay inert, as git leaves them', () => {
  const dir = repo();
  fs.writeFileSync(join(dir, '.git/hooks/pre-commit'), '#!/bin/sh\nexit 1\n', {mode: 0o644});
  fs.writeFileSync(join(dir, 'a.txt'), 'two\n');
  const {report} = transact(dir, ['commit', '-am', 'x']);
  assert.equal(report.outcome, 'completed');
  assert.deepEqual([...report.events], ['start git', 'end git 0']);
});

function bare() {
  const dir = join(root, `remote${++serial}.git`);
  spawnSync('git', ['init', '-q', '--bare', '-b', 'main', dir], {env: leaseEnv});
  return dir;
}

test('pre-push failure leaves the remote unchanged; success updates it', () => {
  const dir = repo(); const remote = bare();
  sh(dir, 'remote', 'add', 'origin', remote);
  sh(dir, 'push', '-q', 'origin', 'main');
  fs.writeFileSync(join(dir, 'a.txt'), 'two\n');
  sh(dir, 'commit', '-qam', 'local');
  const remoteBefore = sh(remote, 'rev-parse', 'main').trim();
  hook(dir, 'pre-push', 'while read local_ref local_oid remote_ref remote_oid; do echo "$remote_ref" >> "$GIT_DIR/../pushed-refs"; done; exit 1');
  const blocked = transact(dir, ['push', 'origin', 'main']).report;
  assert.equal(blocked.outcome, 'failed');
  assert.equal(blocked.blockedBy, 'pre-push');
  assert.equal(sh(remote, 'rev-parse', 'main').trim(), remoteBefore);
  assert.deepEqual([...blocked.events], ['start git', 'start pre-push', 'end pre-push 1', 'end git 1']);
  hook(dir, 'pre-push', 'cat > /dev/null; exit 0');
  const pushed = transact(dir, ['push', 'origin', 'main']).report;
  assert.equal(pushed.outcome, 'completed');
  assert.equal(sh(remote, 'rev-parse', 'main').trim(), head(dir));
});

test('hook bypass and credentials in URLs are refused before dispatch', () => {
  for (const argv of [['commit', '--no-verify', '-m', 'x'], ['commit', '-n', '-m', 'x'], ['commit', '-anm', 'x'],
    ['push', '--no-verify', 'origin'], ['merge', '--no-verify', 'topic'],
    // Git accepts any unambiguous prefix of a long option.
    ['commit', '--no-verif', '-m', 'x'], ['push', '--no-v', 'origin'], ['merge', '--no-ve', 'topic']])
    assert.equal(DshGitWrite.plan(argv).refused, 'GIT_HOOK_BYPASS_REFUSED', argv.join(' '));
  assert.equal(DshGitWrite.plan(['push', 'https://user:secret@example.invalid/r.git']).refused, 'GIT_URL_USERINFO_REFUSED');
  for (const argv of [[], ['-c', 'core.hooksPath=/dev/null', 'commit'], ['--git-dir=/x', 'status'], ['commit\0']])
    assert.equal(DshGitWrite.plan(argv).refused, 'GIT_ARGV_REFUSED', JSON.stringify(argv));
  // `-n` after `--` is a pathspec, and on other commands it is not --no-verify.
  assert.equal(DshGitWrite.plan(['commit', '-m', 'x', '--', '-n']).refused, undefined);
  assert.equal(DshGitWrite.plan(['add', '-n', '.']).refused, undefined);
  assert.equal(DshGitWrite.plan(['commit', '--no-edit']).refused, undefined);
  // The abbreviation really skips hooks in git, so the refusal is not merely cautious.
  const skipped = repo();
  hook(skipped, 'pre-commit', 'exit 1');
  fs.writeFileSync(join(skipped, 'a.txt'), 'abbreviated\n');
  sh(skipped, 'commit', '-q', '-a', '--no-verif', '-m', 'skipped');

  const dir = repo();
  sh(dir, 'remote', 'add', 'origin', 'https://user:secret@example.invalid/r.git');
  const {report} = transact(dir, ['push', 'origin', 'main']);
  assert.equal(report.outcome, 'blocked');
  assert.equal(report.reason, 'GIT_URL_USERINFO_REFUSED');
});

test('answers without a finished command are blocked or unknown, never completed', () => {
  const nonce = '0123456789abcdef';
  assert.deepEqual({...DshGitWrite.report({status: 'UNAVAILABLE', reason: 'LINUX_PREPARE_FAILED'}, nonce)},
    {outcome: 'blocked', reason: 'LINUX_PREPARE_FAILED'});
  assert.deepEqual({...DshGitWrite.report({status: 'CANCELLED_BEFORE_DISPATCH'}, nonce)},
    {outcome: 'blocked', reason: 'CANCELLED_BEFORE_DISPATCH'});
  assert.equal(DshGitWrite.report({status: 'RELEASED', reason: 'REFUSED', refusal: 'LEASE_STALE'}, nonce).outcome, 'blocked');
  assert.equal(DshGitWrite.report({status: 'WRITER_UNKNOWN'}, nonce).outcome, 'unknown');
  // Output that only imitates the trailer, without the nonce, is not trusted.
  const forged = DshGitWrite.report({status: 'RELEASED', reason: 'COMPLETED',
    result: {code: 0, stdout: '\nDSH-GIT-TRAILER-ffffffffffffffff\nstart git\nend git 0\n', stderr: ''}}, nonce);
  assert.equal(forged.outcome, 'unknown');
  assert.equal(DshGitWrite.report({status: 'RELEASED', reason: 'COMPLETED', result: {code: null, timeout: true, stdout: '', stderr: ''}}, nonce).reason, 'TIMEOUT');
});

test('run passes network to the executor and blocks pre-admission refusals only', async () => {
  const seen = [];
  const refused = await DshGitWrite.run(['push', 'origin'], {}, async request => { seen.push(request.network); throw new Error('COMMAND_REFUSED'); });
  assert.deepEqual({...refused}, {outcome: 'blocked', reason: 'COMMAND_REFUSED'});
  const lost = await DshGitWrite.run(['commit', '-m', 'x'], {}, async request => { seen.push(request.network); throw new Error('transport lost'); });
  assert.equal(lost.outcome, 'unknown');
  assert.deepEqual(seen, [true, false]);
  let called = false;
  const bypass = await DshGitWrite.run(['commit', '--no-verify'], {}, async () => { called = true; });
  assert.equal(bypass.outcome, 'blocked');
  assert.equal(called, false);
});

async function startRemote(token) {
  const projects = join(root, `http${++serial}`);
  fs.mkdirSync(projects);
  spawnSync('git', ['init', '-q', '--bare', '-b', 'main', join(projects, 'r.git')], {env: leaseEnv});
  const portFile = join(projects, 'port');
  const child = spawn(process.execPath, [join(here, 'git_http_fixture.cjs'), projects, portFile],
    {env: {PATH: leaseEnv.PATH, DSH_GIT_TOKEN: token}, stdio: 'ignore'});
  for (let i = 0; i < 200 && !fs.existsSync(portFile); i++) await new Promise(r => setTimeout(r, 25));
  const port = Number(fs.readFileSync(portFile, 'utf8'));
  return {url: `http://127.0.0.1:${port}/r.git`, bareDir: join(projects, 'r.git'), port,
    stats: async () => (await fetch(`http://127.0.0.1:${port}/__stats`)).json(), stop: () => child.kill('SIGTERM')};
}

test('credentialed smart-HTTP push: token only in the request env, nowhere it can persist', async () => {
  const token = 'tok_' + Array.from(crypto.getRandomValues(new Uint8Array(24)), b => b.toString(16).padStart(2, '0')).join('');
  const remote = await startRemote(token);
  try {
    const dir = repo();
    sh(dir, 'remote', 'add', 'origin', remote.url);
    const dump = join(root, `env-dump-${serial}`);
    hook(dir, 'pre-push', `cat > /dev/null; env > ${dump}; exit 0`);
    hook(dir, 'post-commit', `env >> ${dump}.post`);
    fs.writeFileSync(join(dir, 'a.txt'), 'two\n');
    const commit = transact(dir, ['commit', '-am', 'to push']);
    assert.equal(commit.report.outcome, 'completed');
    assert.equal(commit.planned.network, false);

    const wrong = transact(dir, ['push', 'origin', 'main'], {secretEnv: {DSH_GIT_TOKEN: 'wrong-token'}});
    assert.equal(wrong.report.outcome, 'failed');
    assert.equal(wrong.report.blockedBy, null);
    assert.notEqual(spawnSync('git', ['--git-dir', remote.bareDir, 'rev-parse', '--verify', '-q', 'main'], {env: leaseEnv}).status, 0);

    const pushed = transact(dir, ['push', 'origin', 'main'], {secretEnv: {DSH_GIT_TOKEN: token}});
    assert.equal(pushed.report.outcome, 'completed', pushed.out.stderr);
    assert.equal(pushed.planned.network, true);
    assert.equal(sh(remote.bareDir, 'rev-parse', 'main').trim(), head(dir));
    const stats = await remote.stats();
    assert.ok(stats.authorized >= 1 && stats.refused >= 1 && stats.pushes >= 1, JSON.stringify(stats));

    // Nowhere the token could persist or leak: the command text, the report, the work tree and
    // .git (config included), hook environments, and /tmp transaction directories.
    const places = {command: pushed.planned.command, report: JSON.stringify(pushed.report), stdout: pushed.out.stdout,
      stderr: pushed.out.stderr, hookEnv: fs.readFileSync(dump, 'utf8'), postCommitEnv: fs.readFileSync(dump + '.post', 'utf8')};
    for (const file of spawnSync('find', [dir, '-type', 'f'], {encoding: 'utf8'}).stdout.trim().split('\n'))
      places[file] = fs.readFileSync(file).toString('latin1');
    for (const [where, text] of Object.entries(places)) assert.ok(!text.includes(token), `token found in ${where}`);
    assert.doesNotMatch(places.hookEnv, /^DSH_GIT_/m);
    assert.equal(fs.readdirSync('/tmp').filter(x => x.startsWith('dsh-git.')).length, 0);
  } finally { remote.stop(); }
});

test('the credential helper answers only https, or http to loopback', () => {
  const fill = input => spawnSync('git', ['-c', 'credential.helper=', '-c', 'credential.helper=' + DshGitWrite.HELPER, 'credential', 'fill'],
    {env: {...leaseEnv, DSH_GIT_TOKEN: 'tok', GIT_TERMINAL_PROMPT: '0'}, input, encoding: 'utf8'});
  for (const host of ['https\nhost=example.invalid', 'http\nhost=127.0.0.1:8080', 'http\nhost=localhost'])
    assert.match(fill(`protocol=${host}\n\n`).stdout, /^password=tok$/m, host);
  for (const host of ['http\nhost=example.invalid', 'http\nhost=127.0.0.1.example.invalid', 'ftp\nhost=127.0.0.1'])
    assert.doesNotMatch(fill(`protocol=${host}\n\n`).stdout, /password=/, host);
});

test('hook executor: runHook blocks whenever the command did not run on Linux', {skip: protocol ? false : 'dsh-hook-protocol not prepared'}, async () => {
  const now = () => 0;
  const answers = {
    unavailable: {status: 'UNAVAILABLE', reason: 'LINUX_PREPARE_FAILED'},
    missingSymbol: {status: 'UNAVAILABLE', reason: 'PRIVATE_SYMBOL_MISSING'},
    cancelled: {status: 'CANCELLED_BEFORE_DISPATCH'},
    refused: {status: 'RELEASED', reason: 'REFUSED', refusal: 'LEASE_STALE'},
    writerUnknown: {status: 'WRITER_UNKNOWN'},
  };
  const calls = [];
  for (const [name, answer] of Object.entries(answers)) {
    const shell = DshHookShell.create(async (operation, payload) => { calls.push({operation, ...payload}); return answer; }, () => 'hook-' + name);
    const {output} = await protocol.runHook(shell, {type: 'command', command: 'exit 0'}, {payload: {hook_event_name: 'PreToolUse'}, defaultTimeoutMs: 600000}, now);
    assert.equal(output.decision, 'block', name);
    assert.equal(DshHookShell.notRun(output), answer.reason === 'REFUSED' ? 'LEASE_STALE' : answer.reason ?? answer.status, name);
  }
  assert.ok(calls.every(x => x.operation === 'execute' && x.trigger === 'hook' && x.timeoutMs === DshHookShell.MAX_TIMEOUT_MS && x.operationId.startsWith('hook-')));

  // Dispatched but never finished (timeout, cancelled while running): runHook would treat a missing
  // exit code as a non-blocking error, so these block too.
  for (const [result, code] of [[{code: null, timeout: true}, 'HOOK_TIMEOUT'], [{code: null, cancelled: true}, 'HOOK_CANCELLED'],
    [{code: null}, 'HOOK_NO_EXIT']]) {
    const unfinished = DshHookShell.create(async () => ({status: 'RELEASED', reason: 'COMPLETED', result: {stdout: '', stderr: '', ...result}}), () => 'h');
    const {output} = await protocol.runHook(unfinished, {command: 'x'}, {payload: {}, defaultTimeoutMs: 1000}, now);
    assert.deepEqual([output.decision, DshHookShell.notRun(output)], ['block', code]);
  }

  const thrown = DshHookShell.create(async () => { throw new Error('COMMAND_REFUSED'); }, () => 'hook-x');
  assert.equal((await protocol.runHook(thrown, {command: 'true'}, {payload: {}, defaultTimeoutMs: 1000}, now)).output.decision, 'block');

  // A finished command keeps runHook's own semantics: 2 blocks with its stderr, 0 parses stdout.
  const ran = code => DshHookShell.create(async () => ({status: 'RELEASED', reason: 'COMPLETED',
    result: {code, stdout: code === 0 ? '{"decision":"approve"}' : '', stderr: code === 2 ? 'policy says no' : ''}}), () => 'h');
  const two = (await protocol.runHook(ran(2), {command: 'x'}, {payload: {}, defaultTimeoutMs: 1000}, now)).output;
  assert.deepEqual([two.decision, two.reason, DshHookShell.notRun(two)], ['block', 'policy says no', null]);
  const zero = (await protocol.runHook(ran(0), {command: 'x'}, {payload: {}, defaultTimeoutMs: 1000}, now)).output;
  assert.equal(zero.decision, 'approve');

  // The control: the previous research adapter threw on refusal, and runHook then gives no
  // decision at all, so the action would go ahead.
  const throwing = {resolve: r => r, execute: () => ({result: async () => { throw new Error('LINUX_PREPARE_FAILED'); }})};
  assert.equal((await protocol.runHook(throwing, {command: 'x'}, {payload: {}, defaultTimeoutMs: 1000}, now)).output.decision, undefined);

  // Aborting while the command waits for Linux cancels the operation; aborted earlier, nothing is asked.
  const controller = new AbortController();
  const asked = [];
  const waiting = DshHookShell.create((operation, payload) => {
    asked.push(operation);
    if (operation === 'cancel') return Promise.resolve({status: 'CANCEL_REQUESTED'});
    return new Promise(resolve => setTimeout(() => resolve({status: 'CANCELLED_BEFORE_DISPATCH'}), 50));
  }, () => 'hook-abort');
  const pending = protocol.runHook(waiting, {command: 'x'}, {payload: {}, defaultTimeoutMs: 1000, signal: controller.signal}, now);
  while (!asked.length) await new Promise(resolve => setTimeout(resolve, 1));
  controller.abort();
  assert.equal((await pending).output.decision, 'block');
  assert.deepEqual(asked, ['execute', 'cancel']);
  const early = await protocol.runHook(waiting, {command: 'x'}, {payload: {}, defaultTimeoutMs: 1000, signal: controller.signal}, now);
  assert.equal(DshHookShell.notRun(early.output), 'CANCELLED_BEFORE_DISPATCH');
  assert.deepEqual(asked, ['execute', 'cancel']);
});

test('init and clone create a repository outside any existing one, with ordered events', () => {
  const source = repo();
  const empty = join(root, `fresh${++serial}`);
  fs.mkdirSync(empty);
  const init = transact(empty, ['init', '-q', '-b', 'main', 'new']).report;
  assert.deepEqual([init.outcome, [...init.events]], ['completed', ['start git', 'end git 0']]);
  assert.ok(fs.existsSync(join(empty, 'new/.git/HEAD')));
  const clone = transact(empty, ['clone', '-q', source, 'copy']);
  assert.equal(clone.report.outcome, 'completed', clone.out.stderr);
  assert.equal(clone.planned.network, true);
  assert.equal(head(join(empty, 'copy')), head(source));
});

test('cwd option: the transaction enters a project directory under the workspace, never outside it', () => {
  const dir = repo();
  fs.writeFileSync(join(dir, 'b.txt'), 'two\n');
  const parent = join(dir, '..');
  const name = dir.split('/').at(-1);
  assert.equal(transact(parent, ['add', 'b.txt'], {options: {cwd: name}}).report.outcome, 'completed');
  assert.match(sh(dir, 'status', '--porcelain'), /^A {2}b\.txt$/m);
  const missing = transact(parent, ['status'], {options: {cwd: 'no-such-project'}}).report;
  assert.deepEqual([missing.outcome, missing.reason], ['blocked', 'GIT_CWD_REFUSED']);
  for (const cwd of ['/etc', '../x', 'a/../../x', '', 'a\nb'])
    assert.equal(DshGitWrite.plan(['status'], {cwd}).refused, 'GIT_CWD_REFUSED', JSON.stringify(cwd));
});

test('hook executor hands the hook runHook\'s stdin payload and env on Linux', {skip: protocol ? false : 'dsh-hook-protocol not prepared'}, async () => {
  const commands = [];
  const shell = DshHookShell.create(async (operation, payload) => {
    commands.push(payload.command);
    const out = spawnSync('/bin/sh', ['-c', payload.command], {cwd: root, env: leaseEnv, encoding: 'utf8'});
    return {status: 'RELEASED', reason: 'COMPLETED', result: {code: out.status, stdout: out.stdout, stderr: out.stderr}};
  }, () => 'hook-stdin');
  const hook = {type: 'command', command: 'payload=$(cat); case $payload in *\'"tool_name":"Bash"\'*) ;; *) echo "no payload" >&2; exit 2 ;; esac\n' +
    '[ "$HOOK_MARK" = "it\'s here" ] || { echo "no env" >&2; exit 2; }\necho \'{"decision":"approve"}\''};
  const payload = {hook_event_name: 'PreToolUse', tool_name: 'Bash', tool_input: {command: "echo 'quoted' $HOME\n"}};
  const {output} = await protocol.runHook(shell, hook, {payload, env: {HOOK_MARK: "it's here"}, trailingNewline: true, defaultTimeoutMs: 1000}, () => 0);
  assert.deepEqual([output.exitCode, output.decision, output.stderr], [0, 'approve', '']);
  // Env names that are not shell names are refused, not dropped: the hook never runs.
  const bad = await protocol.runHook(shell, hook, {payload, env: {'A=B': 'x'}, defaultTimeoutMs: 1000}, () => 0);
  assert.equal(DshHookShell.notRun(bad.output), 'HOOK_ENV_REFUSED');
  assert.equal(commands.length, 1);
  // A command ending in a backslash still runs as itself, not joined to the wrapper.
  const trailing = await protocol.runHook(shell, {type: 'command', command: 'echo \'{"decision":"approve"}\' \\'}, {payload, defaultTimeoutMs: 1000}, () => 0);
  assert.equal(trailing.output.decision, 'approve');
});
