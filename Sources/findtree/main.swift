import Foundation
import Darwin
import CoreServices
import FindTreeCore

struct Arguments {
    var path: String = FileManager.default.homeDirectoryForCurrentUser.path
    var top: Int = 20
    var includeHidden = true
    var stayOnVolume = true
    var workerCount = min(8, max(2, ProcessInfo.processInfo.activeProcessorCount))
    var cacheOnly = false
    var watch = false
    var fileQuery: String?
    var fileLimit = 50
    var largestFiles = false
    var indexEnabled = true
    var indexPath: String = defaultIndexURL().path

    init(_ raw: [String]) {
        var index = 0
        var positionalPath: String?

        while index < raw.count {
            let arg = raw[index]
            switch arg {
            case "--top":
                if index + 1 < raw.count, let value = Int(raw[index + 1]) {
                    top = max(value, 0)
                    index += 1
                }
            case "--workers":
                if index + 1 < raw.count, let value = Int(raw[index + 1]) {
                    workerCount = max(value, 1)
                    index += 1
                }
            case "--index":
                if index + 1 < raw.count {
                    indexPath = (raw[index + 1] as NSString).expandingTildeInPath
                    index += 1
                }
            case "--cached":
                cacheOnly = true
            case "--watch":
                watch = true
            case "--files":
                if index + 1 < raw.count {
                    fileQuery = raw[index + 1]
                    index += 1
                }
            case "--largest-files":
                largestFiles = true
            case "--file-limit":
                if index + 1 < raw.count, let value = Int(raw[index + 1]) {
                    fileLimit = max(value, 1)
                    index += 1
                }
            case "--no-index":
                indexEnabled = false
            case "--exclude-hidden":
                includeHidden = false
            case "--cross-volumes":
                stayOnVolume = false
            case "-h", "--help":
                printHelpAndExit()
            default:
                if !arg.hasPrefix("-") && positionalPath == nil {
                    positionalPath = arg
                }
            }
            index += 1
        }

        if let positionalPath {
            path = (positionalPath as NSString).expandingTildeInPath
        }

        if watch {
            indexEnabled = true
            cacheOnly = false
        }
    }
}

private func defaultIndexURL() -> URL {
    let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
    return applicationSupport
        .appendingPathComponent("findtree", isDirectory: true)
        .appendingPathComponent("index.sqlite")
}

private func printHelpAndExit() -> Never {
    print("""
    findtree - fast macOS disk usage scanner

    Usage:
      findtree [path] [options]

    Options:
      --top N             Show N largest directories (default: 20)
      --workers N         Parallel directory workers (default: up to 8)
      --cached            Load the latest local SQLite snapshot without scanning
      --watch             Show cached data immediately and keep it synced with FSEvents
      --files QUERY       Search the local file index without rescanning
      --largest-files     Show the largest files from the local index
      --file-limit N      Limit file search/list results (default: 50)
      --index PATH        Override the local SQLite index path
      --no-index          Do not save scan results to SQLite
      --exclude-hidden    Skip hidden files
      --cross-volumes     Traverse mounted volumes below the root path

    Examples:
      findtree ~
      findtree /Users --top 30
      findtree ~ --cached
      findtree ~ --watch
      findtree ~ --files ".mov"
      findtree ~ --largest-files --file-limit 100
    """)
    exit(EXIT_SUCCESS)
}

private func formatBytes(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
}

private func formatRate(_ count: Int, _ seconds: Double) -> String {
    guard seconds > 0 else { return "-" }
    let rate = Double(count) / seconds
    if rate >= 1_000_000 {
        return String(format: "%.2f M entries/s", rate / 1_000_000)
    }
    if rate >= 1_000 {
        return String(format: "%.1f K entries/s", rate / 1_000)
    }
    return String(format: "%.0f entries/s", rate)
}

