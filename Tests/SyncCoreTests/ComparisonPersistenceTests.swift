import XCTest
import CSQLite
@testable import SyncCore

final class ComparisonPersistenceTests: XCTestCase {
    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("comparison-persistence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func library() -> ManualMusicLibrary {
        let tracks = [Track(id: "xml:first", title: "Uno", artist: "Sintético", albumTitle: "Grupo observado"),
                      Track(id: "xml:second", title: "Dos", artist: "Sintético", albumTitle: "Grupo observado")]
        return ManualMusicLibrary(id: "apple-music-xml:0123456789ABCDEF", fileName: "Synthetic.xml",
            importedAt: Date(timeIntervalSince1970: 1_700_000_030), exportedAt: Date(timeIntervalSince1970: 1_700_000_000),
            tracks: tracks, warnings: ["La cobertura corresponde al documento XML."], inventory: .init(playlists: [
                .init(id: "xml:folder", name: "Carpeta", kind: .folder),
                .init(id: "xml:playlist", name: "Secuencia", trackIDs: [tracks[1].id, tracks[0].id, tracks[1].id],
                      parentID: "xml:folder", artworkURL: "https://example.invalid/synthetic-artwork"),
                .init(id: "xml:empty", name: "Vacía")
            ], trackInfo: [
                tracks[0].id: .init(persistentID: "0000000000000001", referenceID: 71, playlistOnly: false),
                tracks[1].id: .init(persistentID: "0000000000000002", referenceID: 88, playlistOnly: true)
            ]), documentDigest: String(repeating: "a", count: 64))
    }

    private func snapshots() -> [LibrarySnapshot] {
        MusicService.allCases.map { service in
            .init(account: .init(id: "synthetic-\(service.rawValue)", service: service, displayName: "Fixture",
                                connectionRevision: "revision-\(service.rawValue)"))
        }
    }

    private func record(state: ExecutionState = .unknown, status: RunStatus = .interrupted) -> RunRecord {
        let snapshots = snapshots()
        let operation = SyncOperation(service: .spotify, kind: .saveTracks, title: "Save synthetic song", tracks: [library().tracks[0]])
        return .init(summary: .init(startedAt: Date(timeIntervalSince1970: 1_700_000_000), status: status, totalCount: 1),
                     plan: .init(mode: .appleMusicBase, snapshots: snapshots, operations: [operation]), decisions: .init(),
                     executions: [.init(operation: operation, state: state, before: snapshots[0], error: "Synthetic timeout")],
                     checkpoints: snapshots)
    }

    func testComparisonDocumentsAndFiniteApprovalRoundTripIndependentlyAndUpsertOneKey() async throws {
        let directory = try directory(), url = directory.appendingPathComponent("sync.sqlite"), store = try SyncStore(url: url)
        let library = library(), baseline = LibraryComparisonBaseline(library: library, spotify: snapshots()[0])
        let source = try SnapshotTransferSource(library: library, differenceIDs: ["difference:playlist"],
                                                approvedAt: Date(timeIntervalSince1970: 1_700_000_060))
        let report = LibraryComparisonReport(differences: [
            .init(id: "difference:conflict", unitID: "unit:playlist", scope: .playlists, category: .conflict,
                  title: "Consultar conflicto", appleMusicTrackIDs: ["xml:second", "xml:first", "xml:second"], spotifyTrackIDs: []),
            .init(id: "difference:removal", unitID: "unit:song", scope: .songs, category: .removal,
                  destination: .spotify, title: "Baja separada")
        ], warnings: ["Instantánea XML; no es una consulta de la nube."])
        let missing = try await store.loadDocument(LibraryComparisonBaseline.self, key: "comparison:baseline")
        XCTAssertNil(missing)
        try await store.saveDocument(baseline, key: "comparison:baseline")
        try await store.saveDocument(report, key: "comparison:report")
        try await store.saveDocument(source, key: "comparison:approval")
        var updated = source
        updated.approvedAt = source.approvedAt.addingTimeInterval(60)
        updated.differenceIDs = ["difference:song"]
        try await store.saveDocument(updated, key: "comparison:approval")
        let reopened = try SyncStore(url: url)
        let restoredBaseline = try await reopened.loadDocument(LibraryComparisonBaseline.self, key: "comparison:baseline")
        let restoredReport = try await reopened.loadDocument(LibraryComparisonReport.self, key: "comparison:report")
        let restoredSource = try await reopened.loadDocument(SnapshotTransferSource.self, key: "comparison:approval")
        XCTAssertEqual(restoredBaseline, baseline)
        XCTAssertEqual(restoredReport, report)
        XCTAssertEqual(restoredSource, updated)
        XCTAssertEqual(restoredSource?.library, library)
        XCTAssertEqual(restoredSource?.library.inventory?.playlists[1].trackIDs, ["xml:second", "xml:first", "xml:second"])
        XCTAssertEqual(restoredSource?.differenceIDs, ["difference:song"])
        XCTAssertNotEqual(restoredSource?.approvedAt, source.approvedAt)
    }

