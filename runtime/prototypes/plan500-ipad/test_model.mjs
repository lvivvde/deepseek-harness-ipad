import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {createContext, runInContext, runInNewContext} from 'node:vm';
import {test} from 'node:test';

const scope = {self: {addEventListener() {}}, prototypeMessage() {}, fetch() {}};
runInNewContext(readFileSync(new URL('./web/worker-bridge.js', import.meta.url), 'utf8'), scope);
const call = (id, name, args) => ({type: 'tool/call', data: {turn: 1, callId: id, name, arguments: JSON.stringify(args)}});
const result = (id, value) => ({type: 'tool/result', data: {turn: 1, message: {toolCallId: id, content: [{text: JSON.stringify(value)}]}}});
const reply = {type: 'assistant/message', data: {turn: 1, message: {content: [{type: 'text', text: '测试成功：MODEL_TEST_OK，退出码 0。'}]}}};
const end = kind => ({type: 'turn/end', data: {turn: 1, reason: {kind}}});
function events(command = 'node test.cjs', path = 'math.cjs') {
  return [call('w', 'plan500_write', {path, text: 'module.exports = (a,b) => a+b;', base: 'version'}),
    result('w', {status: 'WRITTEN'}), call('l', 'plan500_linux', {command}),
    result('l', {status: 'RELEASED', result: {code: 0, stdout: 'MODEL_TEST_OK\n', writerQuiescent: true}}), reply, end('completed')];
}
test('accepts ordered native fix, real test, post-test final reply and completed turn', () => {
  const proof = scope.plan500ModelEvidence(events());
  assert.equal(proof.nativeFix, true); assert.equal(proof.linuxTest, true); assert.equal(proof.assistantReturned, true);
  assert.equal(proof.trace[1].exactTestCommand, true);
});
test('refuses marker-only command and writing the test instead of the source', () => {
  assert.equal(scope.plan500ModelEvidence(events('printf MODEL_TEST_OK')).linuxTest, false);
  assert.equal(scope.plan500ModelEvidence(events('node test.cjs', 'test.cjs')).nativeFix, false);
});
test('refuses temporary test replacement even when the original is restored afterward', () => {
  const original = events();
  const replaced = [original[0], original[1], call('fake', 'plan500_write', {path: 'test.cjs', text: "console.log('MODEL_TEST_OK')"}),
    result('fake', {status: 'WRITTEN'}), original[2], original[3],
    call('restore', 'plan500_write', {path: 'test.cjs', text: 'original assertions'}), result('restore', {status: 'WRITTEN'}), reply, end('completed')];
  assert.equal(scope.plan500ModelEvidence(replaced).linuxTest, false);
});
test('refuses commentary before tools, interrupted reply, and failed turn', () => {
  const early = [reply, ...events().filter(x => x !== reply)];
  assert.equal(scope.plan500ModelEvidence(early).assistantReturned, false);
  const interrupted = events().map(x => x === reply ? {...reply, data: {...reply.data, interrupted: true}} : x);
  assert.equal(scope.plan500ModelEvidence(interrupted).assistantReturned, false);
  const failed = events(); failed[failed.length - 1] = end('error');
  assert.equal(scope.plan500ModelEvidence(failed).assistantReturned, false);
});
test('refuses test before the saved source edit and unconfirmed writer drain', () => {
  const original = events();
  assert.equal(scope.plan500ModelEvidence([original[2], original[3], original[0], original[1], reply, end('completed')]).linuxTest, false);
  const active = events(); active[3] = result('l', {status: 'WRITER_UNKNOWN', result: {code: 0, stdout: 'MODEL_TEST_OK', writerQuiescent: false}});
  assert.equal(scope.plan500ModelEvidence(active).linuxTest, false);
});
test('failure trace explains rejection without file text, commands or stdout', () => {
  const refusedFirst = [call('x', 'plan500_linux', {command: 'cd /workspace && node test.cjs'}),
    {type: 'tool/result', data: {turn: 1, message: {toolCallId: 'x', isError: true, content: [{text: 'Error: MODEL_TEST_COMMAND_REFUSED'}]}}},
    ...events()];
  const proof = scope.plan500ModelEvidence(refusedFirst);
  assert.equal(proof.linuxTest, true); assert.equal(proof.boundedCalls, true);
  assert.deepEqual(JSON.parse(JSON.stringify(proof.trace)), [
    {name: 'plan500_linux', turn: 1, callOrder: 0, resultOrder: 1, isError: true, errorCode: 'MODEL_TEST_COMMAND_REFUSED', exactTestCommand: false},
    {name: 'plan500_write', turn: 1, callOrder: 2, resultOrder: 3, isError: false, status: 'WRITTEN', fixturePath: true},
    {name: 'plan500_linux', turn: 1, callOrder: 4, resultOrder: 5, isError: false, status: 'RELEASED', code: 0,
      markerSeen: true, writerQuiescent: true, exactTestCommand: true}]);
  const serialized = JSON.stringify(proof.trace);
  for (const leaked of ['a+b', 'cd /workspace', 'MODEL_TEST_OK\\n']) assert.equal(serialized.includes(leaked), false);
});
test('bridge-refused out-of-scope attempts are allowed, executed or other failures are not', () => {
  const refused = (id, name, args, code) => [call(id, name, args),
    {type: 'tool/result', data: {turn: 1, message: {toolCallId: id, isError: true, content: [{text: 'Error: ' + code}]}}}];
  const ok = [...refused('x', 'plan500_write', {path: 'test.cjs', text: 'fake'}, 'MODEL_FIXTURE_WRITE_REFUSED'), ...events()];
  assert.equal(scope.plan500ModelEvidence(ok).assistantReturned, true);
  const otherError = [...refused('x', 'plan500_linux', {command: 'ls'}, 'LINUX_NOT_READY'), ...events()];
  assert.equal(scope.plan500ModelEvidence(otherError).linuxTest, false);
  const wrongCode = [...refused('x', 'plan500_write', {path: 'test.cjs', text: 'fake'}, 'MODEL_TEST_COMMAND_REFUSED'), ...events()];
  assert.equal(scope.plan500ModelEvidence(wrongCode).linuxTest, false);
  const unanswered = [call('x', 'plan500_linux', {command: 'ls'}), ...events()];
  assert.equal(scope.plan500ModelEvidence(unanswered).linuxTest, false);
});
test('refusal and trace codes are exact allowlisted texts, never echoed content', () => {
  const failed = (id, name, args, text) => [call(id, name, args),
    {type: 'tool/result', data: {turn: 1, message: {toolCallId: id, isError: true, content: [{text}]}}}];
  const echoed = [...failed('x', 'plan500_linux', {command: 'ls'}, 'Invalid timeoutMs: MODEL_TEST_COMMAND_REFUSED'), ...events()];
  const proof = scope.plan500ModelEvidence(echoed);
  assert.equal(proof.boundedCalls, false); assert.equal(proof.trace[0].errorCode, 'OTHER');
  const leaky = scope.plan500ModelEvidence([...failed('y', 'plan500_read', {path: 'x'}, 'Error: SECRET_TOKEN_FROM_FILE'), ...events()]);
  assert.equal(leaky.trace[0].errorCode, 'OTHER'); assert.equal(JSON.stringify(leaky.trace).includes('SECRET'), false);
});
test('unknown tools and reused call ids are out of scope', () => {
  assert.equal(scope.plan500ModelEvidence([call('z', 'shell', {command: 'ls'}), result('z', {}), ...events()]).linuxTest, false);
  const reused = [...events().slice(0, 4), call('l', 'plan500_linux', {command: 'node test.cjs'}), ...events().slice(4)];
  assert.equal(scope.plan500ModelEvidence(reused).boundedCalls, false);
});
test('model evidence exposes only the redacted trace and a reply count', () => {
  const proof = scope.plan500ModelEvidence(events());
  assert.equal('tools' in proof, false); assert.equal(proof.replyCount, 1);
  assert.equal(JSON.stringify(proof).includes('a+b'), false);
});

