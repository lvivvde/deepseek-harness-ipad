// Probe-only instrumentation; never replaces the installed app or upstream package.
import {readFileSync, writeFileSync, copyFileSync} from 'node:fs';
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
// WebKit on this host lacks the well-known disposal symbols expected by the
// upstream compiled explicit-resource-management helper. These keys only name
// methods; the upstream helper still performs actual disposal.
worker = `self.addEventListener('message', event => {
  if (event.data?.t === 'plan500') { event.stopImmediatePropagation(); prototypeMessage(event); }
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
