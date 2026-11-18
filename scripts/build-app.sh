#!/bin/bash
# Marksmith - build a standalone .app (and optionally a .dmg).
#
# Unlike the upstream project, this script NEVER hardcodes an architecture
# directory. It asks SwiftPM for the real binary path via --show-bin-path,
# which works on Intel, Apple Silicon and universal builds alike.
#
# Usage:
#   ./scripts/build-app.sh                 # host architecture (Intel or ARM)
#   ./scripts/build-app.sh --universal    # x86_64 + arm64 universal binary
#   ./scripts/build-app.sh --arch arm64   # explicit target
#   ./scripts/build-app.sh --dmg          # also produce a DMG
#   ./scripts/build-app.sh --no-sign      # skip ad-hoc codesign

set -eo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Marksmith"
APP_DIR="$PROJECT_DIR/build/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

ARCH_ARGS=()
BUILD_LABEL="host architecture"
MAKE_DMG=false
DO_SIGN=true
DEBUG=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --universal)
            ARCH_ARGS=(--arch x86_64 --arch arm64)
            BUILD_LABEL="universal (x86_64 + arm64)"
            shift
            ;;
        --arch)
            if [[ $# -lt 2 ]]; then echo "--arch requires a value" >&2; exit 2; fi
            ARCH_ARGS=(--arch "$2")
            BUILD_LABEL="$2"
            shift 2
            ;;
        --dmg) MAKE_DMG=true; shift ;;
        --no-sign) DO_SIGN=false; shift ;;
        --debug) DEBUG=true; shift ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done

cd "$PROJECT_DIR"
CONFIGURATION="release"
if [[ "$DEBUG" == true ]]; then CONFIGURATION="debug"; fi

echo "==> Building $CONFIGURATION binary for $BUILD_LABEL ..."
swift build -c "$CONFIGURATION" "${ARCH_ARGS[@]}"

# Ask SwiftPM where the products actually are. This is the critical bit:
# .build/<arch>-apple-macosx/<config> differs per machine and per --arch flag.
BIN_DIR="$(swift build -c "$CONFIGURATION" "${ARCH_ARGS[@]}" --show-bin-path)"
BINARY="$BIN_DIR/$APP_NAME"
RESOURCE_BUNDLE="$BIN_DIR/${APP_NAME}_${APP_NAME}.bundle"

if [[ ! -f "$BINARY" ]]; then
    echo "ERROR: expected binary not found at $BINARY" >&2
    echo "Contents of $BIN_DIR:" >&2
    ls -la "$BIN_DIR" >&2
    exit 1
fi

echo "==> Binary: $BINARY"
lipo -info "$BINARY" || file "$BINARY"

echo "==> Creating app bundle ..."
rm -rf "$APP_DIR"
mkdir -p "$MACOS" "$RESOURCES"
cp "$BINARY" "$MACOS/$APP_NAME"
cp "$PROJECT_DIR/Marksmith/App/Info.plist" "$CONTENTS/Info.plist"
printf 'APPL????' > "$CONTENTS/PkgInfo"

if [[ -f "$PROJECT_DIR/Marksmith/App/AppIcon.icns" ]]; then
    cp "$PROJECT_DIR/Marksmith/App/AppIcon.icns" "$RESOURCES/AppIcon.icns"
fi

if [[ -d "$RESOURCE_BUNDLE" ]]; then
    cp -R "$RESOURCE_BUNDLE" "$RESOURCES/"
else
    echo "WARNING: resource bundle not found at $RESOURCE_BUNDLE; copying Resources/ directly" >&2
    cp -R "$PROJECT_DIR/Marksmith/Resources" "$RESOURCES/Resources"
fi

if [[ "$DO_SIGN" == true ]]; then
    echo "==> Ad-hoc code signing (local use, no Apple Developer account needed) ..."
    codesign --force --deep --sign - "$APP_DIR" 2>/dev/null || \
        echo "WARNING: ad-hoc signing failed; the app should still run locally." >&2
fi

echo "==> Verifying bundle ..."
test -x "$MACOS/$APP_NAME"
test -f "$CONTENTS/Info.plist"
if [[ -d "$RESOURCES/${APP_NAME}_${APP_NAME}.bundle" ]]; then
    find "$RESOURCES/${APP_NAME}_${APP_NAME}.bundle" -maxdepth 2 -type d | head -8
fi
echo "App: $APP_DIR"

if [[ "$MAKE_DMG" == true ]]; then
    DMG_PATH="$PROJECT_DIR/build/$APP_NAME.dmg"
    STAGING="$PROJECT_DIR/build/dmg-staging"
    echo "==> Creating DMG ..."
    rm -rf "$STAGING" "$DMG_PATH"
    mkdir -p "$STAGING"
    cp -R "$APP_DIR" "$STAGING/"
    ln -s /Applications "$STAGING/Applications"
    hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG_PATH"
    rm -rf "$STAGING"
    echo "DMG: $DMG_PATH"
fi

echo "Done."
