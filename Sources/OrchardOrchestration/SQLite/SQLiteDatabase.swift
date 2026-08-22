import Foundation
import SQLite3

/// Error surfaced by the SQLite wrapper. Carries the SQLite message so store-level
/// failures (constraint violations, misuse) are debuggable without a debugger attached.
public struct SQLiteError: Error, CustomStringConvertible, Sendable {
    public let message: String
    public let code: Int32

    public init(message: String, code: Int32 = SQLITE_ERROR) {
        self.message = message
        self.code = code
    }

    public var description: String { "SQLite error \(code): \(message)" }
}

/// A dynamically typed SQLite value — the only currency crossing the C boundary.
public enum SQLiteValue: Equatable, Sendable {
    case null
    case int(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    /// `.text` for a present string, `.null` otherwise — the common optional-column bind.
    public static func maybeText(_ value: String?) -> SQLiteValue {
        value.map { .text($0) } ?? .null
    }

    public static func maybeInt(_ value: Int?) -> SQLiteValue {
        value.map { .int(Int64($0)) } ?? .null
    }
}

/// One result row, keyed by column name, with throwing typed accessors.
///
/// Accessors throw instead of force-unwrapping so a schema drift (renamed column, NULL
/// where NOT NULL was assumed) surfaces as a diagnosable error, never a crash.
public struct SQLiteRow {
    private let values: [String: SQLiteValue]

    init(values: [String: SQLiteValue]) {
        self.values = values
    }

    public func text(_ column: String) throws -> String {
        guard case .text(let value)? = values[column] else {
            throw SQLiteError(message: "Column '\(column)' is not TEXT (row: \(values.keys.sorted()))")
        }
        return value
    }

    public func textOrNil(_ column: String) throws -> String? {
        switch values[column] {
        case .text(let value)?: return value
        case .null?, nil: return nil
        default:
            throw SQLiteError(message: "Column '\(column)' is not TEXT or NULL")
        }
    }

    public func int(_ column: String) throws -> Int {
        guard case .int(let value)? = values[column] else {
            throw SQLiteError(message: "Column '\(column)' is not INTEGER")
        }
        return Int(value)
    }

    public func intOrNil(_ column: String) throws -> Int? {
        switch values[column] {
        case .int(let value)?: return Int(value)
        case .null?, nil: return nil
        default:
            throw SQLiteError(message: "Column '\(column)' is not INTEGER or NULL")
        }
    }

    public func value(_ column: String) -> SQLiteValue? {
        values[column]
    }
}

/// Thin typed wrapper over the system `SQLite3` C API (docs/REBUILD-PLAN.md T1: no
/// external SQLite dependency). Opens in WAL mode; all multi-statement writes go through
/// `inTransaction`/`inSavepoint` so a mid-operation failure can never leave half a write.
///
/// Not thread-safe by design: the orchestration store confines the connection to one
/// caller at a time (the runtime serializes RPC handling). WAL + busy_timeout make a
/// second process reading the same file (e.g. a debugging `sqlite3` shell) safe.
public final class SQLiteDatabase {
    private var handle: OpaquePointer?

