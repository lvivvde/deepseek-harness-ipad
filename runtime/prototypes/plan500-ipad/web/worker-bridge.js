// Appended only to a scratch copy of the fixed official Worker. Uses its real tool registry.
const plan500NativePending = new Map();
let plan500NativeId = 0;
// Called by the listener prepended to the Worker, which runs before the official tunnel sees the frame.
self.plan500NativeReply = data => {
  const p = plan500NativePending.get(data.id);
  if (!p) return;
  plan500NativePending.delete(data.id);
  if (data.error) p.reject(new Error(data.error)); else p.resolve(data.result);
};
function plan500Native(operation, payload = {}) {
  const id = ++plan500NativeId;
  return new Promise((resolve, reject) => {
    plan500NativePending.set(id, {resolve, reject});
    self.postMessage({t: 'plan500-native', id, operation, payload});
  });
}
// Keep the real API key entirely in Swift. The Worker provider sees a placeholder. #39 gate 4: the response
// body is a stream fed by Swift in arrival order, so the official adapter parses, retries and cancels as usual.
const plan500OfficialMessages = 'https://api.deepseek.com/anthropic/v1/messages';
const plan500OriginalFetch = globalThis.fetch.bind(globalThis);
let plan500ModelResponses = 0;
let plan500ModelStreamId = 0;
const plan500ModelStreamPrefix = Math.random().toString(36).slice(2, 10);
// Redacted per-stream timings (ms since the Worker started) and fixed codes; never bytes, headers or text.
const plan500ModelStreams = [];
let plan500ModelChunkHook;
const plan500Now = () => Math.round(performance.now());
// Fixed stream ids, statuses and codes only, so a stalled host run shows where it stopped.
const plan500Progress = step => self.postMessage({t: 'plan500-log', progress: step});
const plan500Bytes = base64 => Uint8Array.from(atob(base64), x => x.charCodeAt(0));
globalThis.fetch = async (input, options = {}) => {
  const url = typeof input === 'string' ? input : input.url;
  if (url !== plan500OfficialMessages) return plan500OriginalFetch(input, options);
  const signal = options.signal;
  // Unique across Workers: the Swift gateway outlives each Worker, so a reused id could meet a stale cancel.
  const streamId = 'model-' + plan500ModelStreamPrefix + '-' + (++plan500ModelStreamId);
  let tools;
  try { tools = JSON.parse(options.body).tools; } catch {}
  // Agent turns carry tools; the official first-prompt title request does not.
  const timing = {streamId, kind: Array.isArray(tools) && tools.length > 0 ? 'agent' : 'other', startMs: plan500Now(), chunks: 0, bytes: 0};
  plan500ModelStreams.push(timing);
  if (plan500ModelStreams.length > 64) plan500ModelStreams.shift();
  const aborted = () => signal?.reason ?? new DOMException('The operation was aborted.', 'AbortError');
  // A failure keeps the fixed code in a TypeError, the same kind a lost WebKit fetch throws.
  const failed = code => { timing.failure = code; timing.endMs = plan500Now(); return new TypeError('Load failed (' + code + ')'); };
  let settled = false;
  const cancel = () => {
    if (settled) return;
    settled = true; timing.cancelMs = plan500Now();
    plan500Native('model-cancel', {streamId}).catch(() => {});
  };
  if (signal?.aborted) throw aborted();
  signal?.addEventListener('abort', cancel, {once: true});
  const headers = {};
  new Headers(options.headers).forEach((value, name) => { headers[name] = value; });
  plan500Progress(`${streamId} ${timing.kind} open`);
  const opened = await plan500Native('model-open', {streamId, url, headers, body: options.body});
  plan500Progress(`${streamId} head ${opened.status ?? opened.failure}`);
  if (signal?.aborted) { cancel(); throw aborted(); }
  if (opened.failure) { settled = true; signal?.removeEventListener('abort', cancel); throw failed(opened.failure); }
  timing.status = opened.status; timing.headMs = plan500Now();
  if (opened.status === 200) plan500ModelResponses++;
  const finish = () => {
    settled = true; timing.endMs = plan500Now(); signal?.removeEventListener('abort', cancel);
    plan500Progress(`${streamId} end ${timing.failure ?? 'ok'} chunks ${timing.chunks}`);
  };
  const body = new ReadableStream({
    async pull(controller) {
      const next = await plan500Native('model-read', {streamId});
      if (next.chunk !== undefined) {
        const bytes = plan500Bytes(next.chunk);
        timing.chunks++; timing.bytes += bytes.length;
        timing.firstChunkMs ??= plan500Now(); timing.lastChunkMs = plan500Now();
        controller.enqueue(bytes);
        plan500ModelChunkHook?.(timing);
      } else if (next.done) { finish(); controller.close(); }
      else if (signal?.aborted) { finish(); controller.error(aborted()); }
      else { finish(); controller.error(failed(next.failure)); }
    },
    cancel() { cancel(); },
  });
  return new Response(body, {status: opened.status, headers: opened.headers});
};
// #39 gate 5: a hook runs through the official dsh-hook-protocol runHook (appended to this research Worker,
// exposed as DshHookProtocol) over DshHookShell, which routes it to the Linux path with trigger "hook" and turns
// any command that did not run there into a block with its fixed code, never runHook's non-blocking error branch.
async function plan500RunHook(hook, operationId, signal) {
  const started = performance.now();
  const shell = DshHookShell.create(plan500Native, () => operationId);
  const {output} = await DshHookProtocol.runHook(shell, {command: hook.command, timeoutSec: hook.timeoutSec},
    {payload: hook.payload ?? {hook_event_name: hook.event}, defaultTimeoutMs: 15000, expectedEventName: hook.event, signal},
    () => performance.now());
  const refusal = DshHookShell.notRun(output);
  return {event: hook.event, ran: refusal === null, ...(refusal === null ? {} : {refusal}), exitCode: output.exitCode,
    stdout: output.stdout, decision: output.decision, reason: output.reason, elapsedMs: performance.now() - started};
}
// #39 gate 5: one Git operation as a Linux transaction under the write lease (DshGitWrite, trigger "git").
// `wrap` is research scaffolding around the transaction (a fixture remote); its output goes to stderr.
function plan500GitWrite(data) {
  return DshGitWrite.run(data.argv, {cwd: data.cwd, identity: data.identity, user: data.user}, ({command, network}) => {
    const wrapped = data.wrap ? `${data.wrap.prefix}\n(\n${command})\nc=$?\n{\n${data.wrap.suffix}\n} >&2\nexit $c\n` : command;
    return plan500Native('execute', {command: wrapped, operationId: data.operationId, trigger: 'git', network, timeoutMs: 60000});
  });
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
// #39 gate 4: one official turn. Optionally cancels as the user would once the first body chunk arrived.
// Evidence is redacted: event kinds, fixed codes, delays, order and timings; reply text only as a marker check.
async function plan500ModelTurn(agent, data) {
  const require = host.modules.createRequire('/dsh/config/cordis.yml');
  const {createUserMessage} = require('@deepseek-ai/dsh-llm');
  await host.prototypeContext.get('credentials').set('DEEPSEEK_API_KEY', 'plan500-native-placeholder');
  const events = [], firstStream = plan500ModelStreamId + 1, started = plan500Now();
  const dispose = agent.ctx.on('session/event', (session, event) => { if (session.id === agent.id) events.push(event); });
  // The official UI renders a reply from these transient frames; their timing shows it fills in before the turn ends.
  const live = {chunks: 0, firstMs: null, lastMs: null, endMs: null};
  const disposeLive = agent.ctx.on('agent/assistant-stream', ({frame}) => {
    const at = plan500Now();
    if (frame.type === 'chunk') { live.chunks += 1; live.firstMs ??= at; live.lastMs = at; }
    if (frame.type === 'end') live.endMs = at;
  });
  let cancelledAtMs;
  if (data.cancelAfterFirstChunk) plan500ModelChunkHook = () => {
    plan500ModelChunkHook = undefined;
    // Let the parser hand the chunk to the loop first, so the partial reply is what gets interrupted.
    setTimeout(() => { cancelledAtMs = plan500Now(); agent.cancel({kind: 'user'}); }, data.cancelDelayMs ?? 300);
  };
  const timeout = setTimeout(() => agent.cancel({kind: 'user'}), data.timeoutMs ?? 120000);
  try {
    agent.followup(createUserMessage({source: {kind: 'user', rpcId: 'plan500-gate4'}, content: [{type: 'text', text: data.prompt}]}));
    await agent.whenIdle();
  } finally { clearTimeout(timeout); dispose(); disposeLive(); plan500ModelChunkHook = undefined; }
  const end = events.filter(x => x.type === 'turn/end').at(-1)?.data;
  const replies = events.filter(x => x.type === 'assistant/message').map(x => ({interrupted: x.data.interrupted === true,
    marker: (x.data.message?.content ?? []).some(c => c.type === 'text' && c.text.includes(data.marker ?? 'GATE4_OK')),
    textChars: (x.data.message?.content ?? []).filter(c => c.type === 'text').reduce((n, c) => n + c.text.length, 0)}));
  return {
    elapsedMs: plan500Now() - started, cancelledAtMs, live,
    turnEnd: {kind: end?.reason?.kind, code: end?.reason?.error?.code},
    retries: events.filter(x => x.type === 'llm/retry').map(x => ({retry: x.data.retry, delayMs: x.data.delayMs, code: x.data.failure?.code})),
    retriesStarted: events.filter(x => x.type === 'llm/retry-started').length,
    attempts: events.filter(x => x.type === 'assistant/attempt').length,
    replies, toolCalls: events.filter(x => x.type === 'tool/call').map(x => x.data.name),
    toolResults: events.filter(x => x.type === 'tool/result').map(x => ({isError: x.data.message?.isError === true})),
    order: events.map(x => x.type).filter(x => /^(tool\/|turn\/end|llm\/retry|assistant\/)/.test(x)),
    streams: plan500ModelStreams.filter(x => Number(x.streamId.split('-').at(-1)) >= firstStream).map(x => ({...x})),
  };
}
prototypeMessage = async event => {
  const data = event.data;
  if (!['bridge-install', 'bridge-tool', 'bridge-hook', 'gate5-git', 'home-snapshot', 'model-run', 'model-turn'].includes(data.operation)) return plan500OriginalMessage(event);
  try {
    const ctx = host.prototypeContext;
    const agent = data.sessionId ? ctx.get('agents').get(data.sessionId) : undefined;
    let result;
    if (data.operation === 'bridge-hook') {
      result = await plan500RunHook(data.hook, data.operationId);
    } else if (data.operation === 'gate5-git') {
      result = await plan500GitWrite(data);
    } else if (data.operation === 'home-snapshot') {
      await ctx.get('sessionPersistence').flush();
      const snapshot = prototypeSnapshot(host.vfs);
      snapshot.files = snapshot.files.filter(x => x.path.startsWith('/dsh/home/'));
      snapshot.directories = snapshot.directories.filter(x => x.path === '/dsh/home' || x.path.startsWith('/dsh/home/'));
      result = snapshot;
    } else {
      if (!agent) throw new Error('AGENT_NOT_OPEN');
      const tools = agent.ctx.get('tools');
      if (data.operation === 'model-turn') {
        result = await plan500ModelTurn(agent, data);
      } else if (data.operation === 'model-run') {
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
              // Only the shell trigger: a model call never picks the hook or Git path or the Git token.
              return await plan500Native('execute', {command: args.command, timeoutMs: args.timeoutMs, operationId});
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
