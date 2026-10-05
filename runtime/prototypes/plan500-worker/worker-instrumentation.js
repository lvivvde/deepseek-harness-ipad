// Appended to a COPY of the fixed official bundle for this isolated probe only.
const prototypeRoots = ['/dsh/home', '/dsh/workspace'];
function prototypeAllowed(path) {
  return typeof path === 'string' && !path.split('/').some(p => p === '..' || p === '.') &&
    prototypeRoots.some(root => path === root || path.startsWith(root + '/'));
}
function prototypeRestore(vfs, snapshot) {
  if (!snapshot) return;
  if (snapshot.formatVersion !== 1) throw new Error('PROTOTYPE_SNAPSHOT_VERSION');
  for (const d of snapshot.directories) {
    if (!prototypeAllowed(d.path)) throw new Error('PROTOTYPE_PATH_REFUSED');
    vfs.seedDirectory(d.path, {mode: d.mode, mtimeMs: d.mtimeMs});
  }
  for (const f of snapshot.files) {
    if (!prototypeAllowed(f.path)) throw new Error('PROTOTYPE_PATH_REFUSED');
    vfs.seed(f.path, Uint8Array.from(atob(f.base64), c => c.charCodeAt(0)),
      {mode: f.mode, mtimeMs: f.mtimeMs});
  }
}
function prototypeSnapshot(vfs) {
  const result = {formatVersion: 1, directories: [], files: []};
  function visit(path) {
    const stat = vfs.statSync(path);
    if (stat.isDirectory()) {
      result.directories.push({path, mode: stat.mode, mtimeMs: stat.mtimeMs});
      for (const name of vfs.readdirSync(path)) visit(path + '/' + name);
    } else {
      const bytes = vfs.readFileSync(path);
      let binary = '';
      for (const value of bytes) binary += String.fromCharCode(value);
      result.files.push({path, mode: stat.mode, mtimeMs: stat.mtimeMs, base64: btoa(binary)});
    }
  }
  for (const root of prototypeRoots) visit(root);
  return result;
}
async function prototypeMessage(event) {
  const data = event.data;
  if (data?.t !== 'plan500') return;
  try {
    if (!host?.vfs) throw new Error('PROTOTYPE_NOT_READY');
    const vfs = host.vfs;
    let result;
    if (data.operation === 'snapshot') {
      // Accepted session events can still be in the upstream batching queue.
      // Its flush is a VFS barrier; only the later Swift receipt is persistent.
      await host.prototypeContext.get('sessionPersistence').flush();
      result = prototypeSnapshot(vfs);
    }
    else if (data.operation === 'schema-check') {
      const {assertSupportedJsonSchema} = host.modules.createRequire('/dsh/config/cordis.yml')('@deepseek-ai/dsh-tools');
      assertSupportedJsonSchema({type: 'object', properties: {text: {type: 'string'}}});
      const invalid = [new Date(), {type: 'invented'}, new (class Schema {})()];
      let rejected = 0;
      for (const value of invalid) {
        try { assertSupportedJsonSchema(value); } catch { rejected++; }
      }
      result = {plainAccepted: true, rejected, invalidCases: invalid.length};
    }
    else if (data.operation === 'describe') result = {usage: vfs.usage(), modules: host.modules.usage(), intrinsicObject: Function.prototype.toString.call(Object), intrinsicArray: Function.prototype.toString.call(Array)};
    else if (data.operation === 'write') {
      if (!prototypeAllowed(data.path)) throw new Error('PROTOTYPE_PATH_REFUSED');
      vfs.mkdirSync(data.path.slice(0, data.path.lastIndexOf('/')), {recursive: true});
      await vfs.promises.writeFile(data.path, data.text);
      result = {inMemory: true, durable: false};
    } else if (data.operation === 'read') {
      if (!prototypeAllowed(data.path)) throw new Error('PROTOTYPE_PATH_REFUSED');
      result = vfs.readFileSync(data.path, 'utf8');
    } else throw new Error('PROTOTYPE_OPERATION_REFUSED');
    self.postMessage({t: 'plan500-result', id: data.id, result});
  } catch (error) {
    self.postMessage({t: 'plan500-result', id: data.id, error: String(error)});
  }
}
