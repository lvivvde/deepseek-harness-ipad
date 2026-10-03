// Throwaway abnormal-exit writer: in-flight appends plus fsynced checkpoints.
// Run inside the guest, then SIGKILL the host app while it is writing.
const fs = require('node:fs');
const {DatabaseSync} = require('node:sqlite');
const dir = process.env.ABX_DIR || '/root/.abnormal-exit';
fs.mkdirSync(dir, {recursive: true, mode: 0o700});
if (fs.existsSync(`${dir}/writer.log`)) {
    console.log('WRITER_ABORT_EXISTS');
    process.exit(1);
}
const log = fs.openSync(`${dir}/writer.log`, 'a', 0o600);
const bulk = fs.openSync(`${dir}/bulk.bin`, 'a', 0o600);
const db = new DatabaseSync(`${dir}/writer.sqlite`);
db.exec('PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; CREATE TABLE IF NOT EXISTS w(seq INTEGER PRIMARY KEY, at INTEGER NOT NULL)');
const insert = db.prepare('INSERT INTO w(seq,at) VALUES(?,?)');
const fsyncPath = target => { const fd = fs.openSync(target, 'r'); fs.fsyncSync(fd); fs.closeSync(fd); };
let seq = 0;
console.log('WRITER_STARTED');
setInterval(() => {
    seq++;
    fs.writeSync(log, `${seq}\n`);
    fs.writeSync(bulk, Buffer.alloc(65536, seq % 251));
    insert.run(seq, Date.now());
    if (seq % 10 === 0) {
        fs.fsyncSync(log);
        fs.fsyncSync(bulk);
        fs.writeFileSync(`${dir}/fsynced.tmp`, String(seq));
        fsyncPath(`${dir}/fsynced.tmp`);
        fs.renameSync(`${dir}/fsynced.tmp`, `${dir}/last-fsynced.txt`);
        fsyncPath(dir);
    }
    if (seq % 50 === 0) console.log('WRITER_SEQ:' + seq);
}, 100);
