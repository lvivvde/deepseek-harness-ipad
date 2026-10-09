/*
 * Git writes of deepseek-harness-ipad (#39 gate 5).
 *
 * Every Git operation that may change a repository runs on the Linux path that holds the write
 * lease, as one /bin/sh transaction made by `plan`. The transaction keeps the repository's own
 * hooks: it points core.hooksPath at a private directory of shims, one per executable file in the
 * real hooks directory (core.hooksPath respected), and each shim records `start <hook>` and
 * `end <hook> <code>` before and after running the real hook with the same arguments, stdin and
 * environment. Git itself is bracketed by `start git` and `end git <code>`. The events follow a
 * trailer line carrying a random nonce, so command output cannot be mistaken for them.
 *
 * Hooks are never skipped: `--no-verify` (and `-n` on commit) is refused before dispatch.
 *
 * Credentials: a network operation (push, fetch, pull, clone, ls-remote) adds a credential helper
 * that answers only `get` for https (or http to loopback), from DSH_GIT_TOKEN in the command's
 * environment. The native side puts
 * the token there per request (never in the command text); the shims remove it before any hook
 * runs. Remote URLs carrying userinfo are refused, so no credential is stored in .git/config.
 */
(function (root) {
  'use strict';

  // Hooks whose non-zero exit stops the operation before anything is written.
  const BLOCKING = new Set(['pre-commit', 'prepare-commit-msg', 'commit-msg', 'pre-merge-commit', 'pre-push',
    'pre-rebase', 'pre-applypatch', 'applypatch-msg', 'pre-auto-gc', 'push-to-checkout', 'sendemail-validate']);
  const NETWORK = new Set(['push', 'fetch', 'pull', 'clone', 'ls-remote']);
  const MAX_COMMAND = 32000;
  // Native refusals thrown before admission (WorkerCoordinator.execute).
  const PRE_DISPATCH = new Set(['COMMAND_REFUSED', 'DUPLICATE_OPERATION', 'PATH_REFUSED']);

  const quote = value => "'" + value.replace(/'/g, "'\\''") + "'";
  const userinfo = value => /^[a-z][a-z0-9+.-]*:\/\/[^/]*@/i.test(value);

  // Before `--`, --no-verify or any prefix Git would expand to it (`--no-v` on), and on commit a
  // short-option cluster containing `n`. Clusters that carry a message (`-mnote`) are refused too;
  // that is conservative, never permissive.
  function skipsHooks(argv) {
    const end = argv.indexOf('--');
    const options = end < 0 ? argv : argv.slice(0, end);
    if (options.some(x => x.length >= 6 && '--no-verify'.startsWith(x))) return true;
    return argv[0] === 'commit' && options.slice(1).some(x => /^-[A-Za-z]*n/.test(x) && !x.startsWith('--'));
  }

  // A directory under the workspace root, where the Linux command starts: relative, no `..`.
  const projectDirectory = value => typeof value === 'string' && value.length > 0 && value.length <= 1024 &&
    !value.startsWith('/') && !/[\x00-\x1f\x7f]/.test(value) && value.split('/').every(x => x !== '..');

  function refusal(argv, options) {
    if (!Array.isArray(argv) || argv.length === 0 || !argv.every(x => typeof x === 'string')) return 'GIT_ARGV_REFUSED';
    if (!/^[a-z][a-z0-9-]*$/.test(argv[0])) return 'GIT_ARGV_REFUSED';
    if (argv.some(x => x.includes('\0'))) return 'GIT_ARGV_REFUSED';
    if (skipsHooks(argv)) return 'GIT_HOOK_BYPASS_REFUSED';
    if (argv.some(userinfo)) return 'GIT_URL_USERINFO_REFUSED';
    if (options.user !== undefined && !/^[\x21-\x7e]{1,128}$/.test(options.user)) return 'GIT_USER_REFUSED';
    if (options.cwd !== undefined && !projectDirectory(options.cwd)) return 'GIT_CWD_REFUSED';
    return null;
  }

  // The shim is the same file for every hook; it finds its hook by its own name.
  const SHIM = [
    '#!/bin/sh',
    'n=${0##*/}; ev=$DSH_GIT_EVENTS; real=$DSH_GIT_REAL_HOOKS',
    'unset DSH_GIT_EVENTS DSH_GIT_REAL_HOOKS DSH_GIT_TOKEN DSH_GIT_USER',
    'printf \'start %s\\n\' "$n" >> "$ev"',
    '"$real/$n" "$@"; c=$?',
    'printf \'end %s %s\\n\' "$n" "$c" >> "$ev"',
    'exit $c',
  ].join('\n') + '\n';

  // Answers only https, or plain http to loopback (the test remote), so a remote URL the repository
  // sets cannot send the token in clear text to another host.
  const HELPER = '!f() { test "$1" = get && test -n "$DSH_GIT_TOKEN" || return 0; p=; h=; ' +
    'while IFS= read -r l; do case $l in protocol=*) p=${l#protocol=} ;; host=*) h=${l#host=} ;; esac; done; ' +
    'case $p:$h in https:*|http:127.0.0.1|http:127.0.0.1:*|http:localhost|http:localhost:*) ;; *) return 0 ;; esac; ' +
    'printf "username=%s\\npassword=%s\\n" "${DSH_GIT_USER:-x-access-token}" "$DSH_GIT_TOKEN"; }; f';

  /**
   * Builds the transaction for `git <argv>`. Returns {refused} for an operation that must not run,
   * else {command, nonce, network}. `network` tells the native side to supply the token. `cwd` names
   * the project directory relative to the workspace root, where the Linux command starts.
   */
  function plan(argv, options = {}) {
    const refused = refusal(argv, options);
    if (refused) return {refused};
    const nonce = options.nonce ?? Array.from(root.crypto.getRandomValues(new Uint8Array(16)),
      b => b.toString(16).padStart(2, '0')).join('');
    if (!/^[0-9a-f]{16,64}$/.test(nonce)) return {refused: 'GIT_NONCE_REFUSED'};
    const network = NETWORK.has(argv[0]);
    // init and clone make a repository that does not exist yet: there are no hooks to wrap, so Git
    // keeps its own hooks path (never skipped) and the events are those of Git alone.
    const fresh = argv[0] === 'init' || argv[0] === 'clone';
    const trailer = 'DSH-GIT-TRAILER-' + nonce;
    const config = fresh ? [] : ['-c', 'core.hooksPath="$op/hooks"'];
    if (network) config.push('-c', 'credential.helper=', '-c', quote('credential.helper=' + HELPER), '-c', 'core.askPass=');
    const identity = options.identity ?? {};
    const exports = [];
    for (const [key, value] of [['NAME', identity.name], ['EMAIL', identity.email]]) {
      if (value === undefined) continue;
      exports.push(`GIT_AUTHOR_${key}=${quote(value)} GIT_COMMITTER_${key}=${quote(value)}`);
    }
    if (options.user !== undefined) exports.push('DSH_GIT_USER=' + quote(options.user));
    const lines = [
      'umask 077',
      `refuse() { printf '\\n%s\\nrefuse %s\\n' ${trailer} "$1"; exit 125; }`,
      options.cwd === undefined ? ':' : `cd -- ${quote(options.cwd)} 2>/dev/null || refuse GIT_CWD_REFUSED`,
      'op=$(mktemp -d /tmp/dsh-git.XXXXXX) || refuse GIT_TEMP_FAILED',
      'trap \'rm -rf "$op"\' EXIT',
      'ev=$op/events; : > "$ev"',
      ...(fresh ? ['real=$op/none'] : [
        'real=$(git rev-parse --git-path hooks 2>/dev/null) || refuse GIT_NOT_A_REPOSITORY',
        'case $real in /*) ;; *) real=$(pwd)/$real ;; esac',
        network ? 'if git config --get-regexp \'^remote\\..*url$\' 2>/dev/null | grep -q \'://[^/]*@\'; then refuse GIT_URL_USERINFO_REFUSED; fi' : ':',
        'mkdir "$op/hooks" || refuse GIT_TEMP_FAILED',
        `cat > "$op/shim" <<'DSH_GIT_SHIM'\n${SHIM}DSH_GIT_SHIM`,
        'for f in "$real"/*; do',
        '  if [ -f "$f" ] && [ -x "$f" ]; then cp "$op/shim" "$op/hooks/${f##*/}" && chmod 700 "$op/hooks/${f##*/}" || refuse GIT_TEMP_FAILED; fi',
        'done',
      ]),
      ...exports.map(x => 'export ' + x),
      'export DSH_GIT_EVENTS="$ev" DSH_GIT_REAL_HOOKS="$real" GIT_TERMINAL_PROMPT=0',
      'echo \'start git\' >> "$ev"',
      `git ${config.join(' ')} ${argv.map(quote).join(' ')}`,
      'c=$?',
      'echo "end git $c" >> "$ev"',
      `printf '\\n%s\\n' ${trailer}`,
      'cat "$ev"',
      'exit $c',
    ];
    const command = lines.join('\n') + '\n';
    if (command.length > MAX_COMMAND) return {refused: 'GIT_ARGV_REFUSED'};
    return {command, nonce, network};
  }

  /** Splits the command's stdout into Git's own output and the events after the trailer. */
  function parse(stdout, nonce) {
    const marker = '\nDSH-GIT-TRAILER-' + nonce + '\n';
    const at = stdout.lastIndexOf(marker);
    if (at < 0) return null;
    const events = stdout.slice(at + marker.length).split('\n').filter(Boolean);
    const refused = events.find(x => x.startsWith('refuse '));
    return {output: stdout.slice(0, at), events, refused: refused?.slice(7) ?? null};
  }

  /**
   * Reads the native answer for a transaction. `blocked`: nothing ran (Linux unavailable, cancelled
   * before dispatch, refused); `failed`: Git ran and exited non-zero, `blockedBy` naming the
   * blocking hook that stopped it, if any; `completed`: Git exited 0, with any failed post hooks
   * listed; `unknown`: Git may have run but its end was not observed.
   */
  function report(answer, nonce) {
    if (answer.status === 'UNAVAILABLE' || answer.status === 'CANCELLED_BEFORE_DISPATCH' || answer.status === 'LEASE_BUSY')
      return {outcome: 'blocked', reason: answer.reason ?? answer.status};
    if (answer.status !== 'RELEASED') return {outcome: 'unknown', reason: answer.status ?? 'NO_ANSWER'};
    if (answer.reason === 'REFUSED') return {outcome: 'blocked', reason: String(answer.refusal ?? 'REFUSED')};
    const result = answer.result ?? {};
    const common = {generation: answer.generation, changed: answer.changed ?? [], stderr: result.stderr ?? ''};
    const parsed = parse(result.stdout ?? '', nonce);
    if (!parsed) return {outcome: 'unknown', reason: result.timeout ? 'TIMEOUT' : result.cancelled ? 'CANCELLED' : 'TRAILER_MISSING', ...common};
    if (parsed.refused) return {outcome: 'blocked', reason: parsed.refused, events: parsed.events, ...common};
    const end = parsed.events.find(x => x.startsWith('end git '));
    if (!end) return {outcome: 'unknown', reason: 'GIT_END_MISSING', events: parsed.events, ...common};
    const hooks = parsed.events.filter(x => x.startsWith('end ') && !x.startsWith('end git '))
      .map(x => { const [, name, code] = x.split(' '); return {name, code: Number(code)}; });
    const exitCode = Number(end.slice(8));
    const base = {exitCode, events: parsed.events, output: parsed.output, ...common};
    if (exitCode === 0)
      return {outcome: 'completed', postHookFailures: hooks.filter(x => x.code !== 0 && !BLOCKING.has(x.name)), ...base};
    const stopper = hooks.find(x => x.code !== 0 && BLOCKING.has(x.name));
    return {outcome: 'failed', blockedBy: stopper?.name ?? null, ...base};
  }

  /** Plans, runs through `execute({command, network})` and reports one Git operation. */
  async function run(argv, options, execute) {
    const planned = plan(argv, options);
    if (planned.refused) return {outcome: 'blocked', reason: planned.refused};
    let answer;
    try { answer = await execute({command: planned.command, network: planned.network}); }
    catch (error) {
      // Only refusals made before admission prove nothing ran; any other failure may follow dispatch.
      const reason = String(error?.message ?? error);
      return {outcome: PRE_DISPATCH.has(reason) ? 'blocked' : 'unknown', reason};
    }
    return report(answer, planned.nonce);
  }

  root.DshGitWrite = {plan, parse, report, run, BLOCKING, HELPER};
})(globalThis);
