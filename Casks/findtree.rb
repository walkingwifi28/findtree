cask "findtree" do
  version "0.2.0"
  sha256 "ac1df417544f7741f48354b120d5692b0d69194743ec98258740ed3d32445383"

  url "https://github.com/walkingwifi28/findtree/releases/download/v0.2.0/FindTree-0.2.0-arm64.dmg"
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
