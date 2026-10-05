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
const plan500OriginalMessage = prototypeMessage;
const plan500Installed = new Set();
prototypeMessage = async event => {
  const data = event.data;
  if (!['bridge-install', 'bridge-tool', 'home-snapshot', 'model-run'].includes(data.operation)) return plan500OriginalMessage(event);
  try {
    const ctx = host.prototypeContext;
    const agent = data.sessionId ? ctx.get('agents').get(data.sessionId) : undefined;
    let result;
    if (data.operation === 'home-snapshot') {
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
        const calls = new Map(), results = [], replies = [];
        const dispose = agent.ctx.on('session/event', (session, event) => {
          if (session.id !== agent.id) return;
          if (event.type === 'tool/call') calls.set(event.data.callId, event.data.name);
          if (event.type === 'tool/result') {
            const message = event.data.message;
            let value;
            try { value = JSON.parse(message.content[0]?.text); } catch {}
            results.push({name: calls.get(message.toolCallId), isError: message.isError === true,
              status: value?.status, code: value?.result?.code, stdout: value?.result?.stdout,
              writerQuiescent: value?.result?.writerQuiescent});
          }
          if (event.type === 'assistant/message') replies.push(...event.data.content ?? []);
        });
        const timeout = setTimeout(() => agent.cancel({kind: 'user'}), 240000);
        try {
          agent.followup(createUserMessage({source: {kind: 'user', rpcId: 'plan500-real-model'}, content: [{type: 'text', text:
            'This is an isolated native/Linux integration check. Only use plan500_read, plan500_write and plan500_linux. Read math.cjs and test.cjs from the native workspace. Fix the subtraction bug so add(2,3) returns 5, write math.cjs using the read version, then run node test.cjs through plan500_linux. Do not edit test.cjs. Do not claim success without exit code 0 and MODEL_TEST_OK in Linux stdout. Give a brief Chinese final result including that actual test result.'}]}));
          await agent.whenIdle();
          result = {http200Responses: plan500ModelResponses, tools: results,
            assistantReturned: replies.some(x => x.type === 'text' && x.text?.length > 0)};
        } finally { clearTimeout(timeout); dispose(); }
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
          execute: args => plan500Native('write', args)}));
        tools.register(defineTool({...common, name: 'plan500_linux',
          description: 'Run a Linux shell command in /workspace, the exact same native project directory. Waits for real Linux ready. Returns stdout, stderr, exit code and writer quiescence. Bounded to 30 seconds.',
          parameters: {command: {type: 'string', required: true}, timeoutMs: {type: 'integer'}},
          async execute(args, exec) {
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