private func printResult(_ result: ScanResult, top: Int, cachedAt: Date? = nil) {
    print("\nRoot:      \(result.rootPath)")
    if let cachedAt {
        print("Cached at: \(cachedAt.formatted(date: .numeric, time: .standard))")
    } else {
        print(String(format: "Elapsed:   %.3f s", result.elapsedSeconds))
        print("Rate:      \(formatRate(result.fileCount + result.directoryCount, result.elapsedSeconds))")
    }
    print("Files:     \(result.fileCount)")
    print("Dirs:      \(result.directoryCount)")
    print("Unreadable: \(result.inaccessibleDirectoryCount)")
    print("Logical:   \(formatBytes(result.logicalBytes))")
    print("Allocated: \(formatBytes(result.allocatedBytes))")

    if top > 0 {
        print("\nLargest directories by allocated size:")
        for (rank, directory) in result.largestDirectories(limit: top).enumerated() {
            let allocated = formatBytes(directory.allocatedBytes)
            let logical = formatBytes(directory.logicalBytes)
            print(String(format: "%3d  %10@ allocated  %10@ logical  %@", rank + 1, allocated as NSString, logical as NSString, directory.path))
        }
    }
}

private func scanAndIndex(
    rootURL: URL,
    args: Arguments,
    scanner: FastScanner,
    indexStore: ScanIndexStore
) throws -> ScanResult {
    fputs("Scanning \(rootURL.path) with \(args.workerCount) workers...\n", stderr)
    let progressStart = ContinuousClock.now
    // Save the cursor from before the scan. Events that happen during the scan are replayed later,
    // preventing a change from falling into the gap between scanning and starting FSEvents.
    let cursorBeforeScan = UInt64(FSEventsGetCurrentEventId())

    let fileWriter: FileIndexWriter?
    if args.indexEnabled {
        fileWriter = try FileIndexStore(databaseURL: indexStore.databaseURL).makeFullWriter(rootPath: rootURL.path)
    } else {
        fileWriter = nil
    }

    let fileBatchHandler: (@Sendable ([FileUsage]) throws -> Void)?
    if let fileWriter {
        fileBatchHandler = { files in try fileWriter.consume(files) }
    } else {
        fileBatchHandler = nil
    }

    let result: ScanResult
    do {
        result = try scanner.scan(
            rootURL: rootURL,
            options: ScanOptions(
                stayOnRootVolume: args.stayOnVolume,
                includeHiddenFiles: args.includeHidden,
                workerCount: args.workerCount
            ),
            progressEvery: 100_000,
            onProgress: { progress in
                let duration = progressStart.duration(to: .now)
                let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1_000_000_000_000_000_000
                fputs(
                    "  \(progress.files) files, \(progress.directories) dirs, \(formatBytes(progress.allocatedBytes)) allocated, \(formatRate(progress.files + progress.directories, seconds))\n",
                    stderr
                )
            },
            onFileBatch: fileBatchHandler
        )
        try fileWriter?.finish()
    } catch {
        fileWriter?.cancel()
        throw error
    }

    if args.indexEnabled {
        let indexStartedAt = ContinuousClock.now
        try indexStore.save(result)
        try indexStore.saveLastEventID(cursorBeforeScan, rootPath: rootURL.path)
        let duration = indexStartedAt.duration(to: .now)
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1_000_000_000_000_000_000
        fputs(String(format: "Indexed locally in %.3f s: %@\n", seconds, indexStore.databaseURL.path), stderr)
    }

    return result
}


private final class WatchChangeQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var synchronizing = false
    private var queued: [FileSystemChange] = []

    func enqueue(_ changes: [FileSystemChange]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        queued.append(contentsOf: changes)
        if synchronizing { return false }
        synchronizing = true
        return true
    }

    func takeNextBatch() -> [FileSystemChange]? {
        lock.lock()
        defer { lock.unlock() }
        if queued.isEmpty {
            synchronizing = false
            return nil
        }
        let batch = queued
        queued.removeAll(keepingCapacity: true)
        return batch
    }
}

