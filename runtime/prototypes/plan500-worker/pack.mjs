// Throwaway feasibility probe. Outputs and dependencies belong in ignored build/.
import {createRequire} from 'node:module';
import {readFileSync, writeFileSync, readdirSync, mkdirSync, cpSync} from 'node:fs';
import {resolve, join} from 'node:path';
import {createHash} from 'node:crypto';

const root = resolve('build/prototypes/plan500-worker');
const dependencies = createRequire(join(root, 'dependencies/package.json'));
const {packVfsImage} = dependencies('@deepseek-ai/dsh-experimental-webworker-packer');
const packageRoot = resolve(process.env.PLAN500_HARNESS_ROOT ?? 'build/test-dependencies/harness');
const workspaces = new Map();
for (const name of readdirSync(join(packageRoot, 'node_modules/@deepseek-ai'))) {
  const directory = join(packageRoot, 'node_modules/@deepseek-ai', name);
  const manifest = JSON.parse(readFileSync(join(directory, 'package.json'), 'utf8'));
  workspaces.set(manifest.name, directory);
}
const useZodCjs = process.argv.includes('--zod-cjs');
if (useZodCjs) {
  // Preserve fixed Zod bytes; select its published CJS flavor in a scratch copy.
  // The Worker lowering cannot currently evaluate this cyclic ESM tree.
  const scratch = join(root, 'adapted-zod');
  cpSync(join(packageRoot, 'node_modules/zod'), scratch, {recursive: true});
  const manifestPath = join(scratch, 'package.json');
  const manifest = JSON.parse(readFileSync(manifestPath, 'utf8'));
  function preferCjs(value) {
    if (!value || typeof value !== 'object') return;
    if (value.import && value.require) value.import = value.require;
    for (const child of Object.values(value)) preferCjs(child);
  }
  preferCjs(manifest.exports);
  writeFileSync(manifestPath, JSON.stringify(manifest, null, 2) + '\n');
  workspaces.set('zod', scratch);
}
const useWebkitSchemas = process.argv.includes('--webkit-schemas');
if (useWebkitSchemas) {
  for (const name of ['dsh-tools', 'dsh-cordis-host-runner']) {
    const scratch = join(root, 'adapted-' + name);
    cpSync(join(packageRoot, 'node_modules/@deepseek-ai', name), scratch, {recursive: true});
    const entry = join(scratch, 'lib/index.js');
    const before = 'Function.prototype.toString.call(constructor) === `function ${name}() { [native code] }`';
    const source = readFileSync(entry, 'utf8');
    if (source.split(before).length !== 2) throw new Error('Upstream schema anchor changed: ' + name);
    writeFileSync(entry, source.replace(before,
      'Function.prototype.toString.call(constructor) === Function.prototype.toString.call(name === "Array" ? Array : Object)'));
    workspaces.set('@deepseek-ai/' + name, scratch);
  }
}
const packed = packVfsImage({
  config: readFileSync(join(root, 'composed-web.yml'), 'utf8'),
  profile: 'web', workspaces, resolveFrom: packageRoot,
});
mkdirSync(join(root, 'web'), {recursive: true});
writeFileSync(join(root, 'web/vfs-image.tar.gz'), packed.image);
const receipt = {
  harnessVersion: '0.2.0-rc.2', nodeVersion: process.version,
  zodVersion: JSON.parse(readFileSync(join(packageRoot, 'node_modules/zod/package.json'), 'utf8')).version,
  configSha256: createHash('sha256').update(readFileSync(join(root, 'composed-web.yml'))).digest('hex'),
  harnessLockSha256: createHash('sha256').update(readFileSync(join(packageRoot, 'package-lock.json'))).digest('hex'),
  contract: packed.contract, imageBytes: packed.image.byteLength,
  sha256: createHash('sha256').update(packed.image).digest('hex'),
  packages: packed.packages.size, javascriptEntries: packed.javascriptEntries,
  roster: packed.roster.length, missing: packed.missing,
  adaptations: [...(useZodCjs ? ['fixed-zod-CJS-export-selection'] : []),
    ...(useWebkitSchemas ? ['WebKit-intrinsic-constructor-comparison'] : [])],
  unresolvedExternalRequests: packed.unresolvedExternalRequests,
};
writeFileSync(join(root, 'pack-safe.json'), JSON.stringify(receipt, null, 2) + '\n');
console.log(JSON.stringify(receipt));
if (packed.missing.length) process.exitCode = 1;
