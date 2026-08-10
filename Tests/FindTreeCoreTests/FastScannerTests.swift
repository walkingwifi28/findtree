import Foundation
import Testing
@testable import FindTreeCore

@Test func scansNestedDirectoriesAndAggregatesLogicalSize() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("findtree-test-\(UUID().uuidString)", isDirectory: true)
    let nested = root.appendingPathComponent("nested", isDirectory: true)

    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let first = Data(repeating: 0x41, count: 1_024)
    let second = Data(repeating: 0x42, count: 2_048)
    try first.write(to: root.appendingPathComponent("first.bin"))
    try second.write(to: nested.appendingPathComponent("second.bin"))

    let result = try FastScanner().scan(
        rootURL: root,
        options: ScanOptions(stayOnRootVolume: true, includeHiddenFiles: true),
        progressEvery: 0
    )

    #expect(result.fileCount == 2)
    #expect(result.directoryCount == 1)
    #expect(result.logicalBytes == 3_072)

    let nestedUsage = try #require(result.directories.first { $0.path == nested.path })
    #expect(nestedUsage.fileCount == 1)
    #expect(nestedUsage.logicalBytes == 2_048)
}

@Test func doesNotFollowSymbolicLinks() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("findtree-symlink-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let file = root.appendingPathComponent("data.bin")
    try Data(repeating: 0x44, count: 512).write(to: file)
    try FileManager.default.createSymbolicLink(
        at: root.appendingPathComponent("data-link.bin"),
        withDestinationURL: file
    )

    let result = try FastScanner().scan(rootURL: root, progressEvery: 0)

    #expect(result.fileCount == 1)
    #expect(result.logicalBytes == 512)
}
