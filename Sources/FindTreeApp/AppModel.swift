import Foundation
import AppKit
import Combine
import CoreServices
import FindTreeCore

private final class WeakAppModelBox: @unchecked Sendable {
    weak var value: AppModel?
    init(_ value: AppModel) { self.value = value }
}

@MainActor
final class AppModel: ObservableObject, @unchecked Sendable {
    @Published var rootPath: String
    @Published var currentDirectory: String
    @Published var snapshot: IndexedScanSnapshot?
    @Published var totalCapacityBytes: UInt64?
    @Published var isScanning = false
    @Published var isWatching = false
    @Published var statusMessage = ""
    @Published var lastError: String?

    private let scanner = FastScanner()
    private let indexStore: ScanIndexStore
    private let fileStore: FileIndexStore
    private let syncQueue = DispatchQueue(label: "findtree.app.incremental-sync", qos: .utility)
    private var watcher: FSEventWatcher?
    private var liveRefreshTask: Task<Void, Never>?
    private var childrenByParent: [String: [DirectoryUsage]] = [:]
    private var usageByPath: [String: DirectoryUsage] = [:]

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        self.rootPath = home
        self.currentDirectory = home
        self.totalCapacityBytes = nil

        let indexURL = Self.defaultIndexURL()
        self.indexStore = ScanIndexStore(databaseURL: indexURL)
        self.fileStore = FileIndexStore(databaseURL: indexURL)

