import CryptoKit
import Foundation
import SQLite3

/// A replica belongs to one pinned broker, topic namespace and device identity.
final class GoReplica {
    struct Cursor: Equatable { var epoch = ""; var after: Int64 = 0; var through: Int64 = 0 }
    struct Event { let kind: String; let data: [String: Any] }
    struct Pending { let id: String; let payload: Data }
    private let db: OpaquePointer
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(name: String, directory: URL? = nil) throws {
        let root = try directory ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                            appropriateFor: nil, create: true).appendingPathComponent("JohnnyBot/Replicas")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent(SHA256.hash(data: Data(name.utf8)).hexString + ".sqlite")
        var handle: OpaquePointer?
        guard sqlite3_open(file.path, &handle) == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            throw ACPFailure(message: "无法打开会话缓存")
        }
        db = handle
        try execute("PRAGMA journal_mode=WAL")
        try execute("CREATE TABLE IF NOT EXISTS scopes (scope TEXT PRIMARY KEY, epoch TEXT, cursor INTEGER, upper_bound INTEGER)")
        try execute("CREATE TABLE IF NOT EXISTS events (scope TEXT, seq INTEGER, kind TEXT, data BLOB, PRIMARY KEY(scope,seq))")
        try execute("CREATE TABLE IF NOT EXISTS fragments (scope TEXT, id TEXT, part INTEGER, bytes BLOB, PRIMARY KEY(scope,id,part))")
        try execute("CREATE TABLE IF NOT EXISTS outbox (id TEXT PRIMARY KEY, epoch TEXT, payload BLOB, reply BLOB)")
    }

    deinit { sqlite3_close(db) }

    private func query<T>(_ sql: String, _ args: [Any] = [], row: (OpaquePointer) throws -> T) throws -> [T] {
        var statement: OpaquePointer?
        func error() -> ACPFailure { ACPFailure(message: "会话缓存：" + String(cString: sqlite3_errmsg(db))) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw error() }
        defer { sqlite3_finalize(statement) }
        for (index, arg) in args.enumerated() {
            let i = Int32(index + 1)
            let status: Int32
            switch arg {
            case let value as String: status = sqlite3_bind_text(statement, i, value, -1, transient)
            case let value as Int64: status = sqlite3_bind_int64(statement, i, value)
            case let value as Data: status = value.withUnsafeBytes { sqlite3_bind_blob(statement, i, $0.baseAddress, Int32($0.count), transient) }
            default: throw error()
            }
            guard status == SQLITE_OK else { throw error() }
        }
        var result: [T] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: result.append(try row(statement))
            case SQLITE_DONE: return result
            default: throw error()
            }
        }
    }

    private func execute(_ sql: String, _ args: [Any] = []) throws { _ = try query(sql, args) { _ in () } }
    private func string(_ stmt: OpaquePointer, _ i: Int32) -> String { String(cString: sqlite3_column_text(stmt, i)) }
    private func blob(_ stmt: OpaquePointer, _ i: Int32) -> Data {
        Data(bytes: sqlite3_column_blob(stmt, i), count: Int(sqlite3_column_bytes(stmt, i)))
    }
    private func transaction<T>(_ work: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try work()
            try execute("COMMIT")
            return result
        } catch { try? execute("ROLLBACK"); throw error }
    }
    func cursor(_ scope: String) throws -> Cursor {
        try query("SELECT epoch,cursor,upper_bound FROM scopes WHERE scope=?", [scope]) {
            Cursor(epoch: string($0, 0), after: sqlite3_column_int64($0, 1), through: sqlite3_column_int64($0, 2))
        }.first ?? Cursor()
    }
    func clear(_ scope: String) throws {
        try transaction {
            for table in ["events", "fragments", "scopes"] { try execute("DELETE FROM " + table + " WHERE scope=?", [scope]) }
        }
    }

    func history(_ scope: String) throws -> [Event] {
        try query("SELECT kind,data FROM events WHERE scope=? AND kind != 'event.fragment' ORDER BY seq", [scope]) {
            Event(kind: string($0, 0), data: try object(blob($0, 1)))
        }
    }

    private func object(_ data: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw invalid }
        return value
    }
    private var invalid: ACPFailure { ACPFailure(message: "同步数据不完整，请重新连接") }

    func apply(_ page: [String: Any], scope: String, expected: Cursor, epoch: String) throws -> [Event] {
        try transaction {
            guard try cursor(scope) == expected, page["scope"] as? String == scope, page["epoch"] as? String == epoch,
                  page["after"] as? Int64 == expected.after, let through = page["through"] as? Int64,
                  through >= expected.after, expected.through == 0 || through == expected.through,
                  let more = page["more"] as? Bool else { throw invalid }
            var result: [Event] = []
            var seq = expected.after
            for item in page["events"] as? [[String: Any]] ?? [] {
                guard let n = item["seq"] as? Int64, n > seq, n <= through,
                      var kind = item["kind"] as? String, var data = item["data"] as? [String: Any] else { throw invalid }
                seq = n
                var payload = try JSONSerialization.data(withJSONObject: data)
                if kind == "event.fragment" {
                    guard let id = data["id"] as? String, let part = data["part"] as? Int64,
                          let encoded = data["bytes"] as? String, let bytes = Data(base64Encoded: encoded),
                          let original = data["kind"] as? String, let last = data["last"] as? Bool else { throw invalid }
                    try execute("INSERT INTO fragments VALUES(?,?,?,?)", [scope,id,part,bytes])
                    if last {
                        let pieces = try query("SELECT part,bytes FROM fragments WHERE scope=? AND id=? ORDER BY part", [scope,id]) {
                            (sqlite3_column_int64($0, 0), blob($0, 1))
                        }
                        guard pieces.count == part + 1 else { throw invalid }
                        payload = Data()
                        for (i, piece) in pieces.enumerated() {
                            guard piece.0 == i else { throw invalid }
                            payload.append(piece.1)
                        }
                        data = try object(payload)
                        kind = original
                        try execute("DELETE FROM fragments WHERE scope=? AND id=?", [scope,id])
                    }
                }
                try execute("INSERT INTO events VALUES(?,?,?,?)", [scope,seq,kind,payload])
                if kind != "event.fragment" { result.append(Event(kind: kind, data: data)) }
            }
            guard more ? seq > expected.after : seq == through else { throw invalid }
            try execute("INSERT OR REPLACE INTO scopes VALUES(?,?,?,?)", [scope,epoch,seq,more ? through : Int64(0)])
            return result
        }
    }
    func queue(id: String, epoch: String, payload: Data) throws {
        try execute("INSERT INTO outbox(id,epoch,payload) VALUES(?,?,?)", [id,epoch,payload])
    }
    func complete(id: String, reply: [String: Any]) throws {
        try execute("UPDATE outbox SET reply=? WHERE id=?", [try JSONSerialization.data(withJSONObject: reply),id])
    }
    func pending(epoch: String) throws -> [Pending] {
        try query("SELECT id,payload FROM outbox WHERE epoch=? AND reply IS NULL ORDER BY rowid", [epoch]) {
            Pending(id: string($0, 0), payload: blob($0, 1))
        }
    }
}
