import XCTest
@testable import SyncCore

/// Writes and reads are separate so a successful request can remain invisible for arbitrarily
/// many reads, just as with an eventually consistent provider.
private actor RecoveryProvider: MusicProvider {
    enum Behavior { case immediate, delayedSuccess, delayedTimeout, partialBatch }
    nonisolated let service: MusicService
    private var actual: LibrarySnapshot
    private var visible: LibrarySnapshot
    private let behavior: Behavior
    private var sent: [SyncOperation] = []
    private var firstRead: (@Sendable () async -> Void)?

    init(_ snapshot: LibrarySnapshot, behavior: Behavior = .immediate, firstRead: (@Sendable () async -> Void)? = nil) {
        actual = snapshot; visible = snapshot; service = snapshot.account.service; self.behavior = behavior
        self.firstRead = firstRead
    }
    func account() async throws -> ConnectedAccount { visible.account }
    func capabilities() async -> ProviderCapabilities { .spotify }
    func fetchLibrary() async throws -> LibrarySnapshot {
        if let action = firstRead { firstRead = nil; await action() }
        var copy = visible; copy.id = UUID(); copy.fetchedAt = Date(); return copy
    }
    func searchTracks(matching track: Track) async throws -> CatalogSearchResult<Track> { .init() }
    func searchAlbums(matching album: Album) async throws -> CatalogSearchResult<Album> { .init() }
    func writes() -> [SyncOperation] { sent }
    func reveal() { visible = actual }
    func setSnapshot(_ snapshot: LibrarySnapshot) { visible = snapshot; actual = snapshot }

    func perform(_ operation: SyncOperation) async throws -> MutationReceipt {
        sent.append(operation)
        let partial = behavior == .partialBatch && sent.count == 1
        let tracks = partial ? Array(operation.tracks.prefix(1)) : operation.tracks
        let albums = partial ? Array(operation.albums.prefix(1)) : operation.albums
        var receipt = MutationReceipt(message: "Petición aceptada")
        switch operation.kind {
        case .createPlaylist:
            let id = "created-\(sent.count)"
            actual.playlists.append(Playlist(id: id, name: operation.playlistName ?? "", description: operation.playlistDescription ?? "", tracks: tracks))
            receipt.createdID = id
        case .addPlaylistTracks:
            if let index = actual.playlists.firstIndex(where: { $0.id == operation.targetID }) { actual.playlists[index].tracks += tracks }
        case .saveTracks:
            actual.savedTracks += tracks.filter { track in !actual.savedTracks.contains { $0.playableID == track.playableID } }
        case .removeTracks:
            let ids = Set(tracks.map(\.playableID)); actual.savedTracks.removeAll { ids.contains($0.playableID) }
        case .saveAlbums:
            actual.savedAlbums += albums.filter { album in !actual.savedAlbums.contains { $0.playableID == album.playableID } }
        case .removeAlbums:
            let ids = Set(albums.map(\.playableID)); actual.savedAlbums.removeAll { ids.contains($0.playableID) }
        default: XCTFail("Unexpected operation: \(operation.kind)")
        }
        if behavior == .immediate || behavior == .partialBatch { visible = actual }
        if behavior == .delayedTimeout || partial { throw ProviderError.uncertainWrite("Respuesta perdida después del envío") }
        return receipt
    }
}

final class ExecutorRecoveryTests: XCTestCase {
    private let song = Track(id: "song", title: "Luz", artist: "Sur")

