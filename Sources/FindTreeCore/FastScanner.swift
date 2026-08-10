import Foundation

public struct ScanOptions: Sendable {
    public var stayOnRootVolume: Bool
    public var includeHiddenFiles: Bool
    public var workerCount: Int

    public init(
        stayOnRootVolume: Bool = true,
        includeHiddenFiles: Bool = true,
        workerCount: Int = min(8, max(2, ProcessInfo.processInfo.activeProcessorCount))
    ) {
        self.stayOnRootVolume = stayOnRootVolume
        self.includeHiddenFiles = includeHiddenFiles
        self.workerCount = max(workerCount, 1)
    }
}

public struct ScanProgress: Sendable {
    public let files: Int
    public let directories: Int
    public let logicalBytes: UInt64
    public let allocatedBytes: UInt64

    public init(files: Int, directories: Int, logicalBytes: UInt64, allocatedBytes: UInt64) {
        self.files = files
        self.directories = directories
        self.logicalBytes = logicalBytes
        self.allocatedBytes = allocatedBytes
    }
}


public struct FileUsage: Sendable, Equatable {
    public let path: String
    public let parentPath: String
    public let name: String
    public let logicalBytes: UInt64
    public let allocatedBytes: UInt64

    public init(path: String, parentPath: String, name: String, logicalBytes: UInt64, allocatedBytes: UInt64) {
        self.path = path
        self.parentPath = parentPath
        self.name = name
        self.logicalBytes = logicalBytes
        self.allocatedBytes = allocatedBytes
    }
}

public struct DirectoryUsage: Sendable {
    public let path: String
    public let logicalBytes: UInt64
    public let allocatedBytes: UInt64
    public let fileCount: Int
    public let directoryCount: Int
}

public struct ScanResult: Sendable {
    public let rootPath: String
    public let elapsedSeconds: Double
    public let fileCount: Int
    public let directoryCount: Int
    public let inaccessibleDirectoryCount: Int
    public let logicalBytes: UInt64
    public let allocatedBytes: UInt64
    public let directories: [DirectoryUsage]

    public func largestDirectories(limit: Int) -> [DirectoryUsage] {
        guard limit > 0 else { return [] }
        return directories
            .sorted {
                if $0.allocatedBytes == $1.allocatedBytes {
                    return $0.logicalBytes > $1.logicalBytes
                }
                return $0.allocatedBytes > $1.allocatedBytes
            }
            .prefix(limit)
            .map { $0 }
    }
}

private struct MutableDirectory {
    var parentIndex: Int?
    var name: String
    var logicalBytes: UInt64 = 0
    var allocatedBytes: UInt64 = 0
    var fileCount: Int = 0
    var directoryCount: Int = 0
}

private struct PendingDirectory: Sendable {
    let url: URL
    let logicalPath: String
    let nodeIndex: Int
}

private struct ChildDirectory: Sendable {
    let url: URL
    let name: String
}

private struct DirectoryScan: Sendable {
    let pending: PendingDirectory
    let childDirectories: [ChildDirectory]
    let fileCount: Int
    let files: [FileUsage]
    let logicalBytes: UInt64
    let allocatedBytes: UInt64
    let seenEntries: Int
    let inaccessible: Bool
}

private final class BatchCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [DirectoryScan] = []

    func append(contentsOf scans: [DirectoryScan]) {
        lock.lock()
        storage.append(contentsOf: scans)
        lock.unlock()
    }

    func take() -> [DirectoryScan] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

