import Foundation
import AppKit
import Combine
import FindTreeCore

private final class WeakAppModelBox: @unchecked Sendable {
    weak var value: AppModel?
    init(_ value: AppModel) { self.value = value }
}

private struct PreparedSnapshot: Sendable {
    let snapshot: IndexedScanSnapshot
    let usageByPath: [String: DirectoryUsage]
    let childrenByParent: [String: [DirectoryUsage]]
    let treemapFilesByParent: [String: [FileUsage]]?
}

private func prepareSnapshot(_ snapshot: IndexedScanSnapshot) -> PreparedSnapshot {
    var pathMap: [String: DirectoryUsage] = [:]
    pathMap.reserveCapacity(snapshot.result.directories.count)
    var childMap: [String: [DirectoryUsage]] = [:]
    childMap.reserveCapacity(snapshot.result.directories.count / 2)

    for usage in snapshot.result.directories {
        pathMap[usage.path] = usage
        if usage.path != snapshot.result.rootPath {
            let parent = parentPath(of: usage.path)
            childMap[parent, default: []].append(usage)
        }
    }

    return PreparedSnapshot(
        snapshot: snapshot,
        usageByPath: pathMap,
        childrenByParent: childMap,
        treemapFilesByParent: nil
    )
}

private func prepareSnapshotForInitialTreemap(
    _ snapshot: IndexedScanSnapshot,
    fileStore: FileIndexStore,
    currentDirectory: String
) -> PreparedSnapshot {
    let prepared = prepareSnapshot(snapshot)
    guard fileStore.hasIndex(rootPath: snapshot.result.rootPath),
          let usage = prepared.usageByPath[currentDirectory],
          usage.allocatedBytes > 0
    else {
        return PreparedSnapshot(
            snapshot: prepared.snapshot,
            usageByPath: prepared.usageByPath,
            childrenByParent: prepared.childrenByParent,
            treemapFilesByParent: [:]
        )
    }

    let minimumVisibleBytes = max(usage.allocatedBytes / 100_000, 256 * 1_024)
    var candidates: [(path: String, bytes: UInt64)] = []
    collectTreemapFileCandidates(
        usage: usage,
        childrenByParent: prepared.childrenByParent,
        depth: 0,
        maxDepth: 6,
        minimumVisibleBytes: minimumVisibleBytes,
        into: &candidates
    )
    let parentPaths = candidates
        .sorted { $0.bytes > $1.bytes }
        .prefix(256)
        .map(\.path)

    guard !parentPaths.isEmpty else {
        return PreparedSnapshot(
            snapshot: prepared.snapshot,
            usageByPath: prepared.usageByPath,
            childrenByParent: prepared.childrenByParent,
            treemapFilesByParent: [:]
        )
    }

    do {
        let files = try fileStore.filesForParents(
            rootPath: snapshot.result.rootPath,
            parentPaths: parentPaths,
            limitPerParent: 64
        )
        return PreparedSnapshot(
            snapshot: prepared.snapshot,
            usageByPath: prepared.usageByPath,
            childrenByParent: prepared.childrenByParent,
            treemapFilesByParent: files
        )
    } catch {
        // Keep cached startup usable even if the optional file-detail index needs recovery.
        // The normal asynchronous refresh path will surface the error after the snapshot appears.
        return prepared
    }
}

private func collectTreemapFileCandidates(
    usage: DirectoryUsage,
    childrenByParent: [String: [DirectoryUsage]],
    depth: Int,
    maxDepth: Int,
    minimumVisibleBytes: UInt64,
    into result: inout [(path: String, bytes: UInt64)]
) {
    let allChildren = childrenByParent[usage.path] ?? []
    let childBytes = allChildren.reduce(UInt64(0)) { $0 &+ $1.allocatedBytes }
    let directBytes = usage.allocatedBytes > childBytes ? usage.allocatedBytes - childBytes : 0
    if directBytes > 0 {
        result.append((usage.path, directBytes))
    }

    guard depth < maxDepth else { return }

    let childLimit: Int
    switch depth {
    case 0:
        childLimit = 64
    case 1...3:
        childLimit = 192
    default:
        childLimit = 96
    }

    let children = allChildren
        .filter { child in
            child.allocatedBytes > 0
                && (depth < 2 || child.allocatedBytes >= minimumVisibleBytes)
        }
        .sorted { lhs, rhs in
            if lhs.allocatedBytes == rhs.allocatedBytes { return lhs.path < rhs.path }
            return lhs.allocatedBytes > rhs.allocatedBytes
        }
        .prefix(childLimit)

    for child in children {
        collectTreemapFileCandidates(
            usage: child,
            childrenByParent: childrenByParent,
            depth: depth + 1,
            maxDepth: maxDepth,
            minimumVisibleBytes: minimumVisibleBytes,
            into: &result
        )
    }
}

