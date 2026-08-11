import Foundation
import SQLite3
import Darwin
import Dispatch

private final class FileIndexAccessCoordinator: @unchecked Sendable {
    static let shared = FileIndexAccessCoordinator()

    private let lock = NSLock()
    private var gates: [String: DispatchSemaphore] = [:]

    func gate(for databaseURL: URL) -> DispatchSemaphore {
        let key = databaseURL.standardizedFileURL.path
        lock.lock()
        defer { lock.unlock() }
        if let existing = gates[key] { return existing }
        let gate = DispatchSemaphore(value: 1)
        gates[key] = gate
        return gate
    }
}

public struct FileIndexDelta: Sendable, Equatable {
    public let parentPath: String
    public let logicalDelta: Int64
    public let allocatedDelta: Int64
    public let fileCountDelta: Int64

    public init(parentPath: String, logicalDelta: Int64, allocatedDelta: Int64, fileCountDelta: Int64) {
        self.parentPath = parentPath
        self.logicalDelta = logicalDelta
        self.allocatedDelta = allocatedDelta
        self.fileCountDelta = fileCountDelta
    }
}

public final class FileIndexStore: @unchecked Sendable {
    private let baseDatabaseURL: URL

    public init(databaseURL: URL) {
        self.baseDatabaseURL = databaseURL
    }

    public func databaseURL(rootPath: String) -> URL {
        let root = PathUtilities.standardized(rootPath)
        let hash = Self.fnv1a64(root)
        return baseDatabaseURL.deletingLastPathComponent()
            .appendingPathComponent(String(format: "files-%016llx.sqlite", hash))
    }

    public func hasIndex(rootPath: String) -> Bool {
        FileManager.default.fileExists(atPath: databaseURL(rootPath: rootPath).path)
    }

    public func makeFullWriter(rootPath: String) throws -> FileIndexWriter {
        try FileIndexWriter(
            databaseURL: databaseURL(rootPath: rootPath),
            rootPath: rootPath,
            subtreePath: nil,
            fullRebuild: true
        )
    }

    public func makeSubtreeWriter(rootPath: String, subtreePath: String) throws -> FileIndexWriter {
        let url = databaseURL(rootPath: rootPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw FileIndexError.missingIndex
        }
        return try FileIndexWriter(
            databaseURL: url,
            rootPath: rootPath,
            subtreePath: subtreePath,
            fullRebuild: false
        )
    }

    public func search(rootPath: String, query: String = "", limit: Int = 100) throws -> [FileUsage] {
        guard limit > 0 else { return [] }
        let root = PathUtilities.standardized(rootPath)
        let url = databaseURL(rootPath: root)
        let accessGate = FileIndexAccessCoordinator.shared.gate(for: url)
        accessGate.wait()
        defer { accessGate.signal() }
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }

        let db = try openReadOnly(url)
        defer { sqlite3_close(db) }

        let storedRoot = try loadStoredRoot(db)
        guard storedRoot == root else { return [] }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let sql: String
        let useFTS = trimmed.utf8.count >= 3

