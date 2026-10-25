import XCTest
import CSQLite
@testable import SyncCore

final class ScopedSyncTests: XCTestCase {
    private let capabilities: [MusicService: ProviderCapabilities] = [.spotify: .spotify, .appleMusic: .spotify]
    private var inventory: [LibrarySnapshot] { DemoFixtures.snapshots() }
    private var choices: MatchDecisions { DemoFixtures.decisions() }
    private func request(mode: SyncMode = .spotifyBase, options: SyncOptions = .init(), ref: PlaylistReference = .init(service: .spotify, playlistID: "sp-ruta")) -> SyncRequest {
        SyncRequest(name: "Prueba", mode: mode, playlists: [ref], options: options, accounts: inventory.map(\.account))
    }
    private func plan(_ request: SyncRequest, snapshots: [LibrarySnapshot]? = nil) -> SyncPlan {
        SyncPlanner.makePlan(snapshots: snapshots ?? inventory, mode: request.mode, decisions: choices, capabilities: capabilities, request: request)
    }

    func testSelectionCannotTouchOtherPlaylistsOrSavedLibrary() {
        let preview = plan(request())
        XCTAssertFalse(preview.operations.isEmpty)
        XCTAssertTrue(preview.operations.allSatisfy { $0.service == .appleMusic && $0.targetID == "am-ruta" })
        XCTAssertFalse(preview.operations.contains { [.saveTracks, .removeTracks, .saveAlbums, .removeAlbums, .removePlaylist].contains($0.kind) })
        XCTAssertEqual(preview.snapshots, inventory)
    }

    func testEmptyScopeAndWrongDirectionDoNotWrite() {
        var scoped = request(); scoped.playlists = []
        XCTAssertTrue(plan(scoped).operations.isEmpty)
        scoped = request(mode: .appleMusicBase)
        XCTAssertTrue(plan(scoped).operations.isEmpty)
    }

    func testDifferentAccountsStorefrontOrMissingPlaylistRejectsScope() {
        var scoped = request(); scoped.accountIDs[.spotify] = "another"
        XCTAssertTrue(plan(scoped).operations.isEmpty)
        scoped = request(); scoped.storefronts[.appleMusic] = "us"
        XCTAssertTrue(plan(scoped).operations.isEmpty)
        scoped = request(); scoped.playlists[0].playlistID = "deleted"
        XCTAssertTrue(plan(scoped).operations.isEmpty)
    }

    func testOrderAndMultiplicityArePreservedByDefault() {
        let operation = plan(request()).operations.first { $0.kind == .replacePlaylistTracks }
        XCTAssertEqual(operation?.tracks.map(\.title), ["De música ligera", "Crimen", "De música ligera", "Puente"])
    }

    func testDeduplicationIsExplicitAndDoesNotLoseKnownMatches() {
        var options = SyncOptions(); options.skipDuplicates = true
        let operation = plan(request(options: options)).operations.first { $0.kind == .replacePlaylistTracks }
        XCTAssertEqual(operation?.tracks.map(\.title), ["De música ligera", "Crimen", "Puente"])
        XCTAssertNil(operation?.blockedReason)
    }

    func testDisablingOrderKeepsExistingOrderAndAppendsMissingOccurrences() {
        var options = SyncOptions(); options.keepOrder = false
        let preview = plan(request(options: options))
        XCTAssertFalse(preview.operations.contains { $0.kind == .replacePlaylistTracks })
        XCTAssertEqual(preview.operations.first { $0.kind == .addPlaylistTracks }?.tracks.map(\.title), ["De música ligera", "Puente"])
    }

    func testCopyNeverMutatesExistingPlaylistAndCarriesSourceIdentity() {
        var options = SyncOptions(); options.existingPlaylist = .copy
        let preview = plan(request(options: options))
        XCTAssertEqual(preview.operations.count, 1)
        XCTAssertEqual(preview.operations[0].kind, .createPlaylist)
        XCTAssertNil(preview.operations[0].targetID)
        XCTAssertEqual(preview.operations[0].sourcePlaylist?.playlistID, "sp-ruta")
        XCTAssertEqual(preview.operations[0].tracks.count, 4)
        XCTAssertTrue(preview.issues.isEmpty)
    }

    func testUnrelatedUnmatchedTracksDoNotPolluteSelectedScope() {
        let selected = request(ref: .init(service: .spotify, playlistID: "sp-cafe"))
        let preview = plan(selected)
        XCTAssertFalse(preview.issues.contains { $0.detail.contains("Ensayo en casa") })
    }

