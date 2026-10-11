// Candidate App bridge (#17, ADR 0003). Appended by prepare.mjs to a copy of the fixed official Worker, so
// it shares that module's scope (`host`, `promises`). It is inert in a shell-process Worker: everything
// starts from the restore and install hooks, which only the host Worker's `start` calls.
//
// The Swift gateway is the single authority. Project files live only in the native workspace: every path
// under /dsh/workspace/<project> is a native call, every write goes through the gateway, and a shell
// command whose working directory is in a project runs on the project's Linux plugin. The model key stays
// in Swift; the Worker home survives a restart as a home-only checkpoint without the credentials file.
const candidateWorkspace = '/dsh/workspace/';
const candidateScratch = '/dsh/tmp/dsh-workspace-changes-';
const candidateHome = '/dsh/home';
const candidateCredentials = '/dsh/home/.credentials.yaml';
const candidateGit = '/dsh/bin/git';
const candidateRg = '/dsh/bin/rg';
const candidateRefused = 'VFS_WORKSPACE_WRITE_REFUSED';
const candidateOfficialMessages = 'https://api.deepseek.com/anthropic/v1/messages';
// Swift caps one command at ten minutes; the official executor's own deadline cancels sooner.
const candidateCommandTimeoutMs = 600000;
const candidateCheckpointDelayMs = 1500;
const candidateCheckpointIntervalMs = 30000;
const candidateWatchIntervalMs = 2000;
// A terminal read waits at most this long for output, inside the guest call's own deadline.
const candidateTerminalWaitMs = 15000;
// A line run while another writer holds the project's lease waits for it this long, then fails LEASE_BUSY.
const candidateTerminalBusyWaitMs = 70000;
const candidateTerminalChunk = 32768;

// MARK: Native calls

const candidateNativePending = new Map();
let candidateNativeId = 0;
// Unique across Workers: the Swift host outlives each Worker, so a reused id could meet a stale cancel.
const candidateIdPrefix = Math.random().toString(36).slice(2, 10);
// Called by the listener prepended to the Worker, before the official tunnel sees the frame.
self.candidateNativeReply = data => {
  const pending = candidateNativePending.get(data.id);
  if (!pending) return;
  candidateNativePending.delete(data.id);
  if (data.error !== undefined) pending.reject(new Error(data.error));
  else if (data.result?.error !== undefined) pending.reject(Object.assign(new Error(data.result.error), {code: data.result.error}));
  else pending.resolve(data.result);
};
function candidateNative(operation, fields = {}) {
  const id = ++candidateNativeId;
  return new Promise((resolve, reject) => {
    candidateNativePending.set(id, {resolve, reject});
    self.postMessage({t: 'candidate-native', id, body: {...fields, operation}});
  });
}
// A tool call: `{value}` or `{failure: {code, detail}}`, which becomes an error carrying the code.
async function candidateTool(operation, method, args) {
  const reply = await candidateNative(operation, {method, args});
  if (reply.failure) {
    const error = new Error(`${reply.failure.code}: ${reply.failure.detail ?? ''}`);
    error.code = reply.failure.code; error.detail = reply.failure.detail ?? '';
    throw error;
  }
  return reply.value;
}
const candidateLog = event => self.postMessage({t: 'candidate-log', ...event});
const candidateBytes = base64 => Uint8Array.from(atob(base64), x => x.charCodeAt(0));
function candidateBase64(bytes) {
  const view = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes.buffer ?? bytes, bytes.byteOffset ?? 0, bytes.byteLength);
  let text = '';
  for (let i = 0; i < view.length; i += 0x8000) text += String.fromCharCode.apply(null, view.subarray(i, i + 0x8000));
  return btoa(text);
}

// Textual classification: a project spelling (with any `..`) is resolved physically by the native side.
const candidateInside = path => typeof path === 'string' && path.startsWith(candidateWorkspace) && path.length > candidateWorkspace.length;
function candidateNativePath(value) {
  if (value instanceof URL) value = decodeURIComponent(value.pathname);
  if (typeof value !== 'string' || !value.startsWith('/')) return undefined;
  return candidateInside(value) || value.startsWith(candidateScratch) ? value : undefined;
}

// MARK: Node fs routes (prepare.mjs routes every node:fs/promises member through here)

const candidateErrno = {EPERM: -1, ENOENT: -2, EIO: -5, EBADF: -9, EACCES: -13, EBUSY: -16, EEXIST: -17, EXDEV: -18,
  ENOTDIR: -20, EISDIR: -21, EINVAL: -22, EROFS: -30, ELOOP: -62, ENOTEMPTY: -66, ENOSYS: -78};
