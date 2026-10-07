// #39 gate 3 (research image only): the official file, search and change tools over the native
// workspace. Appended after worker-bridge.js. Installed by `gate3-install`; until then nothing here
// changes the official Worker. Project bytes live only in the native store: the Worker's mount is
// an empty VFS directory, every read is a native call, and every write goes through the gateway.
const plan500G3Mount = '/dsh/workspace/gate3';
const plan500G3Scratch = '/dsh/tmp/dsh-workspace-changes-';
const plan500G3Git = '/dsh/bin/git';
const plan500G3Rg = '/dsh/bin/rg';
const plan500G3Refused = 'VFS_WORKSPACE_WRITE_REFUSED';
let plan500G3Installed = false;

const plan500G3Inside = path => path === plan500G3Mount || path.startsWith(plan500G3Mount + '/');
// Textual classification: a mount spelling (with any `..`) is resolved physically by the native side.
function plan500G3Native(value) {
  if (value instanceof URL) value = decodeURIComponent(value.pathname);
  if (typeof value !== 'string' || !value.startsWith('/')) return undefined;
  return plan500G3Inside(value) || value.startsWith(plan500G3Scratch) ? value : undefined;
}
async function plan500G3(call, method, args = {}) {
  const reply = await plan500Native('gate3', {call, method, args});
  if (reply.failure) {
    const error = new Error(`${reply.failure.code}: ${reply.failure.detail ?? ''}`);
    error.code = reply.failure.code; error.detail = reply.failure.detail ?? '';
    throw error;
  }
  return reply.value;
}
function plan500G3Base64(bytes) {
  const view = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes.buffer ?? bytes, bytes.byteOffset ?? 0, bytes.byteLength);
  let text = '';
  for (let i = 0; i < view.length; i += 0x8000) text += String.fromCharCode.apply(null, view.subarray(i, i + 0x8000));
  return btoa(text);
}

// MARK: Node fs routes (node:fs/promises; the prepare step routes every member through here)

const plan500G3Errno = {EPERM: -1, ENOENT: -2, EIO: -5, EBADF: -9, EACCES: -13, EBUSY: -16, EEXIST: -17, EXDEV: -18,
  ENOTDIR: -20, EISDIR: -21, EINVAL: -22, EROFS: -30, ELOOP: -62, ENOTEMPTY: -66, ENOSYS: -78};
