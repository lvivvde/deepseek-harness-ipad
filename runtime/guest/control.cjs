const {execFileSync} = require('node:child_process');
const readline = require('node:readline');
const {supervisorRequest} = require('./supervisor.cjs');
// A two-phase clock handshake accounts for Node startup time before the host
// supplies its timestamp. Only nonce-bound, fixed health fields cross serial.
(async () => {
  const [nonce, time, action] = process.argv.slice(2);
  if (!/^[0-9a-f]{32}$/.test(nonce || '') || (time!=='--handshake' && !/^\d{13}$/.test(time || ''))) return;
  let health={running:false,writable:false,restartable:false};
  try {health=await supervisorRequest(action==='restart' ? 'restart' : 'health');} catch {}
  let stamp=time;
  if(time==='--handshake') {
    const input=readline.createInterface({input:process.stdin,terminal:false});
    console.log('HARNESS_CONTROL_READY:'+nonce);
    stamp=await new Promise(resolve => {
      const timer=setTimeout(()=>{input.close();resolve(undefined);},5000);
      input.on('line',line => {
        const prefix='HARNESS_TIME:'+nonce+':';
        if(line.startsWith(prefix) && /^\d{13}$/.test(line.slice(prefix.length))) {
          clearTimeout(timer);input.close();resolve(line.slice(prefix.length));
        }
      });
    });
    if(!stamp)return;
  }
  let clock=false;
  try {
    const formatted=new Date(Number(stamp)).toISOString().slice(0,19).replace('T',' ');
    execFileSync('/bin/busybox',['date','-u','-s',formatted],{stdio:'ignore',timeout:1000});
    clock=Math.abs(Date.now()-Number(stamp))<2000;
  } catch {}
  console.log(`HARNESS_CONTROL:${nonce}:${JSON.stringify({clock,epoch:Date.now(),...health})}`);
})().catch(()=>{});
