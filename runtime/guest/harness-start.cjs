const net = require('node:net');
const {HarnessSupervisor, createSupervisorServer} = require('./supervisor.cjs');
// Same raw relay and official trusted-host/auth setup as the verified prototype.
const relay = net.createServer(client => {
  const upstream = net.connect(3001, '127.0.0.1');
  client.pipe(upstream).pipe(client);
  client.on('error', () => upstream.destroy());
  upstream.on('error', () => client.destroy());
  client.on('close', () => upstream.destroy());
  upstream.on('close', () => client.destroy());
});
relay.listen(2999, '10.0.2.15', () => console.log('HARNESS_RELAY_READY'));
const supervisor = new HarnessSupervisor({root:'/root', allGuestWriters:true, executable:process.execPath,
  env:{...process.env,NODE_COMPILE_CACHE:'/root/.cache/node-compile-cache',NODE_OPTIONS:'--require /opt/harness/compile-cache-flush.cjs'},
  arguments:['node_modules/@deepseek-ai/dsh/lib/bin.js', '--profile', 'web', '--patch', '/opt/harness/ipad.patch.yml',
    '--no-open', '--port', '3001', '--trusted-host', '127.0.0.1:28080'], cwd:'/opt/harness',
  onExit:() => console.log('HARNESS_PROCESS_STOPPED')});
createSupervisorServer(supervisor, '/run/harness-supervisor.sock');
supervisor.restart().catch(() => console.log('HARNESS_PROCESS_STOPPED'));