function candidateNodeError(code, syscall, path, detail) {
  const error = new Error(`${code}: ${detail || code}, ${syscall} '${path}'`);
  return Object.assign(error, {code, errno: candidateErrno[code] ?? -5, syscall, path});
}
async function candidatePath(method, args, syscall = method) {
  try { return await candidateTool('path', method, args); }
  catch (error) { throw candidateNodeError(error.code ?? 'EIO', syscall, args.path, error.detail); }
}
function candidateStats(info, bigint) {
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
function candidateDirent(parentPath, entry) {
  const is = type => () => entry.type === type;
  return {name: entry.name, parentPath, path: parentPath, isFile: is('file'), isDirectory: is('directory'),
    isSymbolicLink: is('symlink'), isBlockDevice: () => false, isCharacterDevice: () => false, isFIFO: () => false,
    isSocket: () => false};
}
async function candidateReadFile(path, options) {
  const data = Buffer.from(candidateBytes(await candidatePath('readFile', {path}, 'open')));
  const encoding = typeof options === 'string' ? options : options?.encoding;
  return encoding ? data.toString(encoding) : data;
}
async function candidateWriteFile(path, data, options) {
  const flag = typeof options === 'object' && options ? options.flag ?? 'w' : 'w';
  if (!flag.startsWith('w')) throw candidateNodeError('EROFS', 'open', path, candidateRefused);
  const encoding = typeof options === 'string' ? options : options?.encoding ?? 'utf8';
  const bytes = typeof data === 'string' ? Buffer.from(data, encoding) : data;
  await candidatePath('writeFile', {path, data: candidateBase64(bytes), exclusive: flag.includes('x')}, 'open');
}
// A read-only FileHandle: the snapshot plugin reads changed files through one.
function candidateHandle(path) {
  let position = 0, closed = false;
  const refuse = syscall => async () => { throw candidateNodeError('EROFS', syscall, path, candidateRefused); };
  const handle = {
    fd: -1,
    async stat(options) { return candidateStats(await candidatePath('stat', {path}, 'fstat'), options?.bigint); },
    async read(buffer, offset, length, at) {
      if (closed) throw candidateNodeError('EBADF', 'read', path);
      if (buffer && !ArrayBuffer.isView(buffer)) ({buffer, offset, length, position: at} = buffer);
      buffer ??= Buffer.alloc(16384);
      offset ??= 0; length ??= buffer.byteLength - offset;
      const sequential = at === null || at === undefined || at < 0;
      const chunk = candidateBytes(await candidatePath('read', {path, offset: sequential ? position : Number(at), length}, 'read'));
      new Uint8Array(buffer.buffer, buffer.byteOffset, buffer.byteLength).set(chunk, offset);
      if (sequential) position += chunk.length;
      return {bytesRead: chunk.length, buffer};
    },
    async readFile(options) { return candidateReadFile(path, options); },
    async close() { closed = true; },
    write: refuse('write'), writeFile: refuse('write'), appendFile: refuse('write'), truncate: refuse('ftruncate'),
    chmod: refuse('fchmod'), sync: async () => {}, datasync: async () => {},
  };
  handle[Symbol.asyncDispose] = () => handle.close();
  return handle;
}
async function candidatePromise(name, args, target, second) {
  const [path, options] = args;
  switch (name) {
    case 'readFile': return candidateReadFile(target, options);
    case 'writeFile': return candidateWriteFile(target, args[1], args[2]);
    case 'mkdir': await candidatePath('mkdir', {path: target, recursive: !!options?.recursive}); return undefined;
    case 'mkdtemp': return candidatePath('mkdtemp', {path: target});
    case 'readdir': {
      const entries = await candidatePath('readdir', {path: target}, 'scandir');
      return options?.withFileTypes ? entries.map(x => candidateDirent(target, x)) : entries.map(x => x.name);
    }
    case 'stat': return candidateStats(await candidatePath('stat', {path: target}), options?.bigint);
    case 'lstat': return candidateStats(await candidatePath('lstat', {path: target}), options?.bigint);
    case 'realpath': return candidatePath('realpath', {path: target});
    case 'readlink': return candidatePath('readlink', {path: target});
    case 'access': await candidatePath('stat', {path: target}, 'access'); return undefined;
    case 'rm': await candidatePath('rm', {path: target, recursive: !!options?.recursive, force: !!options?.force}); return undefined;
    case 'unlink': await candidatePath('unlink', {path: target}); return undefined;
    case 'rename':
      if (!target || !second) throw candidateNodeError('EXDEV', 'rename', String(path), 'cross-device link not permitted');
      await candidatePath('rename', {path: target, to: second}); return undefined;
    case 'copyFile': {
      const exclusive = ((args[2] ?? 0) & 1) === 1;
      if (target && second) { await candidatePath('copyFile', {path: target, to: second, exclusive}, 'copyfile'); return undefined; }
      if (second) { await candidateWriteFile(second, await promises.readFile(path), {flag: exclusive ? 'wx' : 'w'}); return undefined; }
      return promises.writeFile(args[1], await candidateReadFile(target), {flag: exclusive ? 'wx' : 'w'});
    }
    case 'open': {
      const flags = args[1] ?? 'r';
      if (flags !== 'r' && flags !== 'rs' && flags !== 0) throw candidateNodeError('EROFS', 'open', target, candidateRefused);
      await candidatePath('stat', {path: target}, 'open');
      return candidateHandle(target);
    }
    case 'opendir': {
      const entries = (await candidatePath('readdir', {path: target}, 'opendir')).map(x => candidateDirent(target, x));
      let index = 0;
      return {path: target, read: async () => entries[index++] ?? null, readSync: () => entries[index++] ?? null,
        close: async () => {}, closeSync: () => {}, async *[Symbol.asyncIterator]() { while (index < entries.length) yield entries[index++]; }};
    }
    default: throw candidateNodeError('EROFS', name, String(target ?? second), candidateRefused);
  }
}
// The Worker VFS parses only string open flags; the attachment store opens with O_CREAT|O_EXCL|O_WRONLY.
let candidateOpenConstants;
function candidateStringFlags(flags) {
  if (typeof flags !== 'number' || !candidateOpenConstants) return flags;
  const {O_WRONLY, O_RDWR, O_CREAT, O_EXCL, O_TRUNC, O_APPEND} = candidateOpenConstants;
  const plus = (flags & O_RDWR) === O_RDWR ? '+' : '', writes = plus || (flags & O_WRONLY) === O_WRONLY;
  const known = O_WRONLY | O_RDWR | O_CREAT | O_EXCL | O_TRUNC | O_APPEND;
  if (!writes && !(flags & known)) return 'r';
  if (plus && !(flags & (O_CREAT | O_TRUNC | O_APPEND))) return 'r+';
  if (!(flags & ~known) && flags & O_CREAT) {
    if (flags & O_APPEND) return 'a' + (flags & O_EXCL ? 'x' : '') + plus;
    if (flags & O_EXCL) return 'wx' + plus;
    if (flags & O_TRUNC) return 'w' + plus;
  }
  throw candidateNodeError('EINVAL', 'open', '', `open flags ${flags} have no Worker VFS equivalent`);
}
// On from the restore hook, before the official tree boots, so workspace records resolve natively.
let candidateRouting = false;
self.candidateFsRoute = (name, args, base) => {
  if (!candidateRouting || name === 'watch' || name === 'constants') return base(...args);
  const target = candidateNativePath(args[0]);
  const second = ['rename', 'copyFile', 'cp', 'link'].includes(name) ? candidateNativePath(args[1]) : undefined;
  if (target === undefined && second === undefined) {
    if (name === 'open' && typeof args[1] === 'number') return (async () => base(args[0], candidateStringFlags(args[1]), ...args.slice(2)))();
    return base(...args);
  }
  return candidatePromise(name, args, target, second);
};

// MARK: ctx.fs (dsh-fs-local, which dsh-fs-sandbox extends): the same messages and checks, native bytes

function candidateInstallFileSystem(require) {
  const posix = require('node:path').posix;
  const {FsError, FsTargetKey, FsVersion} = require('@deepseek-ai/dsh-fs');
  const {LocalFileSystem} = require('@deepseek-ai/dsh-fs-local');
  const proto = LocalFileSystem.prototype;
  const original = {};
  for (const name of ['resolve', 'stat', 'lstat', 'readText', 'streamText', 'readBytes', 'readByteRange', 'listDir',
    'writeText', 'editText', 'watch']) original[name] = proto[name];
  const readLimit = 1 << 30, binarySample = 8192;
  const inProject = target => candidateInside(String(target?.targetKey ?? target));
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
    const info = await candidateTool('fs', 'stat', {path, follow});
    if (!info) return null;
    let version = info.version;
    if (version === null) {
      const s = await candidateTool('path', follow ? 'stat' : 'lstat', {path});
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
      const read = await candidateTool('fs', 'read', {path: target.targetKey, limit});
      return {bytes: Buffer.from(candidateBytes(read.data)), version: read.version};
    } catch (error) { throw mapped(verb, target.displayPath, error); }
  };
  const writeError = (verb, displayPath, error) => error?.code === 'FS_NOT_OBSERVED'
    ? new FsError(`cannot overwrite existing "${displayPath}" without reading it first`, 'FS_NOT_OBSERVED')
    : mapped(verb, displayPath, error);

  proto.resolve = async function (path, opts) {
    if (typeof path !== 'string' || path.trim().length === 0) return original.resolve.call(this, path, opts);
    const displayPath = display(opts?.cwd ?? this.config.cwd, path);
    if (!candidateInside(displayPath)) return original.resolve.call(this, path, opts);
    if (opts?.signal?.aborted) throw new FsError('resolve aborted', 'FS_ABORTED');
    let key;
    try { key = await candidateTool('fs', 'realpath', {path: displayPath}); }
    catch (error) { throw mapped('resolve', displayPath, error); }
    if (opts?.signal?.aborted) throw new FsError('resolve aborted', 'FS_ABORTED');
    return {targetKey: FsTargetKey(key), displayPath};
  };
  proto.stat = async function (target, signal) {
    if (!inProject(target)) return original.stat.call(this, target, signal);
    if (signal?.aborted) throw new FsError('stat aborted', 'FS_ABORTED');
    const info = await probe(target.targetKey, true);
    if (signal?.aborted) throw new FsError('stat aborted', 'FS_ABORTED');
    return info ? {version: info.version, type: info.type, size: info.size} : undefined;
  };
  proto.lstat = async function (path, opts, signal) {
    if (typeof path !== 'string' || path.trim().length === 0) return original.lstat.call(this, path, opts, signal);
    const displayPath = display(opts?.cwd ?? this.config.cwd, path);
    if (!candidateInside(displayPath)) return original.lstat.call(this, path, opts, signal);
    if (signal?.aborted) throw new FsError('lstat aborted', 'FS_ABORTED');
    const info = await probe(displayPath, false);
    if (signal?.aborted) throw new FsError('lstat aborted', 'FS_ABORTED');
    return info ? {version: info.version, type: info.type, size: info.size} : undefined;
  };
  proto.readText = async function (target, signal) {
    if (!inProject(target)) return original.readText.call(this, target, signal);
    await regular(target, 'read', signal);
    const {bytes} = await readAll(target, 'read');
    aborted(signal, 'read');
    if (bytes.subarray(0, binarySample).includes(0)) throw new FsError(`cannot read "${target.displayPath}": binary file`, 'FS_NOT_TEXT');
    return decode(bytes, 'read', target.displayPath);
  };
  proto.streamText = function (target, signal) {
    if (!inProject(target)) return original.streamText.call(this, target, signal);
    const self = this;
    return Promise.resolve((async function* () { yield await proto.readText.call(self, target, signal); })());
  };
  proto.readBytes = async function (target, signal, maxBytes) {
    if (!inProject(target)) return original.readBytes.call(this, target, signal, maxBytes);
    const info = await regular(target, 'read', signal);
    if (info.size > maxBytes) throw new FsError(`cannot read "${target.displayPath}": ${info.size} bytes exceeds the ${maxBytes}-byte limit`, 'FS_TOO_LARGE');
    try { return (await readAll(target, 'read', maxBytes)).bytes; }
    catch (error) {
      if (error?.code === 'FS_TOO_LARGE') throw new FsError(`cannot read "${target.displayPath}": content exceeds the ${maxBytes}-byte limit`, 'FS_TOO_LARGE');
      throw error;
    }
  };
  proto.readByteRange = async function (target, range, signal) {
    if (!inProject(target)) return original.readByteRange.call(this, target, range, signal);
    await regular(target, 'read', signal);
    if (range.length === 0) return new Uint8Array(0);
    try { return Buffer.from(candidateBytes(await candidateTool('fs', 'readRange', {path: target.targetKey, offset: range.offset, length: range.length}))); }
    catch (error) { throw mapped('read', target.displayPath, error); }
  };
  proto.listDir = async function (target, signal) {
    if (!inProject(target)) return original.listDir.call(this, target, signal);
    aborted(signal, 'list');
    let entries;
    try { entries = await candidateTool('fs', 'list', {path: target.targetKey}); }
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
    if (!inProject(target)) return original.writeText.apply(this, arguments);
    return this.withLock(target.targetKey, async () => {
      aborted(signal, 'write');
      const bytes = Buffer.from(content, 'utf8');
      const limit = this.config.diffBasisMaxBytes;
      let outcome;
      try {
        outcome = await candidateTool('fs', 'write', {path: target.targetKey, data: candidateBase64(bytes),
          ...expected ? {expected: {kind: expected.kind, version: expected.version}} : {},
          beforeLimit: bytes.length < limit ? limit : 0});
      } catch (error) { throw writeError('write', target.displayPath, error); }
      let before = null;
      if (outcome.before !== null) {
        const basis = candidateBytes(outcome.before);
        if (!basis.includes(0)) try { before = normalize(new TextDecoder('utf-8', {fatal: true}).decode(basis)); } catch {}
      }
      return {operation: outcome.operation, version: FsVersion(outcome.version), before, after: normalize(content)};
    });
  };
  proto.editText = async function (target, edit, expected, signal) {
    if (!inProject(target)) return original.editText.apply(this, arguments);
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
        outcome = await candidateTool('fs', 'write', {path: target.targetKey, data: candidateBase64(Buffer.from(content, 'utf8')),
          expected: {kind: 'replaceIfVersion', version}, beforeLimit: 0});
      } catch (error) { throw writeError('edit', displayPath, error); }
      return {version: FsVersion(outcome.version), before: original.content, after: edited.content};
    });
  };
  // dsh-fs-local's watch: a directory reports its direct entries, a file itself (absent until it appears).
  proto.watch = async function (target, changed, signal) {
    if (!inProject(target)) return original.watch.call(this, target, changed, signal);
    signal?.throwIfAborted();
    const info = await probe(target.targetKey, true).catch(() => null);
    signal?.throwIfAborted();
    const watch = {key: target.targetKey, directory: info?.type === 'directory', changed};
    watch.signature = await candidateSignature(watch);
    signal?.throwIfAborted();
    candidateWatches.add(watch);
    candidateWatchTimer ??= setInterval(candidatePollWatches, candidateWatchIntervalMs);
    return () => {
      candidateWatches.delete(watch);
      if (candidateWatches.size === 0 && candidateWatchTimer !== undefined) { clearInterval(candidateWatchTimer); candidateWatchTimer = undefined; }
    };
  };
}

