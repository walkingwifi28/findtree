#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  echo "Usage: ./scripts/build-release.sh <version>" >&2
  exit 1
fi

if [[ ! "$VERSION" =~ ^[0-9]+([.][0-9]+){1,2}([.-][0-9A-Za-z.-]+)*$ ]]; then
  echo "Error: invalid version: $VERSION" >&2
  exit 1
fi

BUILD_NUMBER="${GITHUB_RUN_NUMBER:-1}"
DIST_DIR="$ROOT_DIR/dist"
APP_PATH="$DIST_DIR/FindTree.app"
STAGING_DIR="$DIST_DIR/dmg-root"
DMG_NAME="FindTree-${VERSION}-arm64.dmg"
DMG_PATH="$DIST_DIR/$DMG_NAME"
CHECKSUM_PATH="$DMG_PATH.sha256"

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

./scripts/build-app.sh "$VERSION" "$BUILD_NUMBER"

if [[ ! -d "$APP_PATH" ]]; then
  echo "Error: app bundle not found: $APP_PATH" >&2
  exit 1
fi

INFO_PLIST="$APP_PATH/Contents/Info.plist"
EXECUTABLE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$INFO_PLIST")"
EXECUTABLE_PATH="$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME"

if [[ ! -f "$EXECUTABLE_PATH" ]]; then
  echo "Error: executable not found: $EXECUTABLE_PATH" >&2
  exit 1
fi

BINARY_ARCHS="$(lipo -archs "$EXECUTABLE_PATH")"
if [[ "$BINARY_ARCHS" != "arm64" ]]; then
  echo "Error: expected arm64-only binary, got: $BINARY_ARCHS" >&2
  exit 1
fi

PLIST_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
if [[ "$PLIST_VERSION" != "$VERSION" ]]; then
  echo "Error: expected app version $VERSION, got: $PLIST_VERSION" >&2
  exit 1
fi

codesign --verify --deep --strict --verbose=2 "$APP_PATH"

mkdir -p "$STAGING_DIR"
ditto "$APP_PATH" "$STAGING_DIR/FindTree.app"
ln -s /Applications "$STAGING_DIR/Applications"

hdiutil create \
  -volname "FindTree" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH" >/dev/null

rm -rf "$STAGING_DIR"
hdiutil verify "$DMG_PATH" >/dev/null

SHA256="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
printf '%s  %s\n' "$SHA256" "$DMG_NAME" > "$CHECKSUM_PATH"

cat <<EOF
Release package created.

Version:      $VERSION
Build:        $BUILD_NUMBER
Architecture: $BINARY_ARCHS
DMG:          $DMG_PATH
Checksum:     $CHECKSUM_PATH
SHA-256:      $SHA256
EOF