function plan500G3NodeError(code, syscall, path, detail) {
  const error = new Error(`${code}: ${detail || code}, ${syscall} '${path}'`);
  return Object.assign(error, {code, errno: plan500G3Errno[code] ?? -5, syscall, path});
}
async function plan500G3Path(method, args, syscall = method) {
  try { return await plan500G3('path', method, args); }
  catch (error) { throw plan500G3NodeError(error.code ?? 'EIO', syscall, args.path, error.detail); }
}
function plan500G3Stats(info, bigint) {
  const kind = info.mode & 0o170000;
  const stats = {
    isFile: () => kind === 0o100000, isDirectory: () => kind === 0o040000, isSymbolicLink: () => kind === 0o120000,
    isBlockDevice: () => kind === 0o060000, isCharacterDevice: () => kind === 0o020000,
    isFIFO: () => kind === 0o010000, isSocket: () => kind === 0o140000,
  };
  if (bigint) {
    const mtimeNs = BigInt(info.mtimeNs), ctimeNs = BigInt(info.ctimeNs);
    return Object.assign(stats, {dev: BigInt(info.dev), ino: BigInt(Math.trunc(info.ino)), mode: BigInt(info.mode),
      nlink: BigInt(info.nlink), uid: BigInt(info.uid), gid: BigInt(info.gid), rdev: 0n, size: BigInt(info.size),
      blksize: 4096n, blocks: BigInt(Math.ceil(info.size / 512)),
      atimeNs: mtimeNs, mtimeNs, ctimeNs, birthtimeNs: ctimeNs, atimeMs: mtimeNs / 1000000n, mtimeMs: mtimeNs / 1000000n,
      ctimeMs: ctimeNs / 1000000n, birthtimeMs: ctimeNs / 1000000n,
      atime: new Date(info.mtimeMs), mtime: new Date(info.mtimeMs), ctime: new Date(info.ctimeMs), birthtime: new Date(info.ctimeMs)});
  }
  return Object.assign(stats, {dev: info.dev, ino: info.ino, mode: info.mode, nlink: info.nlink, uid: info.uid, gid: info.gid,
    rdev: 0, size: info.size, blksize: 4096, blocks: Math.ceil(info.size / 512),
    atimeMs: info.mtimeMs, mtimeMs: info.mtimeMs, ctimeMs: info.ctimeMs, birthtimeMs: info.ctimeMs,
    atime: new Date(info.mtimeMs), mtime: new Date(info.mtimeMs), ctime: new Date(info.ctimeMs), birthtime: new Date(info.ctimeMs)});
}
function plan500G3Dirent(parentPath, entry) {
  const is = type => () => entry.type === type;
  return {name: entry.name, parentPath, path: parentPath, isFile: is('file'), isDirectory: is('directory'),
    isSymbolicLink: is('symlink'), isBlockDevice: () => false, isCharacterDevice: () => false, isFIFO: () => false,
    isSocket: () => false};
}
async function plan500G3ReadFile(path, options) {
  const data = Buffer.from(plan500Bytes(await plan500G3Path('readFile', {path}, 'open')));
  const encoding = typeof options === 'string' ? options : options?.encoding;
  return encoding ? data.toString(encoding) : data;
}
async function plan500G3WriteFile(path, data, options) {
  const flag = typeof options === 'object' && options ? options.flag ?? 'w' : 'w';
  if (!flag.startsWith('w')) throw plan500G3NodeError('EROFS', 'open', path, plan500G3Refused);
  const encoding = typeof options === 'string' ? options : options?.encoding ?? 'utf8';
  const bytes = typeof data === 'string' ? Buffer.from(data, encoding) : data;
  await plan500G3Path('writeFile', {path, data: plan500G3Base64(bytes), exclusive: flag.includes('x')}, 'open');
}
// A read-only FileHandle: the snapshot plugin reads changed files through one.
function plan500G3Handle(path) {
  let position = 0, closed = false;
  const refuse = syscall => async () => { throw plan500G3NodeError('EROFS', syscall, path, plan500G3Refused); };
  const handle = {
    fd: -1,
    async stat(options) { return plan500G3Stats(await plan500G3Path('stat', {path}, 'fstat'), options?.bigint); },
    async read(buffer, offset, length, at) {
      if (closed) throw plan500G3NodeError('EBADF', 'read', path);
      if (buffer && !ArrayBuffer.isView(buffer)) ({buffer, offset, length, position: at} = buffer);
      buffer ??= Buffer.alloc(16384);
      offset ??= 0; length ??= buffer.byteLength - offset;
      const sequential = at === null || at === undefined || at < 0;
      const chunk = plan500Bytes(await plan500G3Path('read', {path, offset: sequential ? position : Number(at), length}, 'read'));
      new Uint8Array(buffer.buffer, buffer.byteOffset, buffer.byteLength).set(chunk, offset);
      if (sequential) position += chunk.length;
      return {bytesRead: chunk.length, buffer};
    },
    async readFile(options) { return plan500G3ReadFile(path, options); },
    async close() { closed = true; },
    write: refuse('write'), writeFile: refuse('write'), appendFile: refuse('write'), truncate: refuse('ftruncate'),
    chmod: refuse('fchmod'), sync: async () => {}, datasync: async () => {},
  };
  handle[Symbol.asyncDispose] = () => handle.close();
  return handle;
}
async function plan500G3Promise(name, args, target, second) {
  const [path, options] = args;
  switch (name) {
    case 'readFile': return plan500G3ReadFile(target, options);
    case 'writeFile': return plan500G3WriteFile(target, args[1], args[2]);
    case 'mkdir': await plan500G3Path('mkdir', {path: target, recursive: !!options?.recursive}); return undefined;
    case 'mkdtemp': return plan500G3Path('mkdtemp', {path: target});
    case 'readdir': {
      const entries = await plan500G3Path('readdir', {path: target}, 'scandir');
      return options?.withFileTypes ? entries.map(x => plan500G3Dirent(target, x)) : entries.map(x => x.name);
    }
    case 'stat': return plan500G3Stats(await plan500G3Path('stat', {path: target}), options?.bigint);
    case 'lstat': return plan500G3Stats(await plan500G3Path('lstat', {path: target}), options?.bigint);
    case 'realpath': return plan500G3Path('realpath', {path: target});
    case 'readlink': return plan500G3Path('readlink', {path: target});
    case 'access': await plan500G3Path('stat', {path: target}, 'access'); return undefined;
    case 'rm': await plan500G3Path('rm', {path: target, recursive: !!options?.recursive, force: !!options?.force}); return undefined;
    case 'unlink': await plan500G3Path('unlink', {path: target}); return undefined;
    case 'rename':
      if (!target || !second) throw plan500G3NodeError('EXDEV', 'rename', String(path), 'cross-device link not permitted');
      await plan500G3Path('rename', {path: target, to: second}); return undefined;
    case 'copyFile': {
      const exclusive = ((args[2] ?? 0) & 1) === 1;
      if (target && second) { await plan500G3Path('copyFile', {path: target, to: second, exclusive}, 'copyfile'); return undefined; }
      if (second) { await plan500G3WriteFile(second, await promises.readFile(path), {flag: exclusive ? 'wx' : 'w'}); return undefined; }
      return promises.writeFile(args[1], await plan500G3ReadFile(target), {flag: exclusive ? 'wx' : 'w'});
    }
    case 'open': {
      const flags = args[1] ?? 'r';
      if (flags !== 'r' && flags !== 'rs' && flags !== 0) throw plan500G3NodeError('EROFS', 'open', target, plan500G3Refused);
      await plan500G3Path('stat', {path: target}, 'open');
      return plan500G3Handle(target);
    }
    case 'opendir': {
      const entries = (await plan500G3Path('readdir', {path: target}, 'opendir')).map(x => plan500G3Dirent(target, x));
      let index = 0;
      const dir = {path: target, read: async () => entries[index++] ?? null, readSync: () => entries[index++] ?? null,
        close: async () => {}, closeSync: () => {}, async *[Symbol.asyncIterator]() { while (index < entries.length) yield entries[index++]; }};
      return dir;
    }
    default: throw plan500G3NodeError('EROFS', name, String(target ?? second), plan500G3Refused);
  }
}
// The Worker VFS parses only string open flags; the attachment store opens with O_CREAT|O_EXCL|O_WRONLY.
let plan500G3OpenConstants;
function plan500G3StringFlags(flags) {
  if (typeof flags !== 'number') return flags;
  const {O_WRONLY, O_RDWR, O_CREAT, O_EXCL, O_TRUNC, O_APPEND} = plan500G3OpenConstants;
  const plus = (flags & O_RDWR) === O_RDWR ? '+' : '', writes = plus || (flags & O_WRONLY) === O_WRONLY;
  const known = O_WRONLY | O_RDWR | O_CREAT | O_EXCL | O_TRUNC | O_APPEND;
  if (!writes && !(flags & known)) return 'r';
  if (plus && !(flags & (O_CREAT | O_TRUNC | O_APPEND))) return 'r+';
  if (!(flags & ~known) && flags & O_CREAT) {
    if (flags & O_APPEND) return 'a' + (flags & O_EXCL ? 'x' : '') + plus;
    if (flags & O_EXCL) return 'wx' + plus;
    if (flags & O_TRUNC) return 'w' + plus;
  }
  throw plan500G3NodeError('EINVAL', 'open', '', `open flags ${flags} have no Worker VFS equivalent`);
}
// Called by every node:fs/promises member (see prepare-web.mjs); a no-op until gate3-install.
self.plan500FsRoute = (name, args, base) => {
  if (!plan500G3Installed || name === 'watch' || name === 'constants') return base(...args);
  const target = plan500G3Native(args[0]);
  const second = ['rename', 'copyFile', 'cp', 'link'].includes(name) ? plan500G3Native(args[1]) : undefined;
  if (target === undefined && second === undefined) {
    if (name === 'open' && typeof args[1] === 'number') return (async () => base(args[0], plan500G3StringFlags(args[1]), ...args.slice(2)))();
    return base(...args);
  }
  return plan500G3Promise(name, args, target, second);
};

