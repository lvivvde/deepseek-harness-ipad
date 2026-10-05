// Throwaway readiness model. prepare/execute are injected, NOT a real Linux VM.
import assert from 'node:assert/strict';
import {writeFileSync} from 'node:fs';
const checks = [];
const mark = name => checks.push({name, passed: true});
class ProjectGate {
  state = 'disabled'; operations = new Map(); ready = Promise.withResolvers();
  constructor(prepare) { this.prepare = prepare; this.ready.promise.catch(() => {}); }
  open(enabled) {
    if (!enabled || this.state !== 'disabled') return;
    this.state = 'preparing';
    Promise.resolve().then(this.prepare).then(() => {
      if (this.state !== 'preparing') return;
      this.state = 'ready'; this.ready.resolve();
    }, error => {
      if (this.state !== 'preparing') return;
      this.state = 'failed'; this.ready.reject(error);
    });
  }
  close() { this.state = 'closed'; this.ready.reject(new Error('PROJECT_CLOSED')); }
  request(id, execute, {signal, timeoutMs = 200} = {}) {
    if (this.operations.has(id)) return this.operations.get(id);
    const run = async () => {
      if (this.state === 'disabled' || this.state === 'closed') throw new Error('CAPABILITY_UNAVAILABLE');
      let timer;
      const cancelled = Promise.withResolvers();
      const abort = () => cancelled.reject(new Error('CANCELLED'));
      if (signal?.aborted) abort(); else signal?.addEventListener('abort', abort, {once: true});
      try {
        await Promise.race([this.ready.promise, cancelled.promise,
          new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('PREPARE_TIMEOUT')), timeoutMs); })]);
        if (signal?.aborted || this.state !== 'ready') throw new Error('CANCELLED');
        return await execute(signal);
      } finally { clearTimeout(timer); signal?.removeEventListener('abort', abort); }
    };
    const promise = run(); this.operations.set(id, promise); return promise;
  }
}
const completion = Promise.withResolvers();
let preparations = 0, effects = 0;
const gate = new ProjectGate(async () => { preparations++; await completion.promise; });
gate.open(true); gate.open(true);
await Promise.resolve();
assert.equal(preparations, 1); mark('project open immediately starts one shared preparation');
const first = gate.request('commit-1', async () => { effects++; return 'committed'; });
assert.equal(gate.request('commit-1', () => { throw new Error('REPLAY'); }), first);
assert.equal(effects, 0);
let nativeWrites = 0;
await (async () => { nativeWrites++; })();
assert.equal(nativeWrites, 1); assert.equal(effects, 0);
mark('Linux request waits and independent native action remains possible');
const controller = new AbortController();
const cancelled = gate.request('cancelled', () => { effects += 100; }, {signal: controller.signal});
controller.abort(); await assert.rejects(cancelled, /CANCELLED/);
completion.resolve(); assert.equal(await first, 'committed');
assert.equal(effects, 1); mark('ready resumes once; duplicate and cancelled requests never replay');
const late = Promise.withResolvers();
const timed = new ProjectGate(() => late.promise); timed.open(true);
await assert.rejects(timed.request('timeout', () => { effects += 100; }, {timeoutMs: 5}), /PREPARE_TIMEOUT/);
late.resolve(); await Promise.resolve(); await Promise.resolve();
assert.equal(effects, 1); mark('timed-out request never runs on later readiness');
const failed = new ProjectGate(() => { throw new Error('LINUX_PREPARE_FAILED'); }); failed.open(true);
await assert.rejects(failed.request('required-hook', () => { effects += 100; }), /LINUX_PREPARE_FAILED/);
assert.equal(effects, 1); mark('failed preparation prevents required hook and Git effects');
const closing = new ProjectGate(() => new Promise(() => {})); closing.open(true);
const closed = closing.request('closed', () => { effects += 100; }); closing.close();
await assert.rejects(closed, /PROJECT_CLOSED/);
assert.equal(effects, 1); mark('project close rejects queued work without execution');
const disabled = new ProjectGate(() => { preparations += 100; }); disabled.open(false);
await assert.rejects(disabled.request('disabled', () => {}), /CAPABILITY_UNAVAILABLE/);
assert.equal(preparations, 1); mark('disabled capability never starts preparation');
const receipt = {passed: true, realLinuxVMVerified: false, checks};
writeFileSync('build/prototypes/plan500-worker/gate-safe.json', JSON.stringify(receipt, null, 2) + '\n');
console.log(JSON.stringify(receipt));
