import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {runInNewContext} from 'node:vm';
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
