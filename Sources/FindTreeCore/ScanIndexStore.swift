import Foundation
import SQLite3

public struct IndexedScanSnapshot: Sendable {
    public let indexedAt: Date
    public let result: ScanResult

    public init(indexedAt: Date, result: ScanResult) {
        self.indexedAt = indexedAt
        self.result = result
    }
}

public final class ScanIndexStore: @unchecked Sendable {
    public let databaseURL: URL

    public init(databaseURL: URL) {
        self.databaseURL = databaseURL
    }

    public func save(_ result: ScanResult, indexedAt: Date = Date()) throws {
        try prepareParentDirectory()
        let db = try openDatabase()
        defer { sqlite3_close(db) }

        try configure(db)
        try createSchema(db)
        if try dropLegacyFileTableIfNeeded(db) {
            try execute(db, sql: "VACUUM")
        }
        try execute(db, sql: "BEGIN IMMEDIATE TRANSACTION")

        do {
            try deleteExistingDirectories(db, rootPath: result.rootPath)
            try upsertMetadata(db, result: result, indexedAt: indexedAt)
            try insertDirectories(db, rootPath: result.rootPath, directories: result.directories)
            try execute(db, sql: "COMMIT")
        } catch {
            try? execute(db, sql: "ROLLBACK")
            throw error
        }
    }

    public func load(rootPath: String) throws -> IndexedScanSnapshot? {
        let standardizedRoot = standardized(rootPath)
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            return nil
        }

        let db = try openDatabase(readOnly: true)
        defer { sqlite3_close(db) }