private func runWatchMode(
    rootURL: URL,
    args: Arguments,
    scanner: FastScanner,
    indexStore: ScanIndexStore
) throws -> Never {
    var snapshot = try indexStore.load(rootPath: rootURL.path)
    var cursor = try indexStore.lastEventID(rootPath: rootURL.path)

    if snapshot == nil || cursor == nil {
        let fresh = try scanAndIndex(rootURL: rootURL, args: args, scanner: scanner, indexStore: indexStore)
        printResult(fresh, top: args.top)
        snapshot = try indexStore.load(rootPath: rootURL.path)
        cursor = try indexStore.lastEventID(rootPath: rootURL.path)
    } else if let snapshot {
        printResult(snapshot.result, top: args.top, cachedAt: snapshot.indexedAt)
    }

    let updater = IncrementalIndexUpdater(
        rootURL: rootURL,
        store: indexStore,
        scanner: scanner,
        scanOptions: ScanOptions(
            stayOnRootVolume: args.stayOnVolume,
            includeHiddenFiles: args.includeHidden,
            workerCount: args.workerCount
        )
    )

    let changeQueue = WatchChangeQueue()
    let processQueue = DispatchQueue(label: "findtree.incremental-sync", qos: .utility)
    let watcher = FSEventWatcher(
        rootPath: rootURL.path,
        sinceWhen: FSEventStreamEventId(cursor ?? UInt64(kFSEventStreamEventIdSinceNow))
    ) { changes in
        guard changeQueue.enqueue(changes) else { return }

        processQueue.async {
            while let batch = changeQueue.takeNextBatch() {
                do {
                    let sync = try updater.synchronize(changes: batch)
                    if sync.fullRescan {
                        fputs(String(format: "\nFSEvents overflow/root change: full rescan completed in %.3f s\n", sync.elapsedSeconds), stderr)
                    } else if !sync.refreshedPaths.isEmpty {
                        fputs(String(format: "\nIncremental refresh: %d subtree(s) in %.3f s\n", sync.refreshedPaths.count, sync.elapsedSeconds), stderr)
                        for path in sync.refreshedPaths.prefix(10) {
                            fputs("  - \(path)\n", stderr)
                        }
                    }

                    if let updated = try indexStore.load(rootPath: rootURL.path), !sync.refreshedPaths.isEmpty || sync.fullRescan {
                        printResult(updated.result, top: args.top, cachedAt: updated.indexedAt)
                    }
                } catch {
                    fputs("findtree watch: incremental sync failed: \(error)\n", stderr)
                }
            }
        }
    }

    try watcher.start()
    fputs("Watching \(rootURL.path) for changes. Press Ctrl-C to stop.\n", stderr)
    dispatchMain()
}

let args = Arguments(Array(CommandLine.arguments.dropFirst()))
let rootURL = URL(fileURLWithPath: args.path, isDirectory: true).standardizedFileURL
let indexStore = ScanIndexStore(databaseURL: URL(fileURLWithPath: args.indexPath))
let scanner = FastScanner()

if args.fileQuery != nil || args.largestFiles {
    do {
        let fileStore = FileIndexStore(databaseURL: indexStore.databaseURL)
        let files = try fileStore.search(
            rootPath: rootURL.path,
            query: args.fileQuery ?? "",
            limit: args.fileLimit
        )
        if files.isEmpty {
            if fileStore.hasIndex(rootPath: rootURL.path) {
                print("No indexed files matched.")
            } else {
                print("No file index exists. Run findtree \(rootURL.path) once to build it.")
            }
        } else {
            for (rank, file) in files.enumerated() {
                print(String(format: "%4d  %10@ allocated  %10@ logical  %@", rank + 1, formatBytes(file.allocatedBytes) as NSString, formatBytes(file.logicalBytes) as NSString, file.path))
            }
        }
        exit(EXIT_SUCCESS)
    } catch {
        fputs("findtree: \(error)\n", stderr)
        exit(EXIT_FAILURE)
    }
}

if args.cacheOnly {
    do {
        guard let snapshot = try indexStore.load(rootPath: rootURL.path) else {
            fputs("findtree: no cached scan for \(rootURL.path)\n", stderr)
            exit(EXIT_FAILURE)
        }
        printResult(snapshot.result, top: args.top, cachedAt: snapshot.indexedAt)
        exit(EXIT_SUCCESS)
    } catch {
        fputs("findtree: \(error)\n", stderr)
        exit(EXIT_FAILURE)
    }
}

if args.watch {
    do {
        try runWatchMode(rootURL: rootURL, args: args, scanner: scanner, indexStore: indexStore)
    } catch {
        fputs("findtree: \(error)\n", stderr)
        exit(EXIT_FAILURE)
    }
}

do {
    let result = try scanAndIndex(rootURL: rootURL, args: args, scanner: scanner, indexStore: indexStore)
    printResult(result, top: args.top)
} catch {
    fputs("findtree: \(error)\n", stderr)
    exit(EXIT_FAILURE)
}