// MARK: ctx.fs (dsh-fs-local, which dsh-fs-sandbox extends): the same messages and checks, native bytes

function plan500G3InstallFileSystem(require) {
  const posix = require('node:path').posix;
  const {FsError, FsTargetKey, FsVersion} = require('@deepseek-ai/dsh-fs');
  const {LocalFileSystem} = require('@deepseek-ai/dsh-fs-local');
  const proto = LocalFileSystem.prototype;
  const original = {};
  for (const name of ['resolve', 'stat', 'lstat', 'readText', 'streamText', 'readBytes', 'readByteRange', 'listDir',
    'writeText', 'editText', 'watch']) original[name] = proto[name];
  const readLimit = 1 << 30, binarySample = 8192;
  const inMount = target => plan500G3Inside(String(target?.targetKey ?? target));
  // dsh-fs-local's localDisplayPath for POSIX.
  const display = (cwd, path) => {
    const absolute = posix.isAbsolute(cwd) ? cwd : `${process.cwd()}/${cwd}`;
    const raw = posix.isAbsolute(path) ? path : `${absolute}/${path}`;
    return /(?:^|[\\/])\.\.(?:[\\/]|$)/u.test(raw) ? raw : posix.resolve(cwd, path);
  };
  const wording = {FS_NOT_FOUND: 'not found', FS_NOT_REGULAR_FILE: 'not a regular file', FS_NOT_DIRECTORY: 'not a directory',
    FS_PERMISSION_DENIED: 'permission denied', FS_SANDBOX_DENIED: 'path leaves the workspace', FS_TOO_LARGE: 'too large',
    FS_IO_ERROR: 'I/O error'};
  const mapped = (verb, displayPath, error) => error instanceof FsError || !error?.code ? error
    : new FsError(`cannot ${verb} "${displayPath}": ${error.detail || wording[error.code] || error.code}`, error.code);
  const aborted = (signal, verb) => { if (signal?.aborted) throw new FsError(`${verb} aborted`, 'FS_ABORTED'); };
  const decode = (bytes, verb, displayPath) => {
    try { return new TextDecoder('utf-8', {fatal: true}).decode(bytes); }
    catch { throw new FsError(`cannot ${verb} "${displayPath}": invalid UTF-8 text`, 'FS_NOT_TEXT'); }
  };
  const normalize = content => content.replaceAll('\r\n', '\n');
  const detectLineEndings = raw => {
    const sample = raw.slice(0, 4096), crlf = sample.split('\r\n').length - 1;
    return crlf > sample.split('\n').length - 1 - crlf ? 'CRLF' : 'LF';
  };
  const restoreLineEndings = (content, lineEndings) => lineEndings === 'LF' ? content : normalize(content).split('\n').join('\r\n');
  const countOccurrences = (content, needle) => {
    let count = 0, index = 0;
    while (true) { const found = content.indexOf(needle, index); if (found === -1) return count; count += 1; index = found + needle.length; }
  };
  const applyLiteralEdit = (content, oldString, newString, replaceAll, displayPath) => {
    const oldNorm = normalize(oldString);
    if (oldNorm.length === 0) throw new FsError('old_string must be a non-empty string', 'FS_EDIT_NOT_FOUND');
    const newNorm = normalize(newString), replacements = countOccurrences(content, oldNorm);
    if (replacements === 0) throw new FsError(`old_string was not found in "${displayPath}"`, 'FS_EDIT_NOT_FOUND');
    if (!replaceAll && replacements > 1) throw new FsError(`old_string matched ${replacements} times in "${displayPath}"; provide a more specific old_string or set replace_all to true`, 'FS_AMBIGUOUS_EDIT');
    return {content: content.split(oldNorm).join(newNorm), replacements};
  };
  // Native files carry store tokens; directories (which the store does not version) get dsh-fs-local's spelling.
  const probe = async (path, follow) => {
    const info = await plan500G3('fs', 'stat', {path, follow});
    if (!info) return null;
    let version = info.version;
    if (version === null) {
      const s = await plan500G3('path', follow ? 'stat' : 'lstat', {path});
      version = `${s.dev}:${Math.trunc(s.ino)}:${s.size}:${s.mtimeNs}:${s.ctimeNs}`;
    }
    return {version: FsVersion(version), mode: info.mode, type: info.type, size: info.size};
  };
  const regular = async (target, verb, signal) => {
    aborted(signal, verb);
    let info;
    try { info = await probe(target.targetKey, true); } catch (error) { throw mapped(verb, target.displayPath, error); }
    if (!info) throw new FsError(`cannot ${verb} "${target.displayPath}": not found`, 'FS_NOT_FOUND');
    if (info.type !== 'file') throw new FsError(`cannot ${verb} "${target.displayPath}": not a regular file`, 'FS_NOT_REGULAR_FILE');
    return info;
  };
  const readAll = async (target, verb, limit = readLimit) => {
    try {
      const read = await plan500G3('fs', 'read', {path: target.targetKey, limit});
      return {bytes: Buffer.from(plan500Bytes(read.data)), version: read.version};
    } catch (error) { throw mapped(verb, target.displayPath, error); }
  };
  const writeError = (verb, displayPath, error) => error?.code === 'FS_NOT_OBSERVED'
    ? new FsError(`cannot overwrite existing "${displayPath}" without reading it first`, 'FS_NOT_OBSERVED')
    : mapped(verb, displayPath, error);

  proto.resolve = async function (path, opts) {
    if (typeof path !== 'string' || path.trim().length === 0) return original.resolve.call(this, path, opts);
    const displayPath = display(opts?.cwd ?? this.config.cwd, path);
    if (!plan500G3Inside(displayPath)) return original.resolve.call(this, path, opts);
    if (opts?.signal?.aborted) throw new FsError('resolve aborted', 'FS_ABORTED');
    let key;
    try { key = await plan500G3('fs', 'realpath', {path: displayPath}); }
    catch (error) { throw mapped('resolve', displayPath, error); }
    if (opts?.signal?.aborted) throw new FsError('resolve aborted', 'FS_ABORTED');
    return {targetKey: FsTargetKey(key), displayPath};
  };
  proto.stat = async function (target, signal) {
    if (!inMount(target)) return original.stat.call(this, target, signal);
    if (signal?.aborted) throw new FsError('stat aborted', 'FS_ABORTED');
    const info = await probe(target.targetKey, true);
    if (signal?.aborted) throw new FsError('stat aborted', 'FS_ABORTED');
    return info ? {version: info.version, type: info.type, size: info.size} : undefined;
  };
  proto.lstat = async function (path, opts, signal) {
    if (typeof path !== 'string' || path.trim().length === 0) return original.lstat.call(this, path, opts, signal);
    const displayPath = display(opts?.cwd ?? this.config.cwd, path);
    if (!plan500G3Inside(displayPath)) return original.lstat.call(this, path, opts, signal);
    if (signal?.aborted) throw new FsError('lstat aborted', 'FS_ABORTED');
    const info = await probe(displayPath, false);
    if (signal?.aborted) throw new FsError('lstat aborted', 'FS_ABORTED');
    return info ? {version: info.version, type: info.type, size: info.size} : undefined;
  };
  proto.readText = async function (target, signal) {
    if (!inMount(target)) return original.readText.call(this, target, signal);
    await regular(target, 'read', signal);
    const {bytes} = await readAll(target, 'read');
    aborted(signal, 'read');
    if (bytes.subarray(0, binarySample).includes(0)) throw new FsError(`cannot read "${target.displayPath}": binary file`, 'FS_NOT_TEXT');
    return decode(bytes, 'read', target.displayPath);
  };
  proto.streamText = function (target, signal) {
    if (!inMount(target)) return original.streamText.call(this, target, signal);
    const self = this;
    return Promise.resolve((async function* () { yield await proto.readText.call(self, target, signal); })());
  };
  proto.readBytes = async function (target, signal, maxBytes) {
    if (!inMount(target)) return original.readBytes.call(this, target, signal, maxBytes);
    const info = await regular(target, 'read', signal);
    if (info.size > maxBytes) throw new FsError(`cannot read "${target.displayPath}": ${info.size} bytes exceeds the ${maxBytes}-byte limit`, 'FS_TOO_LARGE');
    try { return (await readAll(target, 'read', maxBytes)).bytes; }
    catch (error) {
      if (error?.code === 'FS_TOO_LARGE') throw new FsError(`cannot read "${target.displayPath}": content exceeds the ${maxBytes}-byte limit`, 'FS_TOO_LARGE');
      throw error;
    }
  };
  proto.readByteRange = async function (target, range, signal) {
    if (!inMount(target)) return original.readByteRange.call(this, target, range, signal);
    await regular(target, 'read', signal);
    if (range.length === 0) return new Uint8Array(0);
    try { return Buffer.from(plan500Bytes(await plan500G3('fs', 'readRange', {path: target.targetKey, offset: range.offset, length: range.length}))); }
    catch (error) { throw mapped('read', target.displayPath, error); }
  };
  proto.listDir = async function (target, signal) {
    if (!inMount(target)) return original.listDir.call(this, target, signal);
    aborted(signal, 'list');
    let entries;
    try { entries = await plan500G3('fs', 'list', {path: target.targetKey}); }
    catch (error) { throw mapped('list', target.displayPath, error); }
    const result = [];
    for (const entry of entries.sort((left, right) => left.name.localeCompare(right.name))) {
      aborted(signal, 'list');
      let version = entry.version;
      if (version === undefined && entry.type === 'directory') version = (await probe(entry.target, true))?.version;
      result.push({name: entry.name, type: entry.type,
        target: {targetKey: FsTargetKey(entry.target), displayPath: display(target.displayPath, entry.name)},
        ...version !== undefined ? {version: FsVersion(version)} : {},
        ...entry.type === 'file' ? {size: entry.size} : {}});
    }
    return result;
  };
  // Version check, create-if-absent and the before basis are decided natively under the store's lease.
  proto.writeText = async function (target, content, expected, signal) {
    if (!inMount(target)) return original.writeText.apply(this, arguments);
    return this.withLock(target.targetKey, async () => {
      aborted(signal, 'write');
      const bytes = Buffer.from(content, 'utf8');
      const limit = this.config.diffBasisMaxBytes;
      let outcome;
      try {
        outcome = await plan500G3('fs', 'write', {path: target.targetKey, data: plan500G3Base64(bytes),
          ...expected ? {expected: {kind: expected.kind, version: expected.version}} : {},
          beforeLimit: bytes.length < limit ? limit : 0});
      } catch (error) { throw writeError('write', target.displayPath, error); }
      let before = null;
      if (outcome.before !== null) {
        const basis = plan500Bytes(outcome.before);
        if (!basis.includes(0)) try { before = normalize(new TextDecoder('utf-8', {fatal: true}).decode(basis)); } catch {}
      }
      return {operation: outcome.operation, version: FsVersion(outcome.version), before, after: normalize(content)};
    });
  };
  proto.editText = async function (target, edit, expected, signal) {
    if (!inMount(target)) return original.editText.apply(this, arguments);
    return this.withLock(target.targetKey, async () => {
      const displayPath = target.displayPath, stale = () => new FsError(`cannot edit "${displayPath}": file changed since it was read`, 'FS_STALE_VERSION');
      let existing;
      try { existing = await probe(target.targetKey, true); } catch (error) { throw mapped('edit', displayPath, error); }
      if (!existing) throw stale();
      if (existing.type !== 'file') throw new FsError(`cannot edit "${displayPath}": not a regular file`, 'FS_NOT_REGULAR_FILE');
      if (expected && existing.version !== expected.version) throw stale();
      aborted(signal, 'edit');
      const {bytes, version} = await readAll(target, 'edit');
      if (version !== existing.version) throw stale();
      aborted(signal, 'edit');
      if (bytes.includes(0)) throw new FsError(`cannot edit "${displayPath}": binary file`, 'FS_NOT_TEXT');
      const raw = decode(bytes, 'edit', displayPath);
      const original = {content: normalize(raw), lineEndings: detectLineEndings(raw)};
      const edited = applyLiteralEdit(original.content, edit.oldString, edit.newString, edit.replaceAll, displayPath);
      const content = restoreLineEndings(edited.content, original.lineEndings);
      let outcome;
      try {
        outcome = await plan500G3('fs', 'write', {path: target.targetKey, data: plan500G3Base64(Buffer.from(content, 'utf8')),
          expected: {kind: 'replaceIfVersion', version}, beforeLimit: 0});
      } catch (error) { throw writeError('edit', displayPath, error); }
      return {version: FsVersion(outcome.version), before: original.content, after: edited.content};
    });
  };
  // Gap (documented in #39): no change feed from the native store yet; a mount watch never fires.
  proto.watch = async function (target, changed, signal) {
    if (!inMount(target)) return original.watch.call(this, target, changed, signal);
    signal?.throwIfAborted();
    return () => {};
  };
}

