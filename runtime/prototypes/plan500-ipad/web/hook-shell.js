/*
 * Hook command executor for the official dsh-hook-protocol runHook (#39 gate 5).
 *
 * runHook treats a throwing executor as "no decision", which lets the action continue. A hook that
 * could not run on Linux must block instead, so every answer that is not a finished command
 * (Linux unavailable, preparation failed, cancelled before dispatch, writer unknown, bridge error,
 * or dispatched but stopped by timeout or cancel without an exit code)
 * becomes exit code 2 with a fixed stderr `DSH_HOOK_NOT_RUN <CODE>`, which runHook parses as
 * `decision: "block"` with that reason.
 */
(function (root) {
  'use strict';

  const NOT_RUN = 'DSH_HOOK_NOT_RUN ';
  // The Linux agent and the native coordinator stop any command at this length.
  const MAX_TIMEOUT_MS = 60000;
  const blocked = code => ({exitCode: 2, stdout: {text: ''}, stderr: {text: NOT_RUN + code}});
  const quote = value => "'" + value.replace(/'/g, "'\\''") + "'";

  // The Linux agent gives a command no stdin and a fixed environment, so runHook's payload is
  // replayed from the command text and its env exported before the hook command runs.
  function commandOf(request) {
    const lines = [];
    for (const [name, value] of Object.entries(request.env ?? {})) {
      if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(name) || typeof value !== 'string' || value.includes('\0')) return {refused: 'HOOK_ENV_REFUSED'};
      lines.push(`export ${name}=${quote(value)}`);
    }
    const stdin = request.stdin ?? '';
    if (typeof stdin !== 'string' || stdin.includes('\0')) return {refused: 'HOOK_STDIN_REFUSED'};
    lines.push(`printf '%s' ${quote(stdin)} | (\n${request.command}\n)`);
    return {command: lines.join('\n') + '\n'};
  }

  /** `native(operation, payload)` is the Worker's native bridge; `newId()` names each operation. */
  function create(native, newId) {
    return {
      resolve: request => request,
      execute: request => ({
        result: async () => {
          const operationId = request.operationId ?? newId();
          const cancel = () => { native('cancel', {operationId}).catch(() => {}); };
          if (request.signal?.aborted) return blocked('CANCELLED_BEFORE_DISPATCH');
          const built = commandOf(request);
          if (built.refused) return blocked(built.refused);
          request.signal?.addEventListener?.('abort', cancel, {once: true});
          let answer;
          try {
            answer = await native('execute', {command: built.command, operationId, trigger: 'hook',
              timeoutMs: Math.min(request.timeoutMs ?? MAX_TIMEOUT_MS, MAX_TIMEOUT_MS)});
          } catch (error) {
            return blocked(String(error?.message ?? error).split(/\s/)[0] || 'NATIVE_ERROR');
          } finally {
            request.signal?.removeEventListener?.('abort', cancel);
          }
          if (answer.status !== 'RELEASED') return blocked(answer.reason ?? answer.status ?? 'NO_ANSWER');
          if (answer.reason === 'REFUSED') return blocked(String(answer.refusal ?? 'REFUSED'));
          const result = answer.result;
          // Dispatched but not finished: runHook would read a missing exit code as non-blocking.
          if (!Number.isInteger(result?.code))
            return blocked(result?.timeout ? 'HOOK_TIMEOUT' : result?.cancelled ? 'HOOK_CANCELLED' : 'HOOK_NO_EXIT');
          return {exitCode: result.code, stdout: {text: result.stdout ?? ''}, stderr: {text: result.stderr ?? ''}};
        },
      }),
    };
  }

  /** The fixed code when a runHook output means the command never ran on Linux, else null. */
  function notRun(output) {
    return output.exitCode === 2 && output.stderr.startsWith(NOT_RUN) ? output.stderr.slice(NOT_RUN.length) : null;
  }

  root.DshHookShell = {create, notRun, MAX_TIMEOUT_MS};
})(globalThis);
