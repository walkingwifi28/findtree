cask "findtree" do
  version "0.1.2"
  sha256 "adb251c15f12ae4d422a125f592b9dab9175f1dd1d464b9ef7bc183f34cd80ef"

  url "https://github.com/walkingwifi28/findtree/releases/download/v0.1.2/FindTree-0.1.2-arm64.dmg"
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
