cask "findtree" do
  version "0.1.1"
  sha256 "12f2b0cefb05cc87adb1ff8f3cf2c8fd588ea040f418fccb33f8682586c6473f"

  url "https://github.com/walkingwifi28/findtree/releases/download/v0.1.1/FindTree-0.1.1-arm64.dmg"
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
