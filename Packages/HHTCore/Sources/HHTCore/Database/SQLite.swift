import Foundation
import SQLite3

/// A value that can be bound to, or read from, a SQLite statement.
public enum SQLValue: Equatable, CustomStringConvertible {
    case null
    case int(Int64)
    case double(Double)
    case text(String)

    public var description: String {
        switch self {
        case .null: return ""
        case .int(let v): return String(v)
        case .double(let v): return String(v)
        case .text(let v): return v
        }
    }
}

public protocol SQLBindable {
    var sqlValue: SQLValue { get }
}

extension Int: SQLBindable { public var sqlValue: SQLValue { .int(Int64(self)) } }
extension Int64: SQLBindable { public var sqlValue: SQLValue { .int(self) } }
extension Double: SQLBindable { public var sqlValue: SQLValue { .double(self) } }
extension String: SQLBindable { public var sqlValue: SQLValue { .text(self) } }
extension Bool: SQLBindable { public var sqlValue: SQLValue { .int(self ? 1 : 0) } }
extension Date: SQLBindable { public var sqlValue: SQLValue { .double(timeIntervalSince1970) } }
extension SQLValue: SQLBindable { public var sqlValue: SQLValue { self } }
extension Optional: SQLBindable where Wrapped: SQLBindable {
    public var sqlValue: SQLValue {
        switch self {
        case .none: return .null
        case .some(let w): return w.sqlValue
        }
    }
}

public struct SQLiteError: Error, CustomStringConvertible {
    public let code: Int32
    public let message: String
    public let sql: String?
    public var description: String { "SQLite error \(code): \(message)" + (sql.map { " [\($0)]" } ?? "") }
}

/// One result row, addressable by column name.
public struct Row {
    public let columns: [String: SQLValue]

    public subscript(_ name: String) -> SQLValue { columns[name] ?? .null }

    public func string(_ name: String) -> String? {
        switch self[name] {
        case .text(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .null: return nil
        }
    }
    public func double(_ name: String) -> Double? {
        switch self[name] {
        case .double(let d): return d
        case .int(let i): return Double(i)
        case .text(let s): return Double(s)
        case .null: return nil
        }
    }
    public func int(_ name: String) -> Int? {
        switch self[name] {
        case .int(let i): return Int(i)
        case .double(let d): return Int(d)
        case .text(let s): return Int(s)
        case .null: return nil
        }
    }
    public func bool(_ name: String) -> Bool { (int(name) ?? 0) != 0 }
    public func date(_ name: String) -> Date? { double(name).map { Date(timeIntervalSince1970: $0) } }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Minimal thread-safe wrapper around the system SQLite library. No third-party dependencies.
public final class SQLiteConnection: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let lock = NSRecursiveLock()
    public let path: String

    public init(path: String) throws {
        self.path = path
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &handle, flags, nil)
        guard rc == SQLITE_OK else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(handle)
            throw SQLiteError(code: rc, message: msg, sql: nil)
        }
        try execute("PRAGMA foreign_keys = ON")
        if path != ":memory:" {
            try execute("PRAGMA journal_mode = WAL")
        }
        try execute("PRAGMA synchronous = NORMAL")
    }

    deinit { sqlite3_close_v2(handle) }

    private func error(_ rc: Int32, _ sql: String?) -> SQLiteError {
        SQLiteError(code: rc, message: String(cString: sqlite3_errmsg(handle)), sql: sql)
    }

    /// Execute one or more statements with no bindings and no results.
    public func execute(_ sql: String) throws {
        lock.lock(); defer { lock.unlock() }
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(err)
            throw SQLiteError(code: rc, message: msg, sql: sql)
        }
    }

    private func prepare(_ sql: String, _ args: [SQLBindable]) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK else { throw error(rc, sql) }
        for (i, arg) in args.enumerated() {
            let idx = Int32(i + 1)
            let r: Int32
            switch arg.sqlValue {
            case .null: r = sqlite3_bind_null(stmt, idx)
            case .int(let v): r = sqlite3_bind_int64(stmt, idx, v)
            case .double(let v): r = sqlite3_bind_double(stmt, idx, v)
            case .text(let v): r = sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT)
            }
            guard r == SQLITE_OK else { sqlite3_finalize(stmt); throw error(r, sql) }
        }
        return stmt
    }

    /// Run a statement that returns no rows (INSERT/UPDATE/DELETE).
    @discardableResult
    public func run(_ sql: String, _ args: SQLBindable...) throws -> Int {
        try run(sql, args)
    }

    @discardableResult
    public func run(_ sql: String, _ args: [SQLBindable]) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        let stmt = try prepare(sql, args)
        defer { sqlite3_finalize(stmt) }
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW { rc = sqlite3_step(stmt) }
        guard rc == SQLITE_DONE else { throw error(rc, sql) }
        return Int(sqlite3_changes(handle))
    }

    public func query(_ sql: String, _ args: SQLBindable...) throws -> [Row] {
        try query(sql, args)
    }

    public func query(_ sql: String, _ args: [SQLBindable]) throws -> [Row] {
        lock.lock(); defer { lock.unlock() }
        let stmt = try prepare(sql, args)
        defer { sqlite3_finalize(stmt) }
        var rows: [Row] = []
        let n = sqlite3_column_count(stmt)
        let names = (0..<n).map { String(cString: sqlite3_column_name(stmt, $0)) }
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw error(rc, sql) }
            var cols: [String: SQLValue] = [:]
            for i in 0..<n {
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER: cols[names[Int(i)]] = .int(sqlite3_column_int64(stmt, i))
                case SQLITE_FLOAT: cols[names[Int(i)]] = .double(sqlite3_column_double(stmt, i))
                case SQLITE_TEXT: cols[names[Int(i)]] = .text(String(cString: sqlite3_column_text(stmt, i)))
                default: cols[names[Int(i)]] = .null
                }
            }
            rows.append(Row(columns: cols))
        }
        return rows
    }

    /// Column names of a query result, in order (works for empty results too).
    public func columnNames(_ sql: String) throws -> [String] {
        lock.lock(); defer { lock.unlock() }
        let stmt = try prepare(sql, [])
        defer { sqlite3_finalize(stmt) }
        let n = sqlite3_column_count(stmt)
        return (0..<n).map { String(cString: sqlite3_column_name(stmt, $0)) }
    }

    public func scalar(_ sql: String, _ args: SQLBindable...) throws -> SQLValue {
        let rows = try query(sql, args)
        return rows.first?.columns.values.first ?? .null
    }

    /// Run `body` inside a transaction; rolls back if it throws. Nested calls use savepoints.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        let name = "sp_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        try execute("SAVEPOINT \(name)")
        do {
            let result = try body()
            try execute("RELEASE \(name)")
            return result
        } catch {
            try? execute("ROLLBACK TO \(name)")
            try? execute("RELEASE \(name)")
            throw error
        }
    }

    public var lastInsertRowID: Int64 {
        lock.lock(); defer { lock.unlock() }
        return sqlite3_last_insert_rowid(handle)
    }

    public var userVersion: Int {
        get { (try? query("PRAGMA user_version").first?.int("user_version")) ?? 0 }
    }

    public func setUserVersion(_ v: Int) throws { try execute("PRAGMA user_version = \(v)") }
}
