const net = require('node:net');
const {spawn} = require('node:child_process');
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
const child = spawn(process.execPath, ['node_modules/@deepseek-ai/dsh/lib/bin.js',
  '--profile', 'web', '--patch', '/opt/harness/ipad.patch.yml', '--no-open',
  '--port', '3001', '--trusted-host', '127.0.0.1:28080'], {stdio: 'inherit', env: process.env});
child.on('error', () => { console.log('HARNESS_BOOT_ERROR:HARNESS_EXIT'); relay.close(); process.exitCode = 1; });
child.on('exit', () => { console.log('HARNESS_BOOT_ERROR:HARNESS_EXIT'); relay.close(); process.exitCode = 1; });
