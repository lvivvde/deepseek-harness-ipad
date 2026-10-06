// Appended only to a scratch copy of the fixed official Worker. Uses its real tool registry.
const plan500NativePending = new Map();
let plan500NativeId = 0;
self.addEventListener('message', event => {
  if (event.data?.t !== 'plan500-native-reply') return;
  event.stopImmediatePropagation();
  const p = plan500NativePending.get(event.data.id);
  if (!p) return;
  plan500NativePending.delete(event.data.id);
  if (event.data.error) p.reject(new Error(event.data.error)); else p.resolve(event.data.result);
});
function plan500Native(operation, payload = {}) {
  const id = ++plan500NativeId;
  return new Promise((resolve, reject) => {
    plan500NativePending.set(id, {resolve, reject});
    self.postMessage({t: 'plan500-native', id, operation, payload});
  });
}
// Keep the real API key entirely in Swift. The Worker provider sees a placeholder.
const plan500OriginalFetch = globalThis.fetch.bind(globalThis);
let plan500ModelResponses = 0;
globalThis.fetch = async (input, options) => {
  const url = typeof input === 'string' ? input : input.url;
  if (url !== 'https://api.deepseek.com/anthropic/v1/messages') return plan500OriginalFetch(input, options);
  const result = await plan500Native('model-request', {url, body: options.body});
  if (result.status === 200) plan500ModelResponses++;
  return new Response(Uint8Array.from(atob(result.base64), x => x.charCodeAt(0)),
    {status: result.status, headers: {'content-type': result.contentType}});
};
// The official hook runner (dsh-hook-protocol) is not packed in this Worker image. This adapter has the
// ShellExecutor shape it calls (resolve, execute, result) and routes a command hook to the Linux path
// with trigger "hook", so the native side admits it as a hook task. Refusals keep their fixed code.
const plan500HookShell = {
  resolve: request => request,
  execute: request => ({result: async () => {
    const answer = await plan500Native('execute', {command: request.command, timeoutMs: request.timeoutMs,
      operationId: request.operationId, trigger: 'hook'});
    if (answer.status !== 'RELEASED') throw new Error(answer.reason ?? answer.status);
    return {exitCode: answer.result.code, stdout: {text: answer.result.stdout}, stderr: {text: answer.result.stderr}};
  }}),
};
async function plan500RunHook(shell, hook, operationId) {
  const started = performance.now();
  try {
    const result = await shell.execute(shell.resolve({command: hook.command, timeoutMs: hook.timeoutMs ?? 15000, operationId})).result();
    return {event: hook.event, ran: true, exitCode: result.exitCode, stdout: result.stdout.text, elapsedMs: performance.now() - started};
  } catch (error) {
    return {event: hook.event, ran: false, refusal: String(error.message), elapsedMs: performance.now() - started};
  }
}
const plan500OriginalMessage = prototypeMessage;
const plan500Installed = new Set();
let plan500ModelActive = false;
// The real-model run's only allowed tool uses; each guard refuses anything else with its fixed code before dispatch.
const plan500ModelScope = {
  plan500_read: {allows: () => true},
  plan500_write: {allows: args => args?.path === 'math.cjs', refusal: 'MODEL_FIXTURE_WRITE_REFUSED'},
  plan500_linux: {allows: args => args?.command?.trim() === 'node test.cjs', refusal: 'MODEL_TEST_COMMAND_REFUSED'},
};
const plan500KnownErrors = ['MODEL_FIXTURE_WRITE_REFUSED', 'MODEL_TEST_COMMAND_REFUSED', 'ABORTED_BEFORE_DISPATCH',
  'BRIDGE_REQUEST_FAILED'];