    private func snapshots() -> (LibrarySnapshot, LibrarySnapshot) {
        (LibrarySnapshot(account: ConnectedAccount(id: "spotify-user", service: .spotify, displayName: "S", connectionRevision: "s-old")),
         LibrarySnapshot(account: ConnectedAccount(id: "apple-grant-hash", service: .appleMusic, displayName: "A", connectionRevision: "a-old")))
    }
    private func storage() throws -> SyncStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("executor-recovery-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try SyncStore(url: directory.appendingPathComponent("journal.sqlite"))
    }
    private func record(_ snapshots: [LibrarySnapshot], executions: [OperationExecution]) -> RunRecord {
        RunRecord(summary: RunSummary(status: .interrupted, verifiedCount: executions.filter { $0.state == .verified }.count, totalCount: executions.count),
                  plan: SyncPlan(mode: .spotifyBase, snapshots: snapshots, operations: executions.map(\.operation)),
                  decisions: MatchDecisions(), executions: executions, checkpoints: snapshots)
    }
    private func saveOperation(_ track: Track? = nil) -> SyncOperation {
        SyncOperation(service: .appleMusic, kind: .saveTracks, title: "Guardar", tracks: [track ?? song])
    }

    func testDelayedCreateNeverRetriesOnStaleReadEvenWithCreatedID() async throws {
        for behavior in [RecoveryProvider.Behavior.delayedSuccess, .delayedTimeout] {
            let (s, a) = snapshots()
            let operation = SyncOperation(service: .appleMusic, kind: .createPlaylist, title: "Viaje", playlistName: "Viaje", tracks: [song, song])
            let plan = SyncPlan(mode: .spotifyBase, snapshots: [s, a], operations: [operation])
            let spotify = RecoveryProvider(s), apple = RecoveryProvider(a, behavior: behavior)
            let store = try storage(), executor = SyncExecutor(store: store, verificationDelays: [0, 0])
            let providers: [MusicService: any MusicProvider] = [.spotify: spotify, .appleMusic: apple]
            let first = try await executor.execute(plan: plan, selectedIDs: [operation.id], decisions: MatchDecisions(), providers: providers)
            XCTAssertEqual(first.executions[0].state, .unknown)
            if behavior == .delayedSuccess { XCTAssertEqual(first.executions[0].receipt?.createdID, "created-1") }
            for _ in 0..<2 {
                let resumed = try await executor.resume(id: first.id, providers: providers)
                XCTAssertEqual(resumed.executions[0].state, .unknown)
                XCTAssertEqual(resumed.executions[0].before, first.executions[0].before)
                XCTAssertEqual(resumed.executions[0].receipt, first.executions[0].receipt)
                XCTAssertEqual(resumed.executions[0].error, first.executions[0].error)
                let writes = await apple.writes(); XCTAssertEqual(writes.count, 1)
            }
            await apple.reveal()
            let recovered = try await executor.resume(id: first.id, providers: providers)
            XCTAssertEqual(recovered.executions[0].state, .verified)
            XCTAssertEqual(recovered.summary.verifiedCount, 1)
            let writes = await apple.writes()
            XCTAssertEqual(writes.filter { $0.kind == .createPlaylist }.count, 1)
            XCTAssertEqual(writes.filter { $0.kind == .addPlaylistTracks }.count, 1)
            XCTAssertEqual(recovered.executions[1].state, .unknown, "The separate append is still eventually consistent")
            let persisted = try await store.load(id: first.id)
            XCTAssertEqual(persisted?.executions[0].state, .verified)
        }
    }

    func testDelayedAppendPreservesMultiplicityAndNeverRetries() async throws {
        var (s, a) = snapshots()
        a.playlists = [Playlist(id: "p", name: "Viaje", tracks: [song])]
        let operation = SyncOperation(service: .appleMusic, kind: .addPlaylistTracks, targetID: "p", title: "Viaje", tracks: [song, song])
        let plan = SyncPlan(mode: .spotifyBase, snapshots: [s, a], operations: [operation])
        let apple = RecoveryProvider(a, behavior: .delayedTimeout), spotify = RecoveryProvider(s)
        let executor = SyncExecutor(store: try storage(), verificationDelays: [0])
        let providers: [MusicService: any MusicProvider] = [.spotify: spotify, .appleMusic: apple]
        let first = try await executor.execute(plan: plan, selectedIDs: [operation.id], decisions: MatchDecisions(), providers: providers)
        let stale = try await executor.resume(id: first.id, providers: providers)
        XCTAssertEqual(stale.executions[0].state, .unknown)
        await apple.reveal()
        let recovered = try await executor.resume(id: first.id, providers: providers)
        XCTAssertEqual(recovered.executions[0].state, .verified)
        let writes = await apple.writes(); XCTAssertEqual(writes.count, 1)
        let final = try await apple.fetchLibrary(); XCTAssertEqual(final.playlists[0].tracks.count, 3)
    }

