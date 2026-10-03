const assert = require('node:assert/strict');
const fs = require('node:fs');
const {execFileSync} = require('node:child_process');
const {DatabaseSync} = require('node:sqlite');
const project = '/root/Documents/Projects/runtime-acceptance';
assert(fs.readFileSync('/proc/mounts', 'utf8').split('\n').some(line => /^\/dev\/vda \/ ext4 ro[, ]/.test(line)));
assert.throws(() => fs.writeFileSync('/etc/runtime-write-check', 'fail'), {code: 'EROFS'});
assert(fs.readFileSync('/proc/mounts', 'utf8').includes('/dev/vdb /root ext4 rw,'));
fs.mkdirSync(project, {recursive: true});
const proof = project + '/count.txt';
const count = fs.existsSync(proof) ? Number(fs.readFileSync(proof, 'utf8')) : 0;
assert.equal(count, Number(process.argv[2]));
fs.writeFileSync(project + '/package.json', JSON.stringify({name: 'runtime-acceptance', scripts: {test: 'node test.cjs'}}));
fs.writeFileSync(project + '/test.cjs', 'require("node:assert/strict").equal(6 * 7, 42);\n');
execFileSync('/opt/node/bin/npm', ['test'], {cwd: project, stdio: 'pipe'});
const database = new DatabaseSync(project + '/proof.sqlite');
database.exec('CREATE TABLE IF NOT EXISTS proof (value INTEGER)');
if (count === 0) database.exec('INSERT INTO proof VALUES (42)');
assert.equal(database.prepare('SELECT value FROM proof').get().value, 42);
database.close();
if (count === 0) {
  execFileSync('git', ['init'], {cwd: project});
  execFileSync('git', ['add', 'package.json', 'test.cjs'], {cwd: project});
  execFileSync('git', ['-c', 'user.name=HarnessRuntimeTest', '-c', 'user.email=runtime-test@example.invalid', 'commit', '-m', 'Verify local runtime'], {cwd: project});
}
assert(execFileSync('git', ['rev-parse', 'HEAD'], {cwd: project, encoding: 'utf8'}).trim().length === 40);
fs.writeFileSync(proof, String(count + 1));
execFileSync('/bin/busybox', ['sync']);
console.log('RUNTIME_CHECK_OK:' + (count + 1));
