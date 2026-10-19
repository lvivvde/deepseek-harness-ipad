// Native pnpm for the plugin profile (#23). Appended by prepare.mjs after the bridge, so it shares the
// Worker module's scope (`EXECUTABLES`, `launcherExit`, `requireActiveVfs`) and the bridge's native calls.
//
// The official plugin manager installs by spawning pnpm in the profile directory, which a browser Worker
// cannot run. This virtual executable answers the commands the manager issues (`config get registry`,
// `view`, `add`, `remove`, `install`) natively: it resolves registry packages, verifies each tarball's
// sha512 integrity and unpacks it into the profile's node_modules. Only JavaScript packages qualify;
// install scripts, native binaries and oversized trees fail with pnpm's own error codes, so the manager
// shows its usual reason. Tarballs go to the native package store once and are unpacked again at every
// Worker start from `candidate-lock.json`, so node_modules stays out of the home checkpoint.
const candidateProfile = candidateHome + '/profiles/preview';
const candidateModules = candidateProfile + '/node_modules';
const candidateLockFile = candidateProfile + '/candidate-lock.json';
const candidateDefaultRegistry = 'https://registry.npmjs.org/';
// Unpacked bytes of one profile tree: everything lives in the Worker's memory.
const candidatePackageLimit = 32 << 20;
const candidateFetchTimeoutMs = 60000;

// MARK: Versions (the subset of node-semver that registry ranges use)