    func testNewExecutionCannotBypassOldUncertaintyWithNewConnectionRevision() async throws {
        for state in [ExecutionState.applying, .unknown] {
            let (s, a) = snapshots()
            let create = SyncOperation(service: .appleMusic, kind: .createPlaylist, title: "Incierta", playlistName: "Incierta")
            var old = record([s, a], executions: [OperationExecution(operation: create, state: state, before: a)])
            old.summary.startedAt = Date(timeIntervalSince1970: 1)
            let store = try storage(); try await store.save(old)
            // The blocking request is deliberately outside recent(limit: 50).
            for _ in 0..<51 { try await store.save(record([s, a], executions: [])) }
            var newS = s, newA = a
            newS.account.connectionRevision = "s-new"; newA.account.connectionRevision = "a-new"
            let spotify = RecoveryProvider(newS), apple = RecoveryProvider(newA), operation = saveOperation()
            let plan = SyncPlan(mode: .spotifyBase, snapshots: [newS, newA], operations: [operation])
            let result = try await SyncExecutor(store: store, verificationDelays: [0]).execute(plan: plan, selectedIDs: [operation.id], decisions: MatchDecisions(), providers: [.spotify: spotify, .appleMusic: apple])
            XCTAssertEqual(result.summary.status, .failed)
            XCTAssertTrue(result.summary.message.contains(old.id.uuidString))
            XCTAssertEqual(result.executions[0].state, .pending)
            let writes = await apple.writes(); XCTAssertTrue(writes.isEmpty)
            let saved = try await store.load(id: old.id); XCTAssertEqual(saved?.executions[0].state, state)
        }
    }

    func testRevokedPendingApprovalCannotBeRestoredBySavingStaleRecord() async throws {
        let (s, a) = snapshots()
        let pending = record([s, a], executions: [OperationExecution(operation: saveOperation())])
        let store = try storage(); try await store.save(pending)
        let databaseURL = await store.url
        let otherStore = try SyncStore(url: databaseURL)
        try await otherStore.revokeApprovals(accountIDs: [.appleMusic: a.account.id])
        try await store.save(pending) // An older in-flight executor value must not undo revocation.
        let apple = RecoveryProvider(a), spotify = RecoveryProvider(s)
        let result = try await SyncExecutor(store: store, verificationDelays: [0]).resume(id: pending.id, providers: [.spotify: spotify, .appleMusic: apple])
        XCTAssertTrue(result.approvalRevoked)
        XCTAssertEqual(result.summary.status, .failed)
        XCTAssertEqual(result.executions[0].state, .pending)
        let writes = await apple.writes(); XCTAssertTrue(writes.isEmpty)
        let persisted = try await otherStore.load(id: pending.id); XCTAssertEqual(persisted?.approvalRevoked, true)
    }

