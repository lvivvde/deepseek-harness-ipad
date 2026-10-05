#!/usr/bin/env python3
"""Prepare an unsigned, separate iPad research app. Never signs, installs or launches.

Private Xcode project/logs and runtime inputs stay in ignored build/. No user disk input.
"""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys

SOURCE = Path(__file__).resolve().parent
REPO = SOURCE.parents[2]
GATEWAY = SOURCE.parent / 'plan500-darwin/gateway/Sources/Plan500Gateway'
FILES = ('Image', 'initramfs.gz', 'system.raw')
BUNDLE_ID = 'org.lvivvde.harness.plan500.research'


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def validate(inputs, executor):
    manifest = json.loads((inputs / 'inputs.json').read_text())
    if set(manifest['files']) != set(FILES):
        raise ValueError('PROBE_INPUT_SET_REFUSED')
    for name in FILES:
        if digest(inputs / name) != manifest['files'][name]:
            raise ValueError('PROBE_INPUT_HASH_MISMATCH')
    for name in ('init.sh', 'agent.cjs'):
        if digest(SOURCE.parent / 'plan500-lease' / name) != manifest['leaseSourceSha256'][name]:
            raise ValueError('GUEST_SOURCE_CHANGED')
    # The prepared initramfs embeds this token; never print or put it in public source.
    token = (inputs / 'token-private').read_text().strip()
    if not re.fullmatch(r'[A-Za-z0-9_-]{16,128}', token):
        raise ValueError('TOKEN_FORMAT_REFUSED')
    frameworks = json.loads((executor / 'frameworks.json').read_text())['frameworks']
    expected = {item['framework'] for item in frameworks}
    actual = {path.name for path in (executor / 'Frameworks').iterdir()}
    if actual != expected or 'qemu-aarch64-softmmu.framework' not in expected:
        raise ValueError('EXECUTOR_CLOSURE_REFUSED')
    for item in frameworks:
        name = item['framework']
        if not re.fullmatch(r'[A-Za-z0-9_.-]+\.framework', name):
            raise ValueError('FRAMEWORK_NAME_REFUSED')
        if digest(executor / 'Frameworks' / name / name.removesuffix('.framework')) != item['sha256']:
            raise ValueError('EXECUTOR_HASH_MISMATCH')
    return manifest, [{'framework': item['framework'], 'sha256': item['sha256']} for item in frameworks]


