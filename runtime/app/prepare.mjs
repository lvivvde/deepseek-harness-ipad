// Builds the App's web root (ADR 0003) from fixed official packages: the official config
// and VFS image, a copy of the official Worker with the App bridge, and the official frontend.
// Installed packages are never modified; adaptations are made in scratch copies under build/app.
// Usage: node runtime/app/prepare.mjs [--harness DIR] [--worker-dependencies DIR] [--out DIR]
import {createRequire} from 'node:module';
import {spawnSync} from 'node:child_process';
import {cpSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, symlinkSync, writeFileSync} from 'node:fs';
import {dirname, join, relative, resolve} from 'node:path';
import {createHash} from 'node:crypto';
import {fileURLToPath, pathToFileURL} from 'node:url';

const source = dirname(fileURLToPath(import.meta.url));
const repo = resolve(source, '../..');
export const gitScripts = ['native-git-objects.js', 'native-git-match.js', 'native-git-xdiff.js', 'native-git.js'];

// The runtime's own module transform, which the official worker leaves to pack time, scoped for the
// Worker so plugins installed at runtime are lowered exactly as the image's packages were.
export function loweringSource(workerDependencies, runtime) {
  const index = readFileSync(join(runtime, 'index.js'), 'utf8');
  const start = index.indexOf('//#region src/compile/transform.ts');
  const end = index.indexOf('//#endregion', start);
  if (start < 0 || end < 0 || !index.slice(start, end).includes('function lowerModuleSource(')) throw new Error('runtime transform region not found');
  const acorn = readFileSync(join(workerDependencies, 'node_modules/acorn/dist/acorn.js'), 'utf8');
  return `const candidateLowerModuleSource = (() => {
const {parse} = (() => { const module = {exports: {}}; const exports = module.exports; const define = undefined;
${acorn}
return module.exports; })();
${index.slice(start, end)}
return lowerModuleSource;
})();`;
}
function replaceOnce(text, before, after, what) {
  if (text.split(before).length !== 2) throw new Error('Upstream anchor changed: ' + what);
  return text.replace(before, () => after);
}

// The official Worker plus the App hooks; each anchor must occur exactly once.
export function patchWorker(worker, bridge) {
  // The bridge's terminal output is the bundle's own stream PassThrough, as the official handle's is.
  if (worker.split('const { Duplex, PassThrough, Readable,').length !== 2) throw new Error('Upstream anchor changed: stream PassThrough');
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
  // The plugin profile's package.json is the install record (#23); keep it across boots instead of
  // resetting it to an empty bundle list.
  worker = replaceOnce(worker, 'vfs.seed(join$1(dir, "package.json"), ',
    'if (!vfs.existsSync(join$1(dir, "package.json"))) vfs.seed(join$1(dir, "package.json"), ', 'profile package.json seed');
  // The web preview anchors the installation at the profile's own package.json, so every installed
  // plugin counts as supplied by the installation and none can be uninstalled. Anchor it at an empty
  // installation manifest as native dsh does; bundle lookup still falls back to the profile (#23).
  worker = replaceOnce(worker, '\t\tinstallAnchor: join$1(dir, "package.json"),',
    '\t\tinstallAnchor: join$1(root, "config", "candidate-installation.json"),', 'install anchor');
  worker = replaceOnce(worker, '\tvfs.seed(join$1(dir, "cordis.yml"), "[]\\n");',
    '\tvfs.seed(join$1(dir, "cordis.yml"), "[]\\n");\n\tvfs.seed(join$1(root, "config", "candidate-installation.json"), "{\\"private\\":true}\\n");', 'install anchor seed');
  // The official plugin manager runs pnpm through execa, which the Worker leaves unimplemented (#23).
  worker = replaceOnce(worker, 'const execa = notImplementedFail("execa", "execa");',
    'const execa = (...args) => candidateExeca(...args);', 'execa');
  // Installed plugins live in the profile's node_modules; bare imports from inside the home resolve
  // Node-style up its node_modules directories before the image's own (#23).
  worker = replaceOnce(worker, 'const packageDirectory = join$1(this.root, "node_modules", packageName);',
    'const packageDirectory = candidateModulePaths(fromDirectory).map(dir => join$1(dir, packageName)).find(dir => this.vfs.existsSync(join$1(dir, "package.json"))) ?? join$1(this.root, "node_modules", packageName);', 'home module resolution');
  worker = replaceOnce(worker, 'return [join$1(this.root, "node_modules")];',
    'return [...candidateModulePaths(fromDirectory), join$1(this.root, "node_modules")];', 'home module paths');
  // ... and awaits its exit through node:events once, which the Worker's events subset lacks.
  worker = replaceOnce(worker, '\tEventEmitter: () => EventEmitter,\n\t__esModule: () => true,',
    '\tEventEmitter: () => EventEmitter,\n\tonce: () => candidateEventsOnce,\n\t__esModule: () => true,', 'events once');
  worker = replaceOnce(worker, 'var events_default = { EventEmitter };', 'var events_default = { EventEmitter, once: candidateEventsOnce };', 'events default once');
  worker = replaceOnce(worker, '\tcp: () => cp$1,', '\tcp: () => cp$1,\n\tcopyFile: () => promises.copyFile,', 'fs/promises copyFile');
  // Candidate frames never reach the official tunnel, which fails the Worker on a frame it does not know.
  // WebKit lacks the disposal symbols the compiled resource-management helper names; they only name methods.
  return `self.addEventListener('message', event => {
  if (event.data?.t === 'candidate-native-reply') { event.stopImmediatePropagation(); self.candidateNativeReply?.(event.data); }
  if (event.data?.t === 'candidate-save') { event.stopImmediatePropagation(); self.candidateSave?.().catch(error => self.postMessage({t: 'candidate-log', event: 'checkpoint-failed', code: error.code ?? String(error)})); }
  if (event.data?.t === 'candidate-project') { event.stopImmediatePropagation(); self.candidateProjectOpened?.(event.data.project); }
});
for (const key of ['dispose', 'asyncDispose']) {
  if (!Symbol[key]) Object.defineProperty(Symbol, key, {value: Symbol('Symbol.' + key)});
}
` + worker + '\n' + bridge;
}