    func testRevocationDuringProgressStopsDurablyJournaledButUnsentWrite() async throws {
        let (s, a) = snapshots(), store = try storage(), operation = saveOperation()
        let apple = RecoveryProvider(a), spotify = RecoveryProvider(s)
        let plan = SyncPlan(mode: .spotifyBase, snapshots: [s, a], operations: [operation])
        let result = try await SyncExecutor(store: store, verificationDelays: [0]).execute(plan: plan, selectedIDs: [operation.id], decisions: MatchDecisions(), providers: [.spotify: spotify, .appleMusic: apple]) { update in
            if update.message == "Guardar canción en Apple Music" {
                do { try await store.revokeApprovals(accountIDs: [.spotify: s.account.id, .appleMusic: a.account.id]) }
                catch { XCTFail("\(error)") }
            }
        }
        XCTAssertTrue(result.approvalRevoked)
        XCTAssertEqual(result.executions[0].state, .pending)
        XCTAssertNil(result.executions[0].before)
        let writes = await apple.writes(); XCTAssertTrue(writes.isEmpty)
        let persisted = try await store.load(id: result.id)
        XCTAssertEqual(persisted?.approvalRevoked, true)
        XCTAssertEqual(persisted?.executions[0].state, .pending)
    }

    func testPolicyChangeDuringFirstReadRevokesTheNewExecution() async throws {
        let (s, a) = snapshots(), store = try storage(), operation = saveOperation()
        let apple = RecoveryProvider(a)
        let spotify = RecoveryProvider(s, firstRead: {
            do { try await store.revokeApprovals(accountIDs: [.spotify: s.account.id]) }
            catch { XCTFail("\(error)") }
        })
        let plan = SyncPlan(mode: .spotifyBase, snapshots: [s, a], operations: [operation])
        let result = try await SyncExecutor(store: store, verificationDelays: [0]).execute(plan: plan, selectedIDs: [operation.id], decisions: MatchDecisions(), providers: [.spotify: spotify, .appleMusic: apple])
        XCTAssertTrue(result.approvalRevoked)
        XCTAssertEqual(result.summary.status, .failed)
        XCTAssertEqual(result.executions[0].state, .pending)
        let writes = await apple.writes(); XCTAssertTrue(writes.isEmpty)
    }

    func testIncompleteUnchangedSnapshotsNeverAuthorizeExecuteOrResume() async throws {
        for incompleteBase in [false, true] {
            var (s, a) = snapshots()
            if incompleteBase { s.coverage.albums = false }
            else { a.playlists = [Playlist(id: "unread", name: "Incompleta", contentsComplete: false)] }
            let operation = saveOperation(), store = try storage()
            let apple = RecoveryProvider(a), spotify = RecoveryProvider(s)
            let plan = SyncPlan(mode: .spotifyBase, snapshots: [s, a], operations: [operation])
            let providers: [MusicService: any MusicProvider] = [.spotify: spotify, .appleMusic: apple]
            let executor = SyncExecutor(store: store, verificationDelays: [0])
            let result = try await executor.execute(plan: plan, selectedIDs: [operation.id], decisions: MatchDecisions(), providers: providers)
            XCTAssertEqual(result.summary.status, .failed)
            XCTAssertEqual(result.executions[0].state, .pending)
            let resumed = try await executor.resume(id: result.id, providers: providers)
            XCTAssertEqual(resumed.summary.status, .failed)
            let writes = await apple.writes(); XCTAssertTrue(writes.isEmpty)
        }
    }

    func testIncompleteFreshInventoryCannotAuthorizeACompletePreview() async throws {
        let (s, a) = snapshots(), operation = saveOperation()
        var incomplete = a; incomplete.coverage.tracks = false
        let apple = RecoveryProvider(incomplete), spotify = RecoveryProvider(s)
        let plan = SyncPlan(mode: .spotifyBase, snapshots: [s, a], operations: [operation])
        let result = try await SyncExecutor(store: try storage(), verificationDelays: [0]).execute(plan: plan, selectedIDs: [operation.id], decisions: MatchDecisions(), providers: [.spotify: spotify, .appleMusic: apple])
        XCTAssertEqual(result.summary.status, .failed)
        let writes = await apple.writes(); XCTAssertTrue(writes.isEmpty)
    }