        if trimmed.isEmpty {
            sql = """
            SELECT parent_relative, name, logical_bytes, allocated_bytes
            FROM files
            ORDER BY allocated_bytes DESC, logical_bytes DESC
            LIMIT ?
            """
        } else if useFTS {
            sql = """
            SELECT f.parent_relative, f.name, f.logical_bytes, f.allocated_bytes
            FROM files_fts
            JOIN files AS f ON f.id = files_fts.rowid
            WHERE files_fts MATCH ?
            ORDER BY f.allocated_bytes DESC, f.logical_bytes DESC
            LIMIT ?
            """
        } else {
            sql = """
            SELECT parent_relative, name, logical_bytes, allocated_bytes
            FROM files
            WHERE name LIKE ? COLLATE NOCASE
            ORDER BY allocated_bytes DESC, logical_bytes DESC
            LIMIT ?
            """
        }

        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(db, sql, -1, &statement, nil), db: db)
        defer { sqlite3_finalize(statement) }

        if trimmed.isEmpty {
            sqlite3_bind_int(statement, 1, Int32(clamping: limit))
        } else if useFTS {
            let escaped = trimmed.replacingOccurrences(of: "\"", with: "\"\"")
            try bindText("\"\(escaped)\"", at: 1, statement: statement, db: db)
            sqlite3_bind_int(statement, 2, Int32(clamping: limit))
        } else {
            try bindText("%\(trimmed)%", at: 1, statement: statement, db: db)
            sqlite3_bind_int(statement, 2, Int32(clamping: limit))
        }

        var files: [FileUsage] = []
        files.reserveCapacity(limit)
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                try check(step, db: db)
                break
            }

            let parentRelative = text(statement, column: 0)
            let name = text(statement, column: 1)
            let parentPath = parentRelative.isEmpty
                ? root
                : (root as NSString).appendingPathComponent(parentRelative)
            let path = (parentPath as NSString).appendingPathComponent(name)
            files.append(
                FileUsage(
                    path: path,
                    parentPath: parentPath,
                    name: name,
                    logicalBytes: UInt64(max(sqlite3_column_int64(statement, 2), 0)),
                    allocatedBytes: UInt64(max(sqlite3_column_int64(statement, 3), 0))
                )
            )
        }
        return files
    }

    public func applyFileChanges(rootPath: String, filePaths: [String]) throws -> [FileIndexDelta] {
        guard !filePaths.isEmpty else { return [] }
        let root = PathUtilities.standardized(rootPath)
        let url = databaseURL(rootPath: root)
        let accessGate = FileIndexAccessCoordinator.shared.gate(for: url)
        accessGate.wait()
        defer { accessGate.signal() }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw FileIndexError.missingIndex
        }

        let db = try openReadWrite(url)
        defer { sqlite3_close(db) }
        try execute(db, "PRAGMA journal_mode=WAL")
        try execute(db, "PRAGMA synchronous=NORMAL")
        try execute(db, "PRAGMA temp_store=MEMORY")
        guard try loadStoredRoot(db) == root else { throw FileIndexError.rootMismatch }

        var selectStatement: OpaquePointer?
        var upsertStatement: OpaquePointer?
        var deleteStatement: OpaquePointer?
        try check(sqlite3_prepare_v2(
            db,
            "SELECT logical_bytes, allocated_bytes FROM files WHERE parent_relative = ? AND name = ?",
            -1,
            &selectStatement,
            nil
        ), db: db)
        defer { sqlite3_finalize(selectStatement) }

        try check(sqlite3_prepare_v2(
            db,
            "INSERT OR REPLACE INTO files(parent_relative, name, logical_bytes, allocated_bytes) VALUES (?, ?, ?, ?)",
            -1,
            &upsertStatement,
            nil
        ), db: db)
        defer { sqlite3_finalize(upsertStatement) }

        try check(sqlite3_prepare_v2(
            db,
            "DELETE FROM files WHERE parent_relative = ? AND name = ?",
            -1,
            &deleteStatement,
            nil
        ), db: db)
        defer { sqlite3_finalize(deleteStatement) }

        try execute(db, "BEGIN IMMEDIATE TRANSACTION")
        do {
            var deltas: [FileIndexDelta] = []
            deltas.reserveCapacity(filePaths.count)

            for rawPath in Set(filePaths) {
                let path = PathUtilities.standardized(rawPath)
                guard PathUtilities.isDescendantOrEqual(path, of: root), path != root else { continue }
                let parent = (path as NSString).deletingLastPathComponent
                let name = (path as NSString).lastPathComponent
                let parentRelative = parent == root ? "" : String(parent.dropFirst(root.count + 1))

                sqlite3_reset(selectStatement)
                sqlite3_clear_bindings(selectStatement)
                try bindText(parentRelative, at: 1, statement: selectStatement, db: db)
                try bindText(name, at: 2, statement: selectStatement, db: db)
                let selectStep = sqlite3_step(selectStatement)
                let oldExists = selectStep == SQLITE_ROW
                if selectStep != SQLITE_ROW && selectStep != SQLITE_DONE {
                    try check(selectStep, db: db)
                }
                let oldLogical = oldExists ? sqlite3_column_int64(selectStatement, 0) : 0
                let oldAllocated = oldExists ? sqlite3_column_int64(selectStatement, 1) : 0

                let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                    .fileSizeKey,
                    .fileAllocatedSizeKey
                ])
                let newExists = values?.isRegularFile == true && values?.isSymbolicLink != true
                let newLogical = newExists ? Int64(max(values?.fileSize ?? 0, 0)) : 0
                let newAllocated = newExists ? Int64(max(values?.fileAllocatedSize ?? values?.fileSize ?? 0, 0)) : 0

                if newExists {
                    sqlite3_reset(upsertStatement)
                    sqlite3_clear_bindings(upsertStatement)
                    try bindText(parentRelative, at: 1, statement: upsertStatement, db: db)
                    try bindText(name, at: 2, statement: upsertStatement, db: db)
                    sqlite3_bind_int64(upsertStatement, 3, newLogical)
                    sqlite3_bind_int64(upsertStatement, 4, newAllocated)
                    try checkDone(sqlite3_step(upsertStatement), db: db)
                } else if oldExists {
                    sqlite3_reset(deleteStatement)
                    sqlite3_clear_bindings(deleteStatement)
                    try bindText(parentRelative, at: 1, statement: deleteStatement, db: db)
                    try bindText(name, at: 2, statement: deleteStatement, db: db)
                    try checkDone(sqlite3_step(deleteStatement), db: db)
                }

                let fileCountDelta: Int64 = newExists == oldExists ? 0 : (newExists ? 1 : -1)
                let logicalDelta = newLogical - oldLogical
                let allocatedDelta = newAllocated - oldAllocated
                if fileCountDelta != 0 || logicalDelta != 0 || allocatedDelta != 0 {
                    deltas.append(FileIndexDelta(
                        parentPath: parent,
                        logicalDelta: logicalDelta,
                        allocatedDelta: allocatedDelta,
                        fileCountDelta: fileCountDelta
                    ))
                }
            }

            try execute(db, "COMMIT")
            return deltas
        } catch {
            try? execute(db, "ROLLBACK")
            throw error
        }
    }

    private func openReadWrite(_ url: URL) throws -> OpaquePointer {
        var db: OpaquePointer?
        let status = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        guard status == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            throw FileIndexError.sqlite("Could not open file index")
        }
        sqlite3_busy_timeout(db, 5_000)
        return db
    }

    private func openReadOnly(_ url: URL) throws -> OpaquePointer {
        var db: OpaquePointer?
        let status = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        guard status == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            throw FileIndexError.sqlite("Could not open file index")
        }
        sqlite3_busy_timeout(db, 5_000)
        return db
    }

    private func loadStoredRoot(_ db: OpaquePointer) throws -> String? {
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(db, "SELECT root_path FROM metadata LIMIT 1", -1, &statement, nil), db: db)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return text(statement, column: 0)
    }

    private func text(_ statement: OpaquePointer?, column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }

    private static func fnv1a64(_ value: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return hash
    }
}

