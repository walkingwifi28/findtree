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
        let storedCursor = try store.lastEventID(rootPath: rootURL.path)
        let pendingChanges: [FileSystemChange]
        if let storedCursor {
            pendingChanges = changes.filter { UInt64($0.eventID) > storedCursor }
        } else {
            pendingChanges = changes
        }

        guard !pendingChanges.isEmpty else {
            return IncrementalSyncResult(
                fullRescan: false,
                refreshedPaths: [],
                elapsedSeconds: secondsSince(startedAt),
                lastEventID: storedCursor
            )
        }

        let batchMaxEventID = pendingChanges.map { UInt64($0.eventID) }.max()
        let relevant = pendingChanges.compactMap(logicalChange)

        if relevant.isEmpty {
            if let batchMaxEventID {
                try store.saveLastEventID(batchMaxEventID, rootPath: rootURL.path)
            }
            return IncrementalSyncResult(
                fullRescan: false,
                refreshedPaths: [],
                elapsedSeconds: secondsSince(startedAt),
                lastEventID: batchMaxEventID
            )
        }

        if relevant.contains(where: { FSEventWatcher.eventRequiresFullRescan($0.flags) }) {
            let writer = try fileStore.makeFullWriter(rootPath: rootURL.path)
            do {
                let result = try scanner.scan(
                    rootURL: rootURL,
                    options: scanOptions,
                    progressEvery: 0,
                    onFileBatch: { try writer.consume($0) }
                )
                try writer.finish()
                try store.save(result)

                // The event history that triggered this rebuild is not trustworthy. The rebuilt
                // snapshot is now our new baseline, so do not replay queued pre-rebuild batches.
                let newCursor = UInt64(FSEventsGetCurrentEventId())
                try store.saveLastEventID(newCursor, rootPath: rootURL.path)
                return IncrementalSyncResult(
                    fullRescan: true,
                    refreshedPaths: [rootURL.path],
                    elapsedSeconds: secondsSince(startedAt),
                    lastEventID: newCursor
                )
            } catch {
                writer.cancel()
                throw error
            }
        }

        var paths = Self.coalescedRefreshPaths(for: relevant, rootPath: rootURL.path)
        let canApplyFilesDirectly = fileStore.hasIndex(rootPath: rootURL.path)
        if !canApplyFilesDirectly {
            let fileParents = Self.directFilePaths(for: relevant, rootPath: rootURL.path).map {
                ($0 as NSString).deletingLastPathComponent
            }
            paths = Self.coalescedCandidatePaths(paths + fileParents, rootPath: rootURL.path)
        }

        for path in paths {
            let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)

            let writer = try fileStore.makeSubtreeWriter(rootPath: rootURL.path, subtreePath: url.path)
            do {
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
            } catch {
                writer.cancel()
                throw error
            }
        }

        var refreshedPaths = paths
        if canApplyFilesDirectly {
            let directFiles = Self.directFilePaths(for: relevant, rootPath: rootURL.path).filter { filePath in
                !paths.contains { subtree in
                    PathUtilities.isDescendantOrEqual(filePath, of: subtree)
                }
            }
            if !directFiles.isEmpty {
                let deltas = try fileStore.applyFileChanges(rootPath: rootURL.path, filePaths: directFiles)
                try store.applyFileDeltas(rootPath: rootURL.path, deltas: deltas)
                refreshedPaths.append(contentsOf: deltas.map(\.parentPath))
                refreshedPaths = Self.coalescedCandidatePaths(refreshedPaths, rootPath: rootURL.path)
            }
        }

        if let batchMaxEventID {
            try store.saveLastEventID(batchMaxEventID, rootPath: rootURL.path)
        }

        return IncrementalSyncResult(
            fullRescan: false,
            refreshedPaths: refreshedPaths,
            elapsedSeconds: secondsSince(startedAt),
            lastEventID: batchMaxEventID
        )
    }

    /// Converts file-level FSEvents into the smallest non-overlapping directory set to rescan.
    /// Pure directory metadata/modified notifications are intentionally ignored because item-level
    /// events already identify the changed child. Treating those broad parent notifications as a
    /// subtree refresh can turn a tiny cache write into a rescan of ~/Library or the entire root.
    public static func coalescedRefreshPaths(for changes: [FileSystemChange], rootPath: String) -> [String] {
        let root = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL.path
        let isDirFlag = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir)
        let mustScanFlag = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)
        let createdFlag = FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)
        let removedFlag = FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved)
        let renamedFlag = FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed)
        let structuralDirFlags = createdFlag | removedFlag | renamedFlag

        var candidates = Set<String>()
        for change in changes {
            let path = URL(fileURLWithPath: change.path).standardizedFileURL.path
            guard path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/") else { continue }

            let candidate: String
            if change.flags & mustScanFlag != 0 {
                candidate = path
            } else if change.flags & isDirFlag != 0 {
                guard change.flags & structuralDirFlags != 0 else {
                    continue
                }
                candidate = path
            } else {
                // Regular files are updated directly from their metadata and existing SQLite row.
                // This avoids rescanning a large parent directory for a one-file change.
                continue
            }

            if candidate == root || candidate.hasPrefix(root.hasSuffix("/") ? root : root + "/") {
                candidates.insert(candidate)
            }
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

    private static func directFilePaths(for changes: [FileSystemChange], rootPath: String) -> [String] {
        let root = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL.path
        let isFileFlag = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile)
        var result = Set<String>()
        for change in changes where change.flags & isFileFlag != 0 {
            let path = URL(fileURLWithPath: change.path).standardizedFileURL.path
            guard PathUtilities.isDescendantOrEqual(path, of: root), path != root else { continue }
            result.insert(path)
        }
        return Array(result)
    }

    private static func coalescedCandidatePaths(_ candidates: [String], rootPath: String) -> [String] {
        let root = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL.path
        let sorted = Set(candidates.compactMap { candidate -> String? in
            let path = URL(fileURLWithPath: candidate, isDirectory: true).standardizedFileURL.path
            return PathUtilities.isDescendantOrEqual(path, of: root) ? path : nil
        }).sorted {
            let lhsDepth = $0.split(separator: "/").count
            let rhsDepth = $1.split(separator: "/").count
            if lhsDepth == rhsDepth { return $0 < $1 }
            return lhsDepth < rhsDepth
        }

        var result: [String] = []
        for candidate in sorted {
            let covered = result.contains { ancestor in
                PathUtilities.isDescendantOrEqual(candidate, of: ancestor)
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
