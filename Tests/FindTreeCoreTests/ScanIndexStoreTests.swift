import Foundation
import Testing
import SQLite3
@testable import FindTreeCore

@Test func savesAndLoadsScanSnapshot() throws {
    let tempRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("findtree-index-test-\(UUID().uuidString)", isDirectory: true)
    let scanRoot = tempRoot.appendingPathComponent("scan", isDirectory: true)
    let dbURL = tempRoot.appendingPathComponent("index.sqlite")

    try FileManager.default.createDirectory(at: scanRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    try Data(repeating: 0x41, count: 4_096)
        .write(to: scanRoot.appendingPathComponent("payload.bin"))

    let result = try FastScanner().scan(rootURL: scanRoot, progressEvery: 0)
    let store = ScanIndexStore(databaseURL: dbURL)
    let indexedAt = Date(timeIntervalSince1970: 1_700_000_000)

    try store.save(result, indexedAt: indexedAt)
    let cached = try store.load(rootPath: scanRoot.path)
    let loaded = try #require(cached)

    #expect(loaded.indexedAt == indexedAt)
    #expect(loaded.result.rootPath == result.rootPath)
    #expect(loaded.result.fileCount == result.fileCount)
    #expect(loaded.result.directoryCount == result.directoryCount)
    #expect(loaded.result.logicalBytes == result.logicalBytes)
    #expect(loaded.result.allocatedBytes == result.allocatedBytes)
    #expect(loaded.result.directories.count == result.directories.count)
}


@Test func migratesLegacyEmbeddedFileTable() throws {
    let tempRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("findtree-legacy-index-\(UUID().uuidString)", isDirectory: true)
    let scanRoot = tempRoot.appendingPathComponent("scan", isDirectory: true)
    let dbURL = tempRoot.appendingPathComponent("index.sqlite")
    try FileManager.default.createDirectory(at: scanRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    var db: OpaquePointer?
    #expect(sqlite3_open(dbURL.path, &db) == SQLITE_OK)
    if let db {
        sqlite3_exec(db, "CREATE TABLE files(path TEXT); INSERT INTO files VALUES('/legacy')", nil, nil, nil)
        sqlite3_close(db)
    }

    let result = try FastScanner().scan(rootURL: scanRoot, progressEvery: 0)
    try ScanIndexStore(databaseURL: dbURL).save(result)

    var checkDB: OpaquePointer?
    #expect(sqlite3_open_v2(dbURL.path, &checkDB, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
    defer { if let checkDB { sqlite3_close(checkDB) } }
    var statement: OpaquePointer?
    sqlite3_prepare_v2(checkDB, "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='files'", -1, &statement, nil)
    defer { sqlite3_finalize(statement) }
    #expect(sqlite3_step(statement) == SQLITE_ROW)
    #expect(sqlite3_column_int(statement, 0) == 0)
}
