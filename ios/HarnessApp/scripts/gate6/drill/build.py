#!/usr/bin/env python3
"""Generate and build the gate 6 rollback drill app (#39) under a dedicated test bundle ID.

    python3 build.py --output build/issue39-gate6/drill [--signing-file build/device-acceptance/local-settings.json]
                     [--project-only]

The project, logs and app stay in ignored build/. Without a signing file it only compiles (unsigned).
--project-only writes the project with the signing settings and in-tree products (gui-products/) for an
Xcode GUI build, which can create the first profile for the test ID when the command line has no account.
The drill links the UserDataMigration product and embeds the executor's zstd framework for session logs.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess

SOURCE = Path(__file__).resolve().parent
PACKAGE = SOURCE.parents[2]
REPO = PACKAGE.parents[1]
ZSTD = REPO / 'ios/LinuxPrototype/.runtime/Frameworks/zstd.1.framework'
BUNDLE_ID = 'org.lvivvde.harness.g6drill'
NAME = 'Gate6Drill'
EMBED = '''set -euo pipefail
frameworks="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH"
mkdir -p "$frameworks"
ditto "$GATE6_ZSTD" "$frameworks/zstd.1.framework"
codesign --remove-signature "$frameworks/zstd.1.framework" 2>/dev/null || true
if [[ "${CODE_SIGNING_ALLOWED:-NO}" == "YES" && -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]]; then
    codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$frameworks/zstd.1.framework"
fi
'''


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def project(stage, extra=None):
    sources = stage / 'Sources'; sources.mkdir(parents=True)
    shutil.copyfile(SOURCE / 'DrillApp.swift', sources / 'DrillApp.swift')
    info = {
        'CFBundleDisplayName': 'G6 新版演练', 'CFBundleExecutable': '$(EXECUTABLE_NAME)',
        'CFBundleIdentifier': '$(PRODUCT_BUNDLE_IDENTIFIER)', 'CFBundleName': NAME, 'CFBundlePackageType': 'APPL',
        # Newer than the old app (0.1.0 / 1) so the drill is a real upgrade and the reinstall a real downgrade.
        'CFBundleShortVersionString': '0.2.0', 'CFBundleVersion': '2',
        'LSRequiresIPhoneOS': True, 'UILaunchScreen': {},
        'UIApplicationSceneManifest': {'UIApplicationSupportsMultipleScenes': False},
        'UISupportedInterfaceOrientations': ['UIInterfaceOrientationPortrait', 'UIInterfaceOrientationPortraitUpsideDown',
                                             'UIInterfaceOrientationLandscapeLeft', 'UIInterfaceOrientationLandscapeRight'],
    }
    (stage / 'Info.plist').write_bytes(plistlib.dumps(info))
    objects = {}

    def object(key, isa, **values):
        identifier = hashlib.sha256(key.encode()).hexdigest()[:24].upper()
        objects[identifier] = {'isa': isa, **values}
        return identifier

    reference = object('DrillApp.swift', 'PBXFileReference', path='Sources/DrillApp.swift', sourceTree='<group>',
                       lastKnownFileType='sourcecode.swift')
    build = object('DrillApp.swift-build', 'PBXBuildFile', fileRef=reference)
    app = object('app', 'PBXFileReference', path=NAME + '.app', sourceTree='BUILT_PRODUCTS_DIR', explicitFileType='wrapper.application')
    products = object('products', 'PBXGroup', name='Products', children=[app], sourceTree='<group>')
    group = object('group', 'PBXGroup', children=[reference, products], sourceTree='<group>')
    sourcesPhase = object('sources', 'PBXSourcesBuildPhase', files=[build], buildActionMask=2147483647, runOnlyForDeploymentPostprocessing=0)
    package = object('package', 'XCLocalSwiftPackageReference', relativePath=os.path.relpath(PACKAGE, stage))
    migration = object('migration', 'XCSwiftPackageProductDependency', package=package, productName='UserDataMigration')
    linked = object('migration-build', 'PBXBuildFile', productRef=migration)
    frameworksPhase = object('frameworks', 'PBXFrameworksBuildPhase', files=[linked], buildActionMask=2147483647, runOnlyForDeploymentPostprocessing=0)
    embed = object('embed', 'PBXShellScriptBuildPhase', name='Embed zstd', files=[], inputPaths=[], outputPaths=[],
                   alwaysOutOfDate=1, buildActionMask=2147483647, runOnlyForDeploymentPostprocessing=0,
                   shellPath='/bin/bash', shellScript=EMBED)
    settings = {
        'PRODUCT_BUNDLE_IDENTIFIER': BUNDLE_ID, 'PRODUCT_NAME': NAME, 'SWIFT_VERSION': '5.0', 'INFOPLIST_FILE': 'Info.plist',
        'TARGETED_DEVICE_FAMILY': '2', 'IPHONEOS_DEPLOYMENT_TARGET': '16.0', 'SDKROOT': 'iphoneos',
        'ENABLE_USER_SCRIPT_SANDBOXING': 'NO', 'LD_RUNPATH_SEARCH_PATHS': ['$(inherited)', '@executable_path/Frameworks'],
        'CODE_SIGN_STYLE': 'Automatic', 'SWIFT_OPTIMIZATION_LEVEL': '-O', 'GATE6_ZSTD': str(ZSTD),
        **(extra or {}),
    }
    configuration = object('release', 'XCBuildConfiguration', name='Release', buildSettings=settings)
    configList = object('config-list', 'XCConfigurationList', buildConfigurations=[configuration],
                        defaultConfigurationName='Release', defaultConfigurationIsVisible=0)
    target = object('target', 'PBXNativeTarget', name=NAME, productName=NAME, productReference=app,
                    productType='com.apple.product-type.application', buildConfigurationList=configList,
                    buildPhases=[sourcesPhase, frameworksPhase, embed], buildRules=[], dependencies=[],
                    packageProductDependencies=[migration])
    root = object('root', 'PBXProject', attributes={}, buildConfigurationList=configList, compatibilityVersion='Xcode 14.0',
                  developmentRegion='en', knownRegions=['en', 'Base'], mainGroup=group, productRefGroup=products,
                  projectDirPath='', projectRoot='', targets=[target], packageReferences=[package])
    xcode = stage / (NAME + '.xcodeproj'); xcode.mkdir()
    (xcode / 'project.pbxproj').write_bytes(plistlib.dumps({'archiveVersion': '1', 'classes': {}, 'objectVersion': '60',
                                                            'objects': objects, 'rootObject': root}))
    return xcode


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--signing-file', type=Path, help='Private build settings JSON; omitted means unsigned compile only')
    parser.add_argument('--project-only', action='store_true', help='Write the project for an Xcode GUI build and stop')
    args = parser.parse_args()
    output = args.output.resolve()
    if not output.is_relative_to(REPO / 'build'):
        raise SystemExit('OUTPUT_MUST_BE_IN_IGNORED_BUILD')
    if not (ZSTD / 'zstd.1').is_file():
        raise SystemExit('ZSTD_FRAMEWORK_MISSING')
    settings = {}
    if args.signing_file:
        settings = json.loads(args.signing_file.read_text())
        if set(settings) - {'DEVELOPMENT_TEAM', 'CODE_SIGN_STYLE', 'PROVISIONING_PROFILE_SPECIFIER'} or not settings.get('DEVELOPMENT_TEAM'):
            raise SystemExit('INVALID_PRIVATE_SIGNING_SETTINGS')
    output.mkdir(parents=True, exist_ok=False)
    if args.project_only:
        project(output / 'project', {**settings, 'SYMROOT': str(output / 'gui-products'), 'OBJROOT': str(output / 'gui-intermediates')})
        print(json.dumps({'project': True, 'signed': False, 'bundleId': BUNDLE_ID}))
        return 0
    xcode = project(output / 'project')
    command = ['xcodebuild', '-project', str(xcode), '-scheme', NAME, '-configuration', 'Release', '-sdk', 'iphoneos',
               '-destination', 'generic/platform=iOS', '-derivedDataPath', str(output / 'derived')]
    if args.signing_file:
        command += ['-allowProvisioningUpdates', 'CODE_SIGNING_ALLOWED=YES', *[k + '=' + v for k, v in settings.items()]]
    else:
        command.append('CODE_SIGNING_ALLOWED=NO')
    with (output / 'build-private.log').open('w') as log:
        code = subprocess.run(command + ['build'], stdout=log, stderr=subprocess.STDOUT).returncode
    app = output / f'derived/Build/Products/Release-iphoneos/{NAME}.app'
    completed = code == 0 and (app / NAME).is_file() and (app / 'Frameworks/zstd.1.framework/zstd.1').is_file()
    if completed and plistlib.loads((app / 'Info.plist').read_bytes())['CFBundleIdentifier'] != BUNDLE_ID:
        raise SystemExit('APP_IDENTITY_REFUSED')
    receipt = {'completed': completed, 'bundleId': BUNDLE_ID, 'signed': bool(args.signing_file) and completed,
               'sourceSha256': {p.name: digest(p) for p in sorted(SOURCE.glob('*')) if p.is_file()},
               'migrationSha256': {p.name: digest(p) for p in sorted((PACKAGE / 'Sources/Migration').glob('*.swift'))},
               'appBinarySha256': digest(app / NAME) if completed else None}
    (output / 'build-safe.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps({'completed': completed, 'signed': receipt['signed'], 'bundleId': BUNDLE_ID}))
    return 0 if completed else 1


if __name__ == '__main__':
    raise SystemExit(main())
