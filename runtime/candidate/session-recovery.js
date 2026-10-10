// The Worker half of session recovery. Called only through restore/install/save; tickets, revisions
// and retries stay here rather than leaking into the official tree, connector or App UI.
const candidateHomePath = path => typeof path === 'string' && !path.includes('\0')
  && !path.slice(1).split('/').some(p => !p || p === '..' || p === '.')
  && (path === candidateHome || path.startsWith(candidateHome + '/'))
  && !path.startsWith(candidateCredentials);
function candidateSeedHome(vfs, snapshot) {
  if (snapshot?.formatVersion !== 1 || !Array.isArray(snapshot.directories) || !Array.isArray(snapshot.files)) throw new Error('HOME_SNAPSHOT_VERSION');
  const entries = new Map();
  const decoded = [];
  // Nothing is seeded until every entry, type, metadata, path and canonical encoding has passed.
  for (const [items, directory] of [[snapshot.directories, true], [snapshot.files, false]]) {
    for (const item of items) {
      if (!candidateHomePath(item?.path)) throw new Error('HOME_PATH_REFUSED');
      if (entries.has(item.path) || !Number.isInteger(item.mode) || item.mode < 0 || item.mode > 0o177777
        || (item.mode & 0o170000) !== (directory ? 0o040000 : 0o100000)
        || !Number.isFinite(item.mtimeMs) || item.mtimeMs < 0 || (!directory && item.path === candidateHome)) throw new Error('HOME_SNAPSHOT_REFUSED');
      entries.set(item.path, directory);
      if (!directory) {
        if (typeof item.base64 !== 'string') throw new Error('HOME_SNAPSHOT_REFUSED');
        let bytes;
        try { bytes = candidateBytes(item.base64); } catch { throw new Error('HOME_SNAPSHOT_REFUSED'); }
        if (candidateBase64(bytes) !== item.base64) throw new Error('HOME_SNAPSHOT_REFUSED');
        decoded.push([item, bytes]);
      }
    }
  }
  for (const path of entries.keys()) {
    let parent = path.slice(0, path.lastIndexOf('/'));
    while (parent.startsWith(candidateHome)) {
      if (entries.get(parent) === false) throw new Error('HOME_SNAPSHOT_REFUSED');
      parent = parent.slice(0, parent.lastIndexOf('/'));
    }
  }
  for (const d of [...snapshot.directories].sort((a, b) => a.path.length - b.path.length)) vfs.seedDirectory(d.path, {mode: d.mode, mtimeMs: d.mtimeMs});
  for (const [f, bytes] of decoded) vfs.seed(f.path, bytes, {mode: f.mode, mtimeMs: f.mtimeMs});
}
function candidateSnapshotHome(vfs) {
  const result = {formatVersion: 1, directories: [], files: []};
  const visit = path => {
    if (!candidateHomePath(path)) return;
    const stat = vfs.statSync(path);
    if (stat.isDirectory()) {
      result.directories.push({path, mode: stat.mode, mtimeMs: stat.mtimeMs});
      for (const name of vfs.readdirSync(path)) visit(path + '/' + name);
    } else result.files.push({path, mode: stat.mode, mtimeMs: stat.mtimeMs, base64: candidateBase64(vfs.readFileSync(path))});
  };
  visit(candidateHome);
  return result;
}

const candidateRecovery = (() => {
  let worker, ctx, vfs, revision = 0, savedRevision = -1, timer, running;
  const report = fields => candidateNative('session-changed', {worker, revision, ...fields});
  const backgroundSave = () => save().catch(error => candidateLog({event: 'checkpoint-failed', code: error.code ?? String(error)}));
  const changed = () => {
    revision++;
    report({}).catch(error => candidateLog({event: 'checkpoint-status-failed', code: error.code ?? String(error)}));
    clearTimeout(timer);
    timer = setTimeout(backgroundSave, candidateCheckpointDelayMs);
  };
  async function restore(mounted) {
    const reply = await candidateNative('restore');
    if (typeof reply.worker !== 'string' || !reply.worker) throw new Error('RECOVERY_REPLY_REFUSED');
    worker = reply.worker;
    if (reply.snapshot) candidateSeedHome(mounted, reply.snapshot);
    candidateRouting = true;
  }
  async function capture() {
    const ticket = await candidateNative('checkpoint-begin', {worker, revision});
    if (ticket.worker !== worker || typeof ticket.capture !== 'string') throw new Error('CAPTURE_REPLY_REFUSED');
    await ctx.get('sessionPersistence').flush();
    const target = revision;
    const snapshot = candidateSnapshotHome(vfs);
    const ack = await candidateNative('checkpoint', {worker, capture: ticket.capture, revision: target, snapshot});
    if (ack?.durable !== true || ack.worker !== worker || ack.capture !== ticket.capture || ack.revision !== target) throw new Error('DURABLE_ACK_REFUSED');
    savedRevision = target;
  }
  function save() {
    if (!ctx) return Promise.reject(new Error('SESSION_NOT_READY'));
    clearTimeout(timer);
    if (running) return running;
    running = (async () => {
      // An event during an in-flight save requires another capture. Flush's own VFS writes are included
      // in target; merely producing the snapshot never clears a later event.
      do { await capture(); } while (revision > savedRevision);
    })().catch(async error => {
      await report({failure: error.code ?? 'CHECKPOINT_FAILED'}).catch(() => {});
      throw error;
    }).finally(() => { running = undefined; });
    return running;
  }
  function install(context, mounted) {
    ctx = context; vfs = mounted;
    ctx.on('session/event', changed);
    ctx.on('session/created', changed);
    ctx.on('session/flush', save);
    vfs.subscribe?.(mutation => { if (candidateHomePath(mutation.path)) changed(); });
    setInterval(() => { if (savedRevision < revision) backgroundSave(); }, candidateCheckpointIntervalMs);
    // Save settings and the initial empty home too, without waiting for the first model event.
    changed();
  }
  return {restore, install, save};
})();
self.candidateSave = () => candidateRecovery.save();
