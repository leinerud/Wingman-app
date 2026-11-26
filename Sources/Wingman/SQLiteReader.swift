import Foundation
import SQLite3
import os

/// Minimal read-only SQLite helper. Never writes to Copilot's databases.
enum SQLiteReader {
    private static let log = Logger(subsystem: "se.humblebee.Wingman", category: "sqlite")

    static func rows(path: String, sql: String) -> [[String: String]] {
        if let rows = query(path: path, sql: sql) { return rows }
        // While the Copilot app has the database open it is in WAL mode, and a read-only, sandboxed reader often
        // can't open it (it would need to write the -shm file). Read a private copy of the database and its WAL instead.
        guard let copy = snapshot(path) else { return [] }
        defer { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }
        return query(path: copy.path, sql: sql, writable: true) ?? []   // our own copy, so SQLite may create its -shm
    }

    /// nil when the database couldn't be opened or queried.
    private static func query(path: String, sql: String, writable: Bool = false) -> [[String: String]]? {
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(path, &db, writable ? SQLITE_OPEN_READWRITE : SQLITE_OPEN_READONLY, nil)
        guard rc == SQLITE_OK else {
            log.error("open failed \(rc, privacy: .public) \(path, privacy: .public)")
            sqlite3_close(db); return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 500)
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            log.error("prepare failed: \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        var out: [[String: String]] = []
        var step = sqlite3_step(stmt)
        while step == SQLITE_ROW {
            var row: [String: String] = [:]
            for i in 0..<sqlite3_column_count(stmt) {
                let name = String(cString: sqlite3_column_name(stmt, i))
                if let c = sqlite3_column_text(stmt, i) { row[name] = String(cString: c) }
            }
            out.append(row)
            step = sqlite3_step(stmt)
        }
        guard step == SQLITE_DONE else {
            log.error("step failed: \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
            return nil
        }
        return out
    }

    /// Copies the database (and its WAL, so recent changes are included) into a temporary folder.
    private static func snapshot(_ path: String) -> URL? {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("wingman-db-" + UUID().uuidString)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent)
            try fm.copyItem(at: URL(fileURLWithPath: path), to: dest)
            if fm.fileExists(atPath: path + "-wal") {
                try? fm.copyItem(at: URL(fileURLWithPath: path + "-wal"), to: URL(fileURLWithPath: dest.path + "-wal"))
            }
            return dest
        } catch {
            log.error("snapshot failed: \(error.localizedDescription, privacy: .public)")
            try? fm.removeItem(at: dir)
            return nil
        }
    }
}
