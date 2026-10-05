const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const {spawn, execFile, execFileSync} = require('node:child_process');
const {promisify} = require('node:util');
const run = promisify(execFile);
const {pipeline} = require('node:stream/promises');
const {supervisorRequest} = require('./supervisor.cjs');
const excluded = new Set(['node_modules','.cache','.git-credentials']);
const reserved = name => ['.harness-restore.json','.harness-restore.tmp'].includes(name) || name.startsWith('.restore-') || name.startsWith('.harness-write-probe-');
const validName = name => !!name && name !== '.' && name !== '..' && !/[\/\x00-\x1f]/.test(name);
const uuid = value => /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(value);
function syncDirectory(directory) { const fd=fs.openSync(directory,'r'); try {fs.fsyncSync(fd);} finally {fs.closeSync(fd);} }
function journal(root, record) {
  const temporary=path.join(root,'.harness-restore.tmp');
  const fd=fs.openSync(temporary,'w',0o600);
  try {fs.writeFileSync(fd,JSON.stringify(record));fs.fsyncSync(fd);} finally {fs.closeSync(fd);}
  fs.renameSync(temporary,path.join(root,'.harness-restore.json'));syncDirectory(root);
}
function recoverRestore(root) {
  const file=path.join(root,'.harness-restore.json');
  if (!fs.existsSync(file)) return;
  const record=JSON.parse(fs.readFileSync(file,'utf8'));
  if (!uuid(record.id) || !Array.isArray(record.oldNames) || !Array.isArray(record.newNames) ||
      ![...record.oldNames,...record.newNames].every(name=>validName(name)&&!reserved(name))) throw Error('RESTORE_JOURNAL_INVALID');
  const old=path.join(root,'.restore-original-'+record.id), stage=path.join(root,'.restore-stage-'+record.id);
  for (const name of record.newNames) {
    // Before an old name moves, its live path is still the good original.
    const oldMoved=fs.existsSync(path.join(old,name));
    const newOnlyMoved=!record.oldNames.includes(name) && !fs.existsSync(path.join(stage,name));
    if (oldMoved || newOnlyMoved) fs.rmSync(path.join(root,name),{recursive:true,force:true});
  }
  for (const name of record.oldNames) if (fs.existsSync(path.join(old,name))) {
    fs.rmSync(path.join(root,name),{recursive:true,force:true});
    fs.renameSync(path.join(old,name),path.join(root,name));
  }
  syncDirectory(root);
  fs.rmSync(stage,{recursive:true,force:true});fs.rmSync(old,{recursive:true,force:true});
  fs.unlinkSync(file);syncDirectory(root);
}
async function freezeFilesystem(root) {
  // This independent process thaws ext4 if the transfer process is killed.
  const watchdog=spawn(process.execPath,['-e',
    "setTimeout(()=>{require('node:child_process').execFileSync('/bin/busybox',['fsfreeze','--unfreeze',process.argv[1]],{stdio:'ignore'});},600000);",root],
    {stdio:'ignore',detached:true,env:{...process.env,NODE_OPTIONS:'',NODE_COMPILE_CACHE:''}});
  await new Promise((resolve,reject)=>{watchdog.once('spawn',resolve);watchdog.once('error',reject);});
  const stopped=new Promise(resolve=>watchdog.once('exit',resolve));
  const stopWatchdog=async()=>{watchdog.kill();await stopped;};
  try {execFileSync('/bin/busybox',['sync'],{stdio:'ignore',timeout:5000});
    execFileSync('/bin/busybox',['fsfreeze','--freeze',root],{stdio:'ignore',timeout:5000});}
  catch(error) {
    try {execFileSync('/bin/busybox',['fsfreeze','--unfreeze',root],{stdio:'ignore',timeout:5000});} catch {}
    // The detached watchdog is retained if a failed ioctl may still be pending.
    if(error.code!=='ETIMEDOUT') await stopWatchdog();
    throw error;
  }
  return async () => {
    execFileSync('/bin/busybox',['fsfreeze','--unfreeze',root],{stdio:'ignore',timeout:5000});
    await stopWatchdog();
  };
}
async function rehydrateProfiles(root) {
  const profiles=path.join(root,'.dsh/profiles');
  if (!fs.existsSync(profiles)) return;
  for (const entry of fs.readdirSync(profiles,{withFileTypes:true})) {
    if (!entry.isDirectory()) continue;
    const profile=path.join(profiles,entry.name), manifest=path.join(profile,'package.json');
    if (!fs.existsSync(manifest)) continue;
    const config=JSON.parse(fs.readFileSync(manifest,'utf8'));
    if (!Object.keys(config.dependencies || {}).length) continue;
    // User-owned plugin links/packages come from the backed-up pnpm store or
    // project sources. Never require new credentials or execute build scripts.
    await run('/usr/local/bin/pnpm',['install','--offline','--ignore-scripts','--dir',profile],
      {timeout:120000,maxBuffer:1024*1024,env:{...process.env,HOME:root}});
  }
}
class BackupManager {
  constructor({root='/root',tar,coordinator,freeze=freezeFilesystem,afterMove,rehydrate=rehydrateProfiles}={}) {
    this.root=root;this.tar=tar;this.freeze=freeze;this.afterMove=afterMove;this.rehydrate=rehydrate;
    this.coordinator=coordinator || {pause:async()=>(await supervisorRequest('pause')).lease,
      resume:async lease=>supervisorRequest('resume',{lease})};
  }
  // `started` runs once writers have stopped, so a refused pause can still be reported to the client.
  async export(destination,{started}={}) {
    let lease;
    try {lease=await this.coordinator.pause();}
    catch(error) {console.log('HARNESS_BACKUP_FAILURE:PAUSE');throw error;}
    started?.();
    let thaw,timer,phase='FREEZE';
    try {
      thaw=await this.freeze(this.root);phase="ARCHIVE";
      timer=setTimeout(()=>destination.destroy(Error('BACKUP_TIMEOUT')),540000);
      const names=fs.readdirSync(this.root).filter(name=>!reserved(name) && name!=='.harness-restore.tmp');
      await pipeline(this.tar.c({cwd:this.root,portable:true,strict:true,
        filter: file=>!file.split('/').some(part=>excluded.has(part)) &&
          !reserved(file.split('/')[0]) && !file.startsWith('.trash/.purging-')},names),destination);
    } catch(error) {
      console.log('HARNESS_BACKUP_FAILURE:'+phase);throw error;
    } finally {
      clearTimeout(timer);
      try {if(thaw) await thaw();} finally {await this.coordinator.resume(lease);}
    }
  }
  async restore(source) {
    const id=crypto.randomUUID(), stage=path.join(this.root,'.restore-stage-'+id), old=path.join(this.root,'.restore-original-'+id);
    fs.mkdirSync(stage,{mode:0o700});
    let lease,committed=false,result,rejected=false,entries=0,total=0;
    try {
      const space=fs.statfsSync(this.root);const budget=Number(space.bavail)*Number(space.bsize)-16*1024*1024;
      await pipeline(source,this.tar.x({cwd:stage,strict:true,preserveOwner:false,filter:(file,entry)=>{
        const parts=file.replace(/\/$/,'').split('/');
        if (!parts.length || reserved(parts[0]) || file.startsWith('.trash/.purging-') || parts.some(part=>!validName(part)||excluded.has(part)) ||
            !['File','OldFile','Directory','SymbolicLink','Link'].includes(entry.type)) {rejected=true;return false;}
        if (entry.type==='SymbolicLink' || entry.type==='Link') {
          const link=entry.linkpath;
          const resolved=path.posix.normalize(entry.type==='Link' ? link : path.posix.join(path.posix.dirname(file),link));
          if (path.posix.isAbsolute(link) || resolved==='..' || resolved.startsWith('../')) {rejected=true;return false;}
        }
        if (++entries>100000 || (total+=Number(entry.size))>budget) {rejected=true;return false;}
        return true;
      }}));
      if(rejected) throw Error('BACKUP_INVALID');
      if (fs.readFileSync(path.join(stage,'.harness-layout-version'),'utf8').trim()!=='1' ||
          !fs.statSync(path.join(stage,'projects')).isDirectory() || !fs.statSync(path.join(stage,'.dsh')).isDirectory()) throw Error('BACKUP_LAYOUT');
      lease=await this.coordinator.pause();
      recoverRestore(this.root);
      const oldNames=fs.readdirSync(this.root).filter(name=>!reserved(name)&&name!=='.harness-restore.tmp'&&name!=='.harness-layout-version');
      const newNames=fs.readdirSync(stage).filter(name=>name!=='.harness-layout-version');
      fs.mkdirSync(old,{mode:0o700});
      journal(this.root,{id,oldNames,newNames});
      for (const name of oldNames) {
        fs.renameSync(path.join(this.root,name),path.join(old,name));
        syncDirectory(this.root);syncDirectory(old);this.afterMove?.();
      }
      for (const name of newNames) {
        fs.renameSync(path.join(stage,name),path.join(this.root,name));
        syncDirectory(this.root);syncDirectory(stage);this.afterMove?.();
      }
      await this.rehydrate(this.root);
      execFileSync(process.env.HARNESS_SYNC || '/bin/sync',[],{stdio:'ignore'});
      fs.unlinkSync(path.join(this.root,'.harness-restore.json'));syncDirectory(this.root);
      committed=true;
      result={restored:true,original:path.basename(old),harnessRunning:true};
      return result;
    } catch(error) {
      if (!committed) recoverRestore(this.root);
      throw error;
    } finally {
      fs.rmSync(stage,{recursive:true,force:true});
      if (lease) {
        try {await this.coordinator.resume(lease);}
        catch(error) {
          if (!committed) throw error;
          result.harnessRunning=false;
          console.log('HARNESS_BACKUP_FAILURE:RESUME');
        }
      }
    }
  }
}
if(require.main===module && process.argv[2]==='--cold-boot') recoverRestore('/root');
module.exports={BackupManager,recoverRestore};