private func parentPath(of path: String) -> String {
    guard path != "/", let slash = path.lastIndex(of: "/") else { return "/" }
    if slash == path.startIndex { return "/" }
    return String(path[..<slash])
}

@MainActor
final class AppModel: ObservableObject, @unchecked Sendable {
    @Published var rootPath: String
    @Published var currentDirectory: String
    @Published var snapshot: IndexedScanSnapshot?
    @Published var totalCapacityBytes: UInt64?
    @Published var isScanning = false
    @Published var scanProgressPercent: Int?
    @Published var statusMessage = ""
    @Published var lastError: String?
    @Published private var treemapFilesByParent: [String: [FileUsage]] = [:]

    private let scanner = FastScanner()
    private let indexStore: ScanIndexStore
    private let fileStore: FileIndexStore
    private var cachedSnapshotTask: Task<Void, Never>?
    private var treemapFileTask: Task<Void, Never>?
    private var childrenByParent: [String: [DirectoryUsage]] = [:]
    private var usageByPath: [String: DirectoryUsage] = [:]

    private static let lastRootPathDefaultsKey = "findtree.lastRootPath"

    init() {
        let initialRoot = Self.restoredRootPath()
        self.rootPath = initialRoot
        self.currentDirectory = initialRoot
        self.totalCapacityBytes = nil

        let indexURL = Self.defaultIndexURL()
        self.indexStore = ScanIndexStore(databaseURL: indexURL)
        self.fileStore = FileIndexStore(databaseURL: indexURL)

        refreshVolumeCapacity()
        loadCachedSnapshot()
    }

    deinit {
        cachedSnapshotTask?.cancel()
        treemapFileTask?.cancel()
    }

    var rootUsage: DirectoryUsage? {
        usageByPath[rootPath]
    }

    var currentUsage: DirectoryUsage? {
        usageByPath[currentDirectory]
    }

    var treemapRoot: TreemapNode? {
        guard let usage = usageByPath[currentDirectory], usage.allocatedBytes > 0 else { return nil }
        let minimumVisibleBytes = max(usage.allocatedBytes / 100_000, 256 * 1_024)
        return buildTreemapNode(
            usage: usage,
            depth: 0,
            maxDepth: 6,
            minimumVisibleBytes: minimumVisibleBytes
        )
    }

    private func buildTreemapNode(
        usage: DirectoryUsage,
        depth: Int,
        maxDepth: Int,
        minimumVisibleBytes: UInt64
    ) -> TreemapNode {
        let allChildren = childrenByParent[usage.path] ?? []
        let childAllocatedBytes = allChildren.reduce(UInt64(0)) { partial, child in
            partial &+ child.allocatedBytes
        }
        let directAllocatedBytes = usage.allocatedBytes > childAllocatedBytes
            ? usage.allocatedBytes - childAllocatedBytes
            : 0

        guard depth < maxDepth else {
            return TreemapNode(
                usage: usage,
                children: [],
                files: treemapFilesByParent[usage.path] ?? [],
                directAllocatedBytes: directAllocatedBytes
            )
        }

        // Show many more siblings than before so package/cache directories with
        // hundreds of children are represented as individual rectangles instead of
        // one large blank/aggregate area. Recursion is still bounded by maxDepth.
        let childLimit: Int
        switch depth {
        case 0:
            childLimit = 64
        case 1...3:
            childLimit = 192
        default:
            childLimit = 96
        }

        let children = allChildren
            .filter { child in
                child.allocatedBytes > 0
                    && (depth < 2 || child.allocatedBytes >= minimumVisibleBytes)
            }
            .sorted { lhs, rhs in
                if lhs.allocatedBytes == rhs.allocatedBytes {
                    return lhs.path < rhs.path
                }
                return lhs.allocatedBytes > rhs.allocatedBytes
            }
            .prefix(childLimit)
            .map { child in
                buildTreemapNode(
                    usage: child,
                    depth: depth + 1,
                    maxDepth: maxDepth,
                    minimumVisibleBytes: minimumVisibleBytes
                )
            }

        return TreemapNode(
            usage: usage,
            children: Array(children),
            files: treemapFilesByParent[usage.path] ?? [],
            directAllocatedBytes: directAllocatedBytes
        )
    }