def project(output):
    """Small generated project: research sources only, no dependency on the production target."""
    stage = output / 'project'; stage.mkdir()
    sources = stage / 'Sources'; sources.mkdir()
    shutil.copyfile(SOURCE / 'Sources/ResearchApp.swift', sources / 'ResearchApp.swift')
    for path in GATEWAY.glob('*.swift'):
        shutil.copyfile(path, sources / path.name)
    bridge = REPO / 'ios/HarnessApp/Sources/Native'
    for suffix in ('h', 'm'):
        text = (bridge / f'QemuBridge.{suffix}').read_text().replace('HarnessQemuBridge', 'Plan500QemuBridge')
        (sources / f'QemuBridge.{suffix}').write_text(text)
    shutil.copyfile(SOURCE / 'embed.sh', stage / 'embed.sh')
    info = {
        'CFBundleDisplayName': 'Plan500 Research', 'CFBundleExecutable': '$(EXECUTABLE_NAME)',
        'CFBundleIdentifier': '$(PRODUCT_BUNDLE_IDENTIFIER)', 'CFBundleName': 'Plan500Research',
        'CFBundlePackageType': 'APPL', 'CFBundleShortVersionString': '0.1.0', 'CFBundleVersion': '1',
        'LSRequiresIPhoneOS': True, 'UILaunchScreen': {},
        'UIApplicationSceneManifest': {'UIApplicationSupportsMultipleScenes': False},
        'NSAppTransportSecurity': {'NSAllowsLocalNetworking': True},
        'UISupportedInterfaceOrientations': ['UIInterfaceOrientationPortrait', 'UIInterfaceOrientationPortraitUpsideDown', 'UIInterfaceOrientationLandscapeLeft', 'UIInterfaceOrientationLandscapeRight'],
        'UIFileSharingEnabled': True, 'LSSupportsOpeningDocumentsInPlace': True,
    }
    (stage / 'Info.plist').write_bytes(plistlib.dumps(info))
    objects = {}

    def object(key, isa, **values):
        identifier = hashlib.sha256(key.encode()).hexdigest()[:24].upper()
        objects[identifier] = {'isa': isa, **values}
        return identifier

    references, builds = [], []
    for path in sorted(sources.iterdir()):
        kind = 'sourcecode.swift' if path.suffix == '.swift' else 'sourcecode.c.h' if path.suffix == '.h' else 'sourcecode.c.objc'
        reference = object(path.name, 'PBXFileReference', path='Sources/' + path.name, sourceTree='<group>', lastKnownFileType=kind)
        references.append(reference)
        if path.suffix != '.h': builds.append(object(path.name + '-build', 'PBXBuildFile', fileRef=reference))
    app = object('app', 'PBXFileReference', path='Plan500Research.app', sourceTree='BUILT_PRODUCTS_DIR', explicitFileType='wrapper.application')
    products = object('products', 'PBXGroup', name='Products', children=[app], sourceTree='<group>')
    group = object('group', 'PBXGroup', children=references + [products], sourceTree='<group>')
    sourcesPhase = object('sources', 'PBXSourcesBuildPhase', files=builds, buildActionMask=2147483647, runOnlyForDeploymentPostprocessing=0)
    frameworksPhase = object('frameworks', 'PBXFrameworksBuildPhase', files=[], buildActionMask=2147483647, runOnlyForDeploymentPostprocessing=0)
    embed = object('embed', 'PBXShellScriptBuildPhase', name='Embed isolated probe inputs', files=[], inputPaths=[], outputPaths=[],
                   alwaysOutOfDate=1, buildActionMask=2147483647, runOnlyForDeploymentPostprocessing=0,
                   shellPath='/bin/bash', shellScript='bash "$SRCROOT/embed.sh"')
    settings = {
        'PRODUCT_BUNDLE_IDENTIFIER': BUNDLE_ID, 'PRODUCT_NAME': 'Plan500Research', 'SWIFT_VERSION': '5.0',
        'SWIFT_OBJC_BRIDGING_HEADER': 'Sources/QemuBridge.h', 'INFOPLIST_FILE': 'Info.plist',
        'TARGETED_DEVICE_FAMILY': '2', 'IPHONEOS_DEPLOYMENT_TARGET': '16.0', 'SDKROOT': 'iphoneos',
        'CLANG_ENABLE_MODULES': 'YES', 'ENABLE_USER_SCRIPT_SANDBOXING': 'NO',
        'LD_RUNPATH_SEARCH_PATHS': ['$(inherited)', '@executable_path/Frameworks'],
        'CODE_SIGN_STYLE': 'Automatic', 'SWIFT_OPTIMIZATION_LEVEL': '-O',
    }
    configuration = object('release', 'XCBuildConfiguration', name='Release', buildSettings=settings)
    configList = object('config-list', 'XCConfigurationList', buildConfigurations=[configuration], defaultConfigurationName='Release', defaultConfigurationIsVisible=0)
    target = object('target', 'PBXNativeTarget', name='Plan500Research', productName='Plan500Research', productReference=app,
                    productType='com.apple.product-type.application', buildConfigurationList=configList,
                    buildPhases=[sourcesPhase, frameworksPhase, embed], buildRules=[], dependencies=[])
    root = object('root', 'PBXProject', attributes={}, buildConfigurationList=configList, compatibilityVersion='Xcode 14.0',
                  developmentRegion='en', knownRegions=['en', 'Base'], mainGroup=group, productRefGroup=products,
                  projectDirPath='', projectRoot='', targets=[target])
    xcode = stage / 'Plan500Research.xcodeproj'; xcode.mkdir()
    (xcode / 'project.pbxproj').write_bytes(plistlib.dumps({'archiveVersion': '1', 'classes': {}, 'objectVersion': '56', 'objects': objects, 'rootObject': root}))
    return xcode


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--inputs', required=True, type=Path)
    parser.add_argument('--executor', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--sdk', choices=['iphoneos', 'iphonesimulator'], default='iphoneos')
    args = parser.parse_args()
    inputs, executor, output = args.inputs.resolve(), args.executor.resolve(), args.output.resolve()
    # Generated projects contain private machine paths. Keep them under ignored build/.
    if not output.is_relative_to(REPO / 'build'):
        raise ValueError('OUTPUT_MUST_BE_IN_IGNORED_BUILD')
    manifest, frameworks = validate(inputs, executor)
    output.mkdir(parents=True, exist_ok=False)
    xcode = project(output)
    command = ['xcodebuild', '-project', str(xcode), '-scheme', 'Plan500Research', '-configuration', 'Release',
               '-sdk', args.sdk, '-derivedDataPath', str(output / 'derived'), 'CODE_SIGNING_ALLOWED=NO',
               'PLAN500_INPUT_DIR=' + str(inputs), 'PLAN500_EXECUTOR_DIR=' + str(executor), 'build']
    with (output / 'build-private.log').open('w') as log:
        code = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT).returncode
    app = output / f'derived/Build/Products/Release-{args.sdk}/Plan500Research.app'
    binary = app / 'Plan500Research'
    completed = code == 0 and binary.is_file()
    if completed:
        info = plistlib.loads((app / 'Info.plist').read_bytes())
        if info['CFBundleIdentifier'] != BUNDLE_ID:
            raise ValueError('APP_IDENTITY_REFUSED')
        if args.sdk == 'iphoneos':
            for name in FILES:
                if digest(app / 'ProbeInputs' / name) != manifest['files'][name]:
                    raise ValueError('BUNDLED_INPUT_HASH_MISMATCH')
            if set(p.name for p in (app / 'ProbeInputs').iterdir()) != set(FILES) | {'inputs.json', 'token-private'}:
                raise ValueError('BUNDLED_INPUT_SET_REFUSED')
            if set(p.name for p in (app / 'Frameworks').iterdir()) != {x['framework'] for x in frameworks}:
                raise ValueError('BUNDLED_EXECUTOR_SET_REFUSED')
    receipt = {'completed': completed, 'sdk': args.sdk, 'bundleId': BUNDLE_ID, 'signed': False, 'installed': False,
               'deviceVerified': False, 'inputs': manifest, 'frameworks': frameworks,
               'sourceSha256': {str(p.relative_to(REPO)): digest(p) for p in sorted(SOURCE.rglob('*')) if p.is_file() and '__pycache__' not in p.parts},
               'gatewaySha256': {p.name: digest(p) for p in sorted(GATEWAY.glob('*.swift'))},
               'appBinarySha256': digest(binary) if completed else None}
    (output / 'build-safe.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps({'completed': completed, 'sdk': args.sdk, 'bundleId': BUNDLE_ID, 'signed': False,
                      'installed': False, 'receipt': str(output / 'build-safe.json')}))
    return 0 if completed else 1


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception as error:
        # No credentials or machine paths in stdout; raw Xcode diagnostics stay in build/.
        reason = str(error) if isinstance(error, ValueError) and re.fullmatch(r'[A-Z_]+', str(error)) else type(error).__name__
        print('PLAN500_BUILD_FAILED:' + reason, file=sys.stderr)
        sys.exit(1)
