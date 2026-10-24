import Foundation
import SQLite3

enum SQLiteStoreError: Error {
    case openFailed(String)
    case execFailed(String)
    case prepareFailed(String)
    case stepFailed(String)
}

/// Thin serialised SQLite wrapper. No GRDB dependency so the app stays self-contained.
final class SQLiteStore: @unchecked Sendable {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "app.framekeep.sqlite")

    init(fileURL: URL) throws {
        try AppPaths.ensureDirectory(fileURL.deletingLastPathComponent())
        let status = sqlite3_open_v2(
            fileURL.path,
            &db,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard status == SQLITE_OK else {
            throw SQLiteStoreError.openFailed(errorMessage())
        }
        try execute("PRAGMA journal_mode=WAL;")
        try execute("PRAGMA foreign_keys=ON;")
        try migrate()
    }

    deinit {
        sqlite3_close(db)
    }

    func execute(_ sql: String) throws {
        try queue.sync {
            var err: UnsafeMutablePointer<CChar>?
            let status = sqlite3_exec(db, sql, nil, nil, &err)
            if let err {
                let message = String(cString: err)
                sqlite3_free(err)
                if status != SQLITE_OK { throw SQLiteStoreError.execFailed(message) }
            } else if status != SQLITE_OK {
                throw SQLiteStoreError.execFailed(errorMessage())
            }
        }
    }

    @discardableResult
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try queue.sync {
            try execUnlocked("BEGIN IMMEDIATE;")
            do {
                let value = try body()
                try execUnlocked("COMMIT;")
                return value
            } catch {
                try? execUnlocked("ROLLBACK;")
                throw error
            }
        }
    }

    func query(_ sql: String, bind: ((OpaquePointer) -> Void)? = nil) throws -> [[String: SQLiteValue]] {
        try queue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                throw SQLiteStoreError.prepareFailed(errorMessage())
            }
            defer { sqlite3_finalize(stmt) }
            bind?(stmt)
            var rows: [[String: SQLiteValue]] = []
            while true {
                let step = sqlite3_step(stmt)
                if step == SQLITE_DONE { break }
                guard step == SQLITE_ROW else { throw SQLiteStoreError.stepFailed(errorMessage()) }
                var row: [String: SQLiteValue] = [:]
                let count = sqlite3_column_count(stmt)
                for i in 0..<count {
                    let name = String(cString: sqlite3_column_name(stmt, i))
                    row[name] = columnValue(stmt, index: i)
                }
                rows.append(row)
            }
            return rows
        }
    }

    func run(_ sql: String, bind: ((OpaquePointer) -> Void)? = nil) throws {
        try queue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                throw SQLiteStoreError.prepareFailed(errorMessage())
            }
            defer { sqlite3_finalize(stmt) }
            bind?(stmt)
            let step = sqlite3_step(stmt)
            guard step == SQLITE_DONE || step == SQLITE_ROW else {
                throw SQLiteStoreError.stepFailed(errorMessage())
            }
        }
    }

    func bindText(_ stmt: OpaquePointer, _ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    func bindDouble(_ stmt: OpaquePointer, _ index: Int32, _ value: Double?) {
        if let value {
            sqlite3_bind_double(stmt, index, value)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    func bindInt(_ stmt: OpaquePointer, _ index: Int32, _ value: Int?) {
        if let value {
            sqlite3_bind_int64(stmt, index, Int64(value))
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func migrate() throws {
        try execute(
            """
            CREATE TABLE IF NOT EXISTS jobs (
                id TEXT PRIMARY KEY,
                url TEXT NOT NULL,
                title TEXT,
                state TEXT NOT NULL,
                format_id TEXT,
                format_label TEXT,
                progress REAL,
                speed TEXT,
                eta TEXT,
                failure_kind TEXT,
                failure_message TEXT,
                output_path TEXT,
                probe_json TEXT,
                source TEXT,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS media (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                source_url TEXT,
                kind TEXT NOT NULL,
                file_path TEXT NOT NULL,
                thumbnail_path TEXT,
                duration REAL,
                host TEXT,
                created_at REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_jobs_updated ON jobs(updated_at DESC);
            CREATE INDEX IF NOT EXISTS idx_media_created ON media(created_at DESC);
            """
        )
    }

    private func execUnlocked(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(db, sql, nil, nil, &err)
        if let err {
            let message = String(cString: err)
            sqlite3_free(err)
            if status != SQLITE_OK { throw SQLiteStoreError.execFailed(message) }
        } else if status != SQLITE_OK {
            throw SQLiteStoreError.execFailed(errorMessage())
        }
    }

    private func columnValue(_ stmt: OpaquePointer, index: Int32) -> SQLiteValue {
        switch sqlite3_column_type(stmt, index) {
        case SQLITE_INTEGER:
            return .int(sqlite3_column_int64(stmt, index))
        case SQLITE_FLOAT:
            return .double(sqlite3_column_double(stmt, index))
        case SQLITE_TEXT:
            if let c = sqlite3_column_text(stmt, index) {
                return .text(String(cString: c))
            }
            return .null
        default:
            return .null
        }
    }

    private func errorMessage() -> String {
        if let db, let c = sqlite3_errmsg(db) {
            return String(cString: c)
        }
        return "未知的 SQLite 錯誤"
    }
}

enum SQLiteValue {
    case text(String)
    case int(Int64)
    case double(Double)
    case null

    var string: String? {
        switch self {
        case .text(let v): return v
        default: return nil
        }
    }

    var double: Double? {
        switch self {
        case .double(let v): return v
        case .int(let v): return Double(v)
        default: return nil
        }
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