    func testCancelInProgressAfterIntentIsDurableRestoresPendingWithoutWriting() async throws {
        let (s, a) = snapshots(), store = try storage(), operation = saveOperation()
        let executor = SyncExecutor(store: store, verificationDelays: [0])
        let apple = RecoveryProvider(a), spotify = RecoveryProvider(s)
        let plan = SyncPlan(mode: .spotifyBase, snapshots: [s, a], operations: [operation])
        let providers: [MusicService: any MusicProvider] = [.spotify: spotify, .appleMusic: apple]
        let result = try await executor.execute(plan: plan, selectedIDs: [operation.id], decisions: MatchDecisions(), providers: providers) { update in
            if update.message == "Guardar canción en Apple Music" {
                do {
                    let intent = try await store.recent().first
                    XCTAssertEqual(intent?.executions[0].state, .applying)
                } catch { XCTFail("\(error)") }
                await executor.cancel()
            }
        }
        XCTAssertEqual(result.summary.status, .cancelled)
        XCTAssertEqual(result.executions[0].state, .pending)
        XCTAssertNil(result.executions[0].before)
        let writes = await apple.writes(); XCTAssertTrue(writes.isEmpty)
        let persisted = try await store.load(id: result.id)
        XCTAssertEqual(persisted?.executions[0].state, .pending)
        let resumed = try await executor.resume(id: result.id, providers: providers)
        XCTAssertEqual(resumed.executions[0].state, .verified)
        let resumedWrites = await apple.writes(); XCTAssertEqual(resumedWrites.count, 1)
    }

    func testReadOnlyRecoveryRebindsSameAccountAndPreservesOriginalBackups() async throws {
        let (s, a) = snapshots()
        let create = SyncOperation(service: .appleMusic, kind: .createPlaylist, title: "Viaje", playlistName: "Viaje", tracks: [song])
        let original = record([s, a], executions: [OperationExecution(operation: create, state: .applying, before: a), OperationExecution(operation: saveOperation())])
        let store = try storage(); try await store.save(original)
        var newS = s, newA = a
        newS.account.connectionRevision = "s-restarted"; newA.account.connectionRevision = "a-restarted"
        newA.playlists = [Playlist(id: "created-before-restart", name: "Viaje", tracks: [song])]
        let apple = RecoveryProvider(newA), spotify = RecoveryProvider(newS)
        let providers: [MusicService: any MusicProvider] = [.spotify: spotify, .appleMusic: apple]
        let executor = SyncExecutor(store: store, verificationDelays: [0])
        let recovered = try await executor.reconcile(id: original.id, providers: providers)
        XCTAssertEqual(recovered.executions.map(\.state), [.verified, .pending])
        XCTAssertEqual(recovered.summary.verifiedCount, 1)
        XCTAssertTrue(recovered.approvalRevoked)
        XCTAssertEqual(recovered.plan.snapshots, original.plan.snapshots)
        XCTAssertEqual(recovered.executions[0].before, a)
        XCTAssertEqual(recovered.executions[0].receipt?.createdID, "created-before-restart")
        XCTAssertEqual(recovered.checkpoints.first { $0.account.service == .appleMusic }?.account.connectionRevision, "a-restarted")
        let resumed = try await executor.resume(id: original.id, providers: providers)
        XCTAssertEqual(resumed.summary.status, .failed)
        XCTAssertEqual(resumed.executions.map(\.state), [.verified, .pending])
        let writes = await apple.writes(); XCTAssertTrue(writes.isEmpty)
        let persisted = try await store.load(id: original.id)
        XCTAssertEqual(persisted?.plan.snapshots, original.plan.snapshots)
        XCTAssertEqual(persisted?.executions[0].before, a)
    }