public final class FileIndexWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let targetURL: URL
    private let workingURL: URL
    private let rootPath: String
    private let fullRebuild: Bool
    private let accessGate: DispatchSemaphore
    private var accessGateReleased = false
    private var db: OpaquePointer?
    private var insertStatement: OpaquePointer?
    private var completed = false

    fileprivate init(
        databaseURL: URL,
        rootPath: String,
        subtreePath: String?,
        fullRebuild: Bool
    ) throws {
        self.targetURL = databaseURL
        self.rootPath = PathUtilities.standardized(rootPath)
        self.fullRebuild = fullRebuild
        self.workingURL = fullRebuild
            ? databaseURL.deletingLastPathComponent().appendingPathComponent(".\(databaseURL.lastPathComponent).build-\(UUID().uuidString)")
            : databaseURL
        self.accessGate = FileIndexAccessCoordinator.shared.gate(for: databaseURL)
        self.accessGate.wait()
        var initializationSucceeded = false
        defer {
            if !initializationSucceeded {
                self.accessGate.signal()
            }
        }

        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if fullRebuild {
            try? FileManager.default.removeItem(at: workingURL)
        }

        let opened = try Self.open(workingURL, create: true)
        self.db = opened

        do {
            if fullRebuild {
                try execute(opened, "PRAGMA page_size=16384")
                try execute(opened, "PRAGMA journal_mode=OFF")
                try execute(opened, "PRAGMA synchronous=OFF")
                try execute(opened, "PRAGMA locking_mode=EXCLUSIVE")
                try execute(opened, "PRAGMA temp_store=MEMORY")
                try Self.createBaseSchema(opened)
                try execute(opened, "DELETE FROM metadata")
                try Self.insertMetadata(opened, rootPath: self.rootPath)
            } else {
                try execute(opened, "PRAGMA journal_mode=WAL")
                try execute(opened, "PRAGMA synchronous=NORMAL")
                try execute(opened, "PRAGMA temp_store=MEMORY")
                let storedRoot = try Self.loadStoredRoot(opened)
                guard storedRoot == self.rootPath else { throw FileIndexError.rootMismatch }
            }

            try execute(opened, "BEGIN IMMEDIATE TRANSACTION")

            if !fullRebuild, let subtreePath {
                try Self.deleteSubtree(opened, rootPath: self.rootPath, subtreePath: subtreePath)
            }

            let insertSQL = """
            INSERT OR REPLACE INTO files
                (parent_relative, name, logical_bytes, allocated_bytes)
            VALUES (?, ?, ?, ?)
            """
            try check(sqlite3_prepare_v2(opened, insertSQL, -1, &insertStatement, nil), db: opened)
        } catch {
            try? execute(opened, "ROLLBACK")
            sqlite3_close(opened)
            self.db = nil
            if fullRebuild { try? FileManager.default.removeItem(at: workingURL) }
            throw error
        }
        initializationSucceeded = true
    }

    deinit {
        cancel()
    }

    public func consume(_ files: [FileUsage]) throws {
        guard !files.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !completed, let db, let statement = insertStatement else {
            throw FileIndexError.writerClosed
        }

        for file in files {
            let parentRelative = Self.relativeParent(file.parentPath, rootPath: rootPath)
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            try bindText(parentRelative, at: 1, statement: statement, db: db)
            try bindText(file.name, at: 2, statement: statement, db: db)
            sqlite3_bind_int64(statement, 3, sqlite3_int64(clamping: file.logicalBytes))
            sqlite3_bind_int64(statement, 4, sqlite3_int64(clamping: file.allocatedBytes))
            try checkDone(sqlite3_step(statement), db: db)
        }
    }

    public func finish() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !completed, let db else { return }
        defer { releaseAccessGateIfNeeded() }
        sqlite3_finalize(insertStatement)
        insertStatement = nil

        do {
            try execute(db, "COMMIT")
            if fullRebuild {
                try Self.createSearchIndexes(db)
                try execute(db, "ANALYZE")
            }
            completed = true
            sqlite3_close(db)
            self.db = nil

            if fullRebuild {
                try Self.atomicReplace(source: workingURL, destination: targetURL)
            }
        } catch {
            try? execute(db, "ROLLBACK")
            completed = true
            sqlite3_close(db)
            self.db = nil
            if fullRebuild { try? FileManager.default.removeItem(at: workingURL) }
            throw error
        }
    }

    public func cancel() {
        lock.lock()
        defer { lock.unlock() }
        guard !completed, let db else { return }
        defer { releaseAccessGateIfNeeded() }
        sqlite3_finalize(insertStatement)
        insertStatement = nil
        try? execute(db, "ROLLBACK")
        completed = true
        sqlite3_close(db)
        self.db = nil
        if fullRebuild { try? FileManager.default.removeItem(at: workingURL) }
    }

    private func releaseAccessGateIfNeeded() {
        guard !accessGateReleased else { return }
        accessGateReleased = true
        accessGate.signal()
    }

    private static func open(_ url: URL, create: Bool) throws -> OpaquePointer {
        var db: OpaquePointer?
        let flags = create
            ? SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
            : SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let status = sqlite3_open_v2(url.path, &db, flags, nil)
        guard status == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            throw FileIndexError.sqlite("Could not open file index")
        }
        return db
    }

    private static func createBaseSchema(_ db: OpaquePointer) throws {
        try execute(db, """
        CREATE TABLE IF NOT EXISTS metadata (
            root_path TEXT NOT NULL
        )
        """)
        try execute(db, """
        CREATE TABLE IF NOT EXISTS files (
            id INTEGER PRIMARY KEY,
            parent_relative TEXT NOT NULL,
            name TEXT NOT NULL,
            logical_bytes INTEGER NOT NULL,
            allocated_bytes INTEGER NOT NULL
        )
        """)
    }

    private static func createSearchIndexes(_ db: OpaquePointer) throws {
        try execute(db, "CREATE UNIQUE INDEX IF NOT EXISTS files_parent_name ON files(parent_relative, name)")
        try execute(db, "CREATE INDEX IF NOT EXISTS files_allocated ON files(allocated_bytes DESC)")
        try execute(db, """
        CREATE VIRTUAL TABLE IF NOT EXISTS files_fts
        USING fts5(name, content='files', content_rowid='id', tokenize='trigram')
        """)
        try execute(db, "INSERT INTO files_fts(files_fts) VALUES('rebuild')")
        try execute(db, """
        CREATE TRIGGER IF NOT EXISTS files_ai AFTER INSERT ON files BEGIN
            INSERT INTO files_fts(rowid, name) VALUES (new.id, new.name);
        END
        """)
        try execute(db, """
        CREATE TRIGGER IF NOT EXISTS files_ad AFTER DELETE ON files BEGIN
            INSERT INTO files_fts(files_fts, rowid, name) VALUES ('delete', old.id, old.name);
        END
        """)
        try execute(db, """
        CREATE TRIGGER IF NOT EXISTS files_au AFTER UPDATE ON files BEGIN
            INSERT INTO files_fts(files_fts, rowid, name) VALUES ('delete', old.id, old.name);
            INSERT INTO files_fts(rowid, name) VALUES (new.id, new.name);
        END
        """)
    }

    private static func insertMetadata(_ db: OpaquePointer, rootPath: String) throws {
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(db, "INSERT INTO metadata(root_path) VALUES (?)", -1, &statement, nil), db: db)
        defer { sqlite3_finalize(statement) }
        try bindText(rootPath, at: 1, statement: statement, db: db)
        try checkDone(sqlite3_step(statement), db: db)
    }

    private static func loadStoredRoot(_ db: OpaquePointer) throws -> String? {
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(db, "SELECT root_path FROM metadata LIMIT 1", -1, &statement, nil), db: db)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_text(statement, 0).map { String(cString: $0) }
    }

    private static func deleteSubtree(_ db: OpaquePointer, rootPath: String, subtreePath: String) throws {
        let subtree = PathUtilities.standardized(subtreePath)
        let root = PathUtilities.standardized(rootPath)
        let relative: String
        if subtree == root {
            relative = ""
        } else {
            guard PathUtilities.isDescendantOrEqual(subtree, of: root) else {
                throw FileIndexError.pathOutsideRoot(subtree)
            }
            relative = String(subtree.dropFirst(root.count + 1))
        }

        if relative.isEmpty {
            try execute(db, "DELETE FROM files")
            return
        }

        let lower = relative + "/"
        let upper = lower + "\u{10FFFF}"
        let sql = "DELETE FROM files WHERE parent_relative = ? OR (parent_relative >= ? AND parent_relative < ?)"
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(db, sql, -1, &statement, nil), db: db)
        defer { sqlite3_finalize(statement) }
        try bindText(relative, at: 1, statement: statement, db: db)
        try bindText(lower, at: 2, statement: statement, db: db)
        try bindText(upper, at: 3, statement: statement, db: db)
        try checkDone(sqlite3_step(statement), db: db)
    }

    private static func relativeParent(_ parentPath: String, rootPath: String) -> String {
        let parent = PathUtilities.standardized(parentPath)
        if parent == rootPath { return "" }
        guard PathUtilities.isDescendantOrEqual(parent, of: rootPath) else { return parent }
        return String(parent.dropFirst(rootPath.count + 1))
    }

    private static func atomicReplace(source: URL, destination: URL) throws {
        let destinationPath = destination.path
        unlink(destinationPath + "-wal")
        unlink(destinationPath + "-shm")
        let status = source.path.withCString { sourcePointer in
            destinationPath.withCString { destinationPointer in
                rename(sourcePointer, destinationPointer)
            }
        }
        guard status == 0 else {
            throw FileIndexError.posix(errno)
        }
    }
}