    private func refreshTreemapFiles() {
        treemapFileTask?.cancel()
        treemapFileTask = nil
        treemapFilesByParent = [:]

        guard snapshot != nil,
              fileStore.hasIndex(rootPath: rootPath),
              let usage = usageByPath[currentDirectory],
              usage.allocatedBytes > 0
        else { return }

        let minimumVisibleBytes = max(usage.allocatedBytes / 100_000, 256 * 1_024)
        let directoryRoot = buildTreemapNode(
            usage: usage,
            depth: 0,
            maxDepth: 6,
            minimumVisibleBytes: minimumVisibleBytes
        )

        var candidates: [(path: String, bytes: UInt64)] = []
        collectTreemapFileParents(from: directoryRoot, into: &candidates)
        let parentPaths = candidates
            .sorted { $0.bytes > $1.bytes }
            .prefix(256)
            .map(\.path)
        guard !parentPaths.isEmpty else { return }

        let root = rootPath
        let current = currentDirectory
        let fileStore = self.fileStore
        treemapFileTask = Task { [weak self] in
            do {
                let grouped = try await Task.detached(priority: .utility) {
                    try fileStore.filesForParents(
                        rootPath: root,
                        parentPaths: parentPaths,
                        limitPerParent: 64
                    )
                }.value
                guard !Task.isCancelled, let self,
                      self.rootPath == root, self.currentDirectory == current
                else { return }
                self.treemapFilesByParent = grouped
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, let self,
                      self.rootPath == root, self.currentDirectory == current
                else { return }
                self.lastError = String(describing: error)
            }
        }
    }

    private func collectTreemapFileParents(
        from node: TreemapNode,
        into result: inout [(path: String, bytes: UInt64)]
    ) {
        if node.directAllocatedBytes > 0 {
            result.append((node.usage.path, node.directAllocatedBytes))
        }
        for child in node.children {
            collectTreemapFileParents(from: child, into: &result)
        }
    }

    var canNavigateUp: Bool {
        currentDirectory != rootPath && currentDirectory.hasPrefix(rootPath)
    }

    func chooseRootFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a folder to analyze"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = URL(fileURLWithPath: rootPath, isDirectory: true)

