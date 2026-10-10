// Builds the candidate App's web root (#17, ADR 0003) from fixed official packages: the official config
// and VFS image, a copy of the official Worker with the candidate bridge, and the official frontend.
// Installed packages are never modified; adaptations are made in scratch copies under build/candidate.
// Usage: node runtime/candidate/prepare.mjs [--harness DIR] [--worker-dependencies DIR] [--out DIR]
import {createRequire} from 'node:module';
import {spawnSync} from 'node:child_process';
import {cpSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync} from 'node:fs';
import {dirname, join, relative, resolve} from 'node:path';
import {createHash} from 'node:crypto';
import {fileURLToPath, pathToFileURL} from 'node:url';

const source = dirname(fileURLToPath(import.meta.url));
const repo = resolve(source, '../..');
export const gitScripts = ['native-git-objects.js', 'native-git-match.js', 'native-git-xdiff.js', 'native-git.js'];

function replaceOnce(text, before, after, what) {
  if (text.split(before).length !== 2) throw new Error('Upstream anchor changed: ' + what);
  return text.replace(before, () => after);
}

// The official Worker plus the candidate hooks; each anchor must occur exactly once.
export function patchWorker(worker, bridge) {
  // Restore the home and turn on native project routes before the tree boots and attaches sessions.
  worker = replaceOnce(worker, 'setActiveVfs(mounted);', 'await self.candidateRestore?.(mounted);\nsetActiveVfs(mounted);', 'restore');
  // Install once the tree is active, before the tunnel serves the page; a failure fails the start.
  worker = replaceOnce(worker, 'context = ctx;', 'context = ctx;\nawait self.candidateInstall?.(ctx, loader, mounted);', 'install');
  // Every node:fs/promises member asks the candidate route first (inert until the restore hook runs);
  // copyFile, which the Worker does not ship, copies VFS bytes for the snapshot plugin.
  worker = replaceOnce(worker, '\twatch: watchAsync,\n\tconstants: constants$3\n};', `\twatch: watchAsync,\n\tconstants: constants$3\n};
promises.copyFile = async (source, destination, mode = 0) => {
  if ((mode & 1) && existsSync(destination)) {
    const error = new Error(\`EEXIST: file already exists, copyfile '\${asPath(source)}' -> '\${asPath(destination)}'\`);
    error.code = 'EEXIST';
    throw error;
  }
  writeFileSync(destination, readFileSync(source));
};
for (const name of Object.keys(promises)) {
  const base = promises[name];
  if (typeof base === 'function') promises[name] = (...args) => self.candidateFsRoute ? self.candidateFsRoute(name, args, base) : base(...args);
}`, 'fs/promises');
  worker = replaceOnce(worker, '\tcp: () => cp$1,', '\tcp: () => cp$1,\n\tcopyFile: () => promises.copyFile,', 'fs/promises copyFile');
  // Candidate frames never reach the official tunnel, which fails the Worker on a frame it does not know.
  // WebKit lacks the disposal symbols the compiled resource-management helper names; they only name methods.
  return `self.addEventListener('message', event => {
  if (event.data?.t === 'candidate-native-reply') { event.stopImmediatePropagation(); self.candidateNativeReply?.(event.data); }
  if (event.data?.t === 'candidate-project') { event.stopImmediatePropagation(); self.candidateProjectOpened?.(event.data.project); }
});
for (const key of ['dispose', 'asyncDispose']) {
  if (!Symbol[key]) Object.defineProperty(Symbol, key, {value: Symbol('Symbol.' + key)});
}
` + worker + '\n' + bridge;
}

// The official frontend page; the connector runs first so the transport exists before the entry boots.
export function candidateIndex(html) {
  if (html.includes('importmap')) throw new Error('Upstream anchor changed: index importmap');
  return replaceOnce(html, '<script type="module" crossorigin src="./assets/index-',
    '<script type="importmap">{"imports":{"@deepseek-ai/dsh-client-web/injections":"./apply-injections.js"}}</script>\n'
    + '    <script type="module" src="./connector.js"></script>\n'
    + '    <script type="module" crossorigin src="./assets/index-', 'index entry');
}

const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');
function files(directory, base = directory) {
  return readdirSync(directory).sort().flatMap(name => {
    const path = join(directory, name);
    return statSync(path).isDirectory() ? files(path, base) : [relative(base, path)];
  });
}