// MARK: Subprocesses: rg (fs-search) and git (workspace-changes) run natively

function plan500G3Reader(bytes, maxBytes) {
  const lossy = maxBytes !== undefined && bytes.length > maxBytes;
  const kept = lossy ? bytes.subarray(bytes.length - maxBytes) : bytes;
  const start = bytes.length - kept.length;
  return {readFrom(from = 0) {
    const offset = Math.max(from, start);
    return {text: new TextDecoder().decode(kept.subarray(offset - start)), nextOffset: bytes.length, lossy: lossy && from < start};
  }};
}
function plan500G3Process(tool, spec) {
  const stdin = spec.stdio?.stdin?.data;
  const outcome = (async () => {
    if (spec.signal?.aborted) return {exitCode: null, signal: 'SIGTERM'};
    const result = await plan500G3('spawn', 'run', {tool, argv: spec.argv, cwd: spec.cwd, env: spec.env ?? {},
      stdin: stdin === undefined ? '' : plan500G3Base64(typeof stdin === 'string' ? Buffer.from(stdin, 'utf8') : stdin)});
    handle.collected.stdout = plan500G3Reader(plan500Bytes(result.stdout), spec.stdio?.stdout?.maxBytes);
    handle.collected.stderr = plan500G3Reader(plan500Bytes(result.stderr), spec.stdio?.stderr?.maxBytes);
    return {exitCode: result.exitCode, signal: null};
  })();
  const handle = {pid: undefined, done: outcome, collected: {},
    terminate: async () => { await outcome.catch(() => {}); }, waitForExit: async () => { await outcome.catch(() => {}); }};
  return handle;
}
function plan500G3InstallSubprocess() {
  const proto = Object.getPrototypeOf(host.prototypeContext.get('subprocess'));
  const {resolveExecutable, spawn} = proto;
  proto.resolveExecutable = async function (command, env, signal) {
    return command === 'git' ? plan500G3Git : resolveExecutable.call(this, command, env, signal);
  };
  proto.spawn = function (spec) {
    const tool = spec.argv?.[0] === plan500G3Git ? 'git' : spec.argv?.[0] === plan500G3Rg ? 'rg' : undefined;
    return tool && plan500G3Inside(String(spec.cwd)) ? plan500G3Process(tool, spec) : spawn.call(this, spec);
  };
}