// Exact match only: an error that merely echoes a code (or file text) is not that code.
const plan500ErrorCode = text => plan500KnownErrors.find(code => text?.trim() === 'Error: ' + code) ?? 'OTHER';
function plan500ModelGuard(name, args) {
  const rule = plan500ModelScope[name];
  if (plan500ModelActive && !rule.allows(args)) throw new Error(rule.refusal);
}
// Only current-run events are passed here, in the order delivered by the official session.
function plan500ModelEvidence(events) {
  const calls = new Map(), tools = [], replies = [], ends = [];
  let reusedCallId = false;
  events.forEach((event, sequence) => {
    const data = event.data;
    if (event.type === 'tool/call') {
      let args; try { args = JSON.parse(data.arguments); } catch {}
      if (calls.has(data.callId)) reusedCallId = true;
      calls.set(data.callId, {callId: data.callId, name: data.name, args, callSequence: sequence, turn: data.turn});
    } else if (event.type === 'tool/result') {
      const message = data.message;
      let value; try { value = JSON.parse(message.content[0]?.text); } catch {}
      const isError = message.isError === true;
      tools.push({...calls.get(message.toolCallId), sequence, isError,
        errorCode: isError ? plan500ErrorCode(message.content[0]?.text) : undefined,
        status: value?.status, code: value?.result?.code, stdout: value?.result?.stdout,
        writerQuiescent: value?.result?.writerQuiescent});
    } else if (event.type === 'assistant/message') {
      replies.push({sequence, turn: data.turn, interrupted: data.interrupted === true,
        text: (data.message?.content ?? []).filter(x => x.type === 'text').map(x => x.text).join('\n')});
    } else if (event.type === 'turn/end') ends.push({sequence, turn: data.turn, kind: data.reason?.kind});
  });
  const allowed = x => plan500ModelScope[x.name]?.allows(x.args) === true;
  const fix = tools.find(x => x.name === 'plan500_write' && allowed(x) && !x.isError && x.status === 'WRITTEN');
  // Out-of-scope attempts are acceptable only when the tool's own model-run guard refused them before dispatch.
  const boundedCalls = !reusedCallId && [...calls.values()].every(x => {
    const answer = tools.find(t => t.callId === x.callId);
    return allowed(x) || (answer?.isError === true && plan500ModelScope[x.name]?.refusal === answer.errorCode);
  });
  const tested = boundedCalls && fix && tools.find(x => x.name === 'plan500_linux' && allowed(x)
    && x.callSequence > fix.sequence && !x.isError && x.status === 'RELEASED' && x.code === 0
    && x.writerQuiescent === true && x.stdout?.includes('MODEL_TEST_OK'));
  const final = replies.at(-1), end = ends.at(-1);
  // Redacted for the safe receipt: order, outcome and fixed codes only, never text, commands or output.
  const trace = tools.map(x => {
    const entry = {name: x.name, turn: x.turn, callOrder: x.callSequence, resultOrder: x.sequence, isError: x.isError};
    if (x.isError) entry.errorCode = x.errorCode;
    else { entry.status = x.status; if (x.name === 'plan500_linux') Object.assign(entry, {code: x.code,
      markerSeen: x.stdout?.includes('MODEL_TEST_OK') === true, writerQuiescent: x.writerQuiescent}); }
    if (x.name === 'plan500_write') entry.fixturePath = allowed(x);
    if (x.name === 'plan500_linux') entry.exactTestCommand = allowed(x);
    return entry;
  });
  return {trace, boundedCalls, nativeFix: !!fix, linuxTest: !!tested, turnEnd: end?.kind, replyCount: replies.length,
    assistantReturned: !!(tested && final && end && final.sequence > tested.sequence && !final.interrupted
      && final.text.trim() && end.kind === 'completed' && end.turn === final.turn && final.turn === tested.turn
      && end.sequence > final.sequence)};
}
prototypeMessage = async event => {
  const data = event.data;
  if (!['bridge-install', 'bridge-tool', 'bridge-hook', 'home-snapshot', 'model-run'].includes(data.operation)) return plan500OriginalMessage(event);
  try {
    const ctx = host.prototypeContext;
    const agent = data.sessionId ? ctx.get('agents').get(data.sessionId) : undefined;
    let result;
    if (data.operation === 'bridge-hook') {
      result = await plan500RunHook(plan500HookShell, data.hook, data.operationId);
    } else if (data.operation === 'home-snapshot') {
      await ctx.get('sessionPersistence').flush();
      const snapshot = prototypeSnapshot(host.vfs);
      snapshot.files = snapshot.files.filter(x => x.path.startsWith('/dsh/home/'));
      snapshot.directories = snapshot.directories.filter(x => x.path === '/dsh/home' || x.path.startsWith('/dsh/home/'));
      result = snapshot;
    } else {
      if (!agent) throw new Error('AGENT_NOT_OPEN');
      const tools = agent.ctx.get('tools');
      if (data.operation === 'model-run') {
        const require = host.modules.createRequire('/dsh/config/cordis.yml');
        const {createUserMessage} = require('@deepseek-ai/dsh-llm');
        await ctx.get('credentials').set('DEEPSEEK_API_KEY', 'plan500-native-placeholder');
        const events = [];
        const responsesBefore = plan500ModelResponses;
        const dispose = agent.ctx.on('session/event', (session, event) => {
          if (session.id !== agent.id) return;
          if (['tool/call', 'tool/result', 'assistant/message', 'turn/end'].includes(event.type)) events.push(event);
        });
        const timeout = setTimeout(() => agent.cancel({kind: 'user'}), 240000);
        plan500ModelActive = true;
        try {
          agent.followup(createUserMessage({source: {kind: 'user', rpcId: 'plan500-real-model'}, content: [{type: 'text', text:
            'This is an isolated native/Linux integration check. Only use plan500_read, plan500_write and plan500_linux. Read math.cjs and test.cjs from the native workspace. Fix the subtraction bug so add(2,3) returns 5, write math.cjs using the read version, then run node test.cjs through plan500_linux. Do not edit test.cjs. Do not claim success without exit code 0 and MODEL_TEST_OK in Linux stdout. Give a brief Chinese final result including that actual test result.'}]}));
          await agent.whenIdle();
          result = {http200Responses: plan500ModelResponses - responsesBefore, ...plan500ModelEvidence(events)};
        } finally { plan500ModelActive = false; clearTimeout(timeout); dispose(); }
      } else if (data.operation === 'bridge-install') {
        if (plan500Installed.has(data.sessionId)) throw new Error('BRIDGE_ALREADY_INSTALLED');
        const {defineTool} = host.modules.createRequire('/dsh/config/cordis.yml')('@deepseek-ai/dsh-tools');
        // Mask inherited VFS/shell tools; project writes must use the authoritative gateway.
        tools.restrict({allow: []});
        tools.presentAs('native');
        const common = {output: {schema: {type: 'object', additionalProperties: true}, render: (_args, value) => [{type: 'text', text: JSON.stringify(value)}]}};
        tools.register(defineTool({...common, name: 'plan500_read',
          description: 'Read a regular UTF-8 file in the shared native workspace. Returns its opaque version for writes; works before Linux is ready.',
          parameters: {path: {type: 'string', required: true}},
          execute: args => plan500Native('read', args)}));
        tools.register(defineTool({...common, name: 'plan500_write',
          description: 'Write a native workspace file using the version returned by read, or null for a new file. A held or conflicting draft is preserved and is not a saved project edit.',
          parameters: {path: {type: 'string', required: true}, text: {type: 'string', required: true}, base: {oneOf: [{type: 'string'}, {type: 'null'}], required: true}},
          execute: args => {
            plan500ModelGuard('plan500_write', args);
            return plan500Native('write', args);
          }}));
        tools.register(defineTool({...common, name: 'plan500_linux',
          description: 'Run a Linux shell command in /workspace, the exact same native project directory. Waits for real Linux ready. Returns stdout, stderr, exit code and writer quiescence. Bounded to 30 seconds.',
          parameters: {command: {type: 'string', required: true}, timeoutMs: {type: 'integer'}},
          async execute(args, exec) {
            plan500ModelGuard('plan500_linux', args);
            const operationId = String(exec.callId);
            const cancel = () => { plan500Native('cancel', {operationId}).catch(() => {}); };
            exec.signal.addEventListener('abort', cancel, {once: true});
            try {
              if (exec.signal.aborted) throw new Error('ABORTED_BEFORE_DISPATCH');
              return await plan500Native('execute', {...args, operationId});
            } finally { exec.signal.removeEventListener('abort', cancel); }
          }}));
        plan500Installed.add(data.sessionId);
        result = {installed: true, names: tools.wireSchemas(agent).schemas.map(x => x.name)};
      } else {
        const signal = new AbortController().signal;
        result = await tools.execute({callId: data.operationId ?? 'probe-' + data.id,
          name: data.name, arguments: data.args, agent, signal});
      }
    }
    self.postMessage({t: 'plan500-result', id: data.id, result});
  } catch (error) { self.postMessage({t: 'plan500-result', id: data.id, error: String(error)}); }
};