// #39 gate 4: the streaming fetch shim, driven by a scripted native side.
function shim(handlers) {
  const sent = [], original = [];
  const context = {
    Headers, ReadableStream, Response, DOMException, TextDecoder, atob, performance, AbortController,
    prototypeMessage() {}, fetch: (...args) => { original.push(args); return 'ORIGINAL'; },
    self: {
      postMessage: message => {
        sent.push(message);
        Promise.resolve(handlers[message.operation]?.(message.payload)).then(result =>
          context.self.plan500NativeReply({t: 'plan500-native-reply', id: message.id, result: result ?? {}}));
      },
    },
  };
  createContext(context);
  runInContext(readFileSync(new URL('./web/worker-bridge.js', import.meta.url), 'utf8'), context);
  // Top-level let/const of the bridge are lexical, so read and set them inside the context.
  const streams = () => runInContext('plan500ModelStreams', context);
  const hook = fn => { context.plan500TestHook = fn; runInContext('plan500ModelChunkHook = plan500TestHook', context); };
  return {fetch: context.fetch, sent, original, streams, hook};
}
const official = 'https://api.deepseek.com/anthropic/v1/messages';
const b64 = text => Buffer.from(text).toString('base64');
const reads = parts => { const queue = [...parts]; return () => queue.shift() ?? {done: true}; };