    func testNewExecutionCanProceedAfterPriorUncertaintyIsReconciled() async throws {
        let (s, a) = snapshots()
        let create = SyncOperation(service: .appleMusic, kind: .createPlaylist, title: "Viaje", playlistName: "Viaje")
        let original = record([s, a], executions: [OperationExecution(operation: create, state: .unknown, before: a)])
        let store = try storage(); try await store.save(original)
        var fresh = a; fresh.account.connectionRevision = "restarted"
        fresh.playlists = [Playlist(id: "created", name: "Viaje")]
        let apple = RecoveryProvider(fresh), spotify = RecoveryProvider(s)
        let providers: [MusicService: any MusicProvider] = [.spotify: spotify, .appleMusic: apple]
        let executor = SyncExecutor(store: store, verificationDelays: [0])
        let recovered = try await executor.reconcile(id: original.id, providers: providers)
        XCTAssertEqual(recovered.executions[0].state, .verified)
        let operation = saveOperation()
        let newPlan = SyncPlan(mode: .spotifyBase, snapshots: [s, fresh], operations: [operation])
        let newRun = try await executor.execute(plan: newPlan, selectedIDs: [operation.id], decisions: MatchDecisions(), providers: providers)
        XCTAssertEqual(newRun.executions[0].state, .verified)
        XCTAssertFalse(newRun.approvalRevoked)
        let writes = await apple.writes(); XCTAssertEqual(writes.count, 1)
    }

    func testReadOnlyRecoveryKeepsAbsentResultsUnknownIncludingIdempotentWrites() async throws {
        for kind in [OperationKind.createPlaylist, .addPlaylistTracks, .saveTracks] {
            var (s, a) = snapshots()
            a.playlists = [Playlist(id: "p", name: "Existing")]
            let operation = SyncOperation(service: .appleMusic, kind: kind, targetID: "p", title: "Pendiente", playlistName: "Nueva", tracks: [song])
            let receipt = MutationReceipt(createdID: kind == .createPlaylist ? "not-visible-yet" : nil)
            let original = record([s, a], executions: [OperationExecution(operation: operation, state: .applying, before: a, receipt: receipt, error: "timeout")])
            let store = try storage(); try await store.save(original)
            var fresh = a; fresh.account.connectionRevision = "reconnected"
            let apple = RecoveryProvider(fresh), spotify = RecoveryProvider(s)
            let result = try await SyncExecutor(store: store, verificationDelays: [0]).reconcile(id: original.id, providers: [.spotify: spotify, .appleMusic: apple])
            XCTAssertEqual(result.executions[0].state, .unknown)
            XCTAssertEqual(result.executions[0].before, a)
            XCTAssertEqual(result.executions[0].receipt, receipt)
            XCTAssertEqual(result.executions[0].error, "timeout")
            XCTAssertTrue(result.approvalRevoked)
            let writes = await apple.writes(); XCTAssertTrue(writes.isEmpty)
        }
    }

    func testReadOnlyRecoveryRejectsDifferentStableAccountAndStillRevokesApproval() async throws {
        let (s, a) = snapshots(), operation = saveOperation()
        let original = record([s, a], executions: [OperationExecution(operation: operation, state: .applying, before: a)])
        let store = try storage(); try await store.save(original)
        var otherAccount = a; otherAccount.account.id = "another-grant"; otherAccount.savedTracks = [song]
        let apple = RecoveryProvider(otherAccount), spotify = RecoveryProvider(s)
        let result = try await SyncExecutor(store: store, verificationDelays: [0]).reconcile(id: original.id, providers: [.spotify: spotify, .appleMusic: apple])
        XCTAssertEqual(result.summary.status, .failed)
        XCTAssertEqual(result.executions[0].state, .unknown)
        XCTAssertTrue(result.approvalRevoked)
        XCTAssertEqual(result.checkpoints, original.checkpoints)
        XCTAssertEqual(result.plan.snapshots, original.plan.snapshots)
        let writes = await apple.writes(); XCTAssertTrue(writes.isEmpty)
        let persisted = try await store.load(id: original.id); XCTAssertEqual(persisted?.approvalRevoked, true)
    }

