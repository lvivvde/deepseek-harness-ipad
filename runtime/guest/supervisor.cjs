const fs = require('node:fs');
const path = require('node:path');
const http = require('node:http');
const crypto = require('node:crypto');
const {spawn} = require('node:child_process');
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));

function processTable() {
  const table = new Map();
  if (!fs.existsSync('/proc')) return table;
  for (const pid of fs.readdirSync('/proc').filter(value => /^\d+$/.test(value))) {
    try {
      const stat = fs.readFileSync(`/proc/${pid}/stat`, 'utf8').split(') ')[1].split(' ');
      table.set(Number(pid), {parent:Number(stat[1]), alive:stat[0] !== 'Z', start:stat[19]});
    } catch {}
  }
  return table;
}

class HarnessSupervisor {
  constructor(options) { this.options = options; this.child = undefined; this.lease = undefined; this.timer = undefined; this.owned=new Map();
    this.tracker=setInterval(() => this.capture(), 1000); this.tracker.unref();
  }
  capture() {
    const table=processTable();
    if (this.child?.pid && table.has(this.child.pid)) this.owned.set(this.child.pid, table.get(this.child.pid).start);
    let changed;
    do {
      changed=false;
      for (const [pid,info] of table) if (this.owned.get(info.parent) === table.get(info.parent)?.start && !this.owned.has(pid) && this.owned.has(info.parent)) {
        this.owned.set(pid,info.start); changed=true;
      }
    } while(changed);
    return table;
  }
  liveWriters(table=this.capture()) {
    if (this.options.allGuestWriters) {
      const services=new Set([1,process.pid]);
      for (const name of ['transfer','preview']) {
        try {
          const pid=Number(fs.readFileSync(`/run/harness-${name}.pid`,'utf8'));
          const args=fs.readFileSync(`/proc/${pid}/cmdline`,'utf8').split('\0');
          if ([`${name}.cjs`,`/opt/harness/${name}.cjs`].includes(args[1]) &&
              fs.readlinkSync(`/proc/${pid}/exe`) === process.execPath && fs.readlinkSync(`/proc/${pid}/cwd`) === '/opt/harness') services.add(pid);
        } catch {}
      }
      for (const [pid,info] of table) {
        if (services.has(pid) || !info.alive) continue;
        try {
          const args=fs.readFileSync(`/proc/${pid}/cmdline`,'utf8').split('\0');
          if (!args[0]) continue; // kernel thread
          if (args[1] === '/opt/harness/control.cjs') continue;
          let console; try {console=fs.readlinkSync(`/proc/${pid}/fd/0`);} catch {}
          if (info.parent===1 && ['/dev/ttyAMA0','/dev/console'].includes(console) &&
              args[0]==='/bin/busybox' && ['sh','cttyhack','setsid','sleep'].includes(args[1])) continue;
          this.owned.set(pid,info.start);
        } catch {}
      }
    }
    return [...this.owned].filter(([pid,start]) => table.get(pid)?.start===start && table.get(pid)?.alive);
  }
  get pid() { return this.child?.pid; }
  health() {
    // A write probe blocks on fsfreeze and would block this control server too.
    if (this.lease) return {running:false,writable:false,leased:true,restartable:false};
    let writable = false;
    const probe = path.join(this.options.root, `.harness-write-probe-${crypto.randomUUID()}`);
    try {
      const descriptor = fs.openSync(probe, 'wx', 0o600);
      try { fs.writeSync(descriptor, 'probe'); fs.fsyncSync(descriptor); writable = true; }
      finally { fs.closeSync(descriptor); fs.unlinkSync(probe); }
    } catch {}
    const running = this.child !== undefined && this.child.exitCode === null && this.child.signalCode === null;
    return {running, writable, leased:!!this.lease, restartable:!running && writable && !this.lease && !this.liveWriters().length};
  }
  async restart() {
    if (this.lease) throw new Error('BACKUP_BUSY');
    const health = this.health();
    if (health.running) return health;
    if (!health.writable) throw new Error('USER_READONLY');
    if (this.liveWriters().length) throw new Error('WRITERS_BUSY');
    const child = spawn(this.options.executable, this.options.arguments, {
      stdio:this.options.stdio || 'inherit', env:this.options.env || process.env, cwd:this.options.cwd, detached:true
    });
    this.child = child;
    await new Promise((resolve, reject) => { child.once('spawn', resolve); child.once('error', error => { if(this.child===child) this.child=undefined; reject(error); }); });
    child.on('exit', () => { this.options.onExit?.(); });
    return this.health();
  }
  async pause() {
    if (this.lease) throw new Error('BACKUP_BUSY');
    this.lease = crypto.randomUUID();
    try { await this.stop(); }
    catch (error) { this.lease=undefined; throw error; }
    // A killed transfer process cannot leave the application stopped forever.
    this.timer = setTimeout(() => { const lease=this.lease; this.resume(lease).catch(() => {}); }, 660000);
    this.timer.unref();
    return this.lease;
  }
  async resume(lease) {
    if (!lease || this.lease !== lease) throw new Error('LEASE_INVALID');
    clearTimeout(this.timer); this.lease=undefined;
    return this.restart();
  }
  async stop() {
    const child = this.child;
    this.capture();
    if (child && child.exitCode === null && child.signalCode === null) child.kill('SIGTERM');
    const deadline=Date.now()+8000;
    while (Date.now()<deadline) {
      const alive=this.liveWriters();
      for (const [pid] of alive) if (pid!==child?.pid) { try { process.kill(pid, 'SIGTERM'); } catch {} }
      if (!child || child.exitCode !== null || child.signalCode !== null) {
        if (!alive.length) { this.child=undefined; this.owned.clear(); return; }
      }
      await delay(50);
    }
    // Refuse a backup when a known writer did not exit; don't SIGKILL an active write.
    for (const [pid] of this.liveWriters()) {
      try {
        const args=fs.readFileSync(`/proc/${pid}/cmdline`,'utf8').split('\0');
        const role=['sh','sleep','cttyhack','setsid','transfer.cjs','preview.cjs','harness-start.cjs'].includes(args[1]) ? args[1] : 'OTHER';
        console.log('HARNESS_WRITER_BLOCKED:'+role);
      } catch {}
    }
    throw new Error('WRITERS_BUSY');
  }
  async close() { clearInterval(this.tracker); clearTimeout(this.timer); this.lease=undefined; await this.stop(); }
}

