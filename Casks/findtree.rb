cask "findtree" do
  version "0.1.0"
  sha256 "f81cfe1e1a75cb270cfbabe08aeabc3231b9615198ec1da9daff2d7dbc532393"

  url "https://github.com/walkingwifi28/findtree/releases/download/v0.1.0/FindTree-0.1.0-arm64.dmg"
  name "FindTree"
  desc "Fast macOS disk-usage analyzer with a hierarchical treemap"
  homepage "https://github.com/walkingwifi28/findtree"

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
