import Foundation
import CoreServices

public struct IncrementalSyncResult: Sendable {
    public let fullRescan: Bool
    public let refreshedPaths: [String]
    public let elapsedSeconds: Double
    public let lastEventID: UInt64?

    public init(fullRescan: Bool, refreshedPaths: [String], elapsedSeconds: Double, lastEventID: UInt64?) {
        self.fullRescan = fullRescan
        self.refreshedPaths = refreshedPaths
        self.elapsedSeconds = elapsedSeconds
        self.lastEventID = lastEventID
    }
}

public final class IncrementalIndexUpdater: @unchecked Sendable {
    private let rootURL: URL
    private let eventRootPath: String
    private let rootVolumePath: String?
    private let store: ScanIndexStore
    private let fileStore: FileIndexStore
    private let scanner: FastScanner
    private let scanOptions: ScanOptions
    private let excludedPrefixes: [String]

    public init(
        rootURL: URL,
        store: ScanIndexStore,
        scanner: FastScanner = FastScanner(),
        scanOptions: ScanOptions = ScanOptions(),
        excludedPaths: [String] = []
    ) {
        self.rootURL = rootURL.standardizedFileURL
        self.eventRootPath = PathUtilities.canonicalExisting(rootURL.path)
        self.rootVolumePath = try? rootURL.resourceValues(forKeys: [.volumeURLKey]).volume?.standardizedFileURL.path
        self.store = store
        self.fileStore = FileIndexStore(databaseURL: store.databaseURL)
        self.scanner = scanner
        self.scanOptions = scanOptions

        var exclusions = excludedPaths.map {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        }
        let databaseParent = store.databaseURL.deletingLastPathComponent().standardizedFileURL.path
        if PathUtilities.isDescendantOrEqual(databaseParent, of: self.rootURL.path) {
            exclusions.append(databaseParent)
        }
        if self.rootURL.path == "/" {
            exclusions.append("/.nofollow")
        }
        self.excludedPrefixes = Array(Set(exclusions))
    }

    public func synchronize(changes: [FileSystemChange]) throws -> IncrementalSyncResult {
        let startedAt = ContinuousClock.now
        let relevant = changes.compactMap(logicalChange)
        let maxEventID = relevant.map(\.eventID).max()

        if relevant.isEmpty {
            if let maxEventID = changes.map(\.eventID).max() {
                try store.saveLastEventID(maxEventID, rootPath: rootURL.path)
            }
            return IncrementalSyncResult(
                fullRescan: false,
                refreshedPaths: [],
                elapsedSeconds: secondsSince(startedAt),
                lastEventID: changes.map(\.eventID).max()
            )
        }

        if relevant.contains(where: { FSEventWatcher.eventRequiresFullRescan($0.flags) }) {
            let writer = try fileStore.makeFullWriter(rootPath: rootURL.path)
            let result = try scanner.scan(
                rootURL: rootURL,
                options: scanOptions,
                progressEvery: 0,
                onFileBatch: { try writer.consume($0) }
            )
            try writer.finish()
            try store.save(result)
            if let maxEventID { try store.saveLastEventID(maxEventID, rootPath: rootURL.path) }
            return IncrementalSyncResult(
                fullRescan: true,
                refreshedPaths: [rootURL.path],
                elapsedSeconds: secondsSince(startedAt),
                lastEventID: maxEventID
            )
        }

        let paths = Self.coalescedRefreshPaths(for: relevant, rootPath: rootURL.path)
        for path in paths {
            let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)

            let writer = try fileStore.makeSubtreeWriter(rootPath: rootURL.path, subtreePath: url.path)
            if exists && isDirectory.boolValue {
                let subtree = try scanner.scan(
                    rootURL: url,
                    options: scanOptions,
                    progressEvery: 0,
                    onFileBatch: { try writer.consume($0) }
                )
                try writer.finish()
                try store.replaceSubtree(rootPath: rootURL.path, subtreePath: url.path, with: subtree)
            } else {
                try writer.finish()
                try store.replaceSubtree(rootPath: rootURL.path, subtreePath: url.path, with: nil)
            }
        }

        if let maxEventID {
            try store.saveLastEventID(maxEventID, rootPath: rootURL.path)
        }

        return IncrementalSyncResult(
            fullRescan: false,
            refreshedPaths: paths,
            elapsedSeconds: secondsSince(startedAt),
            lastEventID: maxEventID
        )
    }

    /// Converts file-level FSEvents into the smallest non-overlapping directory set to rescan.
    public static func coalescedRefreshPaths(for changes: [FileSystemChange], rootPath: String) -> [String] {
        let root = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL.path
        let isDirFlag = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir)
        let removedFlag = FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved)

        var candidates = Set<String>()
        for change in changes {
            let path = URL(fileURLWithPath: change.path).standardizedFileURL.path
            guard path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/") else { continue }

            let itemWasDirectory = change.flags & isDirFlag != 0
            let itemRemoved = change.flags & removedFlag != 0
            let candidate: String

            if itemWasDirectory {
                // A removed directory must be removed from the cached subtree by its old path.
                // Existing/created directories can also be refreshed directly.
                candidate = path
            } else {
                candidate = (path as NSString).deletingLastPathComponent
            }

            if candidate == root || candidate.hasPrefix(root.hasSuffix("/") ? root : root + "/") {
                candidates.insert(candidate)
            }

            // A removed non-directory only requires its parent. The explicit branch is kept
            // here to make deletion semantics obvious and avoid treating the missing file as a subtree.
            _ = itemRemoved
        }

        let sorted = candidates.sorted {
            let lhsDepth = $0.split(separator: "/").count
            let rhsDepth = $1.split(separator: "/").count
            if lhsDepth == rhsDepth { return $0 < $1 }
            return lhsDepth < rhsDepth
        }

        var result: [String] = []
        for candidate in sorted {
            let covered = result.contains { ancestor in
                candidate == ancestor || candidate.hasPrefix(ancestor.hasSuffix("/") ? ancestor : ancestor + "/")
            }
            if !covered { result.append(candidate) }
        }
        return result
    }

    private func logicalChange(_ change: FileSystemChange) -> FileSystemChange? {
        let eventPath = PathUtilities.standardized(change.path)
        let logicalRoot = rootURL.path
        let logicalPath: String

        if PathUtilities.isDescendantOrEqual(eventPath, of: eventRootPath) {
            if eventPath == eventRootPath {
                logicalPath = logicalRoot
            } else {
                let suffix = String(eventPath.dropFirst(eventRootPath.count))
                logicalPath = logicalRoot + suffix
            }
        } else if PathUtilities.isDescendantOrEqual(eventPath, of: logicalRoot) {
            logicalPath = eventPath
        } else {
            return nil
        }

        let excluded = excludedPrefixes.contains { prefix in
            PathUtilities.isDescendantOrEqual(logicalPath, of: prefix)
        }
        guard !excluded else { return nil }

        // Ignore mounted volumes that the initial scanner intentionally skipped.
        if FileManager.default.fileExists(atPath: logicalPath),
           let rootVolumePath,
           let values = try? URL(fileURLWithPath: logicalPath).resourceValues(forKeys: [.volumeURLKey]),
           let itemVolumePath = values.volume?.standardizedFileURL.path,
           itemVolumePath != rootVolumePath {
            return nil
        }

        return FileSystemChange(path: logicalPath, flags: change.flags, eventID: change.eventID)
    }

    private func secondsSince(_ startedAt: ContinuousClock.Instant) -> Double {
        let duration = startedAt.duration(to: .now)
        return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1_000_000_000_000_000_000
    }
}
