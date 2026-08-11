# FindTree

FindTree is a fast macOS disk-usage analyzer inspired by WizTree. It provides both a CLI and a native SwiftUI app.

All index data stays on the Mac. There is no network upload path in the project.


## Install

### Homebrew Cask

FindTree can use this repository itself as a Homebrew tap.

```bash
brew tap walkingwifi28/findtree https://github.com/walkingwifi28/findtree.git
brew trust --cask walkingwifi28/findtree/findtree
brew install --cask findtree
```

Launch the app:

```bash
open /Applications/FindTree.app
```

The automated release is currently ad hoc signed and is not Apple notarized. If macOS blocks the app on first launch, open it from Finder with **Control-click → Open**. If it is still blocked, remove the quarantine attribute:

```bash
xattr -dr com.apple.quarantine /Applications/FindTree.app
open /Applications/FindTree.app
```

For whole-disk analysis, enable FindTree in **System Settings → Privacy & Security → Full Disk Access**.

### DMG

Each `v*` tag creates a GitHub Release containing an Apple Silicon DMG and its SHA-256 file. Open the DMG and drag `FindTree.app` to `Applications`.

## Implemented

### Fast scanner

- batched directory metadata retrieval through `FileManager.contentsOfDirectory(...includingPropertiesForKeys:)`
- up to 8 parallel directory workers
- logical size and allocated size tracked separately
- symlinks are not followed
- stays on the starting volume by default
- bottom-up directory aggregation
- progress rate in entries/sec

Foundation can retrieve requested URL resource properties while enumerating a directory using the macOS bulk attribute path, avoiding a separate `stat` call for every file.

### Local index

Directory summaries are stored in:

```text
~/Library/Application Support/findtree/index.sqlite
```

Each scanned root gets a separate optimized file database in the same directory:

```text
~/Library/Application Support/findtree/files-<root-hash>.sqlite
```

The file database stores only:

- parent path relative to the indexed root
- file name
- logical bytes
- allocated bytes

File-name search uses SQLite FTS5 with the trigram tokenizer. Full file paths are reconstructed only when results are returned.


### Native macOS app

The SwiftUI app includes:

- folder picker
- Scan / Rescan
- cached result shown at launch
- volume capacity / used-space summary
- folder drill-down table
- folder filtering and sorting
- interactive treemap
- file-name search
- largest-files view
- Reveal in Finder
- Move to Trash with confirmation
- Full Disk Access settings shortcut

Run from SwiftPM:

```bash
swift run FindTreeApp
```

Build a normal `.app` bundle:

```bash
./scripts/build-app.sh
open dist/FindTree.app
```

The generated app is ad-hoc signed for local development.

## Performance measured on this Mac

Measured on 2026-08-11 on an Apple M3 / 8-core Mac.

For `/Users/atsushi`:

- about 1.40 million files
- about 213 thousand directories
- about 1.61 million total entries
- directory-only scan before file indexing: about 16.2 seconds
- scan while building the optimized per-file index: about 24.6 seconds
- scan throughput with per-file indexing: about 65.5K entries/sec
- cached directory snapshot load: about 0.09 seconds
- optimized file DB: about 483.5 MB for about 1.40 million files
- `.mov` file search from the CLI: about 0.01 seconds wall time
- underlying FTS queries: typically below a few milliseconds

For `/` after excluding macOS internal duplicate views and mounted child volumes:

- about 2.26 million files
- about 486 thousand directories
- about 2.75 million total entries
- scan without file-index writing: about 33.3 seconds
- about 82.5K entries/sec
- `/.nofollow` and the explicit `/System/Volumes/Data` mount are not double-counted
- 459 directories were unreadable without granting additional Full Disk Access to this development binary

An earlier file schema duplicated full paths across a `WITHOUT ROWID` table and secondary indexes. It reached about 1.25 GB and multi-second searches. That schema has been replaced; the migration removes the legacy embedded `files` table and vacuums the directory-summary database.

## Build

```bash
swift build -c release
```

If the shell itself is running through Rosetta on Apple Silicon:

```bash
arch -arm64 swift build -c release
```

## Release

Pushing a `v*` tag runs `.github/workflows/macos-release.yml` automatically.

```bash
git tag v0.1.0
git push origin v0.1.0
```

The workflow:

1. runs the Swift test suite on an arm64 macOS 15 runner
2. builds the release `FindTree.app` with the tag version embedded in `Info.plist`
3. ad hoc signs the app
4. creates `FindTree-<version>-arm64.dmg`
5. creates and verifies the SHA-256 file
6. publishes both files to the GitHub Release
7. generates `Casks/findtree.rb` with the release URL and SHA-256
8. commits and pushes the updated Cask to the repository's default branch

This repository is used directly as the Homebrew tap, so a separate `homebrew-tap` repository or Personal Access Token is not required. The workflow uses `GITHUB_TOKEN` with `contents: write`.

If the default branch is protected against direct pushes, allow GitHub Actions to push the Cask update or change the Cask update step to a pull-request flow.

### Build a release DMG locally

```bash
./scripts/build-release.sh 0.1.0
```

Output:

```text
dist/FindTree-0.1.0-arm64.dmg
dist/FindTree-0.1.0-arm64.dmg.sha256
```

### Generate a Cask locally

```bash
VERSION=0.1.0
DMG="dist/FindTree-${VERSION}-arm64.dmg"
SHA256="$(shasum -a 256 "$DMG" | awk '{print $1}')"

./scripts/generate-cask.sh \
  "$VERSION" \
  "$SHA256" \
  "file://$(pwd)/$DMG" \
  dist/findtree.rb \
  "https://github.com/walkingwifi28/findtree"

ruby -c dist/findtree.rb
```

## Test

```bash
arch -arm64 swift test
```

## CLI usage

```bash
.build/release/findtree ~
.build/release/findtree /Users --top 30
.build/release/findtree ~ --cached
.build/release/findtree ~ --files ".mov" --file-limit 100
.build/release/findtree ~ --largest-files --file-limit 100
```

### CLI options

- `--top N`: show N largest directories
- `--workers N`: parallel directory workers
- `--cached`: read the local directory snapshot without scanning
- `--files QUERY`: search the local file-name index
- `--largest-files`: show largest indexed files
- `--file-limit N`: file result limit
- `--index PATH`: override the directory-index path; file indexes are stored alongside it
- `--no-index`: scan without writing local indexes
- `--exclude-hidden`: skip hidden files
- `--cross-volumes`: traverse mounted volumes under the selected root

## Permissions

A normal user process cannot read every protected location on macOS. For whole-disk analysis, add `FindTree.app` to **System Settings → Privacy & Security → Full Disk Access**.

The app surfaces the unreadable-directory count and provides a shortcut to the Full Disk Access settings page.

## Design notes

FindTree intentionally does not parse raw APFS container structures. The current design uses supported macOS APIs for scanning and local SQLite indexes. That keeps FileVault, APFS volume groups, snapshots, and OS updates out of the scanner's raw-filesystem compatibility surface.

A future low-level `getattrlistbulk()` implementation can still be benchmarked against Foundation if further first-scan optimization is needed.

## License

FindTree is released under the MIT License. See [LICENSE](LICENSE) for details.
