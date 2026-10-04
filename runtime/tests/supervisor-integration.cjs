const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const {HarnessSupervisor} = require('../guest/supervisor.cjs');
(async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'supervisor-'));
  const writer = path.join(root, 'writer.cjs'), output = path.join(root, 'writes');
  await fs.writeFile(writer, `const fs=require('node:fs'); setInterval(()=>fs.appendFileSync(process.argv[2], 'x'), 10);`);
  let failGrowth=true;
  const supervisor = new HarnessSupervisor({root, executable: process.execPath, arguments: [writer, output], stdio: 'ignore',
    diskCapacityBytes:()=>8*1024**3,
    growFilesystem:async bytes=> { if(failGrowth) throw Error('RESIZE_FAILED'); return {capacityBytes:bytes}; }
  });
  try {
    assert.equal(supervisor.health().running, false);
    await supervisor.restart();
    await new Promise(r => setTimeout(r, 100));
    assert.equal(supervisor.health().running, true);
    const first = supervisor.pid;
    await supervisor.restart();
    assert.equal(supervisor.pid, first, 'Live Harness must not be restarted');
    const growth=supervisor.beginGrowth(16*1024**3);
    await assert.rejects(supervisor.pause(),/BUSY/,'Backup must not freeze a growing filesystem');
    await assert.rejects(supervisor.finishGrowth('wrong'),/LEASE/);
    await assert.rejects(supervisor.finishGrowth(growth),/RESIZE_FAILED/);
    assert.equal(supervisor.pid,first,'Online growth must retain the running Harness');
    failGrowth=false;
    const retry=supervisor.beginGrowth(16*1024**3);
    assert.equal((await supervisor.finishGrowth(retry)).capacityBytes,16*1024**3);
    assert.throws(()=>supervisor.beginGrowth(4*1024**3),/SIZE/);
    assert.throws(()=>supervisor.beginGrowth(65*1024**3),/SIZE/);
    const abandoned=supervisor.beginGrowth(16*1024**3);
    supervisor.cancelGrowth(abandoned);
    const lease = await supervisor.pause();
    assert.throws(()=>supervisor.beginGrowth(16*1024**3),/BUSY/,'Growth must not run during backup');
    assert.equal(supervisor.health().leased,true);
    assert.equal(supervisor.health().writable,false,'A leased/frozen filesystem must not be probed by writing');
    const paused = (await fs.readFile(output)).length;
    await new Promise(r => setTimeout(r, 50));
    assert.equal((await fs.readFile(output)).length, paused, 'Backup begins only after the writer exits');
    await assert.rejects(supervisor.restart(), /BUSY/);
    await assert.rejects(supervisor.resume('wrong-lease'), /LEASE/);
    await supervisor.resume(lease);
    assert.equal(supervisor.health().running, true);
    assert.notEqual(supervisor.pid, first);
    await supervisor.pause();
    await fs.rm(root, {recursive:true, force:true});
    assert.equal(supervisor.health().writable, false);
  } finally { await supervisor.close(); await fs.rm(root, {recursive:true, force:true}); }
  console.log('PASS:supervisor');
})().catch(error => { console.error(error); process.exitCode=1; });
