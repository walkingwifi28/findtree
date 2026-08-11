#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

VERSION="${1:-${VERSION:-0.1.0}}"
BUILD_NUMBER="${2:-${BUILD_NUMBER:-1}}"

if [[ ! "$VERSION" =~ ^[0-9]+([.][0-9]+){1,2}([.-][0-9A-Za-z.-]+)*$ ]]; then
    echo "Error: invalid version: $VERSION" >&2
    exit 1
fi

if [[ ! "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
    echo "Error: invalid build number: $BUILD_NUMBER" >&2
    exit 1
fi

SWIFT_CMD=(swift)
if [[ "$(uname -m)" == "x86_64" ]] && [[ "$(sysctl -in sysctl.proc_translated 2>/dev/null || echo 0)" == "1" ]]; then
    SWIFT_CMD=(arch -arm64 swift)
fi

"${SWIFT_CMD[@]}" build -c release --product FindTreeApp
BIN_DIR="$("${SWIFT_CMD[@]}" build -c release --show-bin-path)"
APP_DIR="$ROOT_DIR/dist/FindTree.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"

rm -rf "$APP_DIR"
mkdir -p "$MACOS"
cp "$BIN_DIR/FindTreeApp" "$MACOS/FindTreeApp"
chmod +x "$MACOS/FindTreeApp"

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>FindTreeApp</string>
    <key>CFBundleIdentifier</key>
    <string>jp.findtree.desktop</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>FindTree</string>
    <key>CFBundleDisplayName</key>
    <string>FindTree</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

if command -v codesign >/dev/null 2>&1; then
    codesign --force --deep --sign - "$APP_DIR" >/dev/null
fi

printf 'Built: %s\nVersion: %s (%s)\n' "$APP_DIR" "$VERSION" "$BUILD_NUMBER"
