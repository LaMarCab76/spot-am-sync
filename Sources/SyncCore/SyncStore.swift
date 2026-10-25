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
        let existed = FileManager.default.fileExists(atPath: url.path)
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
        guard let pointer else { throw SyncExecutionError.persistence("SQLite no devolvió una conexión.") }
        database = pointer
        sqlite3_busy_timeout(pointer, 5000)
        for sql in ["PRAGMA journal_mode=WAL", "PRAGMA synchronous=FULL"] {
            guard sqlite3_exec(pointer, sql, nil, nil, nil) == SQLITE_OK else {
                let detail = String(cString: sqlite3_errmsg(pointer)); sqlite3_close(pointer); database = nil
                throw SyncExecutionError.persistence(detail)
            }
        }
        do { try Self.migrate(pointer, url: url, backup: existed) }
        catch { sqlite3_close(pointer); database = nil; throw error }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    deinit { if let database { sqlite3_close(database) } }

    private static func migrate(_ database: OpaquePointer, url: URL, backup: Bool) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK else {
            throw SyncExecutionError.persistence("No se pudo leer la versión de los datos.")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw SyncExecutionError.persistence("Versión de datos ilegible.") }
        let version = sqlite3_column_int(statement, 0)
        guard version <= 2 else { throw SyncExecutionError.persistence("Esta biblioteca fue creada por una versión más nueva de la app.") }
        guard version < 2 else { return }
        if backup {
            let destination = url.deletingLastPathComponent().appendingPathComponent("library-sync-before-workspace-\(UUID().uuidString).sqlite")
            var copy: OpaquePointer?
            guard sqlite3_open(destination.path, &copy) == SQLITE_OK, let copy else {
                if let copy { sqlite3_close(copy) }
                throw SyncExecutionError.persistence("No se pudo crear el respaldo previo a la migración.")
            }
            defer { sqlite3_close(copy) }
            guard let handle = sqlite3_backup_init(copy, "main", database, "main") else {
                throw SyncExecutionError.persistence("No se pudo iniciar el respaldo SQLite.")
            }
            let result = sqlite3_backup_step(handle, -1)
            let finish = sqlite3_backup_finish(handle)
            guard result == SQLITE_DONE, finish == SQLITE_OK else { throw SyncExecutionError.persistence("El respaldo SQLite no se completó.") }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        }
        guard sqlite3_exec(database, "BEGIN IMMEDIATE; CREATE TABLE IF NOT EXISTS runs (id TEXT PRIMARY KEY, started REAL NOT NULL, payload BLOB NOT NULL); CREATE TABLE IF NOT EXISTS decisions (account_pair TEXT PRIMARY KEY, payload BLOB NOT NULL); CREATE TABLE IF NOT EXISTS workspace (id INTEGER PRIMARY KEY CHECK(id=1), payload BLOB NOT NULL); CREATE TABLE IF NOT EXISTS sync_documents (key TEXT PRIMARY KEY, payload BLOB NOT NULL); PRAGMA user_version=2; COMMIT", nil, nil, nil) == SQLITE_OK else {
            sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
            throw SyncExecutionError.persistence("No se pudo completar la migración de configuraciones.")
        }
    }

    public func loadWorkspace() throws -> SyncWorkspace {
        let statement = try prepare("SELECT payload FROM workspace WHERE id=1")
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return SyncWorkspace() }
        guard status == SQLITE_ROW else { throw error() }
        let value = try decoder.decode(SyncWorkspace.self, from: data(statement, column: 0))
        guard value.version == 1 else { throw SyncExecutionError.persistence("Configuraciones de una versión incompatible.") }
        return value
    }

    /// Versioned comparison sessions and finite approvals share the journal's
    /// durable SQLite connection. They survive clearing settled run history.
    public func loadDocument<Value: Decodable & Sendable>(_ type: Value.Type, key: String) throws -> Value? {
        let statement = try prepare("SELECT payload FROM sync_documents WHERE key=?")
        defer { sqlite3_finalize(statement) }
        bind(key, to: statement, at: 1)
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else { throw error() }
        return try decoder.decode(type, from: data(statement, column: 0))
    }

    public func saveDocument<Value: Encodable & Sendable>(_ value: Value, key: String) throws {
        let statement = try prepare("INSERT INTO sync_documents(key,payload) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET payload=excluded.payload")
        defer { sqlite3_finalize(statement) }
        bind(key, to: statement, at: 1); bind(try encoder.encode(value), to: statement, at: 2)
        try stepWrite(statement)
    }

    public func saveWorkspace(_ workspace: SyncWorkspace) throws {
        guard workspace.version == 1 else { throw SyncExecutionError.persistence("Versión de configuraciones incompatible.") }
        let statement = try prepare("INSERT INTO workspace(id,payload) VALUES(1,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload")
        defer { sqlite3_finalize(statement) }
        bind(try encoder.encode(workspace), to: statement, at: 1); try stepWrite(statement)
    }

    /// Recover a verified creation if a crash preceded the UI's configuration save.
    public func restoreVerifiedTargets(in workspace: SyncWorkspace) throws -> SyncWorkspace {
        var recovered = workspace
        for record in try allRecords() {
            guard let request = record.plan.request, let profileID = request.profileID,
                  let p = recovered.profiles.firstIndex(where: { $0.id == profileID }),
                  recovered.profiles[p].request.revision == request.revision,
                  recovered.profiles[p].request.accountIDs == request.accountIDs,
                  recovered.profiles[p].request.storefronts == request.storefronts,
                  recovered.profiles[p].request.options == request.options,
                  recovered.profiles[p].isDemo == record.isDemo else { continue }
            for step in record.executions where step.state == .verified && step.operation.kind == .createPlaylist {
                guard let source = step.operation.sourcePlaylist, let targetID = step.receipt?.createdID,
                      request.playlists.contains(source) else { continue }
                let target = PlaylistTarget(source: source, targetID: targetID)
                if request.options.existingPlaylist == .copy {
                    if !recovered.profiles[p].request.copyTargets.contains(target) { recovered.profiles[p].request.copyTargets.append(target) }
                } else {
                    var targets = recovered.profiles[p].request.playlistTargets ?? []
                    if !targets.contains(target) { targets.append(target) }
                    recovered.profiles[p].request.playlistTargets = targets
                }
            }
        }
        for i in recovered.jobs.indices where recovered.jobs[i].state == .ready {
            if let id = recovered.jobs[i].request.profileID, let profile = recovered.profiles.first(where: { $0.id == id }), profile.request != recovered.jobs[i].request {
                recovered.jobs[i].state = .attention; recovered.jobs[i].plan = nil
                recovered.jobs[i].message = "Se recuperó un destino creado y verificado. Prepará una propuesta nueva antes de continuar."
            }
        }
        return recovered
    }

    /// Never remove the evidence needed to reconcile an interrupted write.
    @discardableResult
    public func clearSettledHistory() throws -> Int {
        var deleted = 0
        try transaction {
            for record in try allRecords() {
                let uncertain = record.summary.status == .running || record.executions.contains {
                    $0.state == .unknown || $0.state == .applying || (($0.state == .failed || $0.state == .pending) && $0.before != nil)
                }
                guard !uncertain else { continue }
                let statement = try prepare("DELETE FROM runs WHERE id=?")
                defer { sqlite3_finalize(statement) }
                bind(record.id.uuidString, to: statement, at: 1); try stepWrite(statement); deleted += 1
            }
        }
        return deleted
    }

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