function createSupervisorServer(supervisor, socket) {
  const server=http.createServer((request,response) => {
    const perform=async () => {
      let size=0, chunks=[];
      for await (const chunk of request) { size+=chunk.length; if (size>4096) throw Error('REQUEST_LIMIT'); chunks.push(chunk); }
      const body=chunks.length ? JSON.parse(Buffer.concat(chunks)) : {};
      if (request.method!=='POST') throw Error('NOT_FOUND');
      let result;
      if (request.url==='/health') result=supervisor.health();
      else if (request.url==='/restart') result=await supervisor.restart();
      else if (request.url==='/pause') result={lease:await supervisor.pause()};
      else if (request.url==='/resume') result=await supervisor.resume(body.lease);
      else throw Error('NOT_FOUND');
      response.writeHead(200, {'content-type':'application/json'}); response.end(JSON.stringify(result));
    };
    perform().catch(error => {
      const code=['BACKUP_BUSY','USER_READONLY','WRITERS_BUSY','LEASE_INVALID'].includes(error.message) ? error.message : 'SUPERVISOR_UNAVAILABLE';
      response.writeHead(503);response.end(JSON.stringify({error:code}));
    });
  });
  server.listen(socket, () => fs.chmodSync(socket, 0o600));
  return server;
}
function supervisorRequest(operation, body={}) {
  return new Promise((resolve,reject) => {
    const request=http.request({socketPath:process.env.HARNESS_SUPERVISOR_SOCKET || '/run/harness-supervisor.sock', path:'/'+operation, method:'POST'}, response => {
      const chunks=[];
      response.on('data',chunk => chunks.push(chunk));
      response.on('error',reject);
      response.on('end',() => {
        try {const result=JSON.parse(Buffer.concat(chunks));if(response.statusCode!==200)throw Error(result.error);resolve(result);}
        catch(error) { reject(error); }
      });
    });
    request.setTimeout(operation==='pause' ? 10000 : 1500, () => request.destroy());
    request.on('error', reject); request.end(JSON.stringify(body));
  });
}
module.exports={HarnessSupervisor, createSupervisorServer, supervisorRequest};