    func testRunPayloadPreservesFullSnapshotSourceAndLegacyRunHasNoSource() async throws {
        let url = try directory().appendingPathComponent("sync.sqlite"), store = try SyncStore(url: url)
        var run = record()
        let approval = try SnapshotTransferSource(library: library(), differenceIDs: ["approved:playlist", "approved:song"])
        run.snapshotSource = approval
        let decoded = try JSONDecoder().decode(RunRecord.self, from: JSONEncoder().encode(run))
        XCTAssertEqual(decoded.snapshotSource, approval)
        // SnapshotTransferSource.== intentionally does not compare the nested library payload.
        XCTAssertEqual(decoded.snapshotSource?.library, approval.library)
        XCTAssertEqual(decoded.executions[0].before, run.executions[0].before)
        try await store.save(run)
        let reopened = try SyncStore(url: url)
        let persisted = try await reopened.load(id: run.id)
        XCTAssertEqual(persisted?.snapshotSource?.library, approval.library)
        XCTAssertEqual(persisted?.snapshotSource?.differenceIDs, approval.differenceIDs)
        let old = record()
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        legacy.removeValue(forKey: "snapshotSource"); legacy.removeValue(forKey: "approvalRevoked")
        let legacyDecoded = try JSONDecoder().decode(RunRecord.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(legacyDecoded.snapshotSource)
        XCTAssertFalse(legacyDecoded.approvalRevoked)
        XCTAssertEqual(legacyDecoded.executions, old.executions)
    }

    func testClearingSettledHistoryPreservesComparisonDocumentsAndUncertainWrites() async throws {
        let url = try directory().appendingPathComponent("sync.sqlite"), store = try SyncStore(url: url)
        let baseline = LibraryComparisonBaseline(library: library(), spotify: snapshots()[0])
        let approval = try SnapshotTransferSource(library: library(), differenceIDs: ["approved:playlist"])
        let unknown = record(), completed = record(state: .verified, status: .completed)
        try await store.saveDocument(baseline, key: "baseline")
        try await store.saveDocument(approval, key: "approval")
        try await store.save(unknown); try await store.save(completed)
        let deleted = try await store.clearSettledHistory()
        XCTAssertEqual(deleted, 1)
        let reopened = try SyncStore(url: url)
        let preservedBaseline = try await reopened.loadDocument(LibraryComparisonBaseline.self, key: "baseline")
        let preservedApproval = try await reopened.loadDocument(SnapshotTransferSource.self, key: "approval")
        let preservedRun = try await reopened.load(id: unknown.id), removedRun = try await reopened.load(id: completed.id)
        XCTAssertEqual(preservedBaseline, baseline)
        XCTAssertEqual(preservedApproval?.library, approval.library)
        XCTAssertEqual(preservedRun?.executions[0].state, .unknown)
        XCTAssertNil(removedRun)
    }

    func testWrongDocumentTypeThrowsWithoutReplacingOtherSavedDocuments() async throws {
        let store = try SyncStore(url: directory().appendingPathComponent("sync.sqlite")), library = library()
        try await store.saveDocument(library, key: "library")
        try await store.saveDocument([1, 2, 3], key: "incompatible")
        do {
            _ = try await store.loadDocument(SnapshotTransferSource.self, key: "incompatible")
            XCTFail("An invalid payload was treated as an empty approval")
        } catch { XCTAssertTrue(error is DecodingError) }
        let restored = try await store.loadDocument(ManualMusicLibrary.self, key: "library")
        let incompatible = try await store.loadDocument([Int].self, key: "incompatible")
        XCTAssertEqual(restored, library)
        XCTAssertEqual(incompatible, [1, 2, 3])
    }

    func testSchemaZeroAndOneMigrationBacksUpAndPreservesRunsDecisionsWorkspaceAndLegacyChecklist() async throws {
        for version in [0, 1] {
            let directory = try directory(), url = directory.appendingPathComponent("sync.sqlite")
            let checklistURL = directory.appendingPathComponent("manual-checklist.json")
            let oldLibrary = ManualMusicLibrary(id: "legacy-library", fileName: "Legacy.xml", tracks: [])
            let checklist = ManualChecklistState(library: oldLibrary, markedIDsByScope: ["legacy-scope": ["manual-mark"]])
            try await ManualChecklistStore(url: checklistURL).save(checklist)
            let checklistBytes = try Data(contentsOf: checklistURL)
            let run = record(), runBytes = try JSONEncoder().encode(run), workspace = SyncWorkspace()
            let decisions = MatchDecisions(playlists: [.init(spotifyID: "spotify-playlist", appleMusicID: "xml-playlist")])
            let decisionBytes = try JSONEncoder().encode(decisions)
            try withDatabase(url, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE) { database in
                try execute("PRAGMA journal_mode=WAL; CREATE TABLE runs(id TEXT PRIMARY KEY, started REAL NOT NULL, payload BLOB NOT NULL); CREATE TABLE decisions(account_pair TEXT PRIMARY KEY, payload BLOB NOT NULL)", in: database)
                try insert(runBytes, key: run.id.uuidString, sql: "INSERT INTO runs(id,started,payload) VALUES(?,1700000000,?)", in: database)
                try insert(decisionBytes, key: "legacy-pair", sql: "INSERT INTO decisions(account_pair,payload) VALUES(?,?)", in: database)
                if version == 1 {
                    try execute("CREATE TABLE workspace(id INTEGER PRIMARY KEY CHECK(id=1), payload BLOB NOT NULL)", in: database)
                    try insert(try JSONEncoder().encode(workspace), key: "1", sql: "INSERT INTO workspace(id,payload) VALUES(?,?)", in: database)
                }
                try execute("PRAGMA user_version=\(version)", in: database)
            }
            let store = try SyncStore(url: url)
            let restoredRun = try await store.load(id: run.id), restoredDecisions = try await store.loadDecisions(accountPair: "legacy-pair")
            let restoredWorkspace = try await store.loadWorkspace()
            XCTAssertEqual(restoredRun, run)
            XCTAssertNil(restoredRun?.snapshotSource)
            XCTAssertEqual(restoredDecisions, decisions)
            XCTAssertEqual(restoredWorkspace, workspace)
            XCTAssertEqual(try Data(contentsOf: checklistURL), checklistBytes)
            let restoredChecklist = try await ManualChecklistStore(url: checklistURL).load()
            XCTAssertEqual(restoredChecklist?.markedIDsByScope, checklist.markedIDsByScope)
            XCTAssertEqual(restoredChecklist?.library, oldLibrary)
            XCTAssertNil(restoredChecklist?.library?.inventory)
            XCTAssertNil(restoredChecklist?.library?.documentDigest)
            let backups = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("library-sync-before-workspace-") && $0.pathExtension == "sqlite" }
            let backup = try XCTUnwrap(backups.first)
            XCTAssertEqual(backups.count, 1)
            let attributes = try FileManager.default.attributesOfItem(atPath: backup.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            // A WAL backup may need SQLite to create its sidecars before serving read queries.
            try withDatabase(backup, flags: SQLITE_OPEN_READWRITE) { database in
                XCTAssertEqual(try scalarInt("PRAGMA user_version", in: database), version)
                XCTAssertEqual(try payload("SELECT payload FROM runs", in: database), runBytes)
                XCTAssertEqual(try payload("SELECT payload FROM decisions", in: database), decisionBytes)
                XCTAssertEqual(try scalarInt("SELECT COUNT(*) FROM sqlite_master WHERE name='sync_documents'", in: database), 0)
                XCTAssertEqual(try scalarText("PRAGMA integrity_check", in: database), "ok")
            }
            try await store.saveDocument(library(), key: "new-comparison")
            let reopened = try SyncStore(url: url)
            let newDocument = try await reopened.loadDocument(ManualMusicLibrary.self, key: "new-comparison")
            XCTAssertEqual(newDocument, library())
            let backupsAfterReopen = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("library-sync-before-workspace-") && $0.pathExtension == "sqlite" }
            XCTAssertEqual(backupsAfterReopen, backups)
            try withDatabase(url) { database in XCTAssertEqual(try scalarInt("PRAGMA user_version", in: database), 2) }
        }
    }