    func testRecoveryRecordsVerifiedEffectsButDoesNotAcceptUnrelatedChanges() async throws {
        let (s, a) = snapshots(), operation = saveOperation()
        let missing = saveOperation(Track(id: "missing", title: "Pendiente", artist: "Sur"))
        let original = record([s, a], executions: [OperationExecution(operation: operation, state: .unknown, before: a), OperationExecution(operation: missing, state: .unknown, before: a)])
        let store = try storage(); try await store.save(original)
        var changed = a; changed.savedTracks = [song, Track(id: "external", title: "Manual", artist: "Otro")]
        changed.account.connectionRevision = "restarted"
        let apple = RecoveryProvider(changed), spotify = RecoveryProvider(s)
        let result = try await SyncExecutor(store: store, verificationDelays: [0]).reconcile(id: original.id, providers: [.spotify: spotify, .appleMusic: apple])
        XCTAssertEqual(result.summary.status, .failed)
        XCTAssertEqual(result.executions.map(\.state), [.verified, .unknown])
        XCTAssertEqual(result.summary.verifiedCount, 1)
        XCTAssertEqual(result.checkpoints, original.checkpoints)
        let persisted = try await store.load(id: original.id)
        XCTAssertEqual(persisted?.summary.verifiedCount, 1)
        XCTAssertEqual(persisted?.executions.map(\.state), [.verified, .unknown])
        let writes = await apple.writes(); XCTAssertTrue(writes.isEmpty)
    }

    func testPartiallyAppliedLibraryBatchRetriesOnlyUnchangedSiblings() async throws {
        for kind in [OperationKind.saveTracks, .removeTracks, .saveAlbums, .removeAlbums] {
            var (s, a) = snapshots()
            let tracks = (1...3).map { Track(id: "track-\($0)", title: "Canción \($0)", artist: "Sur") }
            let albums = (1...3).map { Album(id: "album-\($0)", title: "Álbum \($0)", artist: "Sur") }
            let isAlbum = kind == .saveAlbums || kind == .removeAlbums
            if kind == .removeTracks { a.savedTracks = tracks }
            if kind == .removeAlbums { a.savedAlbums = albums }
            let operations = (0..<3).map { index in
                SyncOperation(service: .appleMusic, kind: kind, title: "\(index)", tracks: isAlbum ? [] : [tracks[index]], albums: isAlbum ? [albums[index]] : [])
            }
            let plan = SyncPlan(mode: .spotifyBase, snapshots: [s, a], operations: operations)
            let store = try storage(), executor = SyncExecutor(store: store, verificationDelays: [0])
            let apple = RecoveryProvider(a, behavior: .partialBatch), spotify = RecoveryProvider(s)
            let providers: [MusicService: any MusicProvider] = [.spotify: spotify, .appleMusic: apple]
            let partial = try await executor.execute(plan: plan, selectedIDs: Set(operations.map(\.id)), decisions: MatchDecisions(), providers: providers)
            XCTAssertEqual(partial.executions.map(\.state), [.verified, .unknown, .unknown], "\(kind)")
            XCTAssertEqual(partial.summary.verifiedCount, 1)
            let resumed = try await executor.resume(id: partial.id, providers: providers)
            XCTAssertEqual(resumed.executions.map(\.state), [.verified, .verified, .verified], "\(kind)")
            XCTAssertEqual(resumed.summary.verifiedCount, 3)
            XCTAssertEqual(resumed.executions[1].before, partial.executions[1].before)
            XCTAssertEqual(resumed.executions[1].error, partial.executions[1].error)
            let writes = await apple.writes(); XCTAssertEqual(writes.count, 2)
            if writes.count == 2 {
                XCTAssertEqual(writes[1].tracks.map(\.id), isAlbum ? [] : Array(tracks.dropFirst()).map(\.id))
                XCTAssertEqual(writes[1].albums.map(\.id), isAlbum ? Array(albums.dropFirst()).map(\.id) : [])
            }
            let persisted = try await store.load(id: partial.id); XCTAssertEqual(persisted?.summary.verifiedCount, 3)
        }
    }

