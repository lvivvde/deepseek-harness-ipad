const fs = require('node:fs');
const path = require('node:path');
if (process.argv[2] !== '--cold-boot') throw new Error('Cleanup is only valid before Harness starts after a fresh VM boot');
// dsh withFileLock stores PID + newline, not arbitrary application state.
const root = process.env.DSH_HOME || '/root/.dsh';
function visit(directory) {
  if (!fs.existsSync(directory)) return;
  for (const entry of fs.readdirSync(directory, {withFileTypes: true})) {
    const name = path.join(directory, entry.name);
    if (entry.isDirectory()) visit(name);
    else if (entry.isFile() && entry.name.endsWith('.lock')) {
      const info = fs.statSync(name);
      if (info.size > 16) continue;
      const value = fs.readFileSync(name, 'utf8');
      if (!/^[1-9][0-9]*\n$/.test(value)) continue;
      // No previous-boot process can survive this boundary. A reused PID belongs
      // to the new VM, not the old holder. Never run this after starting dsh.
      fs.unlinkSync(name);
    }
  }
}
visit(root);

// Git index.lock may contain a partial index, not a PID. Preserve it next to the
// index for rescue; a fresh VM has no surviving old writer. Never run live.
const projects = process.env.HARNESS_PROJECTS || '/root/projects';
function gitDirectories(directory) {
  if (!fs.existsSync(directory)) return;
  for (const entry of fs.readdirSync(directory, {withFileTypes:true})) {
    if (!entry.isDirectory() || ['node_modules','.cache'].includes(entry.name)) continue;
    const child=path.join(directory,entry.name);
    if (entry.name==='.git') preserveGitLock(child);
    else gitDirectories(child);
  }
}
function preserveGitLock(git) {
  const lock=path.join(git,'index.lock');
  if (!fs.lstatSync(lock,{throwIfNoEntry:false})?.isFile()) return;
  fs.renameSync(lock, path.join(git,`harness-stale-index-${Date.now()}-${process.pid}.lock`));
}
gitDirectories(projects);