function main() {
  const option = (name, fallback) => {
    const index = process.argv.indexOf(name);
    return resolve(index < 0 ? fallback : process.argv[index + 1]);
  };
  const harness = option('--harness', join(repo, 'build/test-dependencies/harness'));
  const workerDependencies = option('--worker-dependencies', join(repo, 'build/prototypes/plan500-worker/dependencies'));
  const out = option('--out', join(repo, 'build/candidate/CandidateWeb'));
  const scratch = join(dirname(out), 'scratch');
  rmSync(scratch, {recursive: true, force: true});
  rmSync(out, {recursive: true, force: true});
  mkdirSync(scratch, {recursive: true});
  mkdirSync(out, {recursive: true});

  // The official config, composed by the official CLI in a scratch home: no user profile or credentials.
  const dumped = spawnSync('node', [join(harness, 'node_modules/@deepseek-ai/dsh/lib/bin.js'), '--profile', 'web', '--dump-config'],
    {cwd: repo, env: {...process.env, DSH_HOME: join(scratch, 'dsh-home')}, timeout: 60000, encoding: 'utf8', maxBuffer: 64 << 20});
  writeFileSync(join(dirname(out), 'config-private.log'), dumped.stderr ?? '');
  if (dumped.status !== 0) throw new Error('official config dump failed');
  const config = dumped.stdout;

  const workspaces = new Map();
  for (const name of readdirSync(join(harness, 'node_modules/@deepseek-ai'))) {
    const directory = join(harness, 'node_modules/@deepseek-ai', name);
    workspaces.set(JSON.parse(readFileSync(join(directory, 'package.json'), 'utf8')).name, directory);
  }
  // The Worker lowering cannot evaluate Zod's cyclic ESM tree; select its published CJS flavor.
  const zod = join(scratch, 'zod');
  cpSync(join(harness, 'node_modules/zod'), zod, {recursive: true});
  const zodManifest = JSON.parse(readFileSync(join(zod, 'package.json'), 'utf8'));
  const preferCjs = value => {
    if (!value || typeof value !== 'object') return;
    if (value.import && value.require) value.import = value.require;
    for (const child of Object.values(value)) preferCjs(child);
  };
  preferCjs(zodManifest.exports);
  writeFileSync(join(zod, 'package.json'), JSON.stringify(zodManifest, null, 2) + '\n');
  workspaces.set('zod', zod);
  // WebKit prints intrinsic constructors differently; compare against the realm's own spelling.
  for (const name of ['dsh-tools', 'dsh-cordis-host-runner']) {
    const copy = join(scratch, name);
    cpSync(join(harness, 'node_modules/@deepseek-ai', name), copy, {recursive: true});
    const entry = join(copy, 'lib/index.js');
    writeFileSync(entry, replaceOnce(readFileSync(entry, 'utf8'),
      'Function.prototype.toString.call(constructor) === `function ${name}() { [native code] }`',
      'Function.prototype.toString.call(constructor) === Function.prototype.toString.call(name === "Array" ? Array : Object)', name));
    workspaces.set('@deepseek-ai/' + name, copy);
  }
  const {packVfsImage} = createRequire(join(workerDependencies, 'package.json'))('@deepseek-ai/dsh-experimental-webworker-packer');
  const packed = packVfsImage({config, profile: 'web', workspaces, resolveFrom: harness});
  if (packed.missing.length) throw new Error('packer reports missing packages: ' + packed.missing.join(', '));
  writeFileSync(join(out, 'vfs-image.tar.gz'), packed.image);

  const runtime = join(workerDependencies, 'node_modules/@deepseek-ai/dsh-experimental-webworker-runtime/lib');
  writeFileSync(join(out, 'worker.js'), patchWorker(readFileSync(join(runtime, 'worker.js'), 'utf8'),
    readFileSync(join(source, 'candidate-bridge.js'), 'utf8')));
  cpSync(join(runtime, 'client.js'), join(out, 'client.js'));
  cpSync(join(workerDependencies, 'node_modules/@deepseek-ai/dsh-client-web/lib/apply-injections.js'), join(out, 'apply-injections.js'));
  cpSync(join(source, 'connector.js'), join(out, 'connector.js'));
  const dist = join(harness, 'node_modules/@deepseek-ai/dsh-web-frontend/dist');
  for (const name of readdirSync(dist)) if (name !== 'index.html') cpSync(join(dist, name), join(out, name), {recursive: true});
  writeFileSync(join(out, 'index.html'), candidateIndex(readFileSync(join(dist, 'index.html'), 'utf8')));
  // Native git runs in the App's JavaScriptCore, not in the Worker; the App loads these from the bundle.
  const git = join(repo, 'runtime/prototypes/plan500-ipad/web');
  for (const name of gitScripts) cpSync(join(git, name), join(out, name));

  const version = path => JSON.parse(readFileSync(path, 'utf8')).version;
  const receipt = {
    harnessVersion: version(join(harness, 'node_modules/@deepseek-ai/dsh/package.json')),
    runtimeVersion: version(join(runtime, '../package.json')), nodeVersion: process.version,
    configSha256: sha256(config), harnessLockSha256: sha256(readFileSync(join(harness, 'package-lock.json'))),
    contract: packed.contract, packages: packed.packages.size,
    // Every change to the official code, listed (distribution-components.md section 3).
    adaptations: ['fixed-zod-CJS-export-selection', 'WebKit-intrinsic-constructor-comparison', 'WebKit-disposal-symbols',
      'worker-hook-restore', 'worker-hook-install', 'worker-hook-fs-promises-route', 'fs-promises-copyFile',
      'candidate-frames-filter', 'index-importmap-and-connector', 'candidate-bridge'],
    unresolvedExternalRequests: packed.unresolvedExternalRequests,
    files: Object.fromEntries(files(out).map(path => [path, sha256(readFileSync(join(out, path)))])),
  };
  writeFileSync(join(out, 'candidate-receipt.json'), JSON.stringify(receipt, null, 2) + '\n');
  console.log(JSON.stringify({out: relative(repo, out), files: Object.keys(receipt.files).length, packages: receipt.packages}));
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) main();
