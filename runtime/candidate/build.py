#!/usr/bin/env python3
"""Build the candidate App (#17, ADR 0003) for macOS or iPad. Never installs or launches.

The Xcode project is generated under ignored build/ and links the formal package; the formal App's
project is never touched. The bundle carries the prepared web root (`make candidate-web`) and the
verified Linux guest inputs. No user disk input. The iPad bundle also embeds the verified in-process
QEMU framework closure; it is signed only with a private `--signing-file` (team and profile only).
Usage: python3 runtime/candidate/build.py [--sdk macosx|iphoneos|iphonesimulator] [--web DIR]
       [--inputs DIR] [--executor DIR] [--signing-file JSON] [--output DIR]
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
EXECUTOR = REPO / 'ios/LinuxPrototype/.runtime'
QEMU = 'qemu-aarch64-softmmu.framework'
SIGNING = {'DEVELOPMENT_TEAM', 'CODE_SIGN_STYLE', 'PROVISIONING_PROFILE_SPECIFIER'}
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


def validate_executor(executor):
    """The in-process QEMU closure, framework for framework as `frameworks.json` recorded it."""
    frameworks = json.loads((executor / 'frameworks.json').read_text())['frameworks']
    expected = {item['framework'] for item in frameworks}
    actual = {path.name for path in (executor / 'Frameworks').iterdir()}
    if actual != expected or QEMU not in expected:
        raise ValueError('EXECUTOR_CLOSURE_REFUSED')
    for item in frameworks:
        name = item['framework']
        if not re.fullmatch(r'[A-Za-z0-9_.-]+\.framework', name):
            raise ValueError('EXECUTOR_CLOSURE_REFUSED')
        if digest(executor / 'Frameworks' / name / name.removesuffix('.framework')) != item['sha256']:
            raise ValueError('EXECUTOR_HASH_MISMATCH')
    return {item['framework']: item['sha256'] for item in frameworks}


def signing_settings(path):
    """Private signing settings as xcodebuild arguments: the team, and optionally style and profile."""
    settings = json.loads(path.read_text())
    if (not isinstance(settings, dict) or not settings.get('DEVELOPMENT_TEAM') or set(settings) - SIGNING
            or not all(isinstance(value, str) and value for value in settings.values())):
        raise ValueError('SIGNING_SETTINGS_REFUSED')
    return [key + '=' + value for key, value in sorted(settings.items())]


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

# iPad only: the QEMU closure, stripped and never carrying an earlier signature, re-signed with this
# build's identity when signing is allowed; `qemu` is QEMU's (empty) data directory.
EMBED_EXECUTOR = '''
[[ "$PLATFORM_NAME" == "iphoneos" ]] || { echo "warning: the simulator cannot run the device QEMU; not embedded."; exit 0; }
: "${CANDIDATE_EXECUTOR:?verified executor required}"
frameworks="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH"
rm -rf "$dest/qemu"
mkdir -p "$dest/qemu" "$frameworks"
for source in "$CANDIDATE_EXECUTOR"/Frameworks/*.framework; do
  target="$frameworks/$(basename "$source")"
  rm -rf "$target"
  ditto "$source" "$target"
  codesign --remove-signature "$target" 2>/dev/null || true
  xcrun strip -x -S "$target/$(basename "$source" .framework)"
  if [[ "${CODE_SIGNING_ALLOWED:-NO}" == "YES" && -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]]; then
    codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$target"
  fi
done
'''


def project(output, sdk):
    """Small generated project: the candidate App sources over the formal package's products."""
    mac = sdk == 'macosx'
    stage = output / 'project'
    sources = stage / 'Sources'
    sources.mkdir(parents=True)
    for path in sorted(APP_SOURCES.glob('*.swift')):
        shutil.copyfile(path, sources / path.name)
    info = {
        'CFBundleDisplayName': 'Harness Candidate', 'CFBundleExecutable': '$(EXECUTABLE_NAME)',
        'CFBundleIdentifier': '$(PRODUCT_BUNDLE_IDENTIFIER)', 'CFBundleName': NAME,
        'CFBundlePackageType': 'APPL', 'CFBundleShortVersionString': '0.1.0', 'CFBundleVersion': '1',
        'NSAppTransportSecurity': {'NSAllowsLocalNetworking': True},
    }
    info.update({'LSMinimumSystemVersion': '$(MACOSX_DEPLOYMENT_TARGET)', 'NSPrincipalClass': 'NSApplication'} if mac else {
        'LSRequiresIPhoneOS': True, 'UILaunchScreen': {},
        'UIApplicationSceneManifest': {'UIApplicationSupportsMultipleScenes': False},
        'UISupportedInterfaceOrientations~ipad': ['UIInterfaceOrientationPortrait', 'UIInterfaceOrientationPortraitUpsideDown',
                                                  'UIInterfaceOrientationLandscapeLeft', 'UIInterfaceOrientationLandscapeRight'],
    })
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
                   shellPath='/bin/bash', shellScript=EMBED if mac else EMBED + EMBED_EXECUTOR)
    settings = {
        'PRODUCT_BUNDLE_IDENTIFIER': BUNDLE_ID, 'PRODUCT_NAME': NAME, 'SWIFT_VERSION': '5.0',
        'INFOPLIST_FILE': 'Info.plist', 'SDKROOT': sdk, 'ARCHS': 'arm64',
        'ENABLE_USER_SCRIPT_SANDBOXING': 'NO', 'SWIFT_OPTIMIZATION_LEVEL': '-O',
    }
    settings.update({'MACOSX_DEPLOYMENT_TARGET': '13.0', 'COMBINE_HIDPI_IMAGES': 'YES',
                     'LD_RUNPATH_SEARCH_PATHS': ['$(inherited)', '@executable_path/../Frameworks']} if mac else {
        'IPHONEOS_DEPLOYMENT_TARGET': '16.0', 'TARGETED_DEVICE_FAMILY': '2', 'CODE_SIGN_STYLE': 'Automatic',
        'SUPPORTED_PLATFORMS': 'iphoneos iphonesimulator',
        'LD_RUNPATH_SEARCH_PATHS': ['$(inherited)', '@executable_path/Frameworks']})
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
    parser.add_argument('--sdk', choices=['macosx', 'iphoneos', 'iphonesimulator'], default='macosx')
    parser.add_argument('--web', type=Path, default=REPO / 'build/candidate/CandidateWeb')
    parser.add_argument('--inputs', type=Path, default=REPO / 'build/prototypes/plan500-darwin/inputs')
    parser.add_argument('--executor', type=Path, default=EXECUTOR, help='iPad: prepared QEMU framework closure')
    parser.add_argument('--signing-file', type=Path, help='iPad: private JSON with the team (and style, profile)')
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    mac, sdk = args.sdk == 'macosx', args.sdk
    default = 'app' if mac else 'ipad' if sdk == 'iphoneos' else 'simulator'
    web, inputs = args.web.resolve(), args.inputs.resolve()
    output = (args.output or REPO / 'build/candidate' / default).resolve()
    check_output(output)
    manifest = validate_inputs(inputs)
    web_receipt = validate_web(web)
    device = sdk == 'iphoneos'
    executor = validate_executor(args.executor.resolve()) if device else None
    signing = signing_settings(args.signing_file) if args.signing_file else None
    if signing is not None and not device:
        raise ValueError('SIGNING_ONLY_FOR_IPAD')
    if output.exists():
        shutil.rmtree(output)
    output.mkdir(parents=True)
    xcode = project(output, sdk)
    command = ['xcodebuild', '-project', str(xcode), '-scheme', NAME, '-configuration', 'Release', '-sdk', sdk,
               '-derivedDataPath', str(output / 'derived'),
               'CANDIDATE_WEB=' + str(web), 'CANDIDATE_INPUTS=' + str(inputs), 'build']
    if device:
        command.insert(-1, 'CANDIDATE_EXECUTOR=' + str(args.executor.resolve()))
    if signing is None:
        command.insert(-1, 'CODE_SIGNING_ALLOWED=NO')
    else:
        command[-1:-1] = ['-allowProvisioningUpdates', 'CODE_SIGNING_ALLOWED=YES', *signing]
    with (output / 'build-private.log').open('w') as log:
        code = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT).returncode
    app = output / ('derived/Build/Products/Release/' if mac else f'derived/Build/Products/Release-{sdk}/') / (NAME + '.app')
    bundled = app / 'Contents/Resources' if mac else app
    binary = (app / 'Contents/MacOS' if mac else app) / NAME
    completed = code == 0 and binary.is_file()
    if completed:
        if plistlib.loads((app / ('Contents/Info.plist' if mac else 'Info.plist')).read_bytes())['CFBundleIdentifier'] != BUNDLE_ID:
            raise ValueError('APP_IDENTITY_REFUSED')
        for name in FILES:
            if digest(bundled / 'LinuxInputs' / name) != manifest['files'][name]:
                raise ValueError('BUNDLED_INPUT_HASH_MISMATCH')
        if validate_web(bundled / 'CandidateWeb')['files'] != web_receipt['files']:
            raise ValueError('BUNDLED_WEB_MISMATCH')
        if device and {p.name for p in (app / 'Frameworks').iterdir() if p.name != 'ModelGateway.framework'} != set(executor):
            raise ValueError('BUNDLED_EXECUTOR_SET_REFUSED')
        if signing is not None and subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)],
                                                  capture_output=True).returncode != 0:
            raise ValueError('SIGNATURE_REFUSED')
    signed = completed and signing is not None
    receipt = {'completed': completed, 'bundleId': BUNDLE_ID, 'platform': sdk, 'signed': signed, 'installed': False,
               'inputs': manifest['files'], 'leaseSourceSha256': manifest['leaseSourceSha256'],
               'web': {'harnessVersion': web_receipt.get('harnessVersion'), 'runtimeVersion': web_receipt.get('runtimeVersion'),
                       'configSha256': web_receipt.get('configSha256'), 'files': len(web_receipt['files'])},
               'executor': executor,
               'appSourceSha256': {p.name: digest(p) for p in sorted(APP_SOURCES.glob('*.swift'))},
               'candidateSha256': {p.name: digest(p) for p in sorted((PACKAGE / 'Sources/Candidate').glob('*.swift'))},
               'appBinarySha256': digest(binary) if completed else None}
    (output / 'build-safe.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps({'completed': completed, 'bundleId': BUNDLE_ID, 'platform': sdk, 'signed': signed, 'installed': False,
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