// MARK: Project watches (the native store has no change feed, so each target's signature is polled)

// Files change behind the Worker from Linux commands and native draft or writer actions; a Linux command
// polls at once when it finishes, everything else within the interval.
const candidateWatches = new Set();
let candidateWatchTimer;
let candidateWatchPoll;
let candidateWatchRunning = false;
let candidateWatchAgain = false;
async function candidateSignature(watch) {
  try {
    if (!watch.directory) {
      const info = await candidateTool('fs', 'stat', {path: watch.key, follow: true});
      return info ? JSON.stringify([info.type, info.version, info.size]) : 'absent';
    }
    const entries = await candidateTool('fs', 'list', {path: watch.key});
    return JSON.stringify(entries.map(x => [x.name, x.type, x.version ?? null, x.size ?? null])
      .sort(([left], [right]) => left < right ? -1 : left > right ? 1 : 0));
  } catch (error) { return 'failed:' + (error.code ?? 'UNKNOWN'); }
}
// A call during a pass runs one more pass after it, since the running one may have read a target before the
// change. A failed read is a signature too, so it reports once, not every pass.
function candidatePollWatches() {
  if (candidateWatchRunning) { candidateWatchAgain = true; return candidateWatchPoll; }
  candidateWatchRunning = true;
  candidateWatchPoll = (async () => {
    do {
      candidateWatchAgain = false;
      for (const watch of [...candidateWatches]) {
        const signature = await candidateSignature(watch);
        if (!candidateWatches.has(watch) || signature === watch.signature) continue;
        watch.signature = signature;
        try { watch.changed(); } catch (error) { candidateLog({event: 'watch-failed', code: error.code ?? String(error)}); }
      }
    } while (candidateWatchAgain);
  })().finally(() => { candidateWatchRunning = false; candidateWatchPoll = undefined; });
  return candidateWatchPoll;
}