public enum FileIndexError: Error, CustomStringConvertible {
    case sqlite(String)
    case writerClosed
    case missingIndex
    case rootMismatch
    case pathOutsideRoot(String)
    case posix(Int32)

    public var description: String {
        switch self {
        case .sqlite(let message): return "SQLite file index error: \(message)"
        case .writerClosed: return "File index writer is already closed"
        case .missingIndex: return "No file index exists for this root"
        case .rootMismatch: return "File index root does not match"
        case .pathOutsideRoot(let path): return "File index path is outside the root: \(path)"
        case .posix(let code): return "File index filesystem error: \(String(cString: strerror(code)))"
        }
    }
}

private func execute(_ db: OpaquePointer, _ sql: String) throws {
    var errorMessage: UnsafeMutablePointer<CChar>?
    let status = sqlite3_exec(db, sql, nil, nil, &errorMessage)
    guard status == SQLITE_OK else {
        let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
        sqlite3_free(errorMessage)
        throw FileIndexError.sqlite(message)
    }
}

private func bindText(_ value: String, at index: Int32, statement: OpaquePointer?, db: OpaquePointer) throws {
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    try check(sqlite3_bind_text(statement, index, value, -1, transient), db: db)
}

private func checkDone(_ status: Int32, db: OpaquePointer) throws {
    guard status == SQLITE_DONE else {
        try check(status, db: db)
        return
    }
}

private func check(_ status: Int32, db: OpaquePointer) throws {
    guard status == SQLITE_OK else {
        throw FileIndexError.sqlite(String(cString: sqlite3_errmsg(db)))
    }
}
