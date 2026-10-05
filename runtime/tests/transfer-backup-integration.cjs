const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const os = require('node:os');
const path = require('node:path');
const token = '0123456789abcdef0123456789abcdef';
const work = fs.mkdtempSync(path.join(os.tmpdir(), 'transfer-backup-'));
const socket = path.join(work, 'supervisor.sock'), calls = [];
fs.writeFileSync(path.join(work, 'cmdline'), `console=ttyAMA0 harness.transfer=${token}\n`);
fs.mkdirSync(path.join(work, 'root/projects'), {recursive: true});
Object.assign(process.env, {HARNESS_CMDLINE: path.join(work, 'cmdline'), HARNESS_USER_ROOT: path.join(work, 'root'),
  HARNESS_PROJECTS: path.join(work, 'root/projects'), HARNESS_SUPERVISOR_SOCKET: socket});
// A Harness that did not stop in time: the supervisor refuses the pause.
const supervisor = http.createServer((request, response) => {
  calls.push(request.url); request.resume();
  response.writeHead(503); response.end(JSON.stringify({error: 'WRITERS_BUSY'}));
});
const {server} = require('../guest/transfer.cjs');
const get = port => new Promise((resolve, reject) => {
  http.get({host: '127.0.0.1', port, path: '/userdata/archive', headers: {'X-Harness-Transfer': token}}, response => {
    const chunks = []; response.on('data', chunk => chunks.push(chunk));
    response.on('end', () => resolve({status: response.statusCode, body: Buffer.concat(chunks).toString()}));
    response.on('error', reject);
  }).on('error', reject);
});
(async () => {
  try {
    await new Promise(resolve => supervisor.listen(socket, resolve));
    await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
    const result = await get(server.address().port).catch(error => ({error: error.code || error.message}));
    assert.deepEqual(calls, ['/pause']);
    assert.ok(result.status >= 500, `pause failure must be an HTTP error, got ${JSON.stringify(result)}`);
    assert.equal(JSON.parse(result.body).error, 'WRITERS_BUSY');
    console.log('PASS:transfer-backup');
  } finally {
    server.close(); supervisor.close(); fs.rmSync(work, {recursive: true, force: true});
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