// MARK: The only write path: refuse every VFS mutation under the mount (node:fs sync shims call these too)

function plan500G3InstallGuard(posix) {
  const vfs = host.vfs;
  const refused = (syscall, path) => plan500G3NodeError('EROFS', syscall, path, plan500G3Refused);
  const under = path => typeof path === 'string' && plan500G3Inside(posix.normalize(path));
  for (const [name, syscall] of [['writeFileSync', 'open'], ['appendFileSync', 'open'], ['linkSync', 'link'],
    ['truncateSync', 'truncate'], ['chmodSync', 'chmod'], ['unlinkSync', 'unlink'], ['rmSync', 'rm'], ['mkdtempSync', 'mkdtemp']]) {
    const base = vfs[name].bind(vfs);
    vfs[name] = (path, ...rest) => {
      if (under(path) || (name === 'linkSync' && under(rest[0]))) throw refused(syscall, path);
      return base(path, ...rest);
    };
  }
  const mkdir = vfs.mkdirSync.bind(vfs);
  vfs.mkdirSync = (path, options) => {
    if (under(path) && !(options?.recursive && vfs.existsSync(path))) throw refused('mkdir', path);
    return mkdir(path, options);
  };
  const rename = vfs.renameSync.bind(vfs);
  vfs.renameSync = (from, to) => { if (under(from) || under(to)) throw refused('rename', from); return rename(from, to); };
  const open = vfs.openFileSync.bind(vfs);
  vfs.openFileSync = (path, flags = 'r', mode) => {
    if (under(path) && flags !== 'r' && flags !== 'rs' && flags !== 0) throw refused('open', path);
    return open(path, flags, mode);
  };
}