    func testMissingPreviouslyVerifiedSiblingPreventsRetry() async throws {
        let (s, a) = snapshots()
        let other = saveOperation(Track(id: "second", title: "Otra", artist: "Sur"))
        let original = record([s, a], executions: [OperationExecution(operation: saveOperation(), state: .verified, before: a), OperationExecution(operation: other, state: .unknown, before: a)])
        let store = try storage(); try await store.save(original)
        let apple = RecoveryProvider(a), spotify = RecoveryProvider(s)
        let result = try await SyncExecutor(store: store, verificationDelays: [0]).resume(id: original.id, providers: [.spotify: spotify, .appleMusic: apple])
        XCTAssertEqual(result.summary.status, .failed)
        XCTAssertEqual(result.executions.map(\.state), [.verified, .unknown])
        XCTAssertEqual(result.summary.verifiedCount, 1)
        let writes = await apple.writes(); XCTAssertTrue(writes.isEmpty)
    }

    func testBaseChangeDoesNotConvertUncertainLibraryWriteIntoPending() async throws {
        let (s, a) = snapshots()
        let original = record([s, a], executions: [OperationExecution(operation: saveOperation(), state: .unknown, before: a)])
        let store = try storage(); try await store.save(original)
        var changed = s; changed.playlists = [Playlist(id: "external", name: "Manual")]
        let apple = RecoveryProvider(a), spotify = RecoveryProvider(changed)
        let result = try await SyncExecutor(store: store, verificationDelays: [0]).resume(id: original.id, providers: [.spotify: spotify, .appleMusic: apple])
        XCTAssertEqual(result.summary.status, .failed)
        XCTAssertEqual(result.executions[0].state, .unknown)
        XCTAssertEqual(result.checkpoints, original.checkpoints)
        let writes = await apple.writes(); XCTAssertTrue(writes.isEmpty)
    }

    func testCancellingAnIdempotentRetryPreservesOriginalUncertainty() async throws {
        let (s, a) = snapshots(), operation = saveOperation()
        let original = record([s, a], executions: [OperationExecution(operation: operation, state: .unknown, before: a, error: "timeout")])
        let store = try storage(); try await store.save(original)
        let apple = RecoveryProvider(a), spotify = RecoveryProvider(s)
        let executor = SyncExecutor(store: store, verificationDelays: [0])
        let providers: [MusicService: any MusicProvider] = [.spotify: spotify, .appleMusic: apple]
        let cancelled = try await executor.resume(id: original.id, providers: providers) { update in
            if update.message == "Guardar canción en Apple Music" { await executor.cancel() }
        }
        XCTAssertEqual(cancelled.summary.status, .cancelled)
        XCTAssertEqual(cancelled.executions[0].state, .unknown)
        XCTAssertEqual(cancelled.executions[0].before, a)
        XCTAssertEqual(cancelled.executions[0].error, "timeout")
        let plan = SyncPlan(mode: .spotifyBase, snapshots: [s, a], operations: [operation])
        let blocked = try await executor.execute(plan: plan, selectedIDs: [operation.id], decisions: MatchDecisions(), providers: providers)
        XCTAssertEqual(blocked.summary.status, .failed)
        let writes = await apple.writes(); XCTAssertTrue(writes.isEmpty)
    }

    func testLegacyRecordsDecodeWithoutApprovalRevokedField() throws {
        let (s, a) = snapshots()
        let original = record([s, a], executions: [OperationExecution(operation: saveOperation())])
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        payload.removeValue(forKey: "approvalRevoked")
        let decoded = try JSONDecoder().decode(RunRecord.self, from: JSONSerialization.data(withJSONObject: payload))
        XCTAssertFalse(decoded.approvalRevoked)
        XCTAssertEqual(decoded, original)
    }
}
