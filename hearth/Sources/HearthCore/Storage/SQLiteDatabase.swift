import CSQLite
import Foundation

public enum SQLValue: Sendable, Equatable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
}

extension SQLValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral value: String) { self = .text(value) }
    public init(integerLiteral value: Int64) { self = .int(value) }
    public init(nilLiteral: ()) { self = .null }
}

public extension SQLValue {
    static func optionalText(_ s: String?) -> SQLValue { s.map(SQLValue.text) ?? .null }
    static func bool(_ b: Bool) -> SQLValue { .int(b ? 1 : 0) }
}

public struct SQLRow: Sendable {
    public let columns: [String: SQLValue]

    public func string(_ name: String) -> String? {
        if case .text(let s) = columns[name] { return s }
        return nil
    }
    public func int(_ name: String) -> Int64? {
        switch columns[name] {
        case .int(let i): return i
        case .double(let d): return Int64(d)
        default: return nil
        }
    }
    public func double(_ name: String) -> Double? {
        switch columns[name] {
        case .double(let d): return d
        case .int(let i): return Double(i)
        default: return nil
        }
    }
    public func data(_ name: String) -> Data? {
        switch columns[name] {
        case .blob(let d): return d
        case .text(let s): return Data(s.utf8)
        default: return nil
        }
    }
    public func bool(_ name: String) -> Bool { (int(name) ?? 0) != 0 }
}

public struct SQLiteError: Error, CustomStringConvertible {
    public let code: Int32
    public let message: String
    public var description: String { "SQLite error \(code): \(message)" }
}

/// Thin, thread-safe SQLite wrapper. All access is serialized through a recursive lock so
/// transactions can nest via savepoints.
public final class SQLiteDatabase: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let lock = NSRecursiveLock()
    private var transactionDepth = 0
    public let path: String

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(path: String) throws {
        self.path = path
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unable to open"
            sqlite3_close(db)
            throw SQLiteError(code: rc, message: msg)
        }
        handle = db
        sqlite3_busy_timeout(db, 5_000)
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA foreign_keys = ON")
        try execute("PRAGMA secure_delete = ON")
    }

    deinit { close() }

    public func close() {
        lock.lock(); defer { lock.unlock() }
        if let handle { sqlite3_close_v2(handle) }
        handle = nil
    }

    private func error(_ rc: Int32) -> SQLiteError {
        SQLiteError(code: rc, message: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "closed")
    }

    public func execute(_ sql: String, _ params: [SQLValue] = []) throws {
        _ = try query(sql, params)
    }

    /// Executes a script of several statements with no parameters.
    public func executeScript(_ sql: String) throws {
        lock.lock(); defer { lock.unlock() }
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(err)
            throw SQLiteError(code: rc, message: msg)
        }
    }

    @discardableResult
    public func query(_ sql: String, _ params: [SQLValue] = []) throws -> [SQLRow] {
        lock.lock(); defer { lock.unlock() }
        guard let handle else { throw SQLiteError(code: SQLITE_MISUSE, message: "database closed") }
        var stmt: OpaquePointer?
        var rc = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK else { throw error(rc) }
        defer { sqlite3_finalize(stmt) }

        for (i, value) in params.enumerated() {
            let idx = Int32(i + 1)
            switch value {
            case .null: rc = sqlite3_bind_null(stmt, idx)
            case .int(let v): rc = sqlite3_bind_int64(stmt, idx, v)
            case .double(let v): rc = sqlite3_bind_double(stmt, idx, v)
            case .text(let v): rc = sqlite3_bind_text(stmt, idx, v, -1, Self.transient)
            case .blob(let v):
                if v.isEmpty {
                    rc = sqlite3_bind_zeroblob(stmt, idx, 0)
                } else {
                    rc = v.withUnsafeBytes { sqlite3_bind_blob(stmt, idx, $0.baseAddress, Int32(v.count), Self.transient) }
                }
            }
            guard rc == SQLITE_OK else { throw error(rc) }
        }

        var rows: [SQLRow] = []
        while true {
            rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw error(rc) }
            var cols: [String: SQLValue] = [:]
            for c in 0..<sqlite3_column_count(stmt) {
                let name = String(cString: sqlite3_column_name(stmt, c))
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_INTEGER: cols[name] = .int(sqlite3_column_int64(stmt, c))
                case SQLITE_FLOAT: cols[name] = .double(sqlite3_column_double(stmt, c))
                case SQLITE_TEXT: cols[name] = .text(String(cString: sqlite3_column_text(stmt, c)))
                case SQLITE_BLOB:
                    let n = Int(sqlite3_column_bytes(stmt, c))
                    if n > 0, let p = sqlite3_column_blob(stmt, c) {
                        cols[name] = .blob(Data(bytes: p, count: n))
                    } else {
                        cols[name] = .blob(Data())
                    }
                default: cols[name] = .null
                }
            }
            rows.append(SQLRow(columns: cols))
        }
        return rows
    }

    public func transaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        let savepoint = "sp\(transactionDepth)"
        if transactionDepth == 0 {
            try executeScript("BEGIN IMMEDIATE")
        } else {
            try executeScript("SAVEPOINT \(savepoint)")
        }
        transactionDepth += 1
        do {
            let result = try body()
            transactionDepth -= 1
            try executeScript(transactionDepth == 0 ? "COMMIT" : "RELEASE \(savepoint)")
            return result
        } catch {
            transactionDepth -= 1
            if transactionDepth == 0 {
                try? executeScript("ROLLBACK")
            } else {
                try? executeScript("ROLLBACK TO \(savepoint); RELEASE \(savepoint)")
            }
            throw error
        }
    }

    /// Writes a consistent snapshot of the database to `url` (used by backup).
    public func snapshot(to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        try execute("VACUUM INTO ?", [.text(url.path)])
    }

    public func integrityCheck() throws -> Bool {
        try query("PRAGMA integrity_check").first?.string("integrity_check") == "ok"
    }
}