// MARK: sharp (the attachment store's raster codec is a libvips addon; ImageIO stands in natively)

// The slice of sharp's pipeline the official attachment store calls. Only JPEG encodes: iOS has no
// WebP encoder, so the store's alpha path fails with IMAGE_ENCODER_UNAVAILABLE rather than a wrong format.
function plan500G3Sharp(input, _options) {
  const data = plan500G3Base64(input);
  const plan = {rotate: false, width: undefined, height: undefined, withoutEnlargement: false, format: undefined, quality: 80, raw: false};
  const pipeline = {
    async metadata() {
      const meta = await plan500G3('image', 'metadata', {data});
      // sharp leaves absent metadata undefined; the store treats any present field as retained metadata.
      return {format: meta.format, width: meta.width, height: meta.height, pages: meta.pages, depth: meta.depth,
        space: meta.space, hasAlpha: meta.hasAlpha, hasProfile: meta.hasProfile, orientation: meta.orientation,
        exif: meta.exif ? Buffer.alloc(0) : undefined};
    },
    rotate(angle) { if (angle !== undefined) throw new Error('GATE3_SHARP_UNSUPPORTED: rotate angle'); plan.rotate = true; return pipeline; },
    toColourspace(space) { if (space !== 'srgb') throw new Error('GATE3_SHARP_UNSUPPORTED: ' + space); return pipeline; },
    resize(options) {
      if (options.fit !== undefined && options.fit !== 'inside') throw new Error('GATE3_SHARP_UNSUPPORTED: fit ' + options.fit);
      Object.assign(plan, {width: options.width, height: options.height, withoutEnlargement: !!options.withoutEnlargement});
      return pipeline;
    },
    raw() { plan.raw = true; return pipeline; },
    jpeg(options) { plan.format = 'jpeg'; plan.quality = options?.quality ?? 80; return pipeline; },
    webp(options) { plan.format = 'webp'; plan.quality = options?.quality ?? 80; return pipeline; },
    clone() { const copy = plan500G3Sharp(input); copy.plan(plan); return copy; },
    plan(source) { Object.assign(plan, source); },
    async toBuffer(options) {
      if (plan.raw) { await plan500G3('image', 'decode', {data}); return Buffer.alloc(0); }
      if (!plan.format) throw new Error('GATE3_SHARP_UNSUPPORTED: no output format');
      const out = await plan500G3('image', 'encode', {data, rotate: plan.rotate, width: plan.width, height: plan.height,
        withoutEnlargement: plan.withoutEnlargement, format: plan.format, quality: plan.quality});
      const buffer = Buffer.from(plan500Bytes(out.data));
      return options?.resolveWithObject ? {data: buffer, info: {format: plan.format, width: out.width, height: out.height, size: buffer.length}} : buffer;
    },
  };
  return pipeline;
}

