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
let config = readFileSync(join(root, 'composed-web.yml'), 'utf8');
const integrated = process.argv.includes('--integration');
if (integrated) {
  // Scoped subagent tools survive an inherited-tool mask; disable their plugin rows
  // in this research image before session composition. Never change installed upstream.
  const lines = config.split('\n');
  for (let index = lines.length - 1; index >= 0; index--) {
    const match = /^([ \t]*)name: '@deepseek-ai\/dsh-tool-subagent'$/.exec(lines[index]);
    if (!match) continue;
    const indent = match[1];
    let end = index + 1;
    while (end < lines.length) {
      const row = /^([ \t]*)- /.exec(lines[end]);
      if (row && row[1].length < indent.length) break;
      end++;
    }
    for (let cursor = end - 1; cursor > index; cursor--) {
      if (lines[cursor].startsWith(indent + 'disabled:')) lines.splice(cursor, 1);
    }
    lines.splice(index + 1, 0, indent + 'disabled: true');
  }
  config = lines.join('\n');
  // #39 gate 3: the official str_replace_editor is published but in no preset; add it to the
  // default preset of this research image so it runs over the same filesystem service.
  const preset = config.indexOf('\n- id: preset-standard\n');
  const anchor = config.indexOf('\n      - id: tool-jobs\n', preset);
  if (preset < 0 || anchor < 0) throw new Error('Upstream preset anchor changed');
  config = config.slice(0, anchor) + "\n      - id: tool-str-replace-editor\n        name: '@deepseek-ai/dsh-tool-str-replace-editor'"
    + config.slice(anchor);
  // A preset only activates plugins the root roster declares (disabled until a preset enables them).
  const roster = "\n- id: tool-jobs\n  name: '@deepseek-ai/dsh-tool-jobs'\n  disabled: true\n";
  if (config.split(roster).length !== 2) throw new Error('Upstream roster anchor changed');
  config = config.replace(roster, roster + "- id: tool-str-replace-editor\n  name: '@deepseek-ai/dsh-tool-str-replace-editor'\n  disabled: true\n");
}
const packed = packVfsImage({
  config,
  profile: 'web', workspaces, resolveFrom: packageRoot,
});
mkdirSync(join(root, 'web'), {recursive: true});
writeFileSync(join(root, 'web/vfs-image.tar.gz'), packed.image);
const receipt = {
  harnessVersion: '0.2.0-rc.2', nodeVersion: process.version,
  zodVersion: JSON.parse(readFileSync(join(packageRoot, 'node_modules/zod/package.json'), 'utf8')).version,
  configSha256: createHash('sha256').update(config).digest('hex'),
  integrated,
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
