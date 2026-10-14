import Foundation
import SQLite3

public struct SQLiteError: Error, CustomStringConvertible, Sendable {
    public let code: Int32
    public let message: String
    public var description: String { "SQLite error \(code): \(message)" }
}

/// SQL 参数与结果值。
public enum SQLValue: Equatable, Sendable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)

    public var int: Int64? { if case .int(let v) = self { return v }; return nil }
    public var double: Double? {
        switch self {
        case .double(let v): return v
        case .int(let v): return Double(v)
        default: return nil
        }
    }
    public var text: String? { if case .text(let v) = self { return v }; return nil }
}

public protocol SQLBindable { var sqlValue: SQLValue { get } }
extension Int: SQLBindable { public var sqlValue: SQLValue { .int(Int64(self)) } }
extension Int64: SQLBindable { public var sqlValue: SQLValue { .int(self) } }
extension Double: SQLBindable { public var sqlValue: SQLValue { .double(self) } }
extension String: SQLBindable { public var sqlValue: SQLValue { .text(self) } }
extension Bool: SQLBindable { public var sqlValue: SQLValue { .int(self ? 1 : 0) } }
extension SQLValue: SQLBindable { public var sqlValue: SQLValue { self } }
extension Optional: SQLBindable where Wrapped: SQLBindable {
    public var sqlValue: SQLValue { self?.sqlValue ?? .null }
}

public struct Row: Sendable {
    public let values: [String: SQLValue]
    public subscript(_ column: String) -> SQLValue { values[column] ?? .null }
    public func int(_ c: String) -> Int64 { self[c].int ?? 0 }
    public func string(_ c: String) -> String { self[c].text ?? "" }
    public func optionalString(_ c: String) -> String? { self[c].text }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// 极简 SQLite 封装：串行队列保证线程安全。
public final class SQLiteConnection: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let queue = DispatchQueue(label: "app.globtype.sqlite")
    private let queueKey = DispatchSpecificKey<Void>()

    /// path 为 nil 时使用内存数据库（测试用）。
    public init(path: String?) throws {
        let target = path ?? ":memory:"
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(target, &handle, flags, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(handle)
            throw SQLiteError(code: -1, message: message)
        }
        queue.setSpecific(key: queueKey, value: ())
        try execute("PRAGMA foreign_keys = ON")
        if path != nil { try execute("PRAGMA journal_mode = WAL") }
    }

    /// 以只读方式打开（词典使用）。
    public init(readOnlyPath path: String) throws {
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            throw SQLiteError(code: -1, message: "无法打开 \(path)")
        }
        queue.setSpecific(key: queueKey, value: ())
    }

    deinit { sqlite3_close(handle) }

    private func sync<T>(_ work: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil { return try work() }
        return try queue.sync(execute: work)
    }

    private func error() -> SQLiteError {
        SQLiteError(code: sqlite3_errcode(handle), message: String(cString: sqlite3_errmsg(handle)))
    }

    /// 执行一条或多条不带参数的语句。
    public func execute(_ sql: String) throws {
        try sync {
            guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw error() }
        }
    }

    @discardableResult
    public func run(_ sql: String, _ args: [SQLBindable] = []) throws -> Int {
        try sync {
            let stmt = try prepare(sql, args)
            defer { sqlite3_finalize(stmt) }
            let rc = sqlite3_step(stmt)
            guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw error() }
            return Int(sqlite3_changes(handle))
        }
    }

    public func query(_ sql: String, _ args: [SQLBindable] = []) throws -> [Row] {
        try sync {
            let stmt = try prepare(sql, args)
            defer { sqlite3_finalize(stmt) }
            var rows: [Row] = []
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_DONE { break }
                guard rc == SQLITE_ROW else { throw error() }
                var values: [String: SQLValue] = [:]
                for i in 0..<sqlite3_column_count(stmt) {
                    let name = String(cString: sqlite3_column_name(stmt, i))
                    switch sqlite3_column_type(stmt, i) {
                    case SQLITE_INTEGER: values[name] = .int(sqlite3_column_int64(stmt, i))
                    case SQLITE_FLOAT: values[name] = .double(sqlite3_column_double(stmt, i))
                    case SQLITE_TEXT: values[name] = .text(String(cString: sqlite3_column_text(stmt, i)))
                    default: values[name] = .null
                    }
                }
                rows.append(Row(values: values))
            }
            return rows
        }
    }

    public func queryOne(_ sql: String, _ args: [SQLBindable] = []) throws -> Row? {
        try query(sql, args).first
    }

    public var lastInsertRowID: Int64 { sync { sqlite3_last_insert_rowid(handle) } }

    /// 在事务中执行，出错时回滚。
    public func transaction<T>(_ work: () throws -> T) throws -> T {
        try sync {
            try execute("BEGIN IMMEDIATE")
            do {
                let result = try work()
                try execute("COMMIT")
                return result
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }
    }

    private func prepare(_ sql: String, _ args: [SQLBindable]) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { throw error() }
        for (index, arg) in args.enumerated() {
            let i = Int32(index + 1)
            switch arg.sqlValue {
            case .null: sqlite3_bind_null(stmt, i)
            case .int(let v): sqlite3_bind_int64(stmt, i, v)
            case .double(let v): sqlite3_bind_double(stmt, i, v)
            case .text(let v): sqlite3_bind_text(stmt, i, v, -1, SQLITE_TRANSIENT)
            }
        }
        return stmt
    }
}