public final class FastScanner: @unchecked Sendable {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func scan(
        rootURL: URL,
        options: ScanOptions = ScanOptions(),
        progressEvery: Int = 100_000,
        onProgress: (@Sendable (ScanProgress) -> Void)? = nil,
        onFileBatch: (@Sendable ([FileUsage]) throws -> Void)? = nil
    ) throws -> ScanResult {
        let startedAt = ContinuousClock.now
        let root = rootURL.standardizedFileURL
        let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .volumeIdentifierKey, .volumeURLKey])

        guard rootValues.isDirectory == true else {
            throw ScannerError.notDirectory(root.path)
        }

        let rootVolumeIdentifier = rootValues.volumeIdentifier.map { String(describing: $0) }
        let rootVolumePath = rootValues.volume?.standardizedFileURL.path
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .fileAllocatedSizeKey,
            .volumeIdentifierKey,
            .volumeURLKey
        ]

        let contentOptions: FileManager.DirectoryEnumerationOptions = options.includeHiddenFiles ? [] : [.skipsHiddenFiles]

        var nodes: [MutableDirectory] = [
            MutableDirectory(parentIndex: nil, name: root.lastPathComponent.isEmpty ? root.path : root.lastPathComponent)
        ]
        var pending: [PendingDirectory] = [PendingDirectory(url: root, logicalPath: root.path, nodeIndex: 0)]
        var pendingIndex = 0
        var inaccessibleDirectoryCount = 0
        var seenEntries = 0
        var nextProgressAt = max(progressEvery, 1)
        var globalFileCount = 0
        var globalLogicalBytes: UInt64 = 0
        var globalAllocatedBytes: UInt64 = 0

        let operationQueue = OperationQueue()
        operationQueue.maxConcurrentOperationCount = options.workerCount
        operationQueue.qualityOfService = .userInitiated

        // A larger batch keeps worker overhead low while still allowing newly found
        // directories to enter the queue quickly.
        let batchSize = max(options.workerCount * 64, 256)

        while pendingIndex < pending.count {
            let batchEnd = min(pendingIndex + batchSize, pending.count)
            let batch = Array(pending[pendingIndex..<batchEnd])
            pendingIndex = batchEnd

            let workerCount = min(options.workerCount, batch.count)
            let collector = BatchCollector()

            for worker in 0..<workerCount {
                operationQueue.addOperation { [self] in
                    var local: [DirectoryScan] = []
                    local.reserveCapacity((batch.count + workerCount - 1) / workerCount)

                    var itemIndex = worker
                    while itemIndex < batch.count {
                        let item = batch[itemIndex]
                        local.append(
                            scanDirectory(
                                item,
                                keys: keys,
                                contentOptions: contentOptions,
                                stayOnRootVolume: options.stayOnRootVolume,
                                rootVolumeIdentifier: rootVolumeIdentifier,
                                rootVolumePath: rootVolumePath,
                                collectFiles: onFileBatch != nil
                            )
                        )
                        itemIndex += workerCount
                    }
                    collector.append(contentsOf: local)
                }
            }

            operationQueue.waitUntilAllOperationsAreFinished()

            for directoryScan in collector.take() {
                seenEntries += directoryScan.seenEntries

                if directoryScan.inaccessible {
                    inaccessibleDirectoryCount += 1
                    continue
                }

                let nodeIndex = directoryScan.pending.nodeIndex
                nodes[nodeIndex].logicalBytes &+= directoryScan.logicalBytes
                nodes[nodeIndex].allocatedBytes &+= directoryScan.allocatedBytes
                nodes[nodeIndex].fileCount += directoryScan.fileCount
                nodes[nodeIndex].directoryCount += directoryScan.childDirectories.count

                if !directoryScan.files.isEmpty {
                    try onFileBatch?(directoryScan.files)
                }

                globalFileCount += directoryScan.fileCount
                globalLogicalBytes &+= directoryScan.logicalBytes
                globalAllocatedBytes &+= directoryScan.allocatedBytes

                for child in directoryScan.childDirectories {
                    let childIndex = nodes.count
                    nodes.append(MutableDirectory(parentIndex: nodeIndex, name: child.name))
                    let childLogicalPath = (directoryScan.pending.logicalPath as NSString).appendingPathComponent(child.name)
                    pending.append(PendingDirectory(url: child.url, logicalPath: childLogicalPath, nodeIndex: childIndex))
                }

                if progressEvery > 0, seenEntries >= nextProgressAt {
                    onProgress?(
                        ScanProgress(
                            files: globalFileCount,
                            directories: max(nodes.count - 1, 0),
                            logicalBytes: globalLogicalBytes,
                            allocatedBytes: globalAllocatedBytes
                        )
                    )
                    while nextProgressAt <= seenEntries {
                        nextProgressAt += progressEvery
                    }
                }
            }
        }

        if nodes.count > 1 {
            for index in stride(from: nodes.count - 1, through: 1, by: -1) {
                guard let parent = nodes[index].parentIndex else { continue }
                nodes[parent].logicalBytes &+= nodes[index].logicalBytes
                nodes[parent].allocatedBytes &+= nodes[index].allocatedBytes
                nodes[parent].fileCount += nodes[index].fileCount
                nodes[parent].directoryCount += nodes[index].directoryCount
            }
        }

        let paths = buildPaths(nodes: nodes, rootPath: root.path)
        let usages = nodes.indices.map { index in
            DirectoryUsage(
                path: paths[index],
                logicalBytes: nodes[index].logicalBytes,
                allocatedBytes: nodes[index].allocatedBytes,
                fileCount: nodes[index].fileCount,
                directoryCount: nodes[index].directoryCount
            )
        }

        let elapsed = startedAt.duration(to: .now)
        let elapsedSeconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000_000

        return ScanResult(
            rootPath: root.path,
            elapsedSeconds: elapsedSeconds,
            fileCount: nodes[0].fileCount,
            directoryCount: max(nodes.count - 1, 0),
            inaccessibleDirectoryCount: inaccessibleDirectoryCount,
            logicalBytes: nodes[0].logicalBytes,
            allocatedBytes: nodes[0].allocatedBytes,
            directories: usages
        )
    }

    private func scanDirectory(
        _ pending: PendingDirectory,
        keys: Set<URLResourceKey>,
        contentOptions: FileManager.DirectoryEnumerationOptions,
        stayOnRootVolume: Bool,
        rootVolumeIdentifier: String?,
        rootVolumePath: String?,
        collectFiles: Bool
    ) -> DirectoryScan {
        let children: [URL]
        do {
            children = try fileManager.contentsOfDirectory(
                at: pending.url,
                includingPropertiesForKeys: Array(keys),
                options: contentOptions
            )
        } catch {
            return DirectoryScan(
                pending: pending,
                childDirectories: [],
                fileCount: 0,
                files: [],
                logicalBytes: 0,
                allocatedBytes: 0,
                seenEntries: 0,
                inaccessible: true
            )
        }

        var childDirectories: [ChildDirectory] = []
        childDirectories.reserveCapacity(min(children.count, 32))
        var fileCount = 0
        var files: [FileUsage] = []
        if collectFiles { files.reserveCapacity(max(children.count - childDirectories.count, 0)) }
        var logicalBytes: UInt64 = 0
        var allocatedBytes: UInt64 = 0

        for child in children {
            // macOS exposes /.nofollow as an internal mirror of the unified root when
            // enumerated through Foundation. Traversing it would count the whole disk twice.
            if pending.logicalPath == "/" && child.lastPathComponent == ".nofollow" {
                continue
            }

            let values: URLResourceValues
            do {
                values = try child.resourceValues(forKeys: keys)
            } catch {
                continue
            }

            if values.isSymbolicLink == true {
                continue
            }

            if stayOnRootVolume {
                if let rootVolumePath, let childVolumePath = values.volume?.standardizedFileURL.path {
                    if childVolumePath != rootVolumePath { continue }
                } else if let rootVolumeIdentifier,
                          let childVolumeIdentifier = values.volumeIdentifier.map({ String(describing: $0) }),
                          childVolumeIdentifier != rootVolumeIdentifier {
                    continue
                }
            }

            if values.isDirectory == true {
                childDirectories.append(ChildDirectory(url: child, name: child.lastPathComponent))
            } else if values.isRegularFile == true {
                let logical = UInt64(max(values.fileSize ?? 0, 0))
                let allocated = UInt64(max(values.fileAllocatedSize ?? values.fileSize ?? 0, 0))
                logicalBytes &+= logical
                allocatedBytes &+= allocated
                fileCount += 1
                if collectFiles {
                    files.append(
                        FileUsage(
                            path: (pending.logicalPath as NSString).appendingPathComponent(child.lastPathComponent),
                            parentPath: pending.logicalPath,
                            name: child.lastPathComponent,
                            logicalBytes: logical,
                            allocatedBytes: allocated
                        )
                    )
                }
            }
        }

        return DirectoryScan(
            pending: pending,
            childDirectories: childDirectories,
            fileCount: fileCount,
            files: files,
            logicalBytes: logicalBytes,
            allocatedBytes: allocatedBytes,
            seenEntries: children.count,
            inaccessible: false
        )
    }

    private func buildPaths(nodes: [MutableDirectory], rootPath: String) -> [String] {
        var paths = Array(repeating: "", count: nodes.count)
        guard !nodes.isEmpty else { return paths }
        paths[0] = rootPath

        if nodes.count > 1 {
            for index in 1..<nodes.count {
                guard let parent = nodes[index].parentIndex else {
                    paths[index] = nodes[index].name
                    continue
                }
                paths[index] = (paths[parent] as NSString).appendingPathComponent(nodes[index].name)
            }
        }
        return paths
    }
}

public enum ScannerError: Error, CustomStringConvertible {
    case notDirectory(String)

    public var description: String {
        switch self {
        case .notDirectory(let path):
            return "Not a directory: \(path)"
        }
    }
}