function candidateVersion(text) {
  const match = /^\s*v?(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?\s*$/.exec(String(text));
  if (!match) return undefined;
  return {major: +match[1], minor: +match[2], patch: +match[3], pre: match[4] ? match[4].split('.') : []};
}
function candidateCompare(a, b) {
  for (const key of ['major', 'minor', 'patch']) if (a[key] !== b[key]) return a[key] < b[key] ? -1 : 1;
  if (!a.pre.length || !b.pre.length) return a.pre.length === b.pre.length ? 0 : a.pre.length ? -1 : 1;
  for (let i = 0; i < Math.max(a.pre.length, b.pre.length); i++) {
    const x = a.pre[i], y = b.pre[i];
    if (x === undefined || y === undefined) return x === undefined ? -1 : 1;
    if (x === y) continue;
    const nx = /^\d+$/.test(x), ny = /^\d+$/.test(y);
    if (nx && ny) return +x < +y ? -1 : 1;
    if (nx !== ny) return nx ? -1 : 1;
    return x < y ? -1 : 1;
  }
  return 0;
}
// A partial version (`1`, `1.2`, `1.x`, `*`) as its known parts; prerelease only on a full version.
function candidatePartial(text) {
  const match = /^v?(\d+|[xX*])?(?:\.(\d+|[xX*]))?(?:\.(\d+|[xX*]))?(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$/.exec(text);
  if (!match) return undefined;
  const part = value => value === undefined || /^[xX*]$/.test(value) ? undefined : +value;
  const parts = [part(match[1]), part(match[2]), part(match[3])];
  const known = parts.indexOf(undefined) < 0 ? 3 : parts.indexOf(undefined);
  if (parts.slice(known).some(value => value !== undefined)) return undefined;
  return {parts, known, pre: known === 3 && match[4] ? match[4].split('.') : []};
}
const candidateAt = (parts, pre = []) => ({major: parts[0] ?? 0, minor: parts[1] ?? 0, patch: parts[2] ?? 0, pre});
const candidateBump = (parts, index) => candidateAt(parts.map((value, i) => i < index ? value : i === index ? value + 1 : 0), ['0']);
// One comparator set as [operator, version] pairs; `<` bounds use a `-0` prerelease, as node-semver does.
function candidateComparators(text) {
  const result = [];
  const hyphen = /^\s*(\S+)\s+-\s+(\S+)\s*$/.exec(text);
  if (hyphen) {
    const low = candidatePartial(hyphen[1]), high = candidatePartial(hyphen[2]);
    if (!low || !high) return undefined;
    result.push(['>=', candidateAt(low.parts, low.pre)]);
    if (high.known === 3) result.push(['<=', candidateAt(high.parts, high.pre)]);
    else if (high.known > 0) result.push(['<', candidateBump(high.parts, high.known - 1)]);
    return result;
  }
  const tokens = text.trim().replace(/(\^|~|>=|<=|>|<|=)\s+/g, '$1').split(/\s+/).filter(Boolean);
  for (const token of tokens) {
    const match = /^(\^|~>?|>=|<=|>|<|=)?(.*)$/.exec(token);
    const operator = match[1] ?? '', partial = candidatePartial(match[2]);
    if (!partial) return undefined;
    const {parts, known, pre} = partial;
    const base = candidateAt(parts, pre);
    if (operator === '^') {
      if (known === 0) continue;
      const index = parts[0] > 0 || known === 1 ? 0 : parts[1] > 0 || known === 2 ? 1 : 2;
      result.push(['>=', base], ['<', candidateBump(parts, index)]);
    } else if (operator.startsWith('~')) {
      if (known === 0) continue;
      result.push(['>=', base], ['<', candidateBump(parts, known === 1 ? 0 : 1)]);
    } else if (operator === '' || operator === '=') {
      if (known === 0) continue;
      if (known === 3) result.push(['=', base]);
      else result.push(['>=', base], ['<', candidateBump(parts, known - 1)]);
    } else if (operator === '>') {
      result.push(known === 3 ? ['>', base] : ['>=', candidateBump(parts, Math.max(0, known - 1))]);
    } else if (operator === '>=') result.push(['>=', base]);
    else if (operator === '<') result.push(['<', known === 3 ? base : candidateAt(parts, ['0'])]);
    else if (operator === '<=') result.push(known === 3 ? ['<=', base] : ['<', candidateBump(parts, Math.max(0, known - 1))]);
  }
  return result;
}
function candidateSatisfies(version, range) {
  const parsed = candidateVersion(version);
  if (!parsed) return false;
  for (const set of String(range).split('||')) {
    const comparators = candidateComparators(set);
    if (!comparators) continue;
    const ok = comparators.every(([operator, bound]) => {
      const order = candidateCompare(parsed, bound);
      return operator === '=' ? order === 0 : operator === '>' ? order > 0 : operator === '>=' ? order >= 0
        : operator === '<' ? order < 0 : order <= 0;
    });
    // A prerelease satisfies only a set naming a prerelease of the same release.
    const prerelease = !parsed.pre.length || comparators.some(([, bound]) => bound.pre.length && bound.pre[0] !== '0'
      && bound.major === parsed.major && bound.minor === parsed.minor && bound.patch === parsed.patch);
    if (ok && prerelease) return true;
  }
  return false;
}
const candidateValidRange = range => String(range).split('||').every(set => candidateComparators(set) !== undefined);

// MARK: Registry

class CandidatePnpmError extends Error {
  constructor(code, message) { super(`${code} ${message}`); this.code = code; }
}
const candidateFail = (code, message) => { throw new CandidatePnpmError(code, message); };
async function candidateGet(url, accept) {
  const signal = AbortSignal.timeout(candidateFetchTimeoutMs);
  let response;
  try {
    response = await fetch(url, {headers: accept ? {accept} : {}, signal});
  } catch (error) {
    if (error?.name === 'TimeoutError') candidateFail('ERR_PNPM_FETCH_TIMEOUT', `GET ${url}: request timed out`);
    candidateFail('ERR_PNPM_META_FETCH_FAIL', `GET ${url}: request failed, reason: ${error?.message ?? error} (FETCH_ERROR)`);
  }
  if (response.status === 404) candidateFail('ERR_PNPM_FETCH_404', `GET ${url}: Not Found - 404`);
  if (!response.ok) candidateFail(`ERR_PNPM_FETCH_${response.status}`, `GET ${url}: ${response.statusText}`);
  return response;
}
const candidateEscape = name => name.startsWith('@') ? '@' + encodeURIComponent(name.slice(1)) : encodeURIComponent(name);
// Abbreviated documents carry what resolution needs; `view` asks for the full one for fields like `dsh`.
const candidatePackuments = new Map();
async function candidatePackument(registry, name, full = false) {
  const key = `${full ? 'full' : 'short'} ${registry}${name}`;
  if (!candidatePackuments.has(key)) {
    const promise = candidateGet(registry + candidateEscape(name), full ? 'application/json' : 'application/vnd.npm.install-v1+json')
      .then(response => response.json());
    candidatePackuments.set(key, promise);
    promise.catch(() => candidatePackuments.delete(key));
  }
  return candidatePackuments.get(key);
}
function candidatePick(document, range, name) {
  const tags = document['dist-tags'] ?? {};
  if (range === '' || range === '*' || range === 'latest') range = tags.latest ?? '*';
  if (Object.hasOwn(tags, range)) return document.versions?.[tags[range]];
  if (!candidateValidRange(range)) candidateFail('ERR_PNPM_NO_MATCHING_VERSION', `No matching version found for ${name}@${range}`);
  // The latest tag wins when it satisfies, as pnpm resolves.
  const latest = tags.latest;
  if (latest && document.versions?.[latest] && candidateSatisfies(latest, range)) return document.versions[latest];
  const versions = Object.keys(document.versions ?? {}).filter(version => candidateSatisfies(version, range))
    .sort((a, b) => candidateCompare(candidateVersion(b), candidateVersion(a)));
  if (!versions.length) candidateFail('ERR_PNPM_NO_MATCHING_VERSION', `No matching version found for ${name}@${range}`);
  return document.versions[versions[0]];
}

// MARK: Specs

// `name`, `name@range`, `@scope/name@range`, `alias@npm:name@range`, or an https tarball URL.
function candidateSpec(text) {
  if (/^https?:\/\//.test(text)) return {kind: 'tarball', url: text};
  if (/^(git\+|git:|github:|gitlab:|bitbucket:|gist:|ssh:)/.test(text) || /^[\w.-]+\/[\w.-]+(#.*)?$/.test(text))
    candidateFail('ERR_PNPM_UNSUPPORTED_SPEC', `${text}: installing from git needs a Linux build and is not supported in this version`);
  if (/^(file:|link:|\.|\/)/.test(text))
    candidateFail('ERR_PNPM_UNSUPPORTED_SPEC', `${text}: installing from a local path is not supported in this version; publish it or use an https tarball`);
  const match = /^((?:@[^/@\s]+\/)?[^/@\s]+)(?:@(.*))?$/.exec(text);
  if (!match) candidateFail('ERR_PNPM_UNSUPPORTED_SPEC', `${text}: not a package spec`);
  const alias = /^npm:((?:@[^/@\s]+\/)?[^/@\s]+)(?:@(.*))?$/.exec(match[2] ?? '');
  return alias ? {kind: 'registry', alias: match[1], name: alias[1], range: alias[2] ?? ''}
    : {kind: 'registry', alias: match[1], name: match[1], range: match[2] ?? ''};
}
// The saved dependency value, as pnpm writes it: an exact version stays exact, anything else gets `^`.
function candidateSaved(spec, version) {
  if (spec.kind === 'tarball') return spec.url;
  const value = candidateVersion(spec.range) ? spec.range.trim() : '^' + version;
  return spec.alias === spec.name ? value : `npm:${spec.name}@${value}`;
}
// A dependency value from package.json back to a spec.
function candidateDependency(alias, value) {
  if (/^https?:\/\//.test(value)) return {kind: 'tarball', url: value, alias};
  const parsed = candidateSpec(value.startsWith('npm:') ? `${alias}@${value}` : `${alias}@${value}`);
  return {...parsed, alias};
}

// MARK: Tarballs

async function candidateSha512(bytes) {
  return 'sha512-' + candidateBase64(new Uint8Array(await crypto.subtle.digest('SHA-512', bytes)));
}
async function candidateGunzip(bytes) {
  const stream = new Blob([bytes]).stream().pipeThrough(new DecompressionStream('gzip'));
  return new Uint8Array(await new Response(stream).arrayBuffer());
}
// Regular files of a package tarball with the leading `package/` component dropped; a path leaving the
// package is refused. Symlinks and devices are skipped, as pnpm skips them.
function candidateUntar(bytes) {
  const decoder = new TextDecoder();
  const field = (offset, length) => decoder.decode(bytes.subarray(offset, offset + length)).replace(/\0[\s\S]*$/, '');
  const files = [];
  let offset = 0, longName, paxPath;
  while (offset + 512 <= bytes.length) {
    if (bytes.subarray(offset, offset + 512).every(byte => byte === 0)) break;
    const size = parseInt(field(offset + 124, 12).trim() || '0', 8);
    const type = field(offset + 156, 1) || '0';
    const prefix = field(offset + 257, 6).startsWith('ustar') ? field(offset + 345, 155) : '';
    let name = paxPath ?? longName ?? (prefix ? prefix + '/' : '') + field(offset, 100);
    const mode = parseInt(field(offset + 100, 8).trim() || '644', 8);
    const body = bytes.subarray(offset + 512, offset + 512 + size);
    offset += 512 + Math.ceil(size / 512) * 512;
    if (type === 'L') { longName = decoder.decode(body).replace(/\0[\s\S]*$/, ''); continue; }
    if (type === 'x') {
      const text = decoder.decode(body);
      const path = /(?:^|\n)\d+ path=([^\n]*)\n/.exec(text);
      if (path) paxPath = path[1];
      continue;
    }
    longName = paxPath = undefined;
    if (type === 'g') continue;
    if (type !== '0' && type !== '7') continue;
    const parts = name.split('/').slice(1).filter(part => part !== '' && part !== '.');
    if (!parts.length) continue;
    if (parts.some(part => part === '..') || name.startsWith('/')) candidateFail('ERR_PNPM_BAD_TARBALL', `unsafe path ${name}`);
    files.push({path: parts.join('/'), mode: (mode & 0o111 ? 0o755 : 0o644), bytes: body.slice()});
  }
  return files;
}
async function candidateFetchTarball(url, integrity) {
  const bytes = new Uint8Array(await (await candidateGet(url)).arrayBuffer());
  const actual = await candidateSha512(bytes);
  if (integrity && integrity.startsWith('sha512-') && actual !== integrity)
    candidateFail('ERR_PNPM_TARBALL_INTEGRITY', `${url}: expected ${integrity}, got ${actual}`);
  return {bytes, integrity: actual};
}

// MARK: Resolution

// The node_modules layout Node's resolver reads: a package is placed at the highest directory on its
// requester's chain unless a different version already occupies the first one found there.
async function candidateResolve(dependencies, registry, previous, output) {
  const tree = new Map(); // path -> {name, version, integrity, resolved, dependencies, optional, scripts, os, cpu, size}
  const queue = Object.entries(dependencies).map(([alias, value]) => ({parent: '', alias, spec: candidateDependency(alias, value), optional: false}));
  const tarballs = new Map();
  while (queue.length) {
    const {parent, alias, spec, optional} = queue.shift();
    let chain = parent;
    let found;
    while (true) {
      const candidate = (chain ? chain + '/' : '') + 'node_modules/' + alias;
      if (tree.has(candidate)) { found = candidate; break; }
      if (!chain) break;
      chain = chain.includes('/node_modules/') ? chain.slice(0, chain.lastIndexOf('/node_modules/')) : '';
    }
    let manifest;
    try {
      if (spec.kind === 'tarball') {
        const fetched = tarballs.get(spec.url) ?? await candidateFetchTarball(spec.url);
        tarballs.set(spec.url, fetched);
        const files = candidateUntar(await candidateGunzip(fetched.bytes));
        const json = files.find(file => file.path === 'package.json');
        if (!json) candidateFail('ERR_PNPM_BAD_TARBALL', `${spec.url}: no package.json`);
        manifest = {...JSON.parse(new TextDecoder().decode(json.bytes)), dist: {tarball: spec.url, integrity: fetched.integrity}};
      } else {
        const locked = previous && found === undefined ? previous.get((parent ? parent + '/' : '') + 'node_modules/' + alias) : undefined;
        const document = await candidatePackument(registry, spec.name);
        manifest = locked && locked.name === spec.name && candidateSatisfies(locked.version, spec.range || '*') && document.versions?.[locked.version]
          ? document.versions[locked.version] : candidatePick(document, spec.range, spec.name);
      }
    } catch (error) {
      if (optional) { output.push(`WARN skipping optional dependency ${alias}: ${error.message}`); continue; }
      throw error;
    }
    if (found !== undefined) {
      const existing = tree.get(found);
      if (existing.name === manifest.name && existing.version === manifest.version) continue;
      if (spec.kind !== 'tarball' && existing.name === spec.name && candidateSatisfies(existing.version, spec.range || '*')) continue;
    }
    const native = !candidatePlatform(manifest.os, 'linux') || !candidatePlatform(manifest.cpu, 'x64');
    if (native && optional) { output.push(`WARN skipping optional platform package ${alias}`); continue; }
    const path = found === undefined ? 'node_modules/' + alias
      : (parent ? parent + '/' : '') + 'node_modules/' + alias;
    if (tree.has(path)) candidateFail('ERR_PNPM_UNSUPPORTED_TREE', `${alias} needs two versions in ${parent || 'the profile'}`);
    tree.set(path, {name: manifest.name, version: manifest.version, integrity: manifest.dist?.integrity,
      resolved: manifest.dist?.tarball, native, optional,
      scripts: manifest.hasInstallScript === true || ['preinstall', 'install', 'postinstall'].some(key => manifest.scripts?.[key]),
      size: manifest.dist?.unpackedSize ?? 0});
    for (const [name, range] of Object.entries(manifest.dependencies ?? {}))
      queue.push({parent: path, alias: name, spec: candidateDependency(name, range), optional: false});
    for (const [name, range] of Object.entries(manifest.optionalDependencies ?? {}))
      queue.push({parent: path, alias: name, spec: candidateDependency(name, range), optional: true});
  }
  return {tree, tarballs};
}
// npm's `os`/`cpu` filter against the Worker's own `process.platform` and `process.arch`.
function candidatePlatform(list, value) {
  if (!Array.isArray(list) || !list.length) return true;
  if (list.includes('!' + value)) return false;
  const allowed = list.filter(item => !String(item).startsWith('!'));
  return !allowed.length || allowed.includes(value);
}
// The reasons a tree cannot run in the Worker, in pnpm's codes the manager classifies.
function candidateRefuse(tree) {
  const builds = [...tree.values()].filter(entry => entry.scripts).map(entry => entry.name);
  if (builds.length) candidateFail('ERR_PNPM_IGNORED_BUILDS', `Ignored build scripts: ${builds.join(', ')}. `
    + 'Build scripts need Linux and are not supported for plugins in this version.');
  const binaries = [...tree.values()].filter(entry => entry.native).map(entry => entry.name);
  if (binaries.length) candidateFail('ERR_PNPM_UNSUPPORTED_PLATFORM', `${binaries.join(', ')}: built for another platform; `
    + 'native binary packages cannot run in the plugin Worker');
  const size = [...tree.values()].reduce((sum, entry) => sum + entry.size, 0);
  if (size > candidatePackageLimit) candidateFail('ERR_PNPM_TOO_LARGE', `the plugin tree unpacks to ${Math.round(size / 1048576)} MB; `
    + `this version keeps at most ${candidatePackageLimit / 1048576} MB of plugins in memory`);
}

// Node builtins by their bare names. The Worker loader serves only some of them; a plugin whose entry
// statically imports another one cannot load, so it is refused at install rather than failing on enable.
const candidateNodeBuiltins = new Set(['assert', 'async_hooks', 'buffer', 'child_process', 'cluster', 'console',
  'constants', 'crypto', 'dgram', 'diagnostics_channel', 'dns', 'domain', 'events', 'fs', 'http', 'http2', 'https',
  'inspector', 'module', 'net', 'os', 'path', 'perf_hooks', 'process', 'punycode', 'querystring', 'readline', 'repl',
  'sqlite', 'stream', 'string_decoder', 'sys', 'timers', 'tls', 'trace_events', 'tty', 'url', 'util', 'v8', 'vm',
  'wasi', 'worker_threads', 'zlib']);
// The package's ES module entries: the "." export (import, then default conditions) and main.
function candidateEntries(manifest) {
  const pick = value => typeof value === 'string' ? [value] : Array.isArray(value) ? value.flatMap(pick)
    : value && typeof value === 'object' ? pick(value.import ?? value.node ?? value.default) : [];
  const root = manifest.exports && typeof manifest.exports === 'object' && !Array.isArray(manifest.exports)
    && Object.keys(manifest.exports).some(key => key.startsWith('.')) ? manifest.exports['.'] : manifest.exports;
  return [...pick(root), manifest.main ?? 'index.js'];
}
// Builtins the package's entry reaches through static imports and re-exports that the loader cannot serve.
// Dynamic import() and require() may be guarded, so only static module syntax is followed.
function candidateMissingBuiltins(files) {
  const bodies = new Map(files.map(file => [file.path, file.bytes]));
  let manifest;
  try { manifest = JSON.parse(new TextDecoder().decode(bodies.get('package.json'))); } catch { return []; }
  const find = path => ['', '.js', '.mjs', '/index.js', '/index.mjs'].map(suffix => path + suffix).find(name => bodies.has(name));
  const normal = path => path.split('/').reduce((parts, part) => {
    if (part === '..') parts.pop(); else if (part && part !== '.') parts.push(part);
    return parts;
  }, []).join('/');
  const queue = candidateEntries(manifest).map(entry => find(normal(entry))).filter(Boolean);
  const seen = new Set(), missing = new Set();
  const loader = requireActiveModuleLoader();
  const pattern = /(?:\bfrom\s*|(?:^|[;\n])\s*import\s*)['"]([^'"\n]+)['"]/g;
  while (queue.length) {
    const path = queue.shift();
    if (seen.has(path) || !/\.m?js$/.test(path)) continue;
    seen.add(path);
    for (const [, specifier] of new TextDecoder().decode(bodies.get(path)).matchAll(pattern)) {
      if (specifier.startsWith('.')) {
        const target = find(normal(path.slice(0, path.lastIndexOf('/') + 1) + specifier));
        if (target) queue.push(target);
        continue;
      }
      const bare = specifier.replace(/^node:/, '');
      if (!specifier.startsWith('node:') && !candidateNodeBuiltins.has(bare.split('/')[0])) continue;
      try { loader.internal.resolveSync('node:' + bare); } catch { missing.add('node:' + bare); }
    }
  }
  return [...missing].sort();
}

// MARK: Profile files
// MARK: Profile files

const candidateVfs = () => requireActiveVfs();
function candidateReadJSON(path, fallback) {
  const vfs = candidateVfs();
  if (!vfs.existsSync(path)) return fallback;
  return JSON.parse(new TextDecoder().decode(vfs.readFileSync(path)));
}
function candidateWriteJSON(path, value) {
  candidateVfs().writeFileSync(path, JSON.stringify(value, null, 2) + '\n', {mode: 0o600});
}
function candidateReadLock() {
  const lock = candidateReadJSON(candidateLockFile, undefined);
  return new Map(lock?.lockfileVersion === 1 ? Object.entries(lock.packages ?? {}) : []);
}
// The Worker loader runs only bodies the packer lowered to CommonJS; plugin modules arrive as published.
// Lower each JavaScript file with the runtime's own transform as it lands, keeping the stored tarball
// as published. A body the transform refuses stays as it is, and the loader names it on import.
function candidateLowered(path, bytes) {
  if (typeof candidateLowerModuleSource !== 'function' || !/\.[cm]?js$/.test(path)) return bytes;
  try {
    const {code, lowered} = candidateLowerModuleSource({filename: path, source: new TextDecoder().decode(bytes)});
    return lowered ? new TextEncoder().encode(code) : bytes;
  } catch (error) {
    candidateLog({event: 'plugin-lowering-refused', path, reason: String(error?.message ?? error).slice(0, 200)});
    return bytes;
  }
}
function candidateUnpack(vfs, path, files, write) {
  const root = candidateProfile + '/' + path;
  if (write) {
    vfs.rmSync(root, {recursive: true, force: true});
    vfs.mkdirSync(root, {recursive: true});
  }
  for (const file of files) {
    const target = root + '/' + file.path;
    const bytes = candidateLowered(target, file.bytes);
    if (write) {
      vfs.mkdirSync(target.slice(0, target.lastIndexOf('/')), {recursive: true});
      vfs.writeFileSync(target, bytes, {mode: file.mode});
    } else vfs.seed(target, bytes, {mode: file.mode});
  }
}
// Apply a resolved tree: store and unpack what changed, remove what left, then write the lock.
async function candidateApply(resolved, previous, output) {
  const vfs = candidateVfs();
  const {tree, tarballs} = resolved;
  const paths = [...tree.keys()].sort((a, b) => a.length - b.length);
  // Fetch and check every changed package before the profile changes, so a refused tree leaves it as it was.
  const changed = [];
  for (const path of paths) {
    const entry = tree.get(path), old = previous.get(path);
    if (old && old.integrity === entry.integrity && vfs.existsSync(candidateProfile + '/' + path + '/package.json')) continue;
    const fetched = tarballs.get(entry.resolved) ?? await candidateFetchTarball(entry.resolved, entry.integrity);
    entry.integrity = fetched.integrity;
    changed.push({path, entry, fetched, files: candidateUntar(await candidateGunzip(fetched.bytes))});
  }
  const missing = changed.flatMap(({entry, files}) => candidateMissingBuiltins(files).map(name => `${entry.name} needs ${name}`));
  if (missing.length) candidateFail('ERR_PNPM_UNSUPPORTED_PLATFORM', `${missing.join('; ')}, which the plugin Worker does not provide; `
    + 'this plugin is not supported in this version');
  for (const {path, entry, fetched, files} of changed) {
    await candidateNative('package-put', {integrity: fetched.integrity, base64: candidateBase64(fetched.bytes)});
    // A nested package's directory lives inside its parent's, so it is written after the parent.
    candidateUnpack(vfs, path, files, true);
    output.push(`+ ${entry.name} ${entry.version}`);
  }
  for (const path of [...previous.keys()].sort((a, b) => b.length - a.length)) {
    if (tree.has(path)) continue;
    vfs.rmSync(candidateProfile + '/' + path, {recursive: true, force: true});
    output.push(`- ${previous.get(path).name} ${previous.get(path).version}`);
  }
  const packages = Object.fromEntries(paths.map(path => {
    const {name, version, integrity, resolved: url} = tree.get(path);
    return [path, {name, version, integrity, resolved: url}];
  }));
  candidateWriteJSON(candidateLockFile, {lockfileVersion: 1, packages});
  await candidateNative('package-keep', {integrities: [...new Set(Object.values(packages).map(entry => entry.integrity))]});
}
// Unpack the locked tree from the native store before the official tree boots. A package missing from
// the store is left out; the profile loader then skips its bundle with a reason.
async function candidateRestorePackages(vfs) {
  const lockText = vfs.existsSync(candidateLockFile) ? new TextDecoder().decode(vfs.readFileSync(candidateLockFile)) : undefined;
  if (!lockText) return;
  let lock;
  try { lock = JSON.parse(lockText); } catch { candidateLog({event: 'packages-lock-refused'}); return; }
  const entries = Object.entries(lock?.packages ?? {}).sort(([a], [b]) => a.length - b.length);
  for (const [path, entry] of entries) {
    if (!/^node_modules\/(@[^/]+\/)?[^/]+(\/node_modules\/(@[^/]+\/)?[^/]+)*$/.test(path) || path.split('/').includes('..')) continue;
    try {
      const reply = await candidateNative('package-get', {integrity: entry.integrity});
      const bytes = candidateBytes(reply.base64);
      if (await candidateSha512(bytes) !== entry.integrity) throw new Error('PACKAGE_INTEGRITY');
      candidateUnpack(vfs, path, candidateUntar(await candidateGunzip(bytes)), false);
    } catch (error) {
      candidateLog({event: 'package-restore-failed', path, code: error.code ?? String(error.message ?? error)});
    }
  }
}

// MARK: Commands

function candidateArguments(args) {
  const flags = new Map(), positionals = [];
  for (const argument of args) {
    if (argument.startsWith('--')) {
      const [key, ...rest] = argument.slice(2).split('=');
      flags.set(key, rest.length ? rest.join('=') : true);
    } else if (argument.startsWith('-')) flags.set(argument.slice(1), true);
    else positionals.push(argument);
  }
  return {flags, positionals};
}
function candidateRegistryOf(flags) {
  const value = flags.get('registry');
  if (typeof value !== 'string') return candidateDefaultRegistry;
  return value.endsWith('/') ? value : value + '/';
}
async function candidateView(positionals, flags) {
  const [text, ...fields] = positionals;
  const spec = candidateSpec(text ?? '');
  if (spec.kind !== 'registry') candidateFail('ERR_PNPM_UNSUPPORTED_SPEC', `${text}: view needs a registry package`);
  const registry = candidateRegistryOf(flags);
  const picked = candidatePick(await candidatePackument(registry, spec.name, true), spec.range, spec.name);
  const value = fields.length ? Object.fromEntries(fields.filter(field => picked[field] !== undefined).map(field => [field, picked[field]])) : picked;
  return JSON.stringify(fields.length === 1 ? value[fields[0]] : value, null, 2) + '\n';
}
async function candidateMutate(command, positionals, flags) {
  const registry = candidateRegistryOf(flags);
  const manifest = candidateReadJSON(candidateProfile + '/package.json', {private: true});
  const dependencies = {...manifest.dependencies ?? {}};
  const output = [];
  const previous = candidateReadLock();
  let reuse = previous;
  if (command === 'add') {
    if (!positionals.length) candidateFail('ERR_PNPM_ADDING_TO_ROOT', 'add needs a package');
    for (const text of positionals) {
      const spec = candidateSpec(text);
      let version;
      if (spec.kind === 'registry') version = candidatePick(await candidatePackument(registry, spec.name), spec.range, spec.name).version;
      dependencies[spec.kind === 'registry' ? spec.alias : '\0' + spec.url] = candidateSaved(spec, version);
      // An explicit add re-resolves that package even when the lock still satisfies it.
      if (spec.kind === 'registry') reuse = new Map([...reuse].filter(([path]) => path !== 'node_modules/' + spec.alias));
    }
  } else if (command === 'remove') {
    for (const name of positionals) {
      if (!Object.hasOwn(dependencies, name)) candidateFail('ERR_PNPM_CANNOT_REMOVE_MISSING_DEPS', `Cannot remove '${name}': no such dependency found`);
      delete dependencies[name];
    }
  }
  // A tarball dependency is keyed by its own package name once its manifest is known.
  for (const key of Object.keys(dependencies).filter(key => key.startsWith('\0'))) {
    const url = dependencies[key];
    delete dependencies[key];
    const fetched = await candidateFetchTarball(url);
    const json = candidateUntar(await candidateGunzip(fetched.bytes)).find(file => file.path === 'package.json');
    if (!json) candidateFail('ERR_PNPM_BAD_TARBALL', `${url}: no package.json`);
    dependencies[JSON.parse(new TextDecoder().decode(json.bytes)).name] = url;
  }
  const resolved = await candidateResolve(dependencies, registry, reuse, output);
  candidateRefuse(resolved.tree);
  await candidateApply(resolved, previous, output);
  manifest.dependencies = Object.fromEntries(Object.keys(dependencies).sort().map(name => [name, dependencies[name]]));
  if (!Object.keys(manifest.dependencies).length) delete manifest.dependencies;
  candidateWriteJSON(candidateProfile + '/package.json', manifest);
  output.push(command === 'remove' ? 'Done' : `Done: ${resolved.tree.size} packages`);
  return output.join('\n') + '\n';
}
const CANDIDATE_PNPM_EXECUTABLE = {
  name: 'pnpm',
  async prepare(args, context) {
    const {flags, positionals} = candidateArguments(args);
    const [command, ...rest] = positionals;
    try {
      if (command === 'config' && rest[0] === 'get' && rest[1] === 'registry') return launcherExit(0, candidateDefaultRegistry + '\n');
      if (command === '--version' || flags.has('version') || flags.has('v')) return launcherExit(0, '11.28.4\n');
      if (context.cwd !== candidateProfile) candidateFail('ERR_PNPM_UNSUPPORTED_COMMAND', `pnpm runs only in the plugin profile (${candidateProfile}); project packages install on Linux`);
      if (command === 'view' || command === 'info' || command === 'show') return launcherExit(0, await candidateView(rest, flags));
      if (command === 'add') return launcherExit(0, await candidateMutate('add', rest, flags));
      if (command === 'remove' || command === 'rm' || command === 'uninstall') return launcherExit(0, await candidateMutate('remove', rest, flags));
      if (command === 'install' || command === 'i') return launcherExit(0, await candidateMutate('install', rest, flags));
      candidateFail('ERR_PNPM_UNSUPPORTED_COMMAND', `pnpm ${command ?? ''}: not available for plugins in this version`);
    } catch (error) {
      return launcherExit(1, '', ` ${error.code ?? 'ERR_PNPM_UNEXPECTED'} ${error.code ? error.message.slice(error.code.length + 1) : String(error.message ?? error)}\n`);
    }
  },
  runSync() { return {kind: 'asynchronous'}; },
};
EXECUTABLES.set(CANDIDATE_PNPM_EXECUTABLE.name, CANDIDATE_PNPM_EXECUTABLE);
self.candidateRestorePackages = candidateRestorePackages;

// The official plugin manager runs pnpm (and git for GitHub specs) through execa, which the Worker
// leaves unimplemented. This is the part of execa it reads, over the Worker's own child_process spawn,
// so pnpm reaches the virtual executable above and anything else fails as a missing binary does.
function candidateStream(source) {
  const chunks = [];
  let ended = false, wake;
  const stream = {
    destroyed: false,
    destroy() { stream.destroyed = true; ended = true; wake?.(); },
    async *[Symbol.asyncIterator]() {
      for (;;) {
        if (chunks.length) { yield chunks.shift(); continue; }
        if (ended) return;
        await new Promise(resolve => { wake = resolve; });
        wake = undefined;
      }
    },
  };
  source.on('data', chunk => { if (!stream.destroyed) { chunks.push(chunk); wake?.(); } });
  source.on('end', () => { ended = true; wake?.(); });
  return stream;
}
function candidateExeca(file, args = [], options = {}) {
  const env = options.extendEnv === false ? options.env : {...globalThis.process?.env, ...options.env};
  const child = spawn$1(file, args, {cwd: options.cwd, env, stdio: ['pipe', 'pipe', 'pipe']});
  const text = {stdout: '', stderr: ''};
  const streams = {};
  for (const name of ['stdout', 'stderr']) {
    const disposition = options[name] ?? 'pipe';
    if (disposition === 'pipe' && options.buffer === false) streams[name] = candidateStream(child[name]);
    else streams[name] = null;
    child[name].on('data', chunk => {
      if (disposition === 'inherit') (name === 'stdout' ? console.log : console.error)(String(chunk).replace(/\n$/, ''));
      else if (options.buffer !== false) text[name] += chunk.toString('utf8');
    });
  }
  const command = [file, ...args].join(' ');
  let timedOut = false, isCanceled = false, timer;
  const kill = () => child.kill(options.killSignal ?? 'SIGTERM');
  const cancel = () => { isCanceled = true; kill(); };
  const result = new Promise(resolve => {
    const finish = fields => {
      clearTimeout(timer);
      options.cancelSignal?.removeEventListener?.('abort', cancel);
      const strip = value => value.replace(/\r?\n$/, '');
      const failed = fields.exitCode !== 0 || timedOut || isCanceled;
      const reason = timedOut ? `timed out after ${options.timeout} milliseconds` : isCanceled ? 'was canceled'
        : fields.code ? `failed with ${fields.code}` : `failed with exit code ${fields.exitCode}`;
      resolve({command, cwd: options.cwd, stdout: strip(text.stdout), stderr: strip(text.stderr), timedOut, isCanceled, failed,
        ...failed ? {shortMessage: `Command ${reason}: ${command}`} : {}, ...fields});
    };
    if (options.timeout) timer = setTimeout(() => { timedOut = true; kill(); }, options.timeout);
    if (options.cancelSignal?.aborted) cancel();
    else options.cancelSignal?.addEventListener?.('abort', cancel, {once: true});
    child.on('error', error => finish({exitCode: undefined, signal: undefined, code: error.code}));
    child.on('close', (exitCode, signal) => finish({exitCode: exitCode ?? undefined, signal: signal ?? undefined}));
  }).then(value => {
    if (!value.failed || options.reject === false) return value;
    throw Object.assign(new Error(value.shortMessage), value);
  });
  return Object.assign(result, {pid: child.pid, nodeChildProcess: child, stdout: streams.stdout, stderr: streams.stderr, kill});
}
// The node_modules directories a module inside the home searches, nearest first, as Node walks them.
function candidateModulePaths(fromDirectory) {
  const paths = [];
  if (typeof fromDirectory !== 'string') return paths;
  for (let dir = fromDirectory.replace(/\/+$/, ''); dir === candidateHome || dir.startsWith(candidateHome + '/'); dir = dir.slice(0, dir.lastIndexOf('/'))) {
    if (!dir.endsWith('/node_modules')) paths.push(dir + '/node_modules');
  }
  return paths;
}
// node:events once: the arguments of the first event, or the error an 'error' event carries first.
function candidateEventsOnce(emitter, name, options = {}) {
  return new Promise((resolve, reject) => {
    const signal = options.signal;
    const cleanup = () => { emitter.off?.(name, onEvent); emitter.off?.('error', onError); signal?.removeEventListener?.('abort', onAbort); };
    const onEvent = (...args) => { cleanup(); resolve(args); };
    const onError = error => { cleanup(); reject(error); };
    const onAbort = () => { cleanup(); reject(Object.assign(new Error('The operation was aborted'), {name: 'AbortError', code: 'ABORT_ERR'})); };
    if (signal?.aborted) return onAbort();
    emitter.on(name, onEvent);
    if (name !== 'error') emitter.on('error', onError);
    signal?.addEventListener?.('abort', onAbort, {once: true});
  });
}
self.candidateExeca = candidateExeca;

// The Worker reports Node 0.0.0, so Cordis has no internal ESM resolver and the official plugin metadata
// reader would refuse every installed plugin. Resolve its resource lookups through the Worker loader; a
// resolution failure there is a missing resource, as Node's resolver would report it.
function candidateResolveResource(specifier, parentURL) {
  try {
    return requireActiveModuleLoader().internal.resolveSync(specifier, parentURL).url;
  } catch (error) {
    if (error && typeof error === 'object' && !error.code) error.code = 'MODULE_NOT_FOUND';
    throw error;
  }
}
self.candidateResolveResource = candidateResolveResource;
