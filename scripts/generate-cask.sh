#!/bin/bash
set -euo pipefail

if [[ $# -lt 4 ]]; then
  cat >&2 <<'EOF'
Usage:
  ./scripts/generate-cask.sh <version> <sha256> <download-url> <output-file> [homepage]
EOF
  exit 1
fi

VERSION="$1"
SHA256="$2"
DOWNLOAD_URL="$3"
OUTPUT_FILE="$4"
HOMEPAGE="${5:-https://github.com/walkingwifi28/findtree}"

if [[ ! "$VERSION" =~ ^[0-9]+([.][0-9]+){1,2}([.-][0-9A-Za-z.-]+)*$ ]]; then
  echo "Error: invalid version: $VERSION" >&2
  exit 1
fi

if [[ ! "$SHA256" =~ ^[0-9a-fA-F]{64}$ ]]; then
  echo "Error: SHA-256 must contain 64 hexadecimal characters." >&2
  exit 1
fi

if [[ ! "$DOWNLOAD_URL" =~ ^https://github.com/ ]] && [[ ! "$DOWNLOAD_URL" =~ ^file:// ]]; then
  echo "Error: unsupported download URL: $DOWNLOAD_URL" >&2
  exit 1
fi

SHA256_LOWER="$(printf '%s' "$SHA256" | tr '[:upper:]' '[:lower:]')"
mkdir -p "$(dirname "$OUTPUT_FILE")"

cat > "$OUTPUT_FILE" <<EOF
cask "findtree" do
  version "$VERSION"
  sha256 "$SHA256_LOWER"

  url "$DOWNLOAD_URL"
  name "FindTree"
  desc "Fast macOS disk-usage analyzer with a hierarchical treemap"
  homepage "$HOMEPAGE"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates false
  depends_on arch: :arm64
  depends_on macos: ">= :sequoia"

  app "FindTree.app"

  caveats <<~EOS
    This build is ad hoc signed and is not Apple notarized.
    If macOS blocks the app on first launch, run:
      xattr -dr com.apple.quarantine /Applications/FindTree.app

    For whole-disk analysis, enable FindTree in:
      System Settings > Privacy & Security > Full Disk Access
  EOS

  zap trash: [
    "~/Library/Application Support/findtree",
    "~/Library/Preferences/jp.findtree.desktop.plist",
    "~/Library/Saved Application State/jp.findtree.desktop.savedState",
  ]
end
EOF

echo "Cask generated: $OUTPUT_FILE"