async function plan500G3Install() {
  if (plan500G3Installed) throw new Error('GATE3_ALREADY_INSTALLED');
  const require = host.modules.createRequire('/dsh/config/cordis.yml');
  const posix = require('node:path').posix;
  const seeded = await plan500Native('gate3', {call: 'seed'});
  const vfs = host.vfs;
  vfs.mkdirSync(plan500G3Mount, {recursive: true});
  // The image serves `sharp` as a refusing Worker stub (no libvips); the gate swaps in the ImageIO stand-in.
  // `@vscode/ripgrep` is already a Worker stub naming /dsh/bin/rg, which the subprocess route runs natively.
  if (!(host.modules.staticModules instanceof Map) || !host.modules.staticModules.has('sharp')) throw new Error('GATE3_SHARP_SLOT_CHANGED');
  host.modules.staticModules.set('sharp', () => plan500G3Sharp);
  // The Worker's constants omit O_EXCL, so `O_CREAT | O_EXCL` silently loses exclusivity; add Linux's value.
  plan500G3OpenConstants = require('node:fs').constants;
  if (plan500G3OpenConstants.O_EXCL === undefined) plan500G3OpenConstants.O_EXCL = 128;
  plan500G3InstallFileSystem(require);
  plan500G3InstallSubprocess();
  plan500G3InstallGuard(posix);
  plan500G3Installed = true;
  return seeded;
}

// MARK: Operations

