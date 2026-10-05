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
  assert.equal(proof.tools[1].args.command, 'node test.cjs');
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