// MARK: Subprocesses: rg and git reads run natively; a shell command in a project runs on Linux

// A collect-mode reader keeping the newest `maxBytes`, filled once the process settles.
function candidateReader(maxBytes) {
  let bytes = new Uint8Array(0);
  return {
    fill(value) { bytes = value; },
    readFrom(from = 0) {
      const lossy = maxBytes !== undefined && bytes.length > maxBytes;
      const start = lossy ? bytes.length - maxBytes : 0;
      const offset = Math.max(from, start);
      return {text: new TextDecoder().decode(bytes.subarray(offset)), nextOffset: bytes.length, lossy: lossy && from < start};
    },
  };
}
function candidateProcess(spec, run, cancel) {
  const stdout = candidateReader(spec.stdio?.stdout?.maxBytes), stderr = candidateReader(spec.stdio?.stderr?.maxBytes);
  const done = run(stdout, stderr);
  return {pid: undefined, done, collected: {stdout, stderr},
    terminate: async () => { cancel?.(); await done.catch(() => {}); },
    waitForExit: async () => { await done.catch(() => {}); }};
}
function candidateNativeProcess(tool, spec) {
  const stdin = spec.stdio?.stdin?.data;
  return candidateProcess(spec, async (stdout, stderr) => {
    if (spec.signal?.aborted) return {exitCode: null, signal: 'SIGTERM'};
    const result = await candidateTool('spawn', 'run', {tool, argv: spec.argv, cwd: spec.cwd, env: spec.env ?? {},
      stdin: stdin === undefined ? '' : candidateBase64(typeof stdin === 'string' ? Buffer.from(stdin, 'utf8') : stdin)});
    stdout.fill(candidateBytes(result.stdout)); stderr.fill(candidateBytes(result.stderr));
    return {exitCode: result.exitCode, signal: null};
  });
}
let candidateOperationId = 0;
// One shell command on the project's Linux plugin. A refusal is a provider failure carrying its fixed code,
// so the model sees why the command did not run; it is never retried here or natively.
function candidateLinuxProcess(spec) {
  const operationId = `shell-${candidateIdPrefix}-${++candidateOperationId}`;
  let sent = false;
  const cancel = () => {
    if (sent) return;
    sent = true;
    candidateNative('cancel', {operationId}).catch(() => {});
  };
  return candidateProcess(spec, async (stdout, stderr) => {
    if (spec.signal?.aborted) return {exitCode: null, signal: 'SIGTERM'};
    if (spec.stdio?.stdin?.data !== undefined) throw new Error('LINUX_STDIN_UNSUPPORTED');
    spec.signal?.addEventListener('abort', cancel, {once: true});
    try {
      const reply = await candidateNative('execute', {operationId, command: spec.argv[2], cwd: String(spec.cwd),
        timeoutMs: candidateCommandTimeoutMs, trigger: 'shell'});
      const encoder = new TextEncoder();
      if (reply.stdout !== undefined) stdout.fill(encoder.encode(reply.stdout));
      if (reply.stderr !== undefined) stderr.fill(encoder.encode(reply.stderr));
      switch (reply.status) {
        case 'COMPLETED': return {exitCode: reply.exitCode, signal: reply.signal ?? (reply.exitCode === null ? 'SIGKILL' : null)};
        case 'CANCELLED_BEFORE_DISPATCH': return {exitCode: null, signal: 'SIGTERM'};
        case 'REFUSED': throw new Error(reply.reason);
        default: throw new Error(reply.status);
      }
    } finally {
      spec.signal?.removeEventListener('abort', cancel);
      candidatePollWatches();
    }
  }, cancel);
}
// The official hook runner (dsh-hook-protocol runHook) is the only caller that gives a shell command stdin. It
// reads a throw or a missing exit code as "no decision", which lets the action go on, so every answer that is
// not a finished command becomes exit code 2 with `DSH_HOOK_NOT_RUN <code>`, which it reads as a block
// (#39 gate 5). runHook only calls `result()` on the execution.
const candidateHookNotRun = code => ({exitCode: 2, stdout: {text: ''}, stderr: {text: 'DSH_HOOK_NOT_RUN ' + code}});
const candidateCode = (value, fallback) => String(value ?? '').match(/^[A-Z][A-Z0-9_]*/)?.[0] || fallback;
const candidateQuote = value => "'" + value.replace(/'/g, "'\\''") + "'";
// The guest gives a command no stdin and its own environment, so the payload is replayed from the command text
// and the hook's env exported first. A path in the command's project, in an env value or a JSON payload string,
// is spelled as the guest mounts it. A payload too large for one request is refused natively (BODY_TOO_LARGE).
function candidateHookCommand(spec) {
  const mount = candidateWorkspace + String(spec.workdir).slice(candidateWorkspace.length).split('/')[0];
  const guest = value => value === mount || value.startsWith(mount + '/') ? '/workspace' + value.slice(mount.length) : value;
  const guestJSON = value => typeof value === 'string' ? guest(value)
    : Array.isArray(value) ? value.map(guestJSON)
    : value && typeof value === 'object' ? Object.fromEntries(Object.entries(value).map(([key, item]) => [key, guestJSON(item)]))
    : value;
  const lines = [];
  for (const [name, value] of Object.entries(spec.env ?? {})) {
    if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(name) || typeof value !== 'string' || value.includes('\0')) return {refused: 'HOOK_ENV_REFUSED'};
    lines.push(`export ${name}=${candidateQuote(guest(value))}`);
  }
  if (typeof spec.stdin !== 'string' || spec.stdin.includes('\0')) return {refused: 'HOOK_STDIN_REFUSED'};
  let stdin = spec.stdin;
  try { stdin = JSON.stringify(guestJSON(JSON.parse(stdin))) + (stdin.endsWith('\n') ? '\n' : ''); } catch {}
  lines.push(`printf '%s' ${candidateQuote(stdin)} | (\n${spec.command}\n)`);
  return {command: lines.join('\n') + '\n'};
}
function candidateLinuxHook(spec) {
  return {result: async () => {
    const operationId = `hook-${candidateIdPrefix}-${++candidateOperationId}`;
    const cancel = () => { candidateNative('cancel', {operationId}).catch(() => {}); };
    if (spec.signal?.aborted) return candidateHookNotRun('CANCELLED_BEFORE_DISPATCH');
    const built = candidateHookCommand(spec);
    if (built.refused) return candidateHookNotRun(built.refused);
    spec.signal?.addEventListener('abort', cancel, {once: true});
    let reply;
    try {
      reply = await candidateNative('execute', {operationId, command: built.command, cwd: String(spec.workdir),
        timeoutMs: Math.min(spec.timeoutMs ?? candidateCommandTimeoutMs, candidateCommandTimeoutMs), trigger: 'hook'});
    } catch (error) {
      return candidateHookNotRun(candidateCode(error?.message ?? error, 'NATIVE_ERROR'));
    } finally {
      spec.signal?.removeEventListener('abort', cancel);
      candidatePollWatches();
    }
    if (reply.status !== 'COMPLETED')
      return candidateHookNotRun(reply.status === 'REFUSED' ? candidateCode(reply.reason, 'REFUSED') : candidateCode(reply.status, 'NATIVE_ERROR'));
    if (!Number.isInteger(reply.exitCode))
      return candidateHookNotRun(reply.timedOut ? 'HOOK_TIMEOUT' : reply.cancelled ? 'HOOK_CANCELLED' : 'HOOK_NO_EXIT');
    return {exitCode: reply.exitCode, stdout: {text: reply.stdout ?? ''}, stderr: {text: reply.stderr ?? ''}};
  }};
}
// The official LocalTerminalHandle's shape (dsh-subprocess-local), backed by a pty shell on the project's
// Linux plugin. The terminal holds the project's write lease only while a line runs in it: Swift takes it
// when input runs a line at the prompt and releases it once the prompt is idle again with no file open for
// writing. Output is the bundle's own stream PassThrough, ended when the shell exits.
let candidateTerminalId = 0;
const candidateSleep = ms => new Promise(resolve => setTimeout(resolve, ms));
async function candidateTerminal(spec) {
  spec.signal?.throwIfAborted();
  const terminalId = `term-${candidateIdPrefix}-${++candidateTerminalId}`;
  const call = (operation, fields = {}) => candidateNative('terminal-' + operation, {...fields, terminalId});
  const {pid} = await call('open', {cwd: String(spec.cwd), argv: spec.argv, cols: spec.cols ?? 80, rows: spec.rows ?? 24,
    env: spec.env ?? {}, terminalType: spec.terminalType});
  const output = new PassThrough();
  let exited = false, closing, settle, activity = {state: 'unknown', revision: 0}, writes = Promise.resolve();
  const done = new Promise(resolve => { settle = resolve; });
  const finish = outcome => { if (exited) return; exited = true; output.end(); settle(outcome); };
  const close = () => closing ??= call('close', {graceMs: spec.graceMs ?? 1000})
    .catch(error => { if (error.code !== 'TERMINAL_NOT_FOUND') { closing = undefined; throw error; } })
    .finally(() => candidatePollWatches());
  (async () => {
    let offset = 0, failures = 0;
    while (!exited) {
      let read;
      try { read = await call('read', {offset, waitMs: candidateTerminalWaitMs}); failures = 0; }
      catch (error) {
        // A terminal the guest no longer has, or a guest that stays unreachable, has hung up.
        if (closing || error.code === 'TERMINAL_NOT_FOUND' || ++failures >= 3) break;
        await candidateSleep(500);
        continue;
      }
      activity = read.activity ?? activity;
      offset = read.next;
      if (read.data && !output.write(Buffer.from(candidateBytes(read.data))))
        await new Promise(resolve => { output.once('drain', resolve); output.once('close', resolve); });
      if (read.released) candidatePollWatches();
      if (read.exited) {
        finish({exitCode: read.exited.signal ? null : read.exited.code, signal: read.exited.signal ?? null});
        // The guest keeps an exited shell until it is closed; free its slot now.
        return close().catch(() => {});
      }
    }
    finish({exitCode: null, signal: 'SIGHUP'});
  })();
  const live = () => { if (exited) throw new Error('terminal process has exited'); };
  // Writes go out in order; a run line refused LEASE_BUSY holds the input after it until it is taken.
  const send = async bytes => {
    for (let at = 0; at < bytes.length; at += candidateTerminalChunk) {
      const data = candidateBase64(bytes.subarray(at, at + candidateTerminalChunk));
      for (let waited = 0; ; waited += 250) {
        live();
        const reply = await call('write', {data});
        if (reply.status === 'WRITTEN') break;
        if (reply.status !== 'REFUSED' || reply.reason !== 'LEASE_BUSY' || waited >= candidateTerminalBusyWaitMs)
          throw new Error(reply.status === 'REFUSED' ? reply.reason : reply.status);
        await candidateSleep(250);
      }
    }
  };
  return {
    pid, output, done,
    get running() { return !exited; },
    async write(data) {
      live();
      const bytes = typeof data === 'string' ? new TextEncoder().encode(data) : new Uint8Array(data.buffer ?? data, data.byteOffset ?? 0, data.byteLength);
      const sent = writes.then(() => send(bytes));
      writes = sent.catch(() => {});
      return sent;
    },
    async resize(cols, rows) { live(); await call('resize', {cols, rows}); },
    async inspectForeground() {
      if (exited) return undefined;
      const inspected = await call('inspect');
      activity = inspected.activity ?? activity;
      return inspected.foreground ?? undefined;
    },
    async inspectActivity() {
      if (exited) return {state: 'idle', revision: activity.revision};
      activity = (await call('inspect')).activity ?? activity;
      return activity;
    },
    async signalForeground(signal) { live(); return (await call('signal', {signal})).processGroupId; },
    async terminate() { await close(); finish({exitCode: null, signal: 'SIGHUP'}); },
  };
}
const candidateShellCommand = argv => Array.isArray(argv) && argv.length === 3 && argv[0] === 'bash' && argv[1] === '-c'
  && typeof argv[2] === 'string';