        let metadataSQL = """
        SELECT indexed_at, elapsed_seconds, file_count, directory_count,
               inaccessible_directory_count, logical_bytes, allocated_bytes
        FROM scan_metadata
        WHERE root_path = ?
        """

        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(db, metadataSQL, -1, &statement, nil), db: db)
        defer { sqlite3_finalize(statement) }
        try bindText(standardizedRoot, at: 1, statement: statement, db: db)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }

        let indexedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
        let elapsedSeconds = sqlite3_column_double(statement, 1)
        let fileCount = Int(sqlite3_column_int64(statement, 2))
        let directoryCount = Int(sqlite3_column_int64(statement, 3))
        let inaccessibleCount = Int(sqlite3_column_int64(statement, 4))
        let logicalBytes = UInt64(max(sqlite3_column_int64(statement, 5), 0))
        let allocatedBytes = UInt64(max(sqlite3_column_int64(statement, 6), 0))

        let directories = try loadDirectories(db, rootPath: standardizedRoot)
        let result = ScanResult(
            rootPath: standardizedRoot,
            elapsedSeconds: elapsedSeconds,
            fileCount: fileCount,
            directoryCount: directoryCount,
            inaccessibleDirectoryCount: inaccessibleCount,
            logicalBytes: logicalBytes,
            allocatedBytes: allocatedBytes,
            directories: directories
        )

        return IndexedScanSnapshot(indexedAt: indexedAt, result: result)
    }

    /// Replaces one cached subtree and propagates its size/count delta to all cached ancestors.
    /// Pass nil when the subtree was deleted.
    public func replaceSubtree(
        rootPath: String,
        subtreePath: String,
        with newResult: ScanResult?,
        indexedAt: Date = Date()
    ) throws {
        let root = standardized(rootPath)
        let subtree = standardized(subtreePath)
        guard isDescendantOrEqual(subtree, of: root) else {
            throw ScanIndexError.pathOutsideRoot(subtree)
        }

        if subtree == root {
            guard let newResult else {
                throw ScanIndexError.cannotDeleteRoot
            }
            try save(newResult, indexedAt: indexedAt)
            return
        }

        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw ScanIndexError.missingIndex
        }

        let db = try openDatabase()
        defer { sqlite3_close(db) }
        try configure(db)
        try createSchema(db)
        try execute(db, sql: "BEGIN IMMEDIATE TRANSACTION")

        do {
            let oldUsage = try loadDirectory(db, rootPath: root, path: subtree)
            let oldExists = oldUsage != nil
            let newUsage = newResult?.directories.first(where: { $0.path == subtree })
            let newExists = newUsage != nil

            try deleteSubtreeDirectories(db, rootPath: root, subtreePath: subtree)
            if let newResult {
                try insertDirectories(db, rootPath: root, directories: newResult.directories)
            }

            let oldLogical = Int64(clamping: oldUsage?.logicalBytes ?? 0)
            let newLogical = Int64(clamping: newUsage?.logicalBytes ?? 0)
            let oldAllocated = Int64(clamping: oldUsage?.allocatedBytes ?? 0)
            let newAllocated = Int64(clamping: newUsage?.allocatedBytes ?? 0)
            let oldFiles = Int64(oldUsage?.fileCount ?? 0)
            let newFiles = Int64(newUsage?.fileCount ?? 0)
            let oldDirs = Int64(oldUsage?.directoryCount ?? 0) + (oldExists ? 1 : 0)
            let newDirs = Int64(newUsage?.directoryCount ?? 0) + (newExists ? 1 : 0)

            let logicalDelta = newLogical - oldLogical
            let allocatedDelta = newAllocated - oldAllocated
            let fileDelta = newFiles - oldFiles
            let directoryDelta = newDirs - oldDirs

            for ancestor in ancestors(of: subtree, stoppingAt: root) {
                try applyDelta(
                    db,
                    rootPath: root,
                    directoryPath: ancestor,
                    logicalDelta: logicalDelta,
                    allocatedDelta: allocatedDelta,
                    fileDelta: fileDelta,
                    directoryDelta: directoryDelta
                )
            }

            try updateMetadataDelta(
                db,
                rootPath: root,
                indexedAt: indexedAt,
                logicalDelta: logicalDelta,
                allocatedDelta: allocatedDelta,
                fileDelta: fileDelta,
                directoryDelta: directoryDelta
            )
            try execute(db, sql: "COMMIT")
        } catch {
            try? execute(db, sql: "ROLLBACK")
            throw error
        }
    }

    public func applyFileDeltas(
        rootPath: String,
        deltas: [FileIndexDelta],
        indexedAt: Date = Date()
    ) throws {
        guard !deltas.isEmpty else { return }
        let root = standardized(rootPath)
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw ScanIndexError.missingIndex
        }

        var byDirectory: [String: (logical: Int64, allocated: Int64, files: Int64)] = [:]
        var totalLogical: Int64 = 0
        var totalAllocated: Int64 = 0
        var totalFiles: Int64 = 0

        for delta in deltas {
            let parent = standardized(delta.parentPath)
            guard isDescendantOrEqual(parent, of: root) else { continue }
            totalLogical += delta.logicalDelta
            totalAllocated += delta.allocatedDelta
            totalFiles += delta.fileCountDelta

            var current = parent
            while isDescendantOrEqual(current, of: root) {
                var aggregate = byDirectory[current] ?? (0, 0, 0)
                aggregate.logical += delta.logicalDelta
                aggregate.allocated += delta.allocatedDelta
                aggregate.files += delta.fileCountDelta
                byDirectory[current] = aggregate
                if current == root { break }
                let next = (current as NSString).deletingLastPathComponent
                if next == current { break }
                current = next
            }
        }

        guard !byDirectory.isEmpty else { return }
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        try configure(db)
        try createSchema(db)
        try execute(db, sql: "BEGIN IMMEDIATE TRANSACTION")
        do {
            for (directory, aggregate) in byDirectory {
                try applyDelta(
                    db,
                    rootPath: root,
                    directoryPath: directory,
                    logicalDelta: aggregate.logical,
                    allocatedDelta: aggregate.allocated,
                    fileDelta: aggregate.files,
                    directoryDelta: 0
                )
            }
            try updateMetadataDelta(
                db,
                rootPath: root,
                indexedAt: indexedAt,
                logicalDelta: totalLogical,
                allocatedDelta: totalAllocated,
                fileDelta: totalFiles,
                directoryDelta: 0
            )
            try execute(db, sql: "COMMIT")
        } catch {
            try? execute(db, sql: "ROLLBACK")
            throw error
        }
    }


    private func prepareParentDirectory() throws {
        let parent = databaseURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    }

    private func openDatabase(readOnly: Bool = false) throws -> OpaquePointer {
        var db: OpaquePointer?
        let flags = readOnly
            ? SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
            : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX

        let status = sqlite3_open_v2(databaseURL.path, &db, flags, nil)
        guard status == SQLITE_OK, let db else {
            let message = db.flatMap { sqlite3_errmsg($0) }.map(String.init(cString:)) ?? "unknown sqlite error"
            if let db { sqlite3_close(db) }
            throw ScanIndexError.sqlite(message)
        }
        return db
    }

    private func configure(_ db: OpaquePointer) throws {
        try execute(db, sql: "PRAGMA journal_mode=WAL")
        try execute(db, sql: "PRAGMA synchronous=NORMAL")
        try execute(db, sql: "PRAGMA temp_store=MEMORY")
    }

    private func createSchema(_ db: OpaquePointer) throws {
        try execute(db, sql: """
        CREATE TABLE IF NOT EXISTS scan_metadata (
            root_path TEXT PRIMARY KEY,
            indexed_at REAL NOT NULL,
            elapsed_seconds REAL NOT NULL,
            file_count INTEGER NOT NULL,
            directory_count INTEGER NOT NULL,
            inaccessible_directory_count INTEGER NOT NULL,
            logical_bytes INTEGER NOT NULL,
            allocated_bytes INTEGER NOT NULL
        )
        """)

        try execute(db, sql: """
        CREATE TABLE IF NOT EXISTS directories (
            root_path TEXT NOT NULL,
            path TEXT NOT NULL,
            logical_bytes INTEGER NOT NULL,
            allocated_bytes INTEGER NOT NULL,
            file_count INTEGER NOT NULL,
            directory_count INTEGER NOT NULL,
            PRIMARY KEY (root_path, path)
        ) WITHOUT ROWID
        """)
    }

    private func deleteExistingDirectories(_ db: OpaquePointer, rootPath: String) throws {
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(db, "DELETE FROM directories WHERE root_path = ?", -1, &statement, nil), db: db)
        defer { sqlite3_finalize(statement) }
        try bindText(rootPath, at: 1, statement: statement, db: db)
        try checkStepDone(sqlite3_step(statement), db: db)
    }

    private func deleteSubtreeDirectories(_ db: OpaquePointer, rootPath: String, subtreePath: String) throws {
        let prefix = subtreePath.hasSuffix("/") ? subtreePath + "%" : subtreePath + "/%"
        let sql = "DELETE FROM directories WHERE root_path = ? AND (path = ? OR path LIKE ?)"
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(db, sql, -1, &statement, nil), db: db)
        defer { sqlite3_finalize(statement) }
        try bindText(rootPath, at: 1, statement: statement, db: db)
        try bindText(subtreePath, at: 2, statement: statement, db: db)
        try bindText(prefix, at: 3, statement: statement, db: db)
        try checkStepDone(sqlite3_step(statement), db: db)
    }

    private func upsertMetadata(_ db: OpaquePointer, result: ScanResult, indexedAt: Date) throws {
        let sql = """
        INSERT INTO scan_metadata (
            root_path, indexed_at, elapsed_seconds, file_count, directory_count,
            inaccessible_directory_count, logical_bytes, allocated_bytes
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(root_path) DO UPDATE SET
            indexed_at = excluded.indexed_at,
            elapsed_seconds = excluded.elapsed_seconds,
            file_count = excluded.file_count,
            directory_count = excluded.directory_count,
            inaccessible_directory_count = excluded.inaccessible_directory_count,
            logical_bytes = excluded.logical_bytes,
            allocated_bytes = excluded.allocated_bytes
        """

        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(db, sql, -1, &statement, nil), db: db)
        defer { sqlite3_finalize(statement) }

        try bindText(result.rootPath, at: 1, statement: statement, db: db)
        sqlite3_bind_double(statement, 2, indexedAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 3, result.elapsedSeconds)
        sqlite3_bind_int64(statement, 4, sqlite3_int64(result.fileCount))
        sqlite3_bind_int64(statement, 5, sqlite3_int64(result.directoryCount))
        sqlite3_bind_int64(statement, 6, sqlite3_int64(result.inaccessibleDirectoryCount))
        sqlite3_bind_int64(statement, 7, sqlite3_int64(clamping: result.logicalBytes))
        sqlite3_bind_int64(statement, 8, sqlite3_int64(clamping: result.allocatedBytes))
        try checkStepDone(sqlite3_step(statement), db: db)
    }

    private func updateMetadataDelta(
        _ db: OpaquePointer,
        rootPath: String,
        indexedAt: Date,
        logicalDelta: Int64,
        allocatedDelta: Int64,
        fileDelta: Int64,
        directoryDelta: Int64
    ) throws {
        let sql = """
        UPDATE scan_metadata SET
            indexed_at = ?,
            file_count = MAX(0, file_count + ?),
            directory_count = MAX(0, directory_count + ?),
            logical_bytes = MAX(0, logical_bytes + ?),
            allocated_bytes = MAX(0, allocated_bytes + ?)
        WHERE root_path = ?
        """
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(db, sql, -1, &statement, nil), db: db)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, indexedAt.timeIntervalSince1970)
        sqlite3_bind_int64(statement, 2, fileDelta)
        sqlite3_bind_int64(statement, 3, directoryDelta)
        sqlite3_bind_int64(statement, 4, logicalDelta)
        sqlite3_bind_int64(statement, 5, allocatedDelta)
        try bindText(rootPath, at: 6, statement: statement, db: db)
        try checkStepDone(sqlite3_step(statement), db: db)
    }

    private func applyDelta(
        _ db: OpaquePointer,
        rootPath: String,
        directoryPath: String,
        logicalDelta: Int64,
        allocatedDelta: Int64,
        fileDelta: Int64,
        directoryDelta: Int64
    ) throws {
        let sql = """
        UPDATE directories SET
            logical_bytes = MAX(0, logical_bytes + ?),
            allocated_bytes = MAX(0, allocated_bytes + ?),
            file_count = MAX(0, file_count + ?),
            directory_count = MAX(0, directory_count + ?)
        WHERE root_path = ? AND path = ?
        """
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(db, sql, -1, &statement, nil), db: db)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, logicalDelta)
        sqlite3_bind_int64(statement, 2, allocatedDelta)
        sqlite3_bind_int64(statement, 3, fileDelta)
        sqlite3_bind_int64(statement, 4, directoryDelta)
        try bindText(rootPath, at: 5, statement: statement, db: db)
        try bindText(directoryPath, at: 6, statement: statement, db: db)
        try checkStepDone(sqlite3_step(statement), db: db)
    }

    private func insertDirectories(_ db: OpaquePointer, rootPath: String, directories: [DirectoryUsage]) throws {
        let sql = """
        INSERT OR REPLACE INTO directories (
            root_path, path, logical_bytes, allocated_bytes, file_count, directory_count
        ) VALUES (?, ?, ?, ?, ?, ?)
        """

        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(db, sql, -1, &statement, nil), db: db)
        defer { sqlite3_finalize(statement) }

        for directory in directories {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            try bindText(rootPath, at: 1, statement: statement, db: db)
            try bindText(directory.path, at: 2, statement: statement, db: db)
            sqlite3_bind_int64(statement, 3, sqlite3_int64(clamping: directory.logicalBytes))
            sqlite3_bind_int64(statement, 4, sqlite3_int64(clamping: directory.allocatedBytes))
            sqlite3_bind_int64(statement, 5, sqlite3_int64(directory.fileCount))
            sqlite3_bind_int64(statement, 6, sqlite3_int64(directory.directoryCount))
            try checkStepDone(sqlite3_step(statement), db: db)
        }
    }

    private func loadDirectory(_ db: OpaquePointer, rootPath: String, path: String) throws -> DirectoryUsage? {
        let sql = """
        SELECT path, logical_bytes, allocated_bytes, file_count, directory_count
        FROM directories WHERE root_path = ? AND path = ?
        """
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(db, sql, -1, &statement, nil), db: db)
        defer { sqlite3_finalize(statement) }
        try bindText(rootPath, at: 1, statement: statement, db: db)
        try bindText(path, at: 2, statement: statement, db: db)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return directoryUsage(from: statement)
    }

    private func loadDirectories(_ db: OpaquePointer, rootPath: String) throws -> [DirectoryUsage] {
        let sql = """
        SELECT path, logical_bytes, allocated_bytes, file_count, directory_count
        FROM directories
        WHERE root_path = ?
        """

        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(db, sql, -1, &statement, nil), db: db)
        defer { sqlite3_finalize(statement) }
        try bindText(rootPath, at: 1, statement: statement, db: db)

        var directories: [DirectoryUsage] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else {
                try check(status, db: db)
                break
            }
            directories.append(directoryUsage(from: statement))
        }
        return directories
    }

    private func directoryUsage(from statement: OpaquePointer?) -> DirectoryUsage {
        let path = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? ""
        return DirectoryUsage(
            path: path,
            logicalBytes: UInt64(max(sqlite3_column_int64(statement, 1), 0)),
            allocatedBytes: UInt64(max(sqlite3_column_int64(statement, 2), 0)),
            fileCount: Int(sqlite3_column_int64(statement, 3)),
            directoryCount: Int(sqlite3_column_int64(statement, 4))
        )
    }

    private func standardized(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
    }

    private func isDescendantOrEqual(_ path: String, of root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    /// Returns ancestors outside the replaced subtree, nearest first, including root.
    private func ancestors(of path: String, stoppingAt root: String) -> [String] {
        var result: [String] = []
        var current = (path as NSString).deletingLastPathComponent
        while isDescendantOrEqual(current, of: root) {
            result.append(current)
            if current == root { break }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current { break }
            current = parent
        }
        return result
    }

    private func dropLegacyFileTableIfNeeded(_ db: OpaquePointer) throws -> Bool {
        var statement: OpaquePointer?
        let sql = "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'files' LIMIT 1"
        try check(sqlite3_prepare_v2(db, sql, -1, &statement, nil), db: db)
        let exists = sqlite3_step(statement) == SQLITE_ROW
        sqlite3_finalize(statement)
        statement = nil
        guard exists else { return false }
        try execute(db, sql: "DROP TABLE files")
        return true
    }

    private func execute(_ db: OpaquePointer, sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(db, sql, nil, nil, &errorMessage)
        guard status == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            sqlite3_free(errorMessage)
            throw ScanIndexError.sqlite(message)
        }
    }

    private func bindText(_ value: String, at index: Int32, statement: OpaquePointer?, db: OpaquePointer) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        try check(sqlite3_bind_text(statement, index, value, -1, transient), db: db)
    }

    private func checkStepDone(_ status: Int32, db: OpaquePointer) throws {
        guard status == SQLITE_DONE else {
            try check(status, db: db)
            return
        }
    }

    private func check(_ status: Int32, db: OpaquePointer) throws {
        guard status == SQLITE_OK else {
            throw ScanIndexError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
    }
}

public enum ScanIndexError: Error, CustomStringConvertible {
    case sqlite(String)
    case missingIndex
    case pathOutsideRoot(String)
    case cannotDeleteRoot

    public var description: String {
        switch self {
        case .sqlite(let message):
            return "SQLite error: \(message)"
        case .missingIndex:
            return "No existing local index"
        case .pathOutsideRoot(let path):
            return "Path is outside the indexed root: \(path)"
        case .cannotDeleteRoot:
            return "The indexed root cannot be removed incrementally"
        }
    }
}