    private func withDatabase<T>(_ url: URL, flags: Int32 = SQLITE_OPEN_READONLY, _ body: (OpaquePointer) throws -> T) throws -> T {
        var pointer: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &pointer, flags, nil)
        defer { if let pointer { sqlite3_close(pointer) } }
        XCTAssertEqual(result, SQLITE_OK)
        return try body(XCTUnwrap(pointer))
    }

    private func execute(_ sql: String, in database: OpaquePointer) throws {
        XCTAssertEqual(sqlite3_exec(database, sql, nil, nil, nil), SQLITE_OK, String(cString: sqlite3_errmsg(database)))
    }

    private func statement(_ sql: String, in database: OpaquePointer) throws -> OpaquePointer {
        var pointer: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(database, sql, -1, &pointer, nil), SQLITE_OK, String(cString: sqlite3_errmsg(database)))
        return try XCTUnwrap(pointer)
    }

    private func insert(_ data: Data, key: String, sql: String, in database: OpaquePointer) throws {
        let statement = try statement(sql, in: database)
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = key.withCString { sqlite3_bind_text(statement, 1, $0, -1, transient) }
        _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 2, $0.baseAddress, Int32(data.count), transient) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE, String(cString: sqlite3_errmsg(database)))
    }

    private func scalarInt(_ sql: String, in database: OpaquePointer) throws -> Int {
        let statement = try statement(sql, in: database)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        return Int(sqlite3_column_int(statement, 0))
    }

    private func scalarText(_ sql: String, in database: OpaquePointer) throws -> String {
        let statement = try statement(sql, in: database)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        return String(cString: try XCTUnwrap(sqlite3_column_text(statement, 0)))
    }

    private func payload(_ sql: String, in database: OpaquePointer) throws -> Data {
        let statement = try statement(sql, in: database)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        return Data(bytes: try XCTUnwrap(sqlite3_column_blob(statement, 0)), count: Int(sqlite3_column_bytes(statement, 0)))
    }
}
