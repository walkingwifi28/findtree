import Foundation
import CoreServices
import Testing
@testable import FindTreeCore

@Test func subtreeReplacementMatchesFreshFullScan() throws {
    let tempRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("findtree-incremental-test-\(UUID().uuidString)", isDirectory: true)
    let scanRoot = tempRoot.appendingPathComponent("scan", isDirectory: true)
    let alpha = scanRoot.appendingPathComponent("alpha", isDirectory: true)
    let beta = alpha.appendingPathComponent("beta", isDirectory: true)
    let dbURL = tempRoot.appendingPathComponent("index.sqlite")

    try FileManager.default.createDirectory(at: beta, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    try Data(repeating: 0x11, count: 4_096).write(to: beta.appendingPathComponent("one.bin"))
    try Data(repeating: 0x22, count: 8_192).write(to: scanRoot.appendingPathComponent("root.bin"))

    let scanner = FastScanner()
    let store = ScanIndexStore(databaseURL: dbURL)
    try store.save(scanner.scan(rootURL: scanRoot, progressEvery: 0))

    try Data(repeating: 0x33, count: 65_536).write(to: beta.appendingPathComponent("two.bin"))
    let gamma = alpha.appendingPathComponent("gamma", isDirectory: true)
    try FileManager.default.createDirectory(at: gamma, withIntermediateDirectories: true)
    try Data(repeating: 0x44, count: 12_345).write(to: gamma.appendingPathComponent("three.bin"))

    let refreshedAlpha = try scanner.scan(rootURL: alpha, progressEvery: 0)
    try store.replaceSubtree(rootPath: scanRoot.path, subtreePath: alpha.path, with: refreshedAlpha)

    let fresh = try scanner.scan(rootURL: scanRoot, progressEvery: 0)
    let cached = try #require(store.load(rootPath: scanRoot.path)?.result)
    expectSameSnapshot(cached, fresh)

    try FileManager.default.removeItem(at: beta)
    try store.replaceSubtree(rootPath: scanRoot.path, subtreePath: beta.path, with: nil)

    let freshAfterDelete = try scanner.scan(rootURL: scanRoot, progressEvery: 0)
    let cachedAfterDelete = try #require(store.load(rootPath: scanRoot.path)?.result)
    expectSameSnapshot(cachedAfterDelete, freshAfterDelete)
}

@Test func coalescesNestedEventPathsToSmallestDirectorySet() {
    let root = "/tmp/findtree-root"
    let fileFlag = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemModified)
    let dirFlag = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemModified)

    let changes = [
        FileSystemChange(path: "\(root)/alpha/a.txt", flags: fileFlag, eventID: 1),
        FileSystemChange(path: "\(root)/alpha/beta/b.txt", flags: fileFlag, eventID: 2),
        FileSystemChange(path: "\(root)/gamma", flags: dirFlag, eventID: 3)
    ]

    let paths = IncrementalIndexUpdater.coalescedRefreshPaths(for: changes, rootPath: root)
    #expect(paths.isEmpty)
}

@Test func keepsStructuralDirectoryAndMustScanEvents() {
    let root = "/tmp/findtree-root"
    let createdDir = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemCreated)
    let mustScan = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped)

    let changes = [
        FileSystemChange(path: "\(root)/created", flags: createdDir, eventID: 10),
        FileSystemChange(path: "\(root)/damaged", flags: mustScan, eventID: 11)
    ]

    let paths = IncrementalIndexUpdater.coalescedRefreshPaths(for: changes, rootPath: root)
    #expect(Set(paths) == Set(["\(root)/created", "\(root)/damaged"]))
}

@Test func persistsFSEventCursor() throws {
    let tempRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("findtree-event-cursor-\(UUID().uuidString)", isDirectory: true)
    let dbURL = tempRoot.appendingPathComponent("index.sqlite")
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let store = ScanIndexStore(databaseURL: dbURL)
    try store.saveLastEventID(9_876_543_210, rootPath: tempRoot.path)
    try store.saveLastEventID(100, rootPath: tempRoot.path)
    #expect(try store.lastEventID(rootPath: tempRoot.path) == 9_876_543_210)
}

private func expectSameSnapshot(_ lhs: ScanResult, _ rhs: ScanResult) {
    #expect(lhs.fileCount == rhs.fileCount)
    #expect(lhs.directoryCount == rhs.directoryCount)
    #expect(lhs.logicalBytes == rhs.logicalBytes)
    #expect(lhs.allocatedBytes == rhs.allocatedBytes)

    let left = Dictionary(uniqueKeysWithValues: lhs.directories.map { ($0.path, $0) })
    let right = Dictionary(uniqueKeysWithValues: rhs.directories.map { ($0.path, $0) })
    #expect(left.keys == right.keys)

    for path in right.keys {
        guard let l = left[path], let r = right[path] else { continue }
        #expect(l.logicalBytes == r.logicalBytes)
        #expect(l.allocatedBytes == r.allocatedBytes)
        #expect(l.fileCount == r.fileCount)
        #expect(l.directoryCount == r.directoryCount)
    }
}
