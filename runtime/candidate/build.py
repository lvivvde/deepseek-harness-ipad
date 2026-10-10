#!/usr/bin/env python3
"""Build the unsigned macOS candidate App (#17, ADR 0003). Never signs, installs or launches.

The Xcode project is generated under ignored build/ and links the formal package; the formal App's
project is never touched. The bundle carries the prepared web root (`make candidate-web`) and the
verified Linux guest inputs. No user disk input.
Usage: python3 runtime/candidate/build.py [--web DIR] [--inputs DIR] [--output DIR]
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys

SOURCE = Path(__file__).resolve().parent
REPO = SOURCE.parents[1]
PACKAGE = REPO / 'ios/HarnessApp'
APP_SOURCES = PACKAGE / 'CandidateApp/Sources'
LEASE = REPO / 'runtime/prototypes/plan500-lease'
FILES = ('Image', 'initramfs.gz', 'system.raw')
GIT_SCRIPTS = ('native-git-objects.js', 'native-git-match.js', 'native-git-xdiff.js', 'native-git.js')
BUNDLE_ID = 'org.lvivvde.harness.candidate'
NAME = 'HarnessCandidateApp'  # not the package module's name
PRODUCTS = ('HarnessCandidate', 'ModelGateway')


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def check_output(output):
    # Generated projects and logs hold private machine paths. Keep them under ignored build/.
    if not output.resolve().is_relative_to(REPO / 'build'):
        raise ValueError('OUTPUT_MUST_BE_IN_IGNORED_BUILD')


def validate_inputs(inputs):
    """The guest the macOS slice boots: exactly the prepared kernel, initramfs and system disk."""
    manifest = json.loads((inputs / 'inputs.json').read_text())
    if set(manifest['files']) != set(FILES):
        raise ValueError('INPUT_SET_REFUSED')
    for name in FILES:
        if digest(inputs / name) != manifest['files'][name]:
            raise ValueError('INPUT_HASH_MISMATCH')
    # The initramfs embeds the guest agent; it must be the committed one the gateway speaks to.
    for name in ('init.sh', 'agent.cjs'):
        if digest(LEASE / name) != manifest['leaseSourceSha256'][name]:
            raise ValueError('GUEST_SOURCE_CHANGED')
    # The initramfs embeds this token; never print it or put it in public source.
    if not re.fullmatch(r'[A-Za-z0-9_-]{16,128}', (inputs / 'token-private').read_text().strip()):
        raise ValueError('TOKEN_FORMAT_REFUSED')
    return manifest


def validate_web(web):
    """The prepared web root, file for file as `prepare.mjs` recorded it."""
    receipt = json.loads((web / 'candidate-receipt.json').read_text())
    required = {'index.html', 'worker.js', 'connector.js', *GIT_SCRIPTS}
    if not required <= set(receipt['files']):
        raise ValueError('WEB_SET_REFUSED')
    actual = {str(p.relative_to(web)) for p in web.rglob('*') if p.is_file()} - {'candidate-receipt.json'}
    if actual != set(receipt['files']):
        raise ValueError('WEB_SET_REFUSED')
    for name, expected in receipt['files'].items():
        if digest(web / name) != expected:
            raise ValueError('WEB_HASH_MISMATCH')
    return receipt


EMBED = '''set -euo pipefail
dest="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
rm -rf "$dest/CandidateWeb" "$dest/LinuxInputs"
mkdir -p "$dest/LinuxInputs"
cp -R "$CANDIDATE_WEB" "$dest/CandidateWeb"
for name in Image initramfs.gz system.raw token-private; do
  cp -c "$CANDIDATE_INPUTS/$name" "$dest/LinuxInputs/$name" 2>/dev/null || cp "$CANDIDATE_INPUTS/$name" "$dest/LinuxInputs/$name"
done
chmod 600 "$dest/LinuxInputs/token-private"
'''


def project(output):
    """Small generated project: the candidate App sources over the formal package's products."""
    stage = output / 'project'
    sources = stage / 'Sources'
    sources.mkdir(parents=True)
    for path in sorted(APP_SOURCES.glob('*.swift')):
        shutil.copyfile(path, sources / path.name)
    info = {
        'CFBundleDisplayName': 'Harness Candidate', 'CFBundleExecutable': '$(EXECUTABLE_NAME)',
        'CFBundleIdentifier': '$(PRODUCT_BUNDLE_IDENTIFIER)', 'CFBundleName': NAME,
        'CFBundlePackageType': 'APPL', 'CFBundleShortVersionString': '0.1.0', 'CFBundleVersion': '1',
        'LSMinimumSystemVersion': '$(MACOSX_DEPLOYMENT_TARGET)', 'NSPrincipalClass': 'NSApplication',
        'NSAppTransportSecurity': {'NSAllowsLocalNetworking': True},
    }
    (stage / 'Info.plist').write_bytes(plistlib.dumps(info))
    objects = {}

    def object(key, isa, **values):
        identifier = hashlib.sha256(key.encode()).hexdigest()[:24].upper()
        objects[identifier] = {'isa': isa, **values}
        return identifier

    references, builds = [], []
    for path in sorted(sources.iterdir()):
        reference = object(path.name, 'PBXFileReference', path='Sources/' + path.name, sourceTree='<group>',
                           lastKnownFileType='sourcecode.swift')
        references.append(reference)
        builds.append(object(path.name + '-build', 'PBXBuildFile', fileRef=reference))
    app = object('app', 'PBXFileReference', path=NAME + '.app', sourceTree='BUILT_PRODUCTS_DIR', explicitFileType='wrapper.application')
    products = object('products', 'PBXGroup', name='Products', children=[app], sourceTree='<group>')
    group = object('group', 'PBXGroup', children=references + [products], sourceTree='<group>')
    sources_phase = object('sources', 'PBXSourcesBuildPhase', files=builds, buildActionMask=2147483647, runOnlyForDeploymentPostprocessing=0)
    package = object('package', 'XCLocalSwiftPackageReference', relativePath=os.path.relpath(PACKAGE, stage))
    dependencies, linked = [], []
    for product in PRODUCTS:
        dependency = object(product, 'XCSwiftPackageProductDependency', package=package, productName=product)
        dependencies.append(dependency)
        linked.append(object(product + '-build', 'PBXBuildFile', productRef=dependency))
    frameworks_phase = object('frameworks', 'PBXFrameworksBuildPhase', files=linked, buildActionMask=2147483647, runOnlyForDeploymentPostprocessing=0)
    embed = object('embed', 'PBXShellScriptBuildPhase', name='Embed web root and guest inputs', files=[], inputPaths=[], outputPaths=[],
                   alwaysOutOfDate=1, buildActionMask=2147483647, runOnlyForDeploymentPostprocessing=0,
                   shellPath='/bin/bash', shellScript=EMBED)
    settings = {
        'PRODUCT_BUNDLE_IDENTIFIER': BUNDLE_ID, 'PRODUCT_NAME': NAME, 'SWIFT_VERSION': '5.0',
        'INFOPLIST_FILE': 'Info.plist', 'SDKROOT': 'macosx', 'MACOSX_DEPLOYMENT_TARGET': '13.0', 'ARCHS': 'arm64',
        'ENABLE_USER_SCRIPT_SANDBOXING': 'NO', 'LD_RUNPATH_SEARCH_PATHS': ['$(inherited)', '@executable_path/../Frameworks'],
        'SWIFT_OPTIMIZATION_LEVEL': '-O', 'COMBINE_HIDPI_IMAGES': 'YES',
    }
    configuration = object('release', 'XCBuildConfiguration', name='Release', buildSettings=settings)
    config_list = object('config-list', 'XCConfigurationList', buildConfigurations=[configuration], defaultConfigurationName='Release', defaultConfigurationIsVisible=0)
    target = object('target', 'PBXNativeTarget', name=NAME, productName=NAME, productReference=app,
                    productType='com.apple.product-type.application', buildConfigurationList=config_list,
                    buildPhases=[sources_phase, frameworks_phase, embed], buildRules=[], dependencies=[],
                    packageProductDependencies=dependencies)
    root = object('root', 'PBXProject', attributes={}, buildConfigurationList=config_list, compatibilityVersion='Xcode 14.0',
                  developmentRegion='en', knownRegions=['en', 'Base'], mainGroup=group, productRefGroup=products,
                  projectDirPath='', projectRoot='', targets=[target], packageReferences=[package])
    xcode = stage / (NAME + '.xcodeproj')
    xcode.mkdir()
    (xcode / 'project.pbxproj').write_bytes(plistlib.dumps({'archiveVersion': '1', 'classes': {}, 'objectVersion': '60', 'objects': objects, 'rootObject': root}))
    return xcode


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--web', type=Path, default=REPO / 'build/candidate/CandidateWeb')
    parser.add_argument('--inputs', type=Path, default=REPO / 'build/prototypes/plan500-darwin/inputs')
    parser.add_argument('--output', type=Path, default=REPO / 'build/candidate/app')
    args = parser.parse_args()
    web, inputs, output = args.web.resolve(), args.inputs.resolve(), args.output.resolve()
    check_output(output)
    manifest = validate_inputs(inputs)
    web_receipt = validate_web(web)
    if output.exists():
        shutil.rmtree(output)
    output.mkdir(parents=True)
    xcode = project(output)
    command = ['xcodebuild', '-project', str(xcode), '-scheme', NAME, '-configuration', 'Release', '-sdk', 'macosx',
               '-derivedDataPath', str(output / 'derived'), 'CODE_SIGNING_ALLOWED=NO',
               'CANDIDATE_WEB=' + str(web), 'CANDIDATE_INPUTS=' + str(inputs), 'build']
    with (output / 'build-private.log').open('w') as log:
        code = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT).returncode
    app = output / f'derived/Build/Products/Release/{NAME}.app'
    binary = app / 'Contents/MacOS' / NAME
    completed = code == 0 and binary.is_file()
    if completed:
        if plistlib.loads((app / 'Contents/Info.plist').read_bytes())['CFBundleIdentifier'] != BUNDLE_ID:
            raise ValueError('APP_IDENTITY_REFUSED')
        bundled = app / 'Contents/Resources'
        for name in FILES:
            if digest(bundled / 'LinuxInputs' / name) != manifest['files'][name]:
                raise ValueError('BUNDLED_INPUT_HASH_MISMATCH')
        if validate_web(bundled / 'CandidateWeb')['files'] != web_receipt['files']:
            raise ValueError('BUNDLED_WEB_MISMATCH')
    receipt = {'completed': completed, 'bundleId': BUNDLE_ID, 'platform': 'macosx', 'signed': False, 'installed': False,
               'inputs': manifest['files'], 'leaseSourceSha256': manifest['leaseSourceSha256'],
               'web': {'harnessVersion': web_receipt.get('harnessVersion'), 'runtimeVersion': web_receipt.get('runtimeVersion'),
                       'configSha256': web_receipt.get('configSha256'), 'files': len(web_receipt['files'])},
               'appSourceSha256': {p.name: digest(p) for p in sorted(APP_SOURCES.glob('*.swift'))},
               'candidateSha256': {p.name: digest(p) for p in sorted((PACKAGE / 'Sources/Candidate').glob('*.swift'))},
               'appBinarySha256': digest(binary) if completed else None}
    (output / 'build-safe.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps({'completed': completed, 'bundleId': BUNDLE_ID, 'signed': False, 'installed': False,
                      'app': str(app.relative_to(REPO)), 'receipt': str((output / 'build-safe.json').relative_to(REPO))}))
    return 0 if completed else 1


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception as error:
        # No credentials or machine paths in stdout; raw Xcode diagnostics stay in build/.
        reason = str(error) if isinstance(error, ValueError) and re.fullmatch(r'[A-Z_]+', str(error)) else type(error).__name__
        print('CANDIDATE_BUILD_FAILED:' + reason, file=sys.stderr)
        sys.exit(1)
