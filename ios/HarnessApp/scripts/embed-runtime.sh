#!/bin/bash
set -euo pipefail

# The executor build and guest image build are independent inputs to this App.
executor="${HARNESS_EXECUTOR_DIR:-$SRCROOT/.runtime}"
guest="${HARNESS_GUEST_DIR:-$SRCROOT/.runtime/Guest}"
bundle="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
frameworks="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH"

if [[ "$PLATFORM_NAME" != "iphoneos" ]]; then
    echo "warning: Simulator builds cannot run the device-only QEMU executor."
    exit 0
fi

if [[ ! -f "$executor/Frameworks/qemu-aarch64-softmmu.framework/qemu-aarch64-softmmu" || ! -f "$guest/runtime.json" ]]; then
    if [[ "$CONFIGURATION" == "Release" ]]; then
        echo "error: Release requires both HARNESS_EXECUTOR_DIR and HARNESS_GUEST_DIR."
        exit 1
    fi
    # Avoid retaining a previous build's guest or executor after inputs disappear.
    rm -rf "$bundle/Runtime" "$bundle/qemu" "$frameworks"
    echo "warning: Debug build has no complete runtime; the App will show the missing-runtime state."
    exit 0
fi

python3 "$SRCROOT/scripts/validate-runtime.py" "$guest"
rm -rf "$frameworks"
mkdir -p "$frameworks"
for framework in "$executor"/Frameworks/*.framework; do
    target="$frameworks/$(basename "$framework")"
    ditto "$framework" "$target"
    if [[ "${CODE_SIGNING_ALLOWED:-NO}" == "YES" && -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]]; then
        codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$target"
    fi
done
rm -rf "$bundle/Runtime" "$bundle/qemu"
mkdir -p "$bundle/Runtime"
while IFS= read -r name; do
    ditto "$guest/$name" "$bundle/Runtime/$name"
done < <(python3 "$SRCROOT/scripts/validate-runtime.py" "$guest" --list)
if [[ -d "$executor/qemu" ]]; then ditto "$executor/qemu" "$bundle/qemu"; fi
