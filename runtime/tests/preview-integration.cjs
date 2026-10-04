const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const http = require('node:http');
const net = require('node:net');
const os = require('node:os');
const path = require('node:path');
const {startPreviewService} = require('../guest/preview.cjs');

(async () => {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'preview-test-'));
  const dev = http.createServer((request, response) => response.end('live-project'));
  const ipv6 = http.createServer((request, response) => response.end('ipv6-project'));
  await new Promise((resolve,reject) => {ipv6.once('error',reject);ipv6.listen({port:0,host:'::1',ipv6Only:true},resolve);});
  dev.on('upgrade', (request, socket) => {
    socket.write('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n');
    socket.on('data', chunk => socket.write(chunk));
    socket.on('end', () => socket.destroy());
  });
  await new Promise(resolve => dev.listen(0, '127.0.0.1', resolve));
  const port = dev.address().port;
  const proc = path.join(directory, 'tcp');
  await fs.writeFile(proc, `  sl  local_address rem_address st\n  0: 0100007F:${port.toString(16).padStart(4, '0')} 00000000:0000 0A\n  1: 00000000000000000000000001000000:${ipv6.address().port.toString(16).padStart(4,'0')} 00000000:0000 0A\n`);
  let service;
  try {
    service = await startPreviewService({token: 'test-token', host: '127.0.0.1', port: 0, tables: [proc], fallbackPorts: []});
    const origin = `http://127.0.0.1:${service.server.address().port}`;
    assert.equal((await fetch(origin + '/ports')).status, 403);
    const headers = {'X-Harness-Transfer': 'test-token'};
    const ports = await (await fetch(origin + '/ports', {headers})).json();
    assert.equal(ports.ports.length, 2);
    const proxy = ports.ports.find(item=>item.port===port).relayPort;
    const ipv6Proxy=ports.ports.find(item=>item.port===ipv6.address().port).relayPort;
    assert.equal(await (await fetch(`http://127.0.0.1:${ipv6Proxy}/`)).text(),'ipv6-project');
    assert.equal(await (await fetch(`http://127.0.0.1:${proxy}/`)).text(), 'live-project');
    const socket = net.connect(proxy, '127.0.0.1');
    await new Promise(resolve => socket.once('connect', resolve));
    socket.write('GET /hmr HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGVzdA==\r\nSec-WebSocket-Version: 13\r\n\r\n');
    const upgrade = await new Promise(resolve => socket.once('data', resolve));
    assert.ok(upgrade.toString().startsWith('HTTP/1.1 101'));
    socket.write(Buffer.from([0x81, 0x02, 0x48, 0x69]));
    const echoed = await new Promise(resolve => socket.once('data', resolve));
    assert.deepEqual([...echoed], [0x81, 0x02, 0x48, 0x69]);
    socket.destroy();
    await new Promise(resolve => dev.close(resolve));
    await new Promise(resolve => ipv6.close(resolve));
    assert.deepEqual((await (await fetch(origin + '/ports', {headers})).json()).ports, []);
    console.log('PREVIEW_OK');
  } finally {
    await service?.close();
    dev.close();
    ipv6.close();
    await fs.rm(directory, {recursive: true, force: true});
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