// The official terminal pane, with a seam the App's key row writes through (#23): Esc, Tab, Ctrl and the
// arrows reach the terminal's own model exactly as typed input does, and only while it is writable.
export function patchTerminalClient(client) {
  client = replaceOnce(client, 'xterm.open(node);',
    'xterm.open(node);\n\t\t\t\txterm.element.harnessTerminalInput = data => { if (current.current.state.writable) model.write(data); };', 'terminal input');
  return replaceOnce(client, 'xterm.dispose();', 'delete xterm.element.harnessTerminalInput;\n\t\t\t\t\txterm.dispose();', 'terminal dispose');
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

// The terminal controller (dsh-api-terminal-controller, createLazyRequire) loads xterm lazily, which the
// packer's sweep cannot see, so its entries name them beside the packer's own seeds. Those seeds
// (IMAGE_ENTRY_SEEDS) are not exported; the build fails if the packer's copy no longer matches this one.
const lazyModules = ['@xterm/headless', '@xterm/addon-serialize'];
const imageSeeds = ['@deepseek-ai/dsh-app-boot', '@deepseek-ai/dsh-cmdline', '@deepseek-ai/cordis',
  '@deepseek-ai/cordis-plugin-include', 'js-yaml'];
const seedsLiteral = 'const IMAGE_ENTRY_SEEDS = [\n' + imageSeeds.map(name => `\t"${name}"`).join(',\n') + '\n];';

function checkImageSeeds(packer) {
  const lib = join(packer, 'lib');
  const found = readdirSync(lib).filter(name => name.endsWith('.js'))
    .some(name => readFileSync(join(lib, name), 'utf8').includes(seedsLiteral));
  if (!found) throw new Error('Upstream anchor changed: packer IMAGE_ENTRY_SEEDS');
}

function main() {
  const option = (name, fallback) => {
    const index = process.argv.indexOf(name);
    return resolve(index < 0 ? fallback : process.argv[index + 1]);
  };
  const harness = option('--harness', join(repo, 'build/test-dependencies/harness'));
  const workerDependencies = option('--worker-dependencies', join(repo, 'build/worker-dependencies'));
  const out = option('--out', join(repo, 'build/app/Web'));
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
  // Plugin metadata asks Cordis for Node's internal resolver, which the Worker has none of by design.
  // Its hoisted dependencies resolve upward from the scratch copy as they do from the harness tree.
  symlinkSync(join(harness, 'node_modules'), join(scratch, 'node_modules'));
  const appBoot = join(scratch, 'dsh-app-boot');
  cpSync(join(harness, 'node_modules/@deepseek-ai/dsh-app-boot'), appBoot, {recursive: true});
  const appBootEntry = join(appBoot, 'lib/index.js');
  writeFileSync(appBootEntry, replaceOnce(readFileSync(appBootEntry, 'utf8'),
    '\tif (loader === void 0) throw new Error("Plugin metadata requires the Node module resolver");',
    '\tif (loader === void 0 && typeof globalThis.candidateResolveResource === "function") return fileURLToPath(globalThis.candidateResolveResource(specifier, parentURL));\n\tif (loader === void 0) throw new Error("Plugin metadata requires the Node module resolver");', 'dsh-app-boot'));
  workspaces.set('@deepseek-ai/dsh-app-boot', appBoot);
  const terminal = join(scratch, 'dsh-client-ui-sidebar-terminal');
  cpSync(join(harness, 'node_modules/@deepseek-ai/dsh-client-ui-sidebar-terminal'), terminal, {recursive: true});
  const terminalEntry = join(terminal, 'lib/client.terminal.js');
  writeFileSync(terminalEntry, patchTerminalClient(readFileSync(terminalEntry, 'utf8')));
  workspaces.set('@deepseek-ai/dsh-client-ui-sidebar-terminal', terminal);
  checkImageSeeds(join(workerDependencies, 'node_modules/@deepseek-ai/dsh-experimental-webworker-packer'));
  const {packVfsImage} = createRequire(join(workerDependencies, 'package.json'))('@deepseek-ai/dsh-experimental-webworker-packer');
  const packed = packVfsImage({config, profile: 'web', workspaces, resolveFrom: harness,
    entries: [...imageSeeds, ...lazyModules]});
  if (packed.missing.length) throw new Error('packer reports missing packages: ' + packed.missing.join(', '));
  for (const name of lazyModules) {
    const manifest = packed.files[`node_modules/${name}/package.json`];
    const entry = manifest && JSON.parse(new TextDecoder().decode(manifest)).main;
    if (!entry || !packed.files[`node_modules/${name}/${entry}`]) throw new Error(`vfs image lacks ${name}`);
  }
  writeFileSync(join(out, 'vfs-image.tar.gz'), packed.image);

  const runtime = join(workerDependencies, 'node_modules/@deepseek-ai/dsh-experimental-webworker-runtime/lib');
  writeFileSync(join(out, 'worker.js'), patchWorker(readFileSync(join(runtime, 'worker.js'), 'utf8'),
    [loweringSource(workerDependencies, runtime),
      ...['worker-bridge.js', 'worker-pnpm.js', 'session-recovery.js'].map(name => readFileSync(join(source, name), 'utf8'))].join('\n')));
  cpSync(join(runtime, 'client.js'), join(out, 'client.js'));
  cpSync(join(workerDependencies, 'node_modules/@deepseek-ai/dsh-client-web/lib/apply-injections.js'), join(out, 'apply-injections.js'));
  cpSync(join(source, 'connector.js'), join(out, 'connector.js'));
  const dist = join(harness, 'node_modules/@deepseek-ai/dsh-web-frontend/dist');
  for (const name of readdirSync(dist)) if (name !== 'index.html') cpSync(join(dist, name), join(out, name), {recursive: true});
  writeFileSync(join(out, 'index.html'), candidateIndex(readFileSync(join(dist, 'index.html'), 'utf8')));
  // Native git runs in the App's JavaScriptCore, not in the Worker; the App loads these from the bundle.
  const git = join(repo, 'runtime/native-git');
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
      'candidate-frames-filter', 'vfs-image-lazy-xterm-entries', 'index-importmap-and-connector', 'candidate-bridge',
      'session-recovery', 'profile-package-json-kept', 'native-pnpm-for-plugins', 'execa-over-worker-spawn', 'events-once', 'home-module-resolution', 'plugin-metadata-resolver', 'plugin-module-lowering', 'plugin-install-anchor', 'plugin-builtin-check', 'terminal-key-row-input'],
    unresolvedExternalRequests: packed.unresolvedExternalRequests,
    files: Object.fromEntries(files(out).map(path => [path, sha256(readFileSync(join(out, path)))])),
  };
  writeFileSync(join(out, 'web-receipt.json'), JSON.stringify(receipt, null, 2) + '\n');
  console.log(JSON.stringify({out: relative(repo, out), files: Object.keys(receipt.files).length, packages: receipt.packages}));
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) main();
