const fs = require('node:fs');
const {execFile} = require('node:child_process');
const {promisify} = require('node:util');
const run = promisify(execFile);

function diskCapacityBytes() {
  return Number(fs.readFileSync('/sys/class/block/vdb/size', 'utf8').trim()) * 512;
}

async function growFilesystem(bytes) {
  // Wait for virtio's capacity notification before asking ext4 to grow.
  const deadline = Date.now() + 20000;
  while (diskCapacityBytes() < bytes && Date.now() < deadline) {
    await new Promise(resolve => setTimeout(resolve, 100));
  }
  if (diskCapacityBytes() < bytes) throw Error('DISK_SIZE_PENDING');
  await run('/usr/sbin/resize2fs', ['/dev/vdb'], {timeout:60000, maxBuffer:65536});
  await run('/bin/busybox', ['sync'], {timeout:5000});
  const {stdout} = await run('/usr/sbin/dumpe2fs', ['-h', '/dev/vdb'],
    {timeout:5000, maxBuffer:65536, env:{...process.env, LC_ALL:'C'}});
  const blocks = Number(stdout.match(/^Block count:\s+(\d+)/m)?.[1]);
  const blockSize = Number(stdout.match(/^Block size:\s+(\d+)/m)?.[1]);
  if (!blocks || !blockSize || blocks * blockSize < bytes) throw Error('DISK_SIZE_PENDING');
  return {capacityBytes:blocks * blockSize};
}

module.exports = {diskCapacityBytes, growFilesystem};
