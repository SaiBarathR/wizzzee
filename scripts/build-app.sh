#!/bin/bash
#
# Builds Wizzzee.app into dist/.
#
#   ./scripts/build-app.sh              build and sign the bundle
#   ./scripts/build-app.sh --install    also copy it to /Applications
#   ./scripts/build-app.sh --debug      build the debug configuration
#   ./scripts/build-app.sh --native     build only for this machine's CPU
#
# The bundle is universal (arm64 + x86_64) so a downloaded release runs on
# either kind of Mac, and ad-hoc signed with a stable identifier so macOS treats
# it as the same app across rebuilds. Full Disk Access is still keyed on the
# signature itself, which changes with the binary, so that grant has to be
# re-added after a rebuild.
#
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIGURATION=release
INSTALL=0
UNIVERSAL=1
for argument in "$@"; do
    case "$argument" in
        --install) INSTALL=1 ;;
        --debug) CONFIGURATION=debug ;;
        --native) UNIVERSAL=0 ;;
        *) echo "unknown option: $argument" >&2; exit 1 ;;
    esac
done

APP_NAME="Wizzzee"
BUNDLE="dist/${APP_NAME}.app"
CONTENTS="${BUNDLE}/Contents"

rm -rf "$BUNDLE"
mkdir -p "${CONTENTS}/MacOS" "${CONTENTS}/Resources"

if [ "$UNIVERSAL" -eq 1 ]; then
    ARCHITECTURES=(arm64 x86_64)
else
    ARCHITECTURES=("$(uname -m)")
fi

SLICES=()
for architecture in "${ARCHITECTURES[@]}"; do
    echo "==> Building ${architecture} (${CONFIGURATION})"
    # A scratch path per architecture, so the two slices don't overwrite each
    # other's build products.
    SCRATCH=".build/${architecture}"
    swift build -c "$CONFIGURATION" --arch "$architecture" --scratch-path "$SCRATCH"
    BIN_PATH="$(swift build -c "$CONFIGURATION" --arch "$architecture" \
        --scratch-path "$SCRATCH" --show-bin-path)"
    SLICES+=("${BIN_PATH}/${APP_NAME}")
done

echo "==> Assembling ${BUNDLE}"
if [ "${#SLICES[@]}" -gt 1 ]; then
    lipo -create "${SLICES[@]}" -output "${CONTENTS}/MacOS/${APP_NAME}"
else
    cp "${SLICES[0]}" "${CONTENTS}/MacOS/${APP_NAME}"
fi
cp Resources/Info.plist "${CONTENTS}/Info.plist"
printf 'APPL????' > "${CONTENTS}/PkgInfo"

BUILT_ARCHITECTURES="$(lipo -archs "${CONTENTS}/MacOS/${APP_NAME}" \
    | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ $//')"
if [ "$UNIVERSAL" -eq 1 ] && [ "$BUILT_ARCHITECTURES" != "arm64 x86_64" ]; then
    echo "expected [arm64 x86_64], got [${BUILT_ARCHITECTURES}]" >&2
    exit 1
fi

echo "==> Rendering icon"
ICONSET="$(mktemp -d)/${APP_NAME}.iconset"
swift scripts/make-icon.swift "$ICONSET" >/dev/null
iconutil -c icns "$ICONSET" -o "${CONTENTS}/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"

echo "==> Signing"
# A stable ad-hoc identity keeps the TCC (Full Disk Access) grant attached
# across rebuilds. Not sandboxed: the whole point is to read the entire disk.
codesign --force --sign - \
    --identifier com.wizzzee.diskanalyzer \
    --options runtime \
    --timestamp=none \
    "$BUNDLE" 2>&1 | sed 's/^/    /'

codesign --verify --deep --strict "$BUNDLE" && echo "    signature OK"

# Nudge Launch Services so the new icon and name show up right away.
touch "$BUNDLE"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$BUNDLE" 2>/dev/null || true

SIZE="$(du -sh "$BUNDLE" | cut -f1)"
echo "==> Built ${BUNDLE} (${SIZE}, ${BUILT_ARCHITECTURES})"

if [ "$INSTALL" -eq 1 ]; then
    echo "==> Installing to /Applications"
    rm -rf "/Applications/${APP_NAME}.app"
    cp -R "$BUNDLE" "/Applications/${APP_NAME}.app"
    echo "    installed /Applications/${APP_NAME}.app"
    echo
    echo "Grant Full Disk Access so system and other users' files are included:"
    echo "  System Settings > Privacy & Security > Full Disk Access > +"
    echo "  then add /Applications/${APP_NAME}.app"
else
    echo
    echo "Run it with:  open ${BUNDLE}"
fi
