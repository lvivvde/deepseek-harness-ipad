const fs = require('node:fs');
const path = require('node:path');
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
      try { process.kill(Number(value.trim()), 0); }
      catch (error) { if (error.code === 'ESRCH') fs.unlinkSync(name); else throw error; }
    }
  }
}
visit(root);