// The guest's terminal is always an interactive bash: only it reports an idle prompt, which ends its lease.
const candidateTerminalShell = '/bin/bash';
function candidateInstallSubprocess(ctx) {
  const proto = Object.getPrototypeOf(ctx.get('subprocess'));
  const {resolveExecutable, spawn} = proto;
  proto.resolveExecutable = async function (command, env, signal) {
    if (command === candidateTerminalShell) return command;
    return command === 'git' ? candidateGit : resolveExecutable.call(this, command, env, signal);
  };
  proto.spawn = function (spec) {
    if (!candidateInside(String(spec.cwd))) return spawn.call(this, spec);
    if (candidateShellCommand(spec.argv)) return candidateLinuxProcess(spec);
    const tool = spec.argv?.[0] === candidateGit ? 'git' : spec.argv?.[0] === candidateRg ? 'rg' : undefined;
    return tool ? candidateNativeProcess(tool, spec) : spawn.call(this, spec);
  };
  // The Worker has no pty, so a terminal exists only in a project, as a shell on its Linux plugin. The
  // environment names the guest's shell, which the controller resolves before it spawns.
  proto.terminalEnvironment = async function (signal) {
    signal?.throwIfAborted();
    return {platform: 'posix', defaultShell: candidateTerminalShell};
  };
  proto.spawnTerminal = async function (spec) {
    if (!candidateInside(String(spec.cwd))) throw new Error('TERMINAL_OUTSIDE_PROJECT');
    return candidateTerminal(spec);
  };
}
// The official bash tool confines a command with the Worker's virtual sandbox launcher. In a project the
// command runs on the Linux VM instead, which is its isolation, so the plain `bash -c` argv reaches spawn.
// A hook in a project runs on Linux as a task of its own.
function candidateInstallShell(ctx) {
  const shell = ctx.get('shell');
  const proto = Object.getPrototypeOf(shell);
  const decorate = shell.constructor.decorateResult;
  if (typeof decorate !== 'function') return;
  const execute = proto.execute;
  proto.execute = async function (spec) {
    if (!candidateInside(String(spec.workdir))) return execute.call(this, spec);
    if (spec.stdin !== undefined) return candidateLinuxHook(spec);
    const mode = spec.sandboxPolicy?.mode;
    return decorate(await this.executeArgv(spec, ['bash', '-c', spec.command]),
      result => ({...result, sandbox: {mode, denied: false}}));
  };
}