const plan500G3Encode = value => value instanceof Uint8Array ? {bytes: plan500G3Base64(value)} : value;
// Each injected write must be refused; the native file must be untouched.
async function plan500G3Inject() {
  const require = host.modules.createRequire('/dsh/config/cordis.yml');
  const fs = require('node:fs'), fsp = require('node:fs/promises');
  const path = plan500G3Mount + '/injected.txt';
  const attempts = {
    vfsWrite: () => host.vfs.writeFileSync(path, 'x'),
    vfsMkdir: () => host.vfs.mkdirSync(plan500G3Mount + '/injected-dir'),
    vfsRename: () => host.vfs.renameSync('/dsh/tmp', plan500G3Mount + '/moved'),
    nodeWriteSync: () => fs.writeFileSync(path, 'x'),
    nodeAppendSync: () => fs.appendFileSync(path, 'x'),
    nodeUnlinkSync: () => fs.unlinkSync(plan500G3Mount + '/README.md'),
    promisesWrite: () => fsp.writeFile(path, 'x'),
    promisesAppend: () => fsp.appendFile(path, 'x'),
    promisesMkdir: () => fsp.mkdir(plan500G3Mount + '/injected-dir'),
    promisesRm: () => fsp.rm(plan500G3Mount + '/README.md'),
    promisesRename: () => fsp.rename(plan500G3Mount + '/README.md', plan500G3Mount + '/moved.md'),
    promisesCopy: () => fsp.copyFile(plan500G3Mount + '/README.md', plan500G3Mount + '/copy.md'),
    promisesOpenWrite: () => fsp.open(path, 'w'),
    promisesChmod: () => fsp.chmod(plan500G3Mount + '/README.md', 0o777),
  };
  const result = {};
  for (const [name, attempt] of Object.entries(attempts)) {
    try { await attempt(); result[name] = 'WRITTEN'; }
    catch (error) { result[name] = error.code === 'EROFS' && String(error.message).includes(plan500G3Refused) ? 'REFUSED' : `OTHER:${error.code}`; }
  }
  return result;
}
const plan500G3OriginalMessage = prototypeMessage;
prototypeMessage = async event => {
  const data = event.data;
  if (!['gate3-install', 'gate3-tool', 'gate3-service', 'gate3-turn', 'gate3-subagent', 'gate3-inject'].includes(data.operation)) {
    return plan500G3OriginalMessage(event);
  }
  try {
    const ctx = host.prototypeContext;
    let result;
    if (data.operation === 'gate3-install') result = await plan500G3Install();
    else if (data.operation === 'gate3-inject') result = await plan500G3Inject();
    else {
      const agent = ctx.get('agents').get(data.sessionId);
      if (!agent) throw new Error('AGENT_NOT_OPEN');
      if (data.operation === 'gate3-tool') {
        const signal = new AbortController().signal;
        result = await agent.ctx.get('tools').execute({callId: data.callId ?? 'gate3-' + data.id, name: data.name,
          arguments: data.args, agent, signal});
      } else if (data.operation === 'gate3-service') {
        const signal = new AbortController().signal;
        const scope = {sessionId: data.sessionId, workspaceRoot: plan500G3Mount};
        const args = data.args ?? {};
        if (data.service === 'workspaceFiles') {
          const files = ctx.get('workspaceFiles');
          if (data.method === 'readBytes') result = plan500G3Encode(await files.readBytes(scope, args.path, args.options ?? {}, signal));
          else if (data.method === 'read') result = await files.read(scope, args.path, args.range ?? {}, signal);
          else result = await files[data.method](scope, args.path, signal);
        } else if (data.service === 'fileReferences') {
          result = await ctx.get('fileReferences').list(agent, args.query, signal);
        } else if (data.service === 'workspaceChanges') {
          const changes = ctx.get('workspaceChanges');
          result = data.method === 'diff' ? await changes.diff(data.sessionId, args.seq, args.index, signal)
            : await changes.summary(data.sessionId, args.seq);
        } else throw new Error('GATE3_SERVICE_REFUSED');
      } else if (data.operation === 'gate3-turn') {
        const changes = [];
        const dispose = agent.ctx.on('session/event', (session, event) => {
          if (session.id === agent.id && event.type === 'workspace/changes') changes.push(event.seq);
        });
        try { result = await plan500ModelTurn(agent, {marker: 'GATE3_OK', ...data}); }
        finally { dispose(); }
        result.changeSeqs = changes;
      } else if (data.operation === 'gate3-subagent') {
        const run = await ctx.get('subagents').start('spawn', {label: 'gate3-child', parent: agent,
          prompt: [{type: 'text', text: data.prompt}], signal: new AbortController().signal});
        const settled = await run.result.then(value => ({ok: true, value}), error => ({ok: false, error: String(error)}));
        result = JSON.parse(JSON.stringify({ok: settled.ok, error: settled.error,
          kind: settled.value?.kind ?? settled.value?.status ?? typeof settled.value}));
      }
    }
    // Tool results and service values may carry bigints or functions; the page only needs plain JSON.
    const plain = result === undefined ? null : JSON.parse(JSON.stringify(result, (_key, v) => typeof v === 'bigint' ? Number(v) : v));
    self.postMessage({t: 'plan500-result', id: data.id, result: plain});
  } catch (error) { self.postMessage({t: 'plan500-result', id: data.id, error: String(error)}); }
};
