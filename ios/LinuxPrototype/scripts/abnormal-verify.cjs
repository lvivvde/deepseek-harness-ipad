// Throwaway check after an abnormal exit: compare surviving writes with the
// last fsynced checkpoint. Prints only counts, never file contents.
const fs = require('node:fs');
const {DatabaseSync} = require('node:sqlite');
const dir = process.env.ABX_DIR || '/root/.abnormal-exit';
const fsynced = Number(fs.readFileSync(`${dir}/last-fsynced.txt`, 'utf8'));
const text = fs.readFileSync(`${dir}/writer.log`, 'latin1');
const lines = text.split('\n');
const tail = lines.pop();
let contiguous = 0;
let badLines = 0;
for (const line of lines) {
    if (line === String(contiguous + 1)) contiguous++;
    else badLines++;
}
// Unsynced appends may survive as a NUL-filled tail: ext4 ordered mode can
// commit the new size before the data page. Only complete lines must be valid.
const tailNulBytes = (tail.match(/\0/g) || []).length;
const db = new DatabaseSync(`${dir}/writer.sqlite`);
const integrity = db.prepare('PRAGMA integrity_check').get().integrity_check;
const rows = db.prepare('SELECT count(*) AS n, max(seq) AS max FROM w').get();
db.close();
const bulk = fs.readFileSync(`${dir}/bulk.bin`);
const blocks = Math.floor(bulk.length / 65536);
let badBlocks = 0;
for (let i = 0; i < blocks; i++) {
    const want = (i + 1) % 251;
    const block = bulk.subarray(i * 65536, (i + 1) * 65536);
    if (!block.every(byte => byte === want)) badBlocks++;
}
const summary = {fsynced, logContiguous: contiguous, badLines, unsyncedTailBytes: tail.length, tailNulBytes, sqliteIntegrity: integrity, sqliteRows: rows.n, sqliteMax: rows.max, bulkBlocks: blocks, bulkPartialBytes: bulk.length % 65536, badBlocks};
const ok = badLines === 0 && contiguous >= fsynced && integrity === 'ok' && rows.n === rows.max && rows.max >= fsynced && blocks >= fsynced && badBlocks === 0;
console.log('ABX_SUMMARY:' + JSON.stringify(summary));
console.log(ok ? 'ABX_OK' : 'ABX_MISMATCH');
process.exitCode = ok ? 0 : 1;
