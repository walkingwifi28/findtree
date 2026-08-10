# FindTree

FindTree is a fast macOS disk-usage analyzer inspired by WizTree. It provides both a CLI and a native SwiftUI app.

All index data stays on the Mac. There is no network upload path in the project.

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

### Live incremental updates

- FSEvents watcher
- persistent FSEvent cursor
- changed file events are coalesced to the smallest non-overlapping directory set
- only affected subtrees are rescanned
- size/count deltas are propagated to cached ancestors
- changed file-index subtrees are replaced transactionally
- FSEvents overflow / root changes fall back to a full rescan
- index database events are excluded to prevent feedback loops

CLI live mode:

```bash
.build/release/findtree ~ --watch
```

The cached result is shown immediately, then FSEvents keeps the local index current.

### Native macOS app

The SwiftUI app includes:

- folder picker
- Scan / Rescan
- cached result shown at launch
- live FSEvents status
- allocated/logical size summary
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

## Test

```bash
arch -arm64 swift test
```

## CLI usage

```bash
.build/release/findtree ~
.build/release/findtree /Users --top 30
.build/release/findtree ~ --cached
.build/release/findtree ~ --watch
.build/release/findtree ~ --files ".mov" --file-limit 100
.build/release/findtree ~ --largest-files --file-limit 100
```

### CLI options

- `--top N`: show N largest directories
- `--workers N`: parallel directory workers
- `--cached`: read the local directory snapshot without scanning
- `--watch`: show cached data and keep it current using FSEvents
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

FindTree intentionally does not parse raw APFS container structures. The current design uses supported macOS APIs for scanning and FSEvents for change tracking. That keeps FileVault, APFS volume groups, snapshots, and OS updates out of the scanner's raw-filesystem compatibility surface.

A future low-level `getattrlistbulk()` implementation can still be benchmarked against Foundation if further first-scan optimization is needed.
