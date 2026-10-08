#!/bin/bash
set -euo pipefail
bundle="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
frameworks="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH"
if [[ -n "${PLAN500_WORKER_WEB:-}" ]]; then
    mkdir -p "$bundle/WorkerWeb"
    for name in integration.html worker.js client.js apply-injections.js vfs-image.tar.gz gate3-fixture.json \
        native-git-objects.js native-git-match.js native-git-xdiff.js native-git.js git-http-fixture.cjs; do
        ditto "$PLAN500_WORKER_WEB/$name" "$bundle/WorkerWeb/$name"
    done
fi
if [[ "$PLATFORM_NAME" != "iphoneos" ]]; then
    echo "warning: Simulator checks only compile the probe shell; they cannot run device QEMU."
    exit 0
fi
: "${PLAN500_INPUT_DIR:?isolated probe inputs required}"
: "${PLAN500_EXECUTOR_DIR:?prepared device executor required}"
mkdir -p "$bundle/ProbeInputs" "$bundle/qemu" "$frameworks"
for name in Image initramfs.gz system.raw inputs.json token-private; do
    ditto "$PLAN500_INPUT_DIR/$name" "$bundle/ProbeInputs/$name"
done
for source in "$PLAN500_EXECUTOR_DIR"/Frameworks/*.framework; do
    target="$frameworks/$(basename "$source")"
    ditto "$source" "$target"
    # Never retain a prior signing identity in an unsigned research artifact.
    codesign --remove-signature "$target" 2>/dev/null || true
    xcrun strip -x -S "$target/$(basename "$source" .framework)"
    if [[ "${CODE_SIGNING_ALLOWED:-NO}" == "YES" && -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]]; then
        codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$target"
    fi
done