        guard panel.runModal() == .OK, let url = panel.url else { return }
        setRoot(url.standardizedFileURL.path)
    }

    func setRoot(_ path: String) {
        cachedSnapshotTask?.cancel()
        cachedSnapshotTask = nil
        let standardized = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
        rootPath = standardized
        currentDirectory = standardized
        UserDefaults.standard.set(standardized, forKey: Self.lastRootPathDefaultsKey)
        refreshVolumeCapacity()
        snapshot = nil
        childrenByParent = [:]
        usageByPath = [:]
        lastError = nil
        scanProgressPercent = nil
        treemapFileTask?.cancel()
        treemapFileTask = nil
        treemapFilesByParent = [:]
        statusMessage = ""
        loadCachedSnapshot()
    }

    func scan() {
        guard !isScanning else { return }
        cachedSnapshotTask?.cancel()
        cachedSnapshotTask = nil
        isScanning = true
        scanProgressPercent = 0
        lastError = nil
        statusMessage = "Scanning…"

        let expectedEntries = snapshot.map { $0.result.fileCount + $0.result.directoryCount } ?? 0
        let modelBox = WeakAppModelBox(self)
        let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL
        let scanner = self.scanner
        let indexStore = self.indexStore
        let fileStore = self.fileStore
        let workerCount = min(8, max(2, ProcessInfo.processInfo.activeProcessorCount))

        Task {
            do {
                let updated = try await Task.detached(priority: .userInitiated) {
                    let writer = try fileStore.makeFullWriter(rootPath: rootURL.path)
                    do {
                        let result = try scanner.scan(
                            rootURL: rootURL,
                            options: ScanOptions(
                                stayOnRootVolume: true,
                                includeHiddenFiles: true,
                                workerCount: workerCount
                            ),
                            progressEvery: 5_000,
                            onProgress: { progress in
                                Task { @MainActor in
                                    modelBox.value?.updateScanProgress(progress, expectedEntries: expectedEntries)
                                }
                            },
                            onFileBatch: { try writer.consume($0) }
                        )
                        try writer.finish()
                        try indexStore.save(result)
                        return try indexStore.load(rootPath: rootURL.path).map(prepareSnapshot)
                    } catch {
                        writer.cancel()
                        throw error
                    }
                }.value

                if let updated {
                    apply(updated)
                    statusMessage = "Indexed \(updated.snapshot.result.fileCount.formatted()) files"
                }
            } catch {
                lastError = String(describing: error)
                statusMessage = "Scan failed"
            }
            isScanning = false
            scanProgressPercent = nil
        }
    }

    private func updateScanProgress(_ progress: ScanProgress, expectedEntries: Int) {
        let isComplete = progress.discoveredDirectories > 0
            && progress.processedDirectories >= progress.discoveredDirectories

        let calculated: Int
        if isComplete {
            calculated = 100
        } else if expectedEntries > 0 {
            let processedEntries = progress.files + progress.processedDirectories
            calculated = Int((Double(processedEntries) / Double(expectedEntries)) * 100.0)
        } else if progress.discoveredDirectories > 0 {
            calculated = Int(
                (Double(progress.processedDirectories) / Double(progress.discoveredDirectories)) * 100.0
            )
        } else {
            calculated = 0
        }

        let bounded = min(max(calculated, 0), isComplete ? 100 : 99)
        scanProgressPercent = max(scanProgressPercent ?? 0, bounded)
    }

    func navigate(to directory: DirectoryUsage) {
        currentDirectory = directory.path
        refreshTreemapFiles()
    }

    func navigateUp() {
        guard canNavigateUp else { return }
        let parent = (currentDirectory as NSString).deletingLastPathComponent
        currentDirectory = PathUtilitiesForApp.clamp(parent, toRoot: rootPath)
        refreshTreemapFiles()
    }

    func goToRoot() {
        currentDirectory = rootPath
        refreshTreemapFiles()
    }

    func revealCurrentDirectory() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: currentDirectory)])
    }

    func revealFile(_ file: FileUsage) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)])
    }

    func moveToTrash(_ url: URL) {
        guard snapshot != nil, !isScanning else { return }

        let itemURL = url.standardizedFileURL
        let itemPath = itemURL.path
        let root = rootPath
        let rootPrefix = root == "/" ? "/" : root + "/"
        guard itemPath != root, itemPath.hasPrefix(rootPrefix) else {
            lastError = "The scan root cannot be moved to Trash."
            return
        }

        var isDirectoryValue: ObjCBool = false
        guard FileManager.default.fileExists(atPath: itemPath, isDirectory: &isDirectoryValue) else {
            lastError = "The item no longer exists: \(itemPath)"
            return
        }

        let isDirectory = isDirectoryValue.boolValue
        let itemName = itemURL.lastPathComponent
        let indexStore = self.indexStore
        let fileStore = self.fileStore
        let scanner = self.scanner
        let workerCount = min(8, max(2, ProcessInfo.processInfo.activeProcessorCount))
        statusMessage = "Moving \(itemName) to Trash…"
        lastError = nil

        Task { [weak self] in
            do {
                let refreshed = try await Task.detached(priority: .userInitiated) { () -> PreparedSnapshot? in
                    try FileManager.default.trashItem(at: itemURL, resultingItemURL: nil)

                    if isDirectory {
                        if fileStore.hasIndex(rootPath: root) {
                            let writer = try fileStore.makeSubtreeWriter(
                                rootPath: root,
                                subtreePath: itemPath
                            )
                            do {
                                try writer.finish()
                            } catch {
                                writer.cancel()
                                throw error
                            }
                        }
                        try indexStore.replaceSubtree(
                            rootPath: root,
                            subtreePath: itemPath,
                            with: nil
                        )
                    } else if fileStore.hasIndex(rootPath: root) {
                        let deltas = try fileStore.applyFileChanges(
                            rootPath: root,
                            filePaths: [itemPath]
                        )
                        try indexStore.applyFileDeltas(rootPath: root, deltas: deltas)
                    } else {
                        let parentPath = (itemPath as NSString).deletingLastPathComponent
                        let parentURL = URL(fileURLWithPath: parentPath, isDirectory: true)
                        let subtree = try scanner.scan(
                            rootURL: parentURL,
                            options: ScanOptions(
                                stayOnRootVolume: true,
                                includeHiddenFiles: true,
                                workerCount: workerCount
                            )
                        )
                        try indexStore.replaceSubtree(
                            rootPath: root,
                            subtreePath: parentPath,
                            with: subtree
                        )
                    }

                    return try indexStore.load(rootPath: root).map(prepareSnapshot)
                }.value

                guard let self, self.rootPath == root else { return }
                if let refreshed {
                    self.apply(refreshed)
                }
                self.statusMessage = "Moved \(itemName) to Trash"
            } catch {
                guard let self else { return }
                self.lastError = String(describing: error)
                self.statusMessage = "Move to Trash failed"
            }
        }
    }

    func openFullDiskAccessSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return }
        NSWorkspace.shared.open(url)
    }

    private func loadCachedSnapshot() {
        let root = rootPath
        let indexStore = self.indexStore
        let fileStore = self.fileStore
        statusMessage = "Loading cached index…"

        cachedSnapshotTask?.cancel()
        cachedSnapshotTask = Task { [weak self] in
            do {
                let prepared = try await Task.detached(priority: .userInitiated) { () -> PreparedSnapshot? in
                    try indexStore.load(rootPath: root).map { snapshot in
                        prepareSnapshotForInitialTreemap(
                            snapshot,
                            fileStore: fileStore,
                            currentDirectory: root
                        )
                    }
                }.value

                guard !Task.isCancelled, let self, self.rootPath == root else { return }
                if let prepared {
                    self.apply(prepared)
                    self.statusMessage = "Loaded cached index"
                } else {
                    self.statusMessage = "No index yet — run Scan"
                }
            } catch {
                guard let self, self.rootPath == root else { return }
                self.lastError = String(describing: error)
            }
        }
    }

    private func apply(_ prepared: PreparedSnapshot) {
        usageByPath = prepared.usageByPath
        childrenByParent = prepared.childrenByParent

        if let preloadedFiles = prepared.treemapFilesByParent {
            treemapFileTask?.cancel()
            treemapFileTask = nil
            treemapFilesByParent = preloadedFiles
        }

        snapshot = prepared.snapshot
        if currentDirectory != rootPath && usageByPath[currentDirectory] == nil {
            currentDirectory = rootPath
        }

        if prepared.treemapFilesByParent == nil {
            refreshTreemapFiles()
        }
    }

    private func refreshVolumeCapacity() {
        do {
            let attributes = try FileManager.default.attributesOfFileSystem(forPath: rootPath)
            if let size = attributes[.systemSize] as? NSNumber {
                totalCapacityBytes = size.uint64Value
            } else {
                totalCapacityBytes = nil
            }
        } catch {
            totalCapacityBytes = nil
        }
    }

    private static func restoredRootPath() -> String {
        guard let savedPath = UserDefaults.standard.string(forKey: lastRootPathDefaultsKey) else {
            return "/"
        }

        let standardized = URL(fileURLWithPath: savedPath, isDirectory: true).standardizedFileURL.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standardized, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            UserDefaults.standard.removeObject(forKey: lastRootPathDefaultsKey)
            return "/"
        }
        return standardized
    }

    private static func defaultIndexURL() -> URL {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupport
            .appendingPathComponent("findtree", isDirectory: true)
            .appendingPathComponent("index.sqlite")
    }
}

private enum PathUtilitiesForApp {
    static func clamp(_ path: String, toRoot root: String) -> String {
        if path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/") {
            return path
        }
        return root
    }
}

private extension String {
    var lastPathComponent: String {
        (self as NSString).lastPathComponent
    }
}