        refreshVolumeCapacity()
        loadCachedSnapshot(startWatcher: false)
    }

    deinit {
        watcher?.stop()
        liveRefreshTask?.cancel()
    }

    var rootUsage: DirectoryUsage? {
        usageByPath[rootPath]
    }

    var currentUsage: DirectoryUsage? {
        usageByPath[currentDirectory]
    }

    var treemapRows: [DirectoryUsage] {
        Array(
            (childrenByParent[currentDirectory] ?? [])
                .filter { $0.allocatedBytes > 0 }
                .sorted {
                    if $0.allocatedBytes == $1.allocatedBytes {
                        return $0.path < $1.path
                    }
                    return $0.allocatedBytes > $1.allocatedBytes
                }
                .prefix(48)
        )
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
        stopWatching()
        let standardized = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
        rootPath = standardized
        currentDirectory = standardized
        refreshVolumeCapacity()
        snapshot = nil
        childrenByParent = [:]
        usageByPath = [:]
        lastError = nil
        statusMessage = ""
        loadCachedSnapshot(startWatcher: false)
    }

    func scan() {
        guard !isScanning else { return }
        let resumeWatchingAfterScan = isWatching
        stopWatching()
        isScanning = true
        lastError = nil
        statusMessage = "Scanning…"

        let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL
        let scanner = self.scanner
        let indexStore = self.indexStore
        let fileStore = self.fileStore
        let workerCount = min(8, max(2, ProcessInfo.processInfo.activeProcessorCount))
        let cursorBeforeScan = UInt64(FSEventsGetCurrentEventId())

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
                            progressEvery: 0,
                            onFileBatch: { try writer.consume($0) }
                        )
                        try writer.finish()
                        try indexStore.save(result)
                        try indexStore.saveLastEventID(cursorBeforeScan, rootPath: rootURL.path)
                        return try indexStore.load(rootPath: rootURL.path)
                    } catch {
                        writer.cancel()
                        throw error
                    }
                }.value

                if let updated {
                    apply(updated)
                    statusMessage = "Indexed \(updated.result.fileCount.formatted()) files"
                    if resumeWatchingAfterScan {
                        startWatching(catchUpFromStoredCursor: true)
                    }
                }
            } catch {
                lastError = String(describing: error)
                statusMessage = "Scan failed"
            }
            isScanning = false
        }
    }

    func navigate(to directory: DirectoryUsage) {
        currentDirectory = directory.path
    }

    func navigateUp() {
        guard canNavigateUp else { return }
        let parent = (currentDirectory as NSString).deletingLastPathComponent
        currentDirectory = PathUtilitiesForApp.clamp(parent, toRoot: rootPath)
    }

    func goToRoot() {
        currentDirectory = rootPath
    }

    func revealCurrentDirectory() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: currentDirectory)])
    }

    func openFullDiskAccessSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return }
        NSWorkspace.shared.open(url)
    }

    func toggleWatching() {
        if isWatching {
            stopWatching()
            statusMessage = "Live paused"
        } else {
            startWatching(catchUpFromStoredCursor: false)
        }
    }

    private func loadCachedSnapshot(startWatcher: Bool) {
        do {
            if let cached = try indexStore.load(rootPath: rootPath) {
                apply(cached)
                statusMessage = startWatcher ? "Loaded cached index" : "Loaded cached index · Live paused"
                if startWatcher { self.startWatching(catchUpFromStoredCursor: true) }
            } else {
                statusMessage = "No index yet — run Scan"
            }
        } catch {
            lastError = String(describing: error)
        }
    }

    private func apply(_ snapshot: IndexedScanSnapshot) {
        self.snapshot = snapshot
        var pathMap: [String: DirectoryUsage] = [:]
        pathMap.reserveCapacity(snapshot.result.directories.count)
        var childMap: [String: [DirectoryUsage]] = [:]

        for usage in snapshot.result.directories {
            pathMap[usage.path] = usage
            if usage.path != snapshot.result.rootPath {
                let parent = (usage.path as NSString).deletingLastPathComponent
                childMap[parent, default: []].append(usage)
            }
        }
        usageByPath = pathMap
        childrenByParent = childMap

        if currentDirectory != rootPath && usageByPath[currentDirectory] == nil {
            currentDirectory = rootPath
        }
    }

    private func startWatching(catchUpFromStoredCursor: Bool = false) {
        guard watcher == nil, snapshot != nil else { return }
        do {
            let cursor: UInt64
            if catchUpFromStoredCursor {
                guard let storedCursor = try indexStore.lastEventID(rootPath: rootPath) else {
                    statusMessage = "Run Scan once to enable live updates"
                    return
                }
                cursor = storedCursor
            } else {
                // Live is opt-in. Do not replay an arbitrarily large backlog accumulated while
                // monitoring was paused; Rescan is the explicit way to reconcile older changes.
                cursor = UInt64(FSEventsGetCurrentEventId())
                try indexStore.saveLastEventID(cursor, rootPath: rootPath)
            }

            let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
            let indexStore = self.indexStore
            let updater = IncrementalIndexUpdater(
                rootURL: rootURL,
                store: indexStore,
                scanner: scanner,
                scanOptions: ScanOptions(
                    stayOnRootVolume: true,
                    includeHiddenFiles: true,
                    workerCount: min(8, max(2, ProcessInfo.processInfo.activeProcessorCount))
                )
            )
            let root = rootPath
            let queue = syncQueue
            let modelBox = WeakAppModelBox(self)

            let watcher = FSEventWatcher(
                rootPath: root,
                sinceWhen: FSEventStreamEventId(cursor)
            ) { changes in
                queue.async {
                    do {
                        let sync = try updater.synchronize(changes: changes)
                        guard !sync.refreshedPaths.isEmpty || sync.fullRescan else { return }
                        Task { @MainActor in
                            guard let model = modelBox.value else { return }
                            let message = sync.fullRescan
                                ? "Live index rebuilt"
                                : "Updated \(sync.refreshedPaths.count) changed area(s)"
                            model.scheduleLiveRefresh(message: message)
                        }
                    } catch {
                        Task { @MainActor in
                            guard let model = modelBox.value else { return }
                            model.lastError = String(describing: error)
                            model.statusMessage = "Live update failed"
                        }
                    }
                }
            }
            try watcher.start()
            self.watcher = watcher
            isWatching = true
            statusMessage = "Live monitoring enabled"
        } catch {
            lastError = String(describing: error)
            isWatching = false
        }
    }

    private func stopWatching() {
        watcher?.stop()
        watcher = nil
        liveRefreshTask?.cancel()
        liveRefreshTask = nil
        isWatching = false
    }

    private func scheduleLiveRefresh(message: String) {
        liveRefreshTask?.cancel()
        let indexStore = self.indexStore
        let root = rootPath

        liveRefreshTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                let refreshed = try await Task.detached(priority: .utility) {
                    try indexStore.load(rootPath: root)
                }.value
                guard !Task.isCancelled, let refreshed, let self else { return }
                self.apply(refreshed)
                self.statusMessage = message
            } catch is CancellationError {
                return
            } catch {
                guard let self else { return }
                self.lastError = String(describing: error)
                self.statusMessage = "Live display refresh failed"
            }
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
