import Foundation
import SQLite3

/// A value bindable to / readable from a prepared statement. Keeps
/// `SQLiteDatabase`'s public surface free of the C API's raw pointer types.
enum SQLiteValue: Sendable, Equatable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
}

/// `sqlite3_bind_text`/`_blob` need a destructor telling SQLite to copy the
/// bytes rather than assume they outlive the call; `SQLITE_TRANSIENT` is a
/// C macro that doesn't import, so it's reconstructed here. `nonisolated(unsafe)`
/// opts this immutable, file-scope constant out of the project's default
/// main-actor isolation — `SQLiteDatabase.bind` (actor-isolated, not main
/// actor) reads it, and as a `let` it's safe to touch from any context.
private nonisolated(unsafe) let sqliteTransientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// An **actor** wrapping one SQLite connection via the C API. The
/// `OpaquePointer` connection handle and the prepared-statement cache are
/// actor-confined state — every open/prepare/step/finalize call is
/// serialized through the actor's executor, which is what satisfies Swift 6
/// strict concurrency here without `@unchecked Sendable`: nothing
/// non-`Sendable` ever crosses the actor boundary, it just never leaves.
///
/// Deliberately generic (no notion of documents/chunks/migrations content) —
/// `SearchIndex` owns the schema; this type only owns "run SQL safely."
actor SQLiteDatabase {
    enum DatabaseError: LocalizedError, Equatable {
        case openFailed(String)
        case prepareFailed(String)
        case bindFailed(String)
        case stepFailed(String)

        var errorDescription: String? {
            switch self {
            case .openFailed(let message): "Couldn't open the search database: \(message)"
            case .prepareFailed(let message): "Couldn't prepare a search database statement: \(message)"
            case .bindFailed(let message): "Couldn't bind search database parameters: \(message)"
            case .stepFailed(let message): "Search database statement failed: \(message)"
            }
        }
    }

    // `nonisolated(unsafe)` here isn't a Sendable escape hatch for cross-actor
    // sharing — both properties stay private and are only ever touched from
    // this actor's isolated methods. It's needed solely because `deinit` is
    // always nonisolated, and by the time it runs there are (by definition)
    // no other references to synchronize against, so direct access is safe.
    private nonisolated(unsafe) let handle: OpaquePointer
    /// Prepared statements are reused by SQL text — `SearchIndex` calls the
    /// same handful of statements repeatedly (upsert, lookup, search), and
    /// re-preparing every call is pure overhead `sqlite3_reset` avoids.
    private nonisolated(unsafe) var statementCache: [String: OpaquePointer] = [:]

    /// - Parameter path: a filesystem path, or `":memory:"` for an ephemeral
    ///   database (used by tests).
    init(path: String) throws {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let openResult = sqlite3_open_v2(path, &db, flags, nil)
        guard openResult == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite3_open_v2 returned \(openResult)"
            if let db { sqlite3_close(db) }
            throw DatabaseError.openFailed(message)
        }
        handle = db

        // WAL for concurrent-reader-friendly writes; errors here are
        // non-fatal (e.g. exotic filesystems that don't support WAL fall
        // back to the default journal mode automatically).
        sqlite3_exec(db, "PRAGMA journal_mode = WAL;", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA foreign_keys = ON;", nil, nil, nil)
    }

    deinit {
        for (_, statement) in statementCache {
            sqlite3_finalize(statement)
        }
        sqlite3_close(handle)
    }

    /// Runs a statement that doesn't return rows (DDL, INSERT/UPDATE/DELETE,
    /// `BEGIN`/`COMMIT`/`ROLLBACK`, `PRAGMA` sets).
    func execute(_ sql: String, params: [SQLiteValue] = []) throws {
        let statement = try prepared(for: sql)
        defer { sqlite3_reset(statement) }
        try bind(params, to: statement)
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            throw DatabaseError.stepFailed(lastErrorMessage())
        }
    }

    /// Runs a `SELECT` and returns every row as an array of column values.
    func query(_ sql: String, params: [SQLiteValue] = []) throws -> [[SQLiteValue]] {
        let statement = try prepared(for: sql)
        defer { sqlite3_reset(statement) }
        try bind(params, to: statement)
        var rows: [[SQLiteValue]] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_ROW {
                rows.append(readRow(statement))
            } else if result == SQLITE_DONE {
                break
            } else {
                throw DatabaseError.stepFailed(lastErrorMessage())
            }
        }
        return rows
    }

    /// The `user_version` pragma — the migration cursor. `SearchIndex` reads
    /// this to decide which versioned DDL still needs to run.
    func currentUserVersion() throws -> Int32 {
        let rows = try query("PRAGMA user_version;")
        guard case .integer(let version)? = rows.first?.first else { return 0 }
        return Int32(version)
    }

    /// `PRAGMA user_version` doesn't accept bound parameters; `version` is
    /// always caller-controlled (never user input), so interpolation is safe.
    func setUserVersion(_ version: Int32) throws {
        try execute("PRAGMA user_version = \(version);")
    }

    /// Attempts to create and drop a throwaway FTS5 virtual table. Returns
    /// `false` (never throws) so callers can surface FTS5 absence as health
    /// rather than a crash — real absence, a read-only database, or any
    /// other prepare/step failure all report the same "not available" state.
    func probeFTS5() -> Bool {
        do {
            try execute("CREATE VIRTUAL TABLE IF NOT EXISTS temp.__sqlitedatabase_fts5_probe USING fts5(x);")
            try execute("DROP TABLE IF EXISTS temp.__sqlitedatabase_fts5_probe;")
            return true
        } catch {
            return false
        }
    }

    // MARK: - Private

    private func prepared(for sql: String) throws -> OpaquePointer {
        if let cached = statementCache[sql] {
            sqlite3_reset(cached)
            sqlite3_clear_bindings(cached)
            return cached
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw DatabaseError.prepareFailed(lastErrorMessage())
        }
        statementCache[sql] = statement
        return statement
    }

    private func bind(_ params: [SQLiteValue], to statement: OpaquePointer) throws {
        for (offset, value) in params.enumerated() {
            let position = Int32(offset + 1)
            let result: Int32
            switch value {
            case .null:
                result = sqlite3_bind_null(statement, position)
            case .integer(let intValue):
                result = sqlite3_bind_int64(statement, position, intValue)
            case .real(let doubleValue):
                result = sqlite3_bind_double(statement, position, doubleValue)
            case .text(let stringValue):
                result = sqlite3_bind_text(statement, position, stringValue, -1, sqliteTransientDestructor)
            case .blob(let data):
                result = data.withUnsafeBytes { rawBuffer -> Int32 in
                    sqlite3_bind_blob(statement, position, rawBuffer.baseAddress, Int32(data.count), sqliteTransientDestructor)
                }
            }
            guard result == SQLITE_OK else {
                throw DatabaseError.bindFailed(lastErrorMessage())
            }
        }
    }

    private func readRow(_ statement: OpaquePointer) -> [SQLiteValue] {
        let columnCount = sqlite3_column_count(statement)
        var values: [SQLiteValue] = []
        values.reserveCapacity(Int(columnCount))
        for index in 0..<columnCount {
            switch sqlite3_column_type(statement, index) {
            case SQLITE_INTEGER:
                values.append(.integer(sqlite3_column_int64(statement, index)))
            case SQLITE_FLOAT:
                values.append(.real(sqlite3_column_double(statement, index)))
            case SQLITE_TEXT:
                if let text = sqlite3_column_text(statement, index) {
                    values.append(.text(String(cString: text)))
                } else {
                    values.append(.text(""))
                }
            case SQLITE_BLOB:
                if let bytes = sqlite3_column_blob(statement, index) {
                    let count = Int(sqlite3_column_bytes(statement, index))
                    values.append(.blob(Data(bytes: bytes, count: count)))
                } else {
                    values.append(.blob(Data()))
                }
            default:
                values.append(.null)
            }
        }
        return values
    }

    private func lastErrorMessage() -> String {
        String(cString: sqlite3_errmsg(handle))
    }
}
