// Probe-only instrumentation; never replaces the installed app or upstream package.
import {readFileSync, writeFileSync, copyFileSync, existsSync} from 'node:fs';
import {resolve, join} from 'node:path';
const root = resolve('build/prototypes/plan500-worker');
const lib = join(root, 'dependencies/node_modules/@deepseek-ai/dsh-experimental-webworker-runtime/lib');
let worker = readFileSync(join(lib, 'worker.js'), 'utf8');
function patch(before, after) {
  if (worker.split(before).length !== 2) throw new Error('Upstream instrumentation anchor changed');
  worker = worker.replace(before, after);
}
patch('const mounted = loadVfsImage(bytes, root);',
  'const mounted = loadVfsImage(bytes, root);\nprototypeRestore(mounted, options.prototypeSnapshot);');
patch('image: data.image,', 'image: data.image,\nprototypeSnapshot: data.snapshot,');
patch('get modules() {', 'get prototypeContext() { return context; },\nget modules() {');
patch('setActiveModuleLoader(loader);', `setActiveModuleLoader(loader);
const prototypeLoad = loader.load.bind(loader);
loader.load = (...args) => {
  try { return prototypeLoad(...args); }
  catch (error) {
    self.postMessage({t: 'plan500-log', module: String(args[0]?.path ?? args[0]),
      error: String(error), stack: error?.stack, cause: String(error?.cause)});
    throw error;
  }
};`);
// #39 gate 3: every node:fs/promises member asks the research route first (inert until a page
// installs one), and the snapshot plugin's copyFile, which this bridge does not ship, copies VFS bytes.
patch('\twatch: watchAsync,\n\tconstants: constants$3\n};', `\twatch: watchAsync,\n\tconstants: constants$3\n};
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
  if (typeof base === 'function') promises[name] = (...args) => self.plan500FsRoute ? self.plan500FsRoute(name, args, base) : base(...args);
}`);
patch('\tcp: () => cp$1,', '\tcp: () => cp$1,\n\tcopyFile: () => promises.copyFile,');
// WebKit on this host lacks the well-known disposal symbols expected by the
// upstream compiled explicit-resource-management helper. These keys only name
// methods; the upstream helper still performs actual disposal.
worker = `self.addEventListener('message', event => {
  if (event.data?.t === 'plan500') { event.stopImmediatePropagation(); prototypeMessage(event); }
  // Native bridge replies must never reach the official tunnel, which fails the Worker on unknown frames.
  if (event.data?.t === 'plan500-native-reply') { event.stopImmediatePropagation(); self.plan500NativeReply?.(event.data); }
});
for (const key of ['dispose', 'asyncDispose']) {
  if (!Symbol[key]) Object.defineProperty(Symbol, key, {value: Symbol('Symbol.' + key)});
}
` + worker;
worker += readFileSync('runtime/prototypes/plan500-worker/worker-instrumentation.js', 'utf8');
writeFileSync(join(root, 'web/worker.js'), worker);
copyFileSync(join(lib, 'client.js'), join(root, 'web/client.js'));
copyFileSync(join(root, 'dependencies/node_modules/@deepseek-ai/dsh-client-web/lib/apply-injections.js'),
  join(root, 'web/apply-injections.js'));
copyFileSync('runtime/prototypes/plan500-worker/probe.html', join(root, 'web/index.html'));

if (process.argv.includes('--integration')) {
  const integration = 'runtime/prototypes/plan500-ipad/web/';
  const workerPath = join(root, 'web/worker.js');
  // #39 gate 5: the official hook runner, scoped so its module names never meet the Worker's own.
  const hooks = ['harness-dependencies', '../test-dependencies/harness'].map(x =>
    join(root, x, 'node_modules/@deepseek-ai/dsh-hook-protocol/lib/index.js')).find(x => existsSync(x));
  if (!hooks) throw new Error('dsh-hook-protocol is not prepared');
  const protocol = readFileSync(hooks, 'utf8').replace(/^export \{([^}]*)\};\s*$/m, 'globalThis.DshHookProtocol = {$1};');
  if (!protocol.includes('globalThis.DshHookProtocol')) throw new Error('Upstream hook protocol export changed');
  writeFileSync(workerPath, [readFileSync(workerPath, 'utf8'), '(() => {\n' + protocol + '\n})();',
    ...['hook-shell.js', 'git-write.js', 'worker-bridge.js', 'gate3-worker.js'].map(name => readFileSync(integration + name, 'utf8'))].join('\n'));
  // Native git runs in the app's JavaScriptCore, not in the Worker; the page only ships its sources.
  for (const name of ['native-git-objects.js', 'native-git-match.js', 'native-git-xdiff.js', 'native-git.js']) {
    copyFileSync(integration + name, join(root, 'web', name));
  }
  copyFileSync(integration + 'integration.html', join(root, 'web/integration.html'));
  // #39 gate 5: the self-built test remote the page starts inside the Linux guest.
  copyFileSync('runtime/prototypes/plan500-ipad/git_http_fixture.cjs', join(root, 'web/git-http-fixture.cjs'));
}