// MARK: The only write path: refuse every VFS mutation under a project (node:fs sync shims call these too)

let candidateVfsMkdir;
function candidateInstallGuard(vfs, posix) {
  const refused = (syscall, path) => candidateNodeError('EROFS', syscall, path, candidateRefused);
  const under = path => typeof path === 'string' && candidateInside(posix.normalize(path));
  for (const [name, syscall] of [['writeFileSync', 'open'], ['appendFileSync', 'open'], ['linkSync', 'link'],
    ['truncateSync', 'truncate'], ['chmodSync', 'chmod'], ['unlinkSync', 'unlink'], ['rmSync', 'rm'], ['mkdtempSync', 'mkdtemp']]) {
    const base = vfs[name].bind(vfs);
    vfs[name] = (path, ...rest) => {
      if (under(path) || (name === 'linkSync' && under(rest[0]))) throw refused(syscall, path);
      return base(path, ...rest);
    };
  }
  candidateVfsMkdir = vfs.mkdirSync.bind(vfs);
  vfs.mkdirSync = (path, options) => {
    if (under(path) && !(options?.recursive && vfs.existsSync(path))) throw refused('mkdir', path);
    return candidateVfsMkdir(path, options);
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

// The slice of sharp's pipeline the official attachment store calls. Only JPEG encodes on iOS, so the
// store's alpha path fails with IMAGE_ENCODER_UNAVAILABLE rather than a wrong format.
function candidateSharp(input) {
  const data = candidateBase64(input);
  const plan = {rotate: false, width: undefined, height: undefined, withoutEnlargement: false, format: undefined, quality: 80, raw: false};
  const pipeline = {
    async metadata() {
      const meta = await candidateTool('image', 'metadata', {data});
      // sharp leaves absent metadata undefined; the store treats any present field as retained metadata.
      return {format: meta.format, width: meta.width, height: meta.height, pages: meta.pages, depth: meta.depth,
        space: meta.space, hasAlpha: meta.hasAlpha, hasProfile: meta.hasProfile, orientation: meta.orientation,
        exif: meta.exif ? Buffer.alloc(0) : undefined};
    },
    rotate(angle) { if (angle !== undefined) throw new Error('SHARP_UNSUPPORTED: rotate angle'); plan.rotate = true; return pipeline; },
    toColourspace(space) { if (space !== 'srgb') throw new Error('SHARP_UNSUPPORTED: ' + space); return pipeline; },
    resize(options) {
      if (options.fit !== undefined && options.fit !== 'inside') throw new Error('SHARP_UNSUPPORTED: fit ' + options.fit);
      Object.assign(plan, {width: options.width, height: options.height, withoutEnlargement: !!options.withoutEnlargement});
      return pipeline;
    },
    raw() { plan.raw = true; return pipeline; },
    jpeg(options) { plan.format = 'jpeg'; plan.quality = options?.quality ?? 80; return pipeline; },
    webp(options) { plan.format = 'webp'; plan.quality = options?.quality ?? 80; return pipeline; },
    clone() { const copy = candidateSharp(input); copy.plan(plan); return copy; },
    plan(source) { Object.assign(plan, source); },
    async toBuffer(options) {
      if (plan.raw) { await candidateTool('image', 'decode', {data}); return Buffer.alloc(0); }
      if (!plan.format) throw new Error('SHARP_UNSUPPORTED: no output format');
      const out = await candidateTool('image', 'encode', {data, rotate: plan.rotate, width: plan.width, height: plan.height,
        withoutEnlargement: plan.withoutEnlargement, format: plan.format, quality: plan.quality});
      const buffer = Buffer.from(candidateBytes(out.data));
      return options?.resolveWithObject ? {data: buffer, info: {format: plan.format, width: out.width, height: out.height, size: buffer.length}} : buffer;
    },
  };
  return pipeline;
}

// MARK: Model (the official adapter parses, retries and cancels a body Swift streams in arrival order)

const candidateFetch = globalThis.fetch.bind(globalThis);
let candidateStreamId = 0;
globalThis.fetch = async (input, options = {}) => {
  const url = typeof input === 'string' ? input : input.url;
  if (url !== candidateOfficialMessages) return candidateFetch(input, options);
  const signal = options.signal;
  const streamId = `model-${candidateIdPrefix}-${++candidateStreamId}`;
  const aborted = () => signal?.reason ?? new DOMException('The operation was aborted.', 'AbortError');
  // A failure keeps its fixed code in a TypeError, the same kind a lost WebKit fetch throws.
  const failed = code => new TypeError('Load failed (' + code + ')');
  let settled = false;
  const cancel = () => {
    if (settled) return;
    settled = true;
    candidateNative('model-cancel', {streamId}).catch(() => {});
  };
  if (signal?.aborted) throw aborted();
  signal?.addEventListener('abort', cancel, {once: true});
  const headers = {};
  new Headers(options.headers).forEach((value, name) => { headers[name] = value; });
  const opened = await candidateNative('model-open', {streamId, url, headers, body: options.body});
  if (signal?.aborted) { cancel(); throw aborted(); }
  if (opened.failure) { settled = true; signal?.removeEventListener('abort', cancel); throw failed(opened.failure); }
  const finish = () => { settled = true; signal?.removeEventListener('abort', cancel); };
  const body = new ReadableStream({
    async pull(controller) {
      const next = await candidateNative('model-read', {streamId});
      if (next.chunk !== undefined) controller.enqueue(candidateBytes(next.chunk));
      else if (next.done) { finish(); controller.close(); }
      else if (signal?.aborted) { finish(); controller.error(aborted()); }
      else { finish(); controller.error(failed(next.failure)); }
    },
    cancel() { cancel(); },
  });
  return new Response(body, {status: opened.status, headers: opened.headers});
};

// MARK: Worker home (restored before the tree boots; checkpointed after session events)

const candidateHomePath = path => typeof path === 'string' && !path.split('/').some(p => p === '..' || p === '.')
  && (path === candidateHome || path.startsWith(candidateHome + '/'))
  && path !== candidateCredentials && !path.startsWith(candidateCredentials);
function candidateSeedHome(vfs, snapshot) {
  if (snapshot.formatVersion !== 1) throw new Error('HOME_SNAPSHOT_VERSION');
  for (const entry of [...snapshot.directories, ...snapshot.files]) if (!candidateHomePath(entry.path)) throw new Error('HOME_PATH_REFUSED');
  for (const d of snapshot.directories) vfs.seedDirectory(d.path, {mode: d.mode, mtimeMs: d.mtimeMs});
  for (const f of snapshot.files) vfs.seed(f.path, candidateBytes(f.base64), {mode: f.mode, mtimeMs: f.mtimeMs});
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
// The restore hook: runs in `start` right after the image loads, before the official tree boots.
self.candidateRestore = async mounted => {
  const {snapshot} = await candidateNative('restore');
  if (snapshot) candidateSeedHome(mounted, snapshot);
  candidateRouting = true;
};
let candidateCheckpointTimer;
let candidateCheckpointChain = Promise.resolve();
// Serialized: a later checkpoint never lands before an earlier one.
function candidateCheckpoint(ctx, vfs) {
  clearTimeout(candidateCheckpointTimer);
  candidateCheckpointChain = candidateCheckpointChain.then(async () => {
    // Accepted session events can still be in the upstream batching queue; its flush is a VFS barrier.
    await ctx.get('sessionPersistence').flush();
    await candidateNative('checkpoint', {snapshot: candidateSnapshotHome(vfs)});
  }).catch(error => candidateLog({event: 'checkpoint-failed', code: error.code ?? String(error)}));
  return candidateCheckpointChain;
}

// MARK: Projects (only projects the user opened natively become workspaces)

const candidateRegistered = new Set();
let candidateEarlyProjects = [];
let candidateRegister = project => { candidateEarlyProjects.push(project); };
async function candidateRegisterProject(ctx, project) {
  if (!project?.open || !candidateInside(project.mount) || candidateRegistered.has(project.mount)) return;
  candidateRegistered.add(project.mount);
  // The VFS directory only lists the project under /dsh/workspace; its contents are native.
  candidateVfsMkdir(project.mount, {recursive: true});
  const registry = ctx.get('workspaceRegistry');
  if (!(await registry.resolveByPath(project.mount))) await registry.create(project.mount, project.name);
}
// The page forwards a project the user just opened natively.
self.candidateProjectOpened = project => candidateRegister(project);

// The install hook: runs in `start` once the tree is active, before the tunnel serves the page.
self.candidateInstall = async (ctx, loader, vfs) => {
  const require = loader.requireFrom('/dsh/config');
  const posix = require('node:path').posix;
  // The image serves `sharp` as a refusing Worker stub (no libvips); ImageIO stands in natively.
  if (!(loader.staticModules instanceof Map) || !loader.staticModules.has('sharp')) throw new Error('CANDIDATE_SHARP_SLOT_CHANGED');
  loader.staticModules.set('sharp', () => candidateSharp);
  // The Worker's constants omit O_EXCL, so `O_CREAT | O_EXCL` silently loses exclusivity; add Linux's value.
  candidateOpenConstants = require('node:fs').constants;
  if (candidateOpenConstants.O_EXCL === undefined) candidateOpenConstants.O_EXCL = 128;
  candidateInstallFileSystem(require);
  candidateInstallSubprocess(ctx);
  candidateInstallShell(ctx);
  candidateInstallGuard(vfs, posix);
  // Terminals an earlier Worker left open would hold guest slots, and a lease, nothing reads any more.
  await candidateNative('terminals-reset').catch(error => candidateLog({event: 'terminals-reset-failed', code: error.code ?? String(error)}));
  // The provider needs a key to send; the real one is added by Swift and never enters the Worker.
  await ctx.get('credentials').set('DEEPSEEK_API_KEY', 'candidate-native-placeholder');
  const {projects} = await candidateNative('projects');
  for (const project of [...projects, ...candidateEarlyProjects]) await candidateRegisterProject(ctx, project);
  candidateEarlyProjects = [];
  candidateRegister = project => candidateRegisterProject(ctx, project)
    .catch(error => candidateLog({event: 'project-register-failed', code: error.code ?? String(error)}));
  ctx.on('session/event', () => {
    clearTimeout(candidateCheckpointTimer);
    candidateCheckpointTimer = setTimeout(() => candidateCheckpoint(ctx, vfs), candidateCheckpointDelayMs);
  });
  setInterval(() => candidateCheckpoint(ctx, vfs), candidateCheckpointIntervalMs);
  candidateLog({event: 'installed', projects: candidateRegistered.size});
};