    func testUnrelatedBrokenPlaylistLinksDoNotMakeSelectedScopePartial() {
        var choices = self.choices; choices.playlists = []
        let selected = request(ref: .init(service: .spotify, playlistID: "sp-cafe"))
        let preview = SyncPlanner.makePlan(snapshots: inventory, mode: selected.mode, decisions: choices, capabilities: capabilities, request: selected)
        XCTAssertTrue(preview.issues.isEmpty)
    }

    func testFrozenTargetOverridesAnUnrelatedGlobalLink() {
        var selected = request()
        selected.playlistTargets = [PlaylistTarget(source: selected.playlists[0], targetID: "am-archivo")]
        let preview = plan(selected)
        XCTAssertTrue(preview.operations.allSatisfy { $0.targetID == "am-archivo" })
        XCTAssertFalse(preview.operations.isEmpty)
    }

    func testDuplicateFrozenTargetsBlockAllOperations() {
        var selected = request()
        selected.playlistTargets = [PlaylistTarget(source: selected.playlists[0], targetID: "am-ruta"), PlaylistTarget(source: selected.playlists[0], targetID: "am-archivo")]
        XCTAssertTrue(plan(selected).operations.isEmpty)
    }

    func testMissingCopyTargetDoesNotCreateAnotherCopy() {
        var options = SyncOptions(); options.existingPlaylist = .copy
        var scoped = request(options: options)
        scoped.copyTargets = [PlaylistTarget(source: scoped.playlists[0], targetID: "missing-copy")]
        XCTAssertTrue(plan(scoped).operations.isEmpty)
        XCTAssertTrue(plan(scoped).issues.contains { $0.title == "Copia pendiente" })
    }

    func testMergeExpandsOnlySelectedLinkedPairAndNeverDeletes() {
        let preview = plan(request(mode: .merge))
        XCTAssertTrue(preview.operations.allSatisfy { ["am-ruta", "sp-ruta"].contains($0.targetID ?? "") })
        XCTAssertFalse(preview.operations.contains { $0.kind.isDestructive })
    }

    func testConfigurationRevisionAndOptionsChangePreviewIdentity() {
        let initial = request()
        var changed = initial; changed.revision += 1
        XCTAssertNotEqual(plan(initial).id, plan(changed).id)
        changed = initial; changed.options.skipDuplicates = true
        XCTAssertNotEqual(plan(initial).id, plan(changed).id)
    }

    func testLegacyPlanAndTrackDecodeWithoutNewFields() throws {
        let old = SyncPlan(mode: .merge, snapshots: inventory, operations: [])
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        json.removeValue(forKey: "request"); json.removeValue(forKey: "undoOfRunID")
        let decoded = try JSONDecoder().decode(SyncPlan.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.request); XCTAssertEqual(decoded.snapshots, inventory)
    }

