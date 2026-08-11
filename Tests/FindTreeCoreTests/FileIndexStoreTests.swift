import Foundation
import CoreServices
import Testing
@testable import FindTreeCore

@Test func buildsAndSearchesFileIndex() throws {
    let tempRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("findtree-file-index-\(UUID().uuidString)", isDirectory: true)
    let scanRoot = tempRoot.appendingPathComponent("scan", isDirectory: true)
    let nested = scanRoot.appendingPathComponent("nested", isDirectory: true)
    let dbURL = tempRoot.appendingPathComponent("index.sqlite")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    try Data(repeating: 1, count: 1_024).write(to: scanRoot.appendingPathComponent("small.txt"))
    try Data(repeating: 2, count: 32_768).write(to: nested.appendingPathComponent("movie.mov"))

    let fileStore = FileIndexStore(databaseURL: dbURL)
    let writer = try fileStore.makeFullWriter(rootPath: scanRoot.path)
    let scanner = FastScanner()
    _ = try scanner.scan(
        rootURL: scanRoot,
        progressEvery: 0,
        onFileBatch: { try writer.consume($0) }
    )
    try writer.finish()

    let mov = try fileStore.search(rootPath: scanRoot.path, query: ".mov", limit: 10)
    #expect(mov.count == 1)
    #expect(mov.first?.name == "movie.mov")

    let largest = try fileStore.search(rootPath: scanRoot.path, limit: 10)
    #expect(largest.count == 2)
    #expect(largest.first?.name == "movie.mov")
}


@Test func loadsDirectFilesForTreemapParents() throws {
    let tempRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("findtree-treemap-files-\(UUID().uuidString)", isDirectory: true)
    let dbURL = tempRoot.appendingPathComponent("index.sqlite")
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let root = "/example/treemap-root"
    let nested = root + "/nested"
    let store = FileIndexStore(databaseURL: dbURL)
    let writer = try store.makeFullWriter(rootPath: root)
    try writer.consume([
        FileUsage(path: root + "/root-small.dat", parentPath: root, name: "root-small.dat", logicalBytes: 1, allocatedBytes: 4_096),
        FileUsage(path: root + "/root-large.dat", parentPath: root, name: "root-large.dat", logicalBytes: 2, allocatedBytes: 16_384),
        FileUsage(path: nested + "/nested.dat", parentPath: nested, name: "nested.dat", logicalBytes: 3, allocatedBytes: 8_192)
    ])
    try writer.finish()

    let grouped = try store.filesForParents(
        rootPath: root,
        parentPaths: [root, nested],
        limitPerParent: 8
    )

    #expect(grouped[root]?.map(\.name) == ["root-large.dat", "root-small.dat"])
    #expect(grouped[nested]?.map(\.name) == ["nested.dat"])
}

@Test func incrementalUpdaterKeepsFileIndexInSync() throws {
    let tempRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("findtree-file-sync-\(UUID().uuidString)", isDirectory: true)
    let scanRoot = tempRoot.appendingPathComponent("scan", isDirectory: true)
    let nested = scanRoot.appendingPathComponent("nested", isDirectory: true)
    let dbURL = tempRoot.appendingPathComponent("index.sqlite")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let firstFile = nested.appendingPathComponent("first.dat")
    try Data(repeating: 1, count: 1_024).write(to: firstFile)

    let scanner = FastScanner()
    let scanStore = ScanIndexStore(databaseURL: dbURL)
    let fileStore = FileIndexStore(databaseURL: dbURL)
    let writer = try fileStore.makeFullWriter(rootPath: scanRoot.path)
    let initial = try scanner.scan(
        rootURL: scanRoot,
        progressEvery: 0,
        onFileBatch: { try writer.consume($0) }
    )
    try writer.finish()
    try scanStore.save(initial)

    try FileManager.default.removeItem(at: firstFile)
    let secondFile = nested.appendingPathComponent("second.dat")
    try Data(repeating: 2, count: 4_096).write(to: secondFile)

    let modifiedFlags = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemModified)
    let removedFlags = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemRemoved)
    let updater = IncrementalIndexUpdater(rootURL: scanRoot, store: scanStore)
    _ = try updater.synchronize(changes: [
        FileSystemChange(path: firstFile.path, flags: removedFlags, eventID: 122),
        FileSystemChange(path: secondFile.path, flags: modifiedFlags, eventID: 123)
    ])

    #expect(try fileStore.search(rootPath: scanRoot.path, query: "first.dat", limit: 10).isEmpty)
    let second = try fileStore.search(rootPath: scanRoot.path, query: "second.dat", limit: 10)
    #expect(second.count == 1)
    #expect(second.first?.logicalBytes == 4_096)

    let cached = try #require(scanStore.load(rootPath: scanRoot.path)?.result)
    let fresh = try scanner.scan(rootURL: scanRoot, progressEvery: 0)
    #expect(cached.fileCount == fresh.fileCount)
    #expect(cached.directoryCount == fresh.directoryCount)
    #expect(cached.logicalBytes == fresh.logicalBytes)
    #expect(cached.allocatedBytes == fresh.allocatedBytes)
}


@Test func subtreeFileWriterRemovesStaleFiles() throws {
    let tempRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("findtree-file-writer-\(UUID().uuidString)", isDirectory: true)
    let dbURL = tempRoot.appendingPathComponent("index.sqlite")
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let root = "/example/root"
    let nested = "/example/root/nested"
    let store = FileIndexStore(databaseURL: dbURL)
    let full = try store.makeFullWriter(rootPath: root)
    try full.consume([
        FileUsage(path: "\(nested)/first.dat", parentPath: nested, name: "first.dat", logicalBytes: 1, allocatedBytes: 4_096)
    ])
    try full.finish()

    let partial = try store.makeSubtreeWriter(rootPath: root, subtreePath: nested)
    try partial.consume([
        FileUsage(path: "\(nested)/second.dat", parentPath: nested, name: "second.dat", logicalBytes: 2, allocatedBytes: 4_096)
    ])
    try partial.finish()

    #expect(try store.search(rootPath: root, query: "first.dat", limit: 10).isEmpty)
    #expect(try store.search(rootPath: root, query: "second.dat", limit: 10).count == 1)
}

@Test func searchWaitsForAtomicIndexReplacement() async throws {
    let tempRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("findtree-file-concurrency-\(UUID().uuidString)", isDirectory: true)
    let dbURL = tempRoot.appendingPathComponent("index.sqlite")
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let root = "/example/concurrent-root"
    let store = FileIndexStore(databaseURL: dbURL)

    let initial = try store.makeFullWriter(rootPath: root)
    try initial.consume([
        FileUsage(path: "\(root)/old.txt", parentPath: root, name: "old.txt", logicalBytes: 1, allocatedBytes: 4_096)
    ])
    try initial.finish()

    let replacement = try store.makeFullWriter(rootPath: root)
    try replacement.consume([
        FileUsage(path: "\(root)/new.txt", parentPath: root, name: "new.txt", logicalBytes: 2, allocatedBytes: 4_096)
    ])

    let searchTask = Task.detached {
        try store.search(rootPath: root, query: "new.txt", limit: 10)
    }
    try await Task.sleep(for: .milliseconds(50))
    try replacement.finish()

    let results = try await searchTask.value
    #expect(results.count == 1)
    #expect(results.first?.name == "new.txt")
}
