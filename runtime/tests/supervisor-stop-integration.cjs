const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const {HarnessSupervisor} = require('../guest/supervisor.cjs');
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
// dsh blocks its event loop while starting on a slow CPU, so SIGTERM can take far longer than other writers.
const slowExit = `process.on('SIGTERM',()=>{const end=Date.now()+Number(process.argv[1]);while(Date.now()<end){} process.exit(0);});setInterval(()=>{},1000);`;
const ignoresTerm = `process.on('SIGTERM',()=>{});setInterval(()=>{},1000);`;
const leavesWriter = `require('node:child_process').spawn(process.execPath,['-e',${JSON.stringify(ignoresTerm)}],{stdio:'ignore'});setInterval(()=>{},1000);`;

async function stopWith(script, extra, options) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'supervisor-stop-'));
  const supervisor = new HarnessSupervisor({root, executable: process.execPath, arguments: ['-e', script, ...extra], stdio: 'ignore', ...options});
  try {
    await supervisor.restart();
    await delay(300);
    supervisor.capture();
    const started = Date.now();
    const outcome = await supervisor.pause().then(() => 'PAUSED', error => error.message);
    return {outcome, elapsed: Date.now() - started};
  } finally {
    for (const pid of [supervisor.pid, ...supervisor.owned.keys()]) { try { process.kill(pid, 'SIGKILL'); } catch {} }
    clearInterval(supervisor.tracker); clearTimeout(supervisor.timer);
    await fs.rm(root, {recursive: true, force: true});
  }
}

(async () => {
  const slow = await stopWith(slowExit, ['1000'], {stopTimeoutMs: 300, childExitTimeoutMs: 5000});
  assert.equal(slow.outcome, 'PAUSED', 'A Harness that is still exiting after SIGTERM must be waited for');
  assert.ok(slow.elapsed >= 900, `paused before Harness exited (${slow.elapsed} ms)`);

  const stuck = await stopWith(ignoresTerm, [], {stopTimeoutMs: 300, childExitTimeoutMs: 800});
  assert.equal(stuck.outcome, 'WRITERS_BUSY', 'A Harness that never exits must not be killed');
  assert.ok(stuck.elapsed >= 750 && stuck.elapsed < 3000, `child wait not bounded (${stuck.elapsed} ms)`);

  // Descendant writers are found through /proc, as in the guest.
  if (require('node:fs').existsSync('/proc/self/stat')) {
    const writer = await stopWith(leavesWriter, [], {stopTimeoutMs: 300, childExitTimeoutMs: 5000});
    assert.equal(writer.outcome, 'WRITERS_BUSY', 'Another writer ignoring SIGTERM must still refuse the backup');
    assert.ok(writer.elapsed < 2000, `the longer Harness wait must not apply to other writers (${writer.elapsed} ms)`);
  }
  console.log('PASS:supervisor-stop');
})().catch(error => { console.error(error); process.exitCode = 1; });
