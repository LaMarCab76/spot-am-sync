import Foundation
import CSQLite

/// One durable transaction contains the approved plan, pre-write inventory and journal.
/// Tokens are deliberately outside this schema and belong in the provider's Keychain.
public actor SyncStore {
    private var database: OpaquePointer?
    public let url: URL
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    public init(url: URL) throws {
        self.url = url
        encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var pointer: OpaquePointer?
        guard sqlite3_open_v2(url.path, &pointer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let detail = pointer.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite no disponible"
            if let pointer { sqlite3_close(pointer) }
            throw SyncExecutionError.persistence(detail)
        }
        database = pointer
        sqlite3_busy_timeout(pointer, 5000)
        for sql in ["PRAGMA journal_mode=WAL", "PRAGMA synchronous=FULL", "CREATE TABLE IF NOT EXISTS runs (id TEXT PRIMARY KEY, started REAL NOT NULL, payload BLOB NOT NULL)", "CREATE TABLE IF NOT EXISTS decisions (account_pair TEXT PRIMARY KEY, payload BLOB NOT NULL)"] {
            guard sqlite3_exec(pointer, sql, nil, nil, nil) == SQLITE_OK else {
                let detail = String(cString: sqlite3_errmsg(pointer)); sqlite3_close(pointer); database = nil
                throw SyncExecutionError.persistence(detail)
            }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    deinit { if let database { sqlite3_close(database) } }

    public func save(_ record: RunRecord) throws {
        try transaction {
            var updated = record
            // An executor may hold an older value across an await. Revocation is monotonic,
            // including when another SyncStore instance updates the same database.
            if try load(id: record.id)?.approvalRevoked == true { updated.approvalRevoked = true }
            try write(updated)
        }
    }

    private func write(_ record: RunRecord) throws {
        let payload = try encoder.encode(record)
        let statement = try prepare("INSERT INTO runs(id, started, payload) VALUES(?, ?, ?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload")
        defer { sqlite3_finalize(statement) }
        bind(record.id.uuidString, to: statement, at: 1)
        sqlite3_bind_double(statement, 2, record.summary.startedAt.timeIntervalSince1970)
        bind(payload, to: statement, at: 3)
        try stepWrite(statement)
    }

    public func load(id: UUID) throws -> RunRecord? {
        let statement = try prepare("SELECT payload FROM runs WHERE id=?")
        defer { sqlite3_finalize(statement) }
        bind(id.uuidString, to: statement, at: 1)
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else { throw error() }
        return try decoder.decode(RunRecord.self, from: data(statement, column: 0))
    }

    public func recent(limit: Int = 50) throws -> [RunRecord] {
        let statement = try prepare("SELECT payload FROM runs ORDER BY started DESC LIMIT ?")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(max(1, min(limit, 500))))
        var result: [RunRecord] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw error() }
            result.append(try decoder.decode(RunRecord.self, from: data(statement, column: 0)))
        }
    }

    /// Stable account IDs deliberately exclude connectionRevision. Scan the entire journal:
    /// an old uncertain request does not become safe when it falls out of the history UI.
    public func unresolvedRuns(accountIDs: [MusicService: String], excluding id: UUID? = nil) throws -> [RunRecord] {
        try allRecords().filter { record in
            record.id != id && overlaps(record, accountIDs: accountIDs) && record.executions.contains {
                $0.state == .applying || $0.state == .unknown ||
                    (($0.state == .failed || $0.state == .pending) && $0.before != nil)
            }
        }
    }

    /// Changing policies for either account invalidates every related approval.
    public func revokeApprovals(accountIDs: [MusicService: String]) throws {
        try transaction {
            for var record in try allRecords() where overlaps(record, accountIDs: accountIDs) && !record.approvalRevoked {
                record.approvalRevoked = true
                try write(record)
            }
        }
    }

    private func overlaps(_ record: RunRecord, accountIDs: [MusicService: String]) -> Bool {
        record.plan.snapshots.contains { accountIDs[$0.account.service] == $0.account.id }
    }

    private func allRecords() throws -> [RunRecord] {
        let statement = try prepare("SELECT payload FROM runs ORDER BY started ASC")
        defer { sqlite3_finalize(statement) }
        var records: [RunRecord] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return records }
            guard status == SQLITE_ROW else { throw error() }
            records.append(try decoder.decode(RunRecord.self, from: data(statement, column: 0)))
        }
    }

    private func transaction(_ body: () throws -> Void) throws {
        guard sqlite3_exec(database, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { throw error() }
        do {
            try body()
            guard sqlite3_exec(database, "COMMIT", nil, nil, nil) == SQLITE_OK else { throw error() }
        } catch {
            sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    public func saveDecisions(_ decisions: MatchDecisions, accountPair: String) throws {
        let statement = try prepare("INSERT INTO decisions(account_pair,payload) VALUES(?,?) ON CONFLICT(account_pair) DO UPDATE SET payload=excluded.payload")
        defer { sqlite3_finalize(statement) }
        bind(accountPair, to: statement, at: 1); bind(try encoder.encode(decisions), to: statement, at: 2)
        try stepWrite(statement)
    }

    public func loadDecisions(accountPair: String) throws -> MatchDecisions? {
        let statement = try prepare("SELECT payload FROM decisions WHERE account_pair=?")
        defer { sqlite3_finalize(statement) }
        bind(accountPair, to: statement, at: 1)
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else { throw error() }
        return try decoder.decode(MatchDecisions.self, from: data(statement, column: 0))
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw error() }
        return statement
    }
    private func bind(_ text: String, to statement: OpaquePointer, at index: Int32) {
        _ = text.withCString { sqlite3_bind_text(statement, index, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
    }
    private func bind(_ value: Data, to statement: OpaquePointer, at index: Int32) {
        _ = value.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(value.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
    }
    private func data(_ statement: OpaquePointer, column: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0, let bytes = sqlite3_column_blob(statement, column) else { return Data() }
        return Data(bytes: bytes, count: count)
    }
    private func stepWrite(_ statement: OpaquePointer) throws { guard sqlite3_step(statement) == SQLITE_DONE else { throw error() } }
    private func error() -> SyncExecutionError {
        .persistence(database.map { String(cString: sqlite3_errmsg($0)) } ?? "Base cerrada")
    }
}
