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
RESOURCES="$CONTENTS/Resources"
ICON_SOURCE="$ROOT_DIR/Resources/AppIcon.png"
ICONSET_DIR="$ROOT_DIR/dist/AppIcon.iconset"
ICON_FILE="$RESOURCES/AppIcon.icns"

rm -rf "$APP_DIR" "$ICONSET_DIR"
mkdir -p "$MACOS" "$RESOURCES"
cp "$BIN_DIR/FindTreeApp" "$MACOS/FindTreeApp"
chmod +x "$MACOS/FindTreeApp"

if [[ ! -f "$ICON_SOURCE" ]]; then
    echo "Error: app icon source not found: $ICON_SOURCE" >&2
    exit 1
fi

mkdir -p "$ICONSET_DIR"

function make_icon() {
    local size="$1"
    local output="$2"
    /usr/bin/sips -z "$size" "$size" "$ICON_SOURCE" --out "$ICONSET_DIR/$output" >/dev/null
}

make_icon 16 icon_16x16.png
make_icon 32 icon_16x16@2x.png
make_icon 32 icon_32x32.png
make_icon 64 icon_32x32@2x.png
make_icon 128 icon_128x128.png
make_icon 256 icon_128x128@2x.png
make_icon 256 icon_256x256.png
make_icon 512 icon_256x256@2x.png
make_icon 512 icon_512x512.png
make_icon 1024 icon_512x512@2x.png

/usr/bin/iconutil -c icns "$ICONSET_DIR" -o "$ICON_FILE"
rm -rf "$ICONSET_DIR"

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
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
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