    func testScheduledReviewDedupesAndNeverReplaysMissedIntervals() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var schedule = ReviewSchedule(); schedule.enabled = true; schedule.nextReview = now.addingTimeInterval(-86_400 * 4)
        var workspace = SyncWorkspace(); workspace.profiles = [SyncProfile(request: request(), schedule: schedule)]
        XCTAssertEqual(workspace.enqueueDue(at: now, accounts: inventory.map(\.account)), 1)
        XCTAssertEqual(workspace.jobs.count, 1)
        XCTAssertEqual(workspace.jobs[0].state, .queued)
        XCTAssertNil(workspace.jobs[0].plan)
        XCTAssertGreaterThan(workspace.profiles[0].schedule.nextReview!, now)
        XCTAssertEqual(workspace.enqueueDue(at: now.addingTimeInterval(86_400 * 3), accounts: inventory.map(\.account)), 0)
    }

    func testDisconnectedAndDemoProfilesDoNotScheduleOrConsumeDueDate() {
        let now = Date()
        var schedule = ReviewSchedule(); schedule.enabled = true; schedule.nextReview = now.addingTimeInterval(-1)
        var workspace = SyncWorkspace(); workspace.profiles = [SyncProfile(request: request(), schedule: schedule)]
        XCTAssertEqual(workspace.enqueueDue(at: now, accounts: []), 0)
        XCTAssertEqual(workspace.profiles[0].schedule.nextReview, schedule.nextReview)
        workspace.profiles[0].isDemo = true
        XCTAssertEqual(workspace.enqueueDue(at: now, accounts: inventory.map(\.account)), 0)
    }

    func testScheduleUsesTimeZoneAndHandlesDaylightSavingGap() throws {
        var schedule = ReviewSchedule(); schedule.timeZoneID = "America/New_York"; schedule.hour = 2; schedule.minute = 30
        let before = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-03-08T06:50:00Z"))
        let next = try XCTUnwrap(schedule.next(after: before))
        XCTAssertGreaterThan(next, before)
        XCTAssertLessThan(next.timeIntervalSince(before), 3600)
        schedule.timeZoneID = "Invalid/Zone"
        XCTAssertNil(schedule.next(after: before))
    }

    func testRestartNeverRestoresExecutingJobsAsApproved() {
        var workspace = SyncWorkspace()
        var applying = ReviewJob(request: request()); applying.state = .applying
        var analyzing = ReviewJob(request: request()); analyzing.state = .analyzing
        workspace.jobs = [applying, analyzing]; workspace.recoverAfterRestart()
        XCTAssertEqual(workspace.jobs.map(\.state), [.attention, .queued])
    }

    func testSQLiteWorkspaceMigrationBacksUpLegacyDatabaseAndPreservesJournal() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("test.sqlite")
        var pointer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &pointer), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(pointer, "CREATE TABLE runs(id TEXT PRIMARY KEY, started REAL NOT NULL, payload BLOB NOT NULL); CREATE TABLE decisions(account_pair TEXT PRIMARY KEY,payload BLOB NOT NULL); PRAGMA user_version=0", nil, nil, nil), SQLITE_OK)
        sqlite3_close(pointer)
        let store = try SyncStore(url: url)
        var value = SyncWorkspace(); value.profiles = [SyncProfile(request: request())]
        try await store.saveWorkspace(value)
        let restored = try await store.loadWorkspace()
        XCTAssertEqual(restored, value)
        let backups = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("library-sync-before-workspace-") }
        XCTAssertEqual(backups.count, 1)
        let another = try SyncStore(url: url)
        let anotherValue = try await another.loadWorkspace()
        XCTAssertEqual(anotherValue, value)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix("library-sync-before-workspace-") }.count, 1)
    }

    func testHistoryClearRetainsUnknownWrites() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("test.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try SyncStore(url: url)
        let operation = SyncOperation(service: .appleMusic, kind: .addPlaylistTracks, title: "Prueba")
        let record = RunRecord(summary: RunSummary(status: .partial), plan: plan(request()), decisions: choices,
                               executions: [OperationExecution(operation: operation, state: .unknown, before: inventory[1])], checkpoints: inventory)
        try await store.save(record)
        var settled = record; settled.summary.id = UUID(); settled.summary.status = .completed; settled.executions[0].state = .verified
        try await store.save(settled)
        let count = try await store.clearSettledHistory()
        XCTAssertEqual(count, 1)
        let preserved = try await store.load(id: record.id), removed = try await store.load(id: settled.id)
        XCTAssertNotNil(preserved); XCTAssertNil(removed)
    }

    func testUndoRequiresUnchangedStateAndRespectsProviderCapabilities() {
        var after = inventory
        let old = after[1].playlists[0].tracks
        after[1].playlists[0].tracks = Array(old.reversed())
        let operation = SyncOperation(service: .appleMusic, kind: .replacePlaylistTracks, targetID: "am-ruta", title: "Cambio")
        let record = RunRecord(summary: RunSummary(status: .completed), plan: plan(request()), decisions: choices,
                               executions: [OperationExecution(operation: operation, state: .verified, before: inventory[1])], checkpoints: after, finalSnapshots: after)
        let inverse = UndoPlanner.makePlan(record: record, current: after, capabilities: [.spotify: .spotify, .appleMusic: .appleMusic])
        XCTAssertEqual(inverse.operations.count, 1)
        XCTAssertNotNil(inverse.operations[0].blockedReason)
        XCTAssertEqual(inverse.operations[0].tracks, old)
        XCTAssertEqual(inverse.undoOfRunID, record.id)
        after[1].savedTracks.removeAll()
        XCTAssertTrue(UndoPlanner.makePlan(record: record, current: after, capabilities: capabilities).operations.isEmpty)
    }

    func testHistoryCSVQuotesNewlinesAndNeutralizesFormulas() {
        let csv = HistoryCSV.encode([RunSummary(message: "=SUM(1,2)\n\"dato\"")])
        XCTAssertTrue(csv.contains("\"'=SUM(1,2)\n\"\"dato\"\"\""))
    }

    func testVerifiedCopyTargetRecoversFromJournalAfterCrashBeforeWorkspaceSave() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("test.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try SyncStore(url: url)
        var options = SyncOptions(); options.existingPlaylist = .copy
        let profile = SyncProfile(request: request(options: options))
        var workspace = SyncWorkspace(); workspace.profiles = [profile]
        let preview = plan(profile.request)
        let creation = try XCTUnwrap(preview.operations.first { $0.kind == .createPlaylist })
        var record = RunRecord(summary: RunSummary(status: .interrupted), plan: preview, decisions: choices,
                               executions: [OperationExecution(operation: creation, state: .verified, before: inventory[1], receipt: MutationReceipt(createdID: "durable-copy"))], checkpoints: inventory)
        try await store.save(record)
        let recovered = try await store.restoreVerifiedTargets(in: workspace)
        XCTAssertEqual(recovered.profiles[0].request.copyTargets.first?.targetID, "durable-copy")
        record.executions[0].state = .unknown; try await store.save(record)
        let uncertain = try await store.restoreVerifiedTargets(in: workspace)
        XCTAssertTrue(uncertain.profiles[0].request.copyTargets.isEmpty)
    }

    func testConflictingRecoveredCopyTargetsDoNotPickOneImplicitly() {
        var options = SyncOptions(); options.existingPlaylist = .copy
        var scoped = request(options: options)
        scoped.copyTargets = [PlaylistTarget(source: scoped.playlists[0], targetID: "first"), PlaylistTarget(source: scoped.playlists[0], targetID: "second")]
        XCTAssertTrue(plan(scoped).operations.isEmpty)
    }

    func testFutureSQLiteSchemaIsRejectedWithoutAddingTables() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("test.sqlite")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var pointer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &pointer), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(pointer, "PRAGMA user_version=3; CREATE TABLE future_data(value TEXT)", nil, nil, nil), SQLITE_OK)
        sqlite3_close(pointer)
        XCTAssertThrowsError(try SyncStore(url: url))
        XCTAssertEqual(sqlite3_open(url.path, &pointer), SQLITE_OK)
        defer { sqlite3_close(pointer) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(pointer, "SELECT count(*) FROM sqlite_master WHERE name IN ('runs','decisions','workspace')", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(statement, 0), 0)
    }

    func testUndoHonorsNewProtectionAndRejectsUnknownWrites() {
        var after = inventory; after[0].playlists[0].tracks.reverse()
        let operation = SyncOperation(service: .spotify, kind: .replacePlaylistTracks, targetID: "sp-ruta", title: "Cambio")
        var record = RunRecord(summary: RunSummary(status: .completed), plan: plan(request(mode: .appleMusicBase, ref: .init(service: .appleMusic, playlistID: "am-ruta"))), decisions: choices,
                               executions: [OperationExecution(operation: operation, state: .verified, before: inventory[0])], checkpoints: after, finalSnapshots: after)
        var current = choices; current.protectedPlaylistIDs[.spotify] = ["sp-ruta"]
        let inverse = UndoPlanner.makePlan(record: record, current: after, capabilities: capabilities, decisions: current)
        XCTAssertTrue(inverse.operations.contains { $0.blockedReason?.contains("protegida") == true })
        record.executions[0].state = .unknown
        XCTAssertTrue(UndoPlanner.makePlan(record: record, current: after, capabilities: capabilities).operations.isEmpty)
    }

    func testCompletedNoChangeReviewDoesNotBlockNextScheduledOccurrence() {
        let now = Date()
        var schedule = ReviewSchedule(); schedule.enabled = true; schedule.nextReview = now.addingTimeInterval(-1)
        let profile = SyncProfile(request: request(), schedule: schedule)
        var workspace = SyncWorkspace(); workspace.profiles = [profile]
        workspace.enqueueDue(at: now, accounts: inventory.map(\.account))
        workspace.jobs[0].state = .completed
        XCTAssertEqual(workspace.enqueueDue(at: now.addingTimeInterval(86_400 * 3), accounts: inventory.map(\.account)), 1)
    }

    func testExecutorRejectsConfigurationChangedInAnotherStoreBeforeWriting() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("test.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try SyncStore(url: url), otherStore = try SyncStore(url: url)
        var options = SyncOptions(); options.existingPlaylist = .copy
        let profile = SyncProfile(request: request(options: options))
        var workspace = SyncWorkspace(); workspace.profiles = [profile]
        try await store.saveWorkspace(workspace)
        let preview = plan(profile.request)
        workspace.profiles[0].request.revision += 1
        try await otherStore.saveWorkspace(workspace)
        let spotify = DemoMusicProvider(snapshot: inventory[0]), apple = DemoMusicProvider(snapshot: inventory[1])
        let result = try await SyncExecutor(store: store, verificationDelays: [0]).execute(plan: preview, selectedIDs: Set(preview.executable.map(\.id)), decisions: choices, providers: [.spotify: spotify, .appleMusic: apple])
        XCTAssertEqual(result.summary.status, .failed)
        XCTAssertTrue(result.summary.message.contains("configuración"))
        let after = try await apple.fetchLibrary()
        XCTAssertEqual(after.stateFingerprint, inventory[1].stateFingerprint)
        XCTAssertEqual(result.summary.verifiedCount, 0)
    }
}