    /// `sqlite3_bind_text` must copy the Swift string's transient buffer.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(path: String) throws {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, let opened = db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unable to open \(path)"
            sqlite3_close(db)
            throw SQLiteError(message: message)
        }
        handle = opened
        try exec("PRAGMA journal_mode=WAL")
        try exec("PRAGMA busy_timeout=5000")
        try exec("PRAGMA synchronous=NORMAL")
    }

    deinit {
        close()
    }

    public func close() {
        if let handle {
            sqlite3_close_v2(handle)
        }
        handle = nil
    }

    private func requireHandle() throws -> OpaquePointer {
        guard let handle else { throw SQLiteError(message: "database is closed") }
        return handle
    }

    private func lastErrorMessage() -> String {
        handle.map { String(cString: sqlite3_errmsg($0)) } ?? "database is closed"
    }

    /// Run one or more semicolon-separated statements with no parameters (DDL, pragmas,
    /// BEGIN/COMMIT).
    public func exec(_ sql: String) throws {
        let db = try requireHandle()
        var errorPointer: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errorPointer) == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? lastErrorMessage()
            sqlite3_free(errorPointer)
            throw SQLiteError(message: "\(message) — in SQL: \(sql.prefix(200))")
        }
    }

    /// Execute a parameterized statement that returns no rows; returns the change count.
    @discardableResult
    public func run(_ sql: String, _ params: [SQLiteValue] = []) throws -> Int {
        let db = try requireHandle()
        let statement = try prepare(sql, params)
        defer { sqlite3_finalize(statement) }
        let stepResult = sqlite3_step(statement)
        guard stepResult == SQLITE_DONE || stepResult == SQLITE_ROW else {
            throw SQLiteError(message: "\(lastErrorMessage()) — in SQL: \(sql.prefix(200))", code: stepResult)
        }
        return Int(sqlite3_changes(db))
    }

    /// Execute a parameterized query and materialize every row.
    public func query(_ sql: String, _ params: [SQLiteValue] = []) throws -> [SQLiteRow] {
        let statement = try prepare(sql, params)
        defer { sqlite3_finalize(statement) }
        var rows: [SQLiteRow] = []
        while true {
            let stepResult = sqlite3_step(statement)
            if stepResult == SQLITE_DONE { break }
            guard stepResult == SQLITE_ROW else {
                throw SQLiteError(message: "\(lastErrorMessage()) — in SQL: \(sql.prefix(200))", code: stepResult)
            }
            rows.append(readRow(statement))
        }
        return rows
    }

    /// First row of a query, or nil.
    public func queryOne(_ sql: String, _ params: [SQLiteValue] = []) throws -> SQLiteRow? {
        try query(sql, params).first
    }

    /// Run `body` inside `BEGIN IMMEDIATE … COMMIT`, rolling back on a thrown error.
    /// IMMEDIATE takes the write lock up front so a mid-transaction upgrade can't deadlock
    /// against another writer. Do not nest; use `inSavepoint` for inner scopes.
    public func inTransaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try exec("COMMIT")
            return result
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Run `body` inside a named savepoint. Nests freely and works both inside a
    /// transaction and standalone (SQLite treats an outermost savepoint as a transaction).
    public func inSavepoint<T>(_ name: String, _ body: () throws -> T) throws -> T {
        try exec("SAVEPOINT \(name)")
        do {
            let result = try body()
            try exec("RELEASE \(name)")
            return result
        } catch {
            try? exec("ROLLBACK TO \(name)")
            try? exec("RELEASE \(name)")
            throw error
        }
    }

    // MARK: - Internals

    private func prepare(_ sql: String, _ params: [SQLiteValue]) throws -> OpaquePointer {
        let db = try requireHandle()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let prepared = statement else {
            throw SQLiteError(message: "\(lastErrorMessage()) — in SQL: \(sql.prefix(200))")
        }
        for (index, value) in params.enumerated() {
            let slot = Int32(index + 1)
            let bindResult: Int32
            switch value {
            case .null:
                bindResult = sqlite3_bind_null(prepared, slot)
            case .int(let intValue):
                bindResult = sqlite3_bind_int64(prepared, slot, intValue)
            case .real(let realValue):
                bindResult = sqlite3_bind_double(prepared, slot, realValue)
            case .text(let textValue):
                bindResult = sqlite3_bind_text(prepared, slot, textValue, -1, Self.transient)
            case .blob(let data):
                bindResult = data.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(prepared, slot, bytes.baseAddress, Int32(bytes.count), Self.transient)
                }
            }
            guard bindResult == SQLITE_OK else {
                sqlite3_finalize(prepared)
                throw SQLiteError(message: "bind failed at index \(index + 1): \(lastErrorMessage())")
            }
        }
        return prepared
    }

    private func readRow(_ statement: OpaquePointer) -> SQLiteRow {
        var values: [String: SQLiteValue] = [:]
        let columnCount = sqlite3_column_count(statement)
        for index in 0..<columnCount {
            let name = String(cString: sqlite3_column_name(statement, index))
            switch sqlite3_column_type(statement, index) {
            case SQLITE_INTEGER:
                values[name] = .int(sqlite3_column_int64(statement, index))
            case SQLITE_FLOAT:
                values[name] = .real(sqlite3_column_double(statement, index))
            case SQLITE_TEXT:
                values[name] = .text(String(cString: sqlite3_column_text(statement, index)))
            case SQLITE_BLOB:
                if let pointer = sqlite3_column_blob(statement, index) {
                    let count = Int(sqlite3_column_bytes(statement, index))
                    values[name] = .blob(Data(bytes: pointer, count: count))
                } else {
                    values[name] = .blob(Data())
                }
            default:
                values[name] = .null
            }
        }
        return SQLiteRow(values: values)
    }
}