test('streams body chunks in arrival order with status and headers', async () => {
  const hooked = [];
  const native = shim({
    'model-open': () => ({status: 200, headers: {'content-type': 'text/event-stream', 'x-request-id': 'r1'}}),
    'model-read': reads([{chunk: b64('event: a\n')}, {chunk: b64('data: 中文\n\n')}]),
  });
  native.hook(timing => hooked.push(timing.chunks));
  const response = await native.fetch(official, {method: 'POST', body: '{"tools":[{}]}',
    headers: {'x-api-key': 'plan500-native-placeholder', 'content-type': 'application/json'}});
  assert.equal(response.status, 200);
  assert.equal(response.headers.get('x-request-id'), 'r1');
  assert.equal(await response.text(), 'event: a\ndata: 中文\n\n');
  const open = native.sent.find(x => x.operation === 'model-open').payload;
  assert.equal(open.url, official); assert.equal(open.headers['content-type'], 'application/json');
  const timing = native.streams().at(-1);
  assert.equal(timing.chunks, 2); assert.equal(timing.kind, 'agent'); assert.ok(timing.firstChunkMs <= timing.lastChunkMs);
  assert.ok(hooked.length >= 1);
});
test('non-ok response keeps its body for the official error path', async () => {
  const native = shim({'model-open': () => ({status: 429, headers: {'retry-after': '1'}}),
    'model-read': reads([{chunk: b64('{"error":"rate"}')}])});
  const response = await native.fetch(official, {method: 'POST', body: '{}'});
  assert.equal(response.ok, false); assert.equal(response.headers.get('retry-after'), '1');
  assert.equal(await response.text(), '{"error":"rate"}');
});
test('open failure throws a TypeError carrying only the fixed code', async () => {
  const native = shim({'model-open': () => ({failure: 'MODEL_OFFLINE'})});
  await assert.rejects(native.fetch(official, {method: 'POST', body: '{}'}),
    error => error.name === 'TypeError' && error.message === 'Load failed (MODEL_OFFLINE)');
  assert.equal(native.streams().at(-1).failure, 'MODEL_OFFLINE');
});
test('mid-stream failure errors the body after the delivered bytes, never a clean end', async () => {
  const native = shim({'model-open': () => ({status: 200, headers: {}}),
    'model-read': reads([{chunk: b64('partial')}, {failure: 'MODEL_DISCONNECTED'}])});
  const reader = (await native.fetch(official, {method: 'POST', body: '{}'})).body.getReader();
  assert.equal(new TextDecoder().decode((await reader.read()).value), 'partial');
  await assert.rejects(reader.read(), error => error.name === 'TypeError' && error.message.includes('MODEL_DISCONNECTED'));
});
test('abort cancels the native request and the body rejects as aborted', async () => {
  let release;
  const native = shim({'model-open': () => ({status: 200, headers: {}}),
    'model-read': () => new Promise(resolve => { release = resolve; }),
    'model-cancel': () => { release({failure: 'MODEL_CANCELLED'}); return {cancelled: true}; }});
  const controller = new AbortController();
  const reader = (await native.fetch(official, {method: 'POST', body: '{}', signal: controller.signal})).body.getReader();
  const pending = reader.read();
  await new Promise(resolve => setTimeout(resolve, 10));
  controller.abort();
  await assert.rejects(pending, error => error.name === 'AbortError');
  assert.equal(native.sent.filter(x => x.operation === 'model-cancel').length, 1);
  assert.ok(native.streams().at(-1).cancelMs !== undefined);
});
test('an already aborted request never reaches native and other URLs keep the original fetch', async () => {
  const native = shim({});
  const controller = new AbortController(); controller.abort();
  await assert.rejects(native.fetch(official, {method: 'POST', body: '{}', signal: controller.signal}), error => error.name === 'AbortError');
  assert.equal(native.sent.length, 0);
  assert.equal(await native.fetch('https://example.invalid/x', {}), 'ORIGINAL');
  assert.equal(native.original.length, 1);
});
test('stream evidence carries no body bytes or header values', async () => {
  const native = shim({'model-open': () => ({status: 200, headers: {'x-request-id': 'SECRET_REQ'}}),
    'model-read': reads([{chunk: b64('SECRET_BODY')}])});
  await (await native.fetch(official, {method: 'POST', body: '{"messages":"SECRET_PROMPT"}', headers: {'x-api-key': 'SECRET_KEY'}})).text();
  assert.equal(/SECRET/.test(JSON.stringify(native.streams())), false);
});
