const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {Writable, Readable} = require('node:stream');
const {createRequire} = require('node:module');
const tar = createRequire(path.join(process.env.HARNESS_NPM_ROOT, 'package.json'))('tar');
const {BackupManager, recoverRestore} = require('../guest/backup.cjs');
(async () => {
  const base=fs.mkdtempSync(path.join(os.tmpdir(),'backup-test-'));
  const source=path.join(base,'source'), target=path.join(base,'target');
  for (const root of [source,target]) {
    fs.mkdirSync(path.join(root,'projects','demo'),{recursive:true});
    fs.writeFileSync(path.join(root,'.harness-layout-version'),'1\n');
    fs.writeFileSync(path.join(root,'projects/demo/file'),root===source ? 'backup project' : 'original project');
  }
  fs.mkdirSync(path.join(source,'.dsh')); fs.writeFileSync(path.join(source,'.dsh/state.json'),'{"session":"preserved"}');
  for (const name of ['node_modules','.cache']) { fs.mkdirSync(path.join(source,'projects/demo',name)); fs.writeFileSync(path.join(source,'projects/demo',name,'excluded'),'exclude'); }
  fs.writeFileSync(path.join(source,'.git-credentials'),'never-export');
  fs.writeFileSync(path.join(source,'projects/demo/.git-credentials'),'never-export-nested');
  fs.writeFileSync(path.join(source,'projects/demo/.restore-notes'),'user-owned notes');
  fs.mkdirSync(path.join(source,'.trash/.purging-removed'),{recursive:true});
  fs.writeFileSync(path.join(source,'.trash/.purging-removed/deleted'),'never resurrect');
  const calls=[];
  const coordinator={pause:async()=>{calls.push('pause');return 'test-lease';},resume:async()=>{calls.push('resume');}};
  const freeze=async()=>{calls.push('freeze');return async()=>{calls.push('thaw');};};
  try {
    const manager=new BackupManager({root:source,tar,coordinator,freeze});
    const chunks=[];
    await manager.export(new Writable({write(chunk,_encoding,callback){chunks.push(chunk); callback();}}),{started:()=>calls.push('started')});
    const archive=Buffer.concat(chunks);
    assert.deepEqual(calls,['pause','started','freeze','thaw','resume']);
    const archiveFile=path.join(base,'backup.tar');fs.writeFileSync(archiveFile,archive);
    const names=[];await tar.t({file:archiveFile,onentry:entry=>names.push(entry.path)});
    assert.ok(names.includes('.dsh/state.json'));assert.ok(!names.some(name=>name.includes('node_modules')||name.includes('.cache')||name.includes('.git-credentials')));
    assert.ok(names.includes('projects/demo/.restore-notes'));
    assert.ok(!names.some(name=>name.startsWith('.trash/.purging-')));
    calls.length=0;
    const restored=new BackupManager({root:target,tar,coordinator,freeze});
    await restored.restore(Readable.from(archive));
    assert.equal(fs.readFileSync(path.join(target,'projects/demo/file'),'utf8'),'backup project');
    assert.equal(fs.readFileSync(path.join(target,'projects/demo/.restore-notes'),'utf8'),'user-owned notes');
    assert.equal(fs.readFileSync(path.join(target,'.dsh/state.json'),'utf8'),'{"session":"preserved"}');
    const original=fs.readdirSync(target).find(name=>name.startsWith('.restore-original-'));
    assert.equal(fs.readFileSync(path.join(target,original,'projects/demo/file'),'utf8'),'original project');
    await assert.rejects(restored.restore(Readable.from(Buffer.from('bad tar'))));
    assert.equal(fs.readFileSync(path.join(target,'projects/demo/file'),'utf8'),'backup project');
    const hostile=path.join(base,'hostile');fs.mkdirSync(hostile);
    fs.symlinkSync('/tmp/escape-outside-backup',path.join(hostile,'bad-link'));
    const hostileFile=path.join(base,'hostile.tar');
    await tar.c({cwd:hostile,file:hostileFile},['bad-link']);
    await assert.rejects(restored.restore(Readable.from(fs.readFileSync(hostileFile))));
    assert.equal(fs.readFileSync(path.join(target,'projects/demo/file'),'utf8'),'backup project');
    const broken=new BackupManager({root:target,tar,coordinator,freeze,afterMove:()=>{throw Error('simulated rename failure');}});
    await assert.rejects(broken.restore(Readable.from(archive)));
    assert.equal(fs.readFileSync(path.join(target,'projects/demo/file'),'utf8'),'backup project');
    // A killed App mid-transaction is rolled back on cold boot before Harness opens.
    const id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', stage='.restore-stage-'+id, old='.restore-original-'+id;
    fs.mkdirSync(path.join(target,stage));fs.mkdirSync(path.join(target,old));
    fs.writeFileSync(path.join(target,'.harness-restore.json'),JSON.stringify({id,oldNames:['projects'],newNames:['projects']}));
    fs.renameSync(path.join(target,'projects'),path.join(target,old,'projects'));
    fs.mkdirSync(path.join(target,'projects'));fs.writeFileSync(path.join(target,'projects/partial'),'partial');
    recoverRestore(target);
    assert.equal(fs.readFileSync(path.join(target,'projects/demo/file'),'utf8'),'backup project');
    assert.equal(fs.existsSync(path.join(target,'.harness-restore.json')),false);
    // A post-commit Harness launch failure is reported as restored data,
    // not as a failed transaction that claims the live filesystem was unchanged.
    const noRestart=new BackupManager({root:target,tar,freeze,coordinator:{pause:async()=> 'lease',resume:async()=>{throw Error('launch failed');}}});
    const receipt=await noRestart.restore(Readable.from(archive));
    assert.equal(receipt.restored,true);assert.equal(receipt.harnessRunning,false);
    assert.equal(fs.readFileSync(path.join(target,'projects/demo/file'),'utf8'),'backup project');
    console.log('PASS:backup');
  } finally {fs.rmSync(base,{recursive:true,force:true});}
})().catch(error=>{console.error(error);process.exitCode=1;});
