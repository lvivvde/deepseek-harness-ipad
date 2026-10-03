#!/bin/bash
set -euo pipefail
# Device-only, prebuilt interpreter frameworks prepared by prepare-runtime.py.
if [[ "${PLATFORM_NAME}" != "iphoneos" ]]; then
    echo "Simulator build: device QEMU frameworks are intentionally omitted."
    exit 0
fi
runtime="$SRCROOT/.runtime"
if [[ ! -d "$runtime/Frameworks" ]]; then
    echo "No QEMU runtime prepared: building diagnostic shell only."
    exit 0
fi
mkdir -p "$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH"
for framework in "$runtime"/Frameworks/*.framework; do
    target="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH/$(basename "$framework")"
    ditto "$framework" "$target"
    if [[ "${CODE_SIGNING_ALLOWED:-NO}" == "YES" && -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]]; then
        codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$target"
    fi
done
if [[ -d "$runtime/qemu" ]]; then
    ditto "$runtime/qemu" "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/qemu"
fi
