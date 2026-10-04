// HTTP/WS relays give QEMU a routable target even for loopback-only dev servers.
const http = require('node:http');
const net = require('node:net');
const fs = require('node:fs');
const crypto = require('node:crypto');

const fallbackPorts = [3000, 4173, 5173, 8080];
const reserved = new Set([2999, 3001, 3002, 3003, 28080, 28081, 28082, 28083, 28084]);

async function listeningPorts(tables) {
  const ports = new Set();
  for (const table of tables) {
    const text = await fs.promises.readFile(table, 'utf8');
    for (const line of text.split('\n').slice(1)) {
      const columns = line.trim().split(/\s+/);
      if (columns[3] !== '0A') continue;
      const [address, hexPort] = columns[1].split(':');
      // Only IPv4 loopback/wildcard/guest NIC and IPv6 wildcard/loopback.
      if (!['00000000', '0100007F', '0F02000A', '00000000000000000000000000000000',
        '00000000000000000000000001000000'].includes(address)) continue;
      const port = parseInt(hexPort, 16);
      if (port >= 1024 && port <= 65535 && !reserved.has(port) && !(port >= 40000 && port < 40100)) ports.add(port);
    }
  }
  return [...ports].sort((a, b) => a - b).slice(0, 32);
}

function respondsToHTTP(port) {
  return new Promise(resolve => {
    const request = http.request({host: '127.0.0.1', port, method: 'HEAD', path: '/', timeout: 1500}, response => {
      response.resume(); resolve(true);
    });
    request.on('timeout', () => request.destroy());
    request.on('error', () => resolve(false));
    request.end();
  });
}

function createRelay(port) {
  const server = http.createServer((request, response) => {
    if (!['GET', 'HEAD', 'POST', 'PUT', 'PATCH', 'DELETE', 'OPTIONS'].includes(request.method)) {
      response.writeHead(405).end(); return;
    }
    const upstream = http.request({host: '127.0.0.1', port, method: request.method, path: request.url,
      headers: {...request.headers, host: `127.0.0.1:${port}`}, timeout: 30000}, remote => {
      response.writeHead(remote.statusCode, remote.headers);
      remote.pipe(response);
    });
    upstream.on('timeout', () => upstream.destroy());
    upstream.on('error', () => { if (!response.headersSent) response.writeHead(502); response.end(); });
    request.on('aborted', () => upstream.destroy());
    response.on('close', () => upstream.destroy());
    request.pipe(upstream);
  });
  server.on('upgrade', (request, socket, head) => {
    if (request.headers.upgrade?.toLowerCase() !== 'websocket') { socket.destroy(); return; }
    const upstream = net.connect(port, '127.0.0.1');
    upstream.on('connect', () => {
      const headers = {...request.headers, host: `127.0.0.1:${port}`};
      upstream.write(`${request.method} ${request.url} HTTP/1.1\r\n` +
        Object.entries(headers).map(([key, value]) => `${key}: ${value}\r\n`).join('') + '\r\n');
      if (head.length) upstream.write(head);
      socket.pipe(upstream).pipe(socket);
    });
    socket.on('error', () => upstream.destroy());
    upstream.on('error', () => socket.destroy());
    socket.on('close', () => upstream.destroy());
    upstream.on('close', () => socket.destroy());
  });
  return server;
}

async function startPreviewService(options = {}) {
  const token = options.token;
  const host = options.host || '10.0.2.15';
  const tables = options.tables || ['/proc/net/tcp', '/proc/net/tcp6'];
  const relays = new Map();
  const fallback = options.fallbackPorts || fallbackPorts;
  let scanTail = Promise.resolve();
  async function ensureRelay(port) {
    if (relays.has(port)) return relays.get(port).address().port;
    if (relays.size >= 32) throw new Error('PREVIEW_LIMIT');
    const relay = createRelay(port);
    const relayPort = 40000 + relays.size;
    await new Promise((resolve, reject) => {
      relay.once('error', reject);
      relay.listen(relayPort, host, resolve);
    });
    relays.set(port, relay);
    return relayPort;
  }
  for (const port of fallback) await ensureRelay(port);
  const server = http.createServer((request, response) => {
    const operation = async () => {
      const supplied = Buffer.from(String(request.headers['x-harness-transfer'] || ''));
      const expected = Buffer.from(token || '');
      if (!token || supplied.length !== expected.length || !crypto.timingSafeEqual(supplied, expected)) {
        response.writeHead(403).end(); return;
      }
      if (request.method !== 'GET' || request.url !== '/ports') { response.writeHead(404).end(); return; }
      let detected, degraded = false;
      try { detected = await listeningPorts(tables); }
      catch { detected = fallback; degraded = true; }
      const alive = (await Promise.all(detected.map(async port => await respondsToHTTP(port) ? port : undefined)))
        .filter(port => port !== undefined);
      const ports = [];
      for (const port of alive) {
        try { ports.push({port, relayPort: await ensureRelay(port)}); }
        catch { degraded = true; }
      }
      response.writeHead(200, {'content-type': 'application/json', 'cache-control': 'no-store'});
      response.end(JSON.stringify({ports, degraded}));
    };
    scanTail = scanTail.then(operation).catch(() => {
      if (!response.headersSent) response.writeHead(503);
      response.end();
    });
  });
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(options.port ?? 3003, host, resolve);
  });
  return {server, close: async () => {
    for (const relay of relays.values()) { relay.closeAllConnections(); relay.close(); }
    server.closeAllConnections();
    await new Promise(resolve => server.close(resolve));
  }};
}

if (require.main === module) {
  const token = (fs.readFileSync('/proc/cmdline', 'utf8').match(/(?:^|\s)harness\.transfer=([0-9a-f]{32,})(?:\s|$)/) || [])[1];
  startPreviewService({token}).then(() => console.log('HARNESS_PREVIEW_READY'))
    .catch(() => console.log('HARNESS_PREVIEW_UNAVAILABLE'));
}
module.exports = {startPreviewService};
