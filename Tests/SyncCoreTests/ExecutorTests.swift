import XCTest
@testable import SyncCore

private actor ExecutionTestProvider: MusicProvider {
    nonisolated let service: MusicService
    var snapshot: LibrarySnapshot
    var writes = 0
    var failAfterWrite = false
    var extraTrackOnWrite: Track?
    init(_ snapshot: LibrarySnapshot, failAfterWrite: Bool = false, extraTrackOnWrite: Track? = nil) {
        self.snapshot = snapshot; service = snapshot.account.service; self.failAfterWrite = failAfterWrite; self.extraTrackOnWrite = extraTrackOnWrite
    }
    func account() async throws -> ConnectedAccount { snapshot.account }
    func capabilities() async -> ProviderCapabilities { .spotify }
    func fetchLibrary() async throws -> LibrarySnapshot { var copy = snapshot; copy.id = UUID(); copy.fetchedAt = Date(); return copy }
    func searchTracks(matching track: Track) async throws -> [Track] { [] }
    func searchAlbums(matching album: Album) async throws -> [Album] { [] }
    func setSnapshot(_ value: LibrarySnapshot) { snapshot = value }
    func writeCount() -> Int { writes }
    func perform(_ op: SyncOperation) async throws -> MutationReceipt {
        writes += 1
        var receipt = MutationReceipt()
        switch op.kind {
        case .saveTracks: snapshot.savedTracks.append(contentsOf: op.tracks.filter { t in !snapshot.savedTracks.contains { $0.playableID == t.playableID } })
        case .removeTracks:
            let ids = Set(op.tracks.map(\.playableID)); snapshot.savedTracks.removeAll { ids.contains($0.playableID) }
        case .createPlaylist:
            let id = "created-\(writes)"
            snapshot.playlists.append(Playlist(id: id, name: op.playlistName ?? "", description: op.playlistDescription ?? "", tracks: op.tracks))
            receipt = MutationReceipt(createdID: id)
        case .addPlaylistTracks:
            if let i = snapshot.playlists.firstIndex(where: { $0.id == op.targetID }) { snapshot.playlists[i].tracks += op.tracks }
        default: break
        }
        if let extraTrackOnWrite { snapshot.savedTracks.append(extraTrackOnWrite) }
        if failAfterWrite { throw ProviderError.uncertainWrite("La conexión se cortó después de enviar la petición.") }
        return receipt
    }
}

final class ExecutorTests: XCTestCase {
    private func fixture() -> (LibrarySnapshot, LibrarySnapshot, Track, Track, MatchDecisions) {
        let s = Track(id: "spotify-song", title: "Luz", artist: "Sur", durationMS: 180000, isrc: "AR0000000001", explicit: false)
        let a = Track(id: "apple-song", title: "Luz", artist: "Sur", durationMS: 180000, isrc: "AR0000000001", explicit: false)
        let spotify = LibrarySnapshot(account: ConnectedAccount(id: "s-user", service: .spotify, displayName: "S", connectionRevision: "s-rev"), savedTracks: [s])
        let apple = LibrarySnapshot(account: ConnectedAccount(id: "a-user", service: .appleMusic, displayName: "A", connectionRevision: "a-rev"))
        let decisions = MatchDecisions(tracks: [TrackMatch(sourceService: .spotify, source: s, candidates: [a], selected: a, confidence: .exact)])
        return (spotify, apple, s, a, decisions)
    }
    private func store() throws -> SyncStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("spotam-tests-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try SyncStore(url: directory.appendingPathComponent("sync.sqlite"))
    }

    func testStalePreviewNeverWrites() async throws {
        let (s, a, _, song, decisions) = fixture()
        let operation = SyncOperation(service: .appleMusic, kind: .saveTracks, title: song.title, tracks: [song])
        let plan = SyncPlan(mode: .spotifyBase, snapshots: [s, a], operations: [operation])
        var changed = a; changed.savedTracks = [Track(id: "external", title: "Nueva", artist: "Otro")]
        let spotify = ExecutionTestProvider(s), apple = ExecutionTestProvider(changed)
        let executor = SyncExecutor(store: try store(), verificationDelays: [0])
        let result = try await executor.execute(plan: plan, selectedIDs: [operation.id], decisions: decisions, providers: [.spotify: spotify, .appleMusic: apple])
        XCTAssertEqual(result.summary.status, .failed)
        let count = await apple.writeCount(); XCTAssertEqual(count, 0)
    }

    func testAppliedTimeoutIsReconciledWithoutDuplicatingCreate() async throws {
        var (s, a, source, target, decisions) = fixture()
        s.savedTracks = []; s.playlists = [Playlist(id: "source-list", name: "Viaje", tracks: [source, source])]
        let operation = SyncOperation(service: .appleMusic, kind: .createPlaylist, title: "Viaje", playlistName: "Viaje", tracks: [target, target])
        let plan = SyncPlan(mode: .spotifyBase, snapshots: [s, a], operations: [operation])
        let spotify = ExecutionTestProvider(s), apple = ExecutionTestProvider(a, failAfterWrite: true)
        let storage = try store(), executor = SyncExecutor(store: storage, verificationDelays: [0])
        let result = try await executor.execute(plan: plan, selectedIDs: [operation.id], decisions: decisions, providers: [.spotify: spotify, .appleMusic: apple])
        XCTAssertEqual(result.executions[0].state, .verified)
        XCTAssertEqual(result.executions[0].receipt?.createdID, "created-1")
        let count = await apple.writeCount(); XCTAssertEqual(count, 2, "Creation and append are individually journaled, without duplicates")
        XCTAssertEqual(result.executions[1].state, .verified)
        let saved = try await storage.load(id: result.id)
        XCTAssertEqual(saved?.executions[0].state, .verified)
    }

    func testResumingAnAppliedWriteUsesReadbackAndSendsNoWrite() async throws {
        let (s, a, _, song, decisions) = fixture()
        let operation = SyncOperation(service: .appleMusic, kind: .saveTracks, title: song.title, tracks: [song])
        let plan = SyncPlan(mode: .spotifyBase, snapshots: [s, a], operations: [operation])
        var after = a; after.savedTracks = [song]
        let record = RunRecord(summary: RunSummary(status: .interrupted, totalCount: 1), plan: plan, decisions: decisions, executions: [OperationExecution(operation: operation, state: .applying, before: a)], checkpoints: [s, a])
        let storage = try store(); try await storage.save(record)
        let apple = ExecutionTestProvider(after), spotify = ExecutionTestProvider(s)
        let result = try await SyncExecutor(store: storage, verificationDelays: [0]).resume(id: record.id, providers: [.spotify: spotify, .appleMusic: apple])
        XCTAssertEqual(result.executions[0].state, .verified)
        let count = await apple.writeCount(); XCTAssertEqual(count, 0)
    }

    func testResumeRejectsUnrelatedChangeEvenWhenOperationWasApplied() async throws {
        let (s, a, _, song, decisions) = fixture()
        let operation = SyncOperation(service: .appleMusic, kind: .saveTracks, title: song.title, tracks: [song])
        let plan = SyncPlan(mode: .spotifyBase, snapshots: [s, a], operations: [operation])
        var after = a; after.savedTracks = [song, Track(id: "external", title: "Manual", artist: "Otro")]
        let record = RunRecord(summary: RunSummary(status: .interrupted, totalCount: 1), plan: plan, decisions: decisions, executions: [OperationExecution(operation: operation, state: .unknown, before: a)], checkpoints: [s, a])
        let storage = try store(); try await storage.save(record)
        let apple = ExecutionTestProvider(after), spotify = ExecutionTestProvider(s)
        let result = try await SyncExecutor(store: storage, verificationDelays: [0]).resume(id: record.id, providers: [.spotify: spotify, .appleMusic: apple])
        XCTAssertEqual(result.summary.status, .failed)
        let count = await apple.writeCount(); XCTAssertEqual(count, 0)
    }

    func testUnexpectedLibrarySideEffectsStopLaterOperations() async throws {
        let (s, a, _, song, decisions) = fixture()
        let save = SyncOperation(service: .appleMusic, kind: .saveTracks, title: song.title, tracks: [song])
        let create = SyncOperation(service: .appleMusic, kind: .createPlaylist, title: "Después", playlistName: "Después")
        let plan = SyncPlan(mode: .spotifyBase, snapshots: [s, a], operations: [save, create])
        let apple = ExecutionTestProvider(a, extraTrackOnWrite: Track(id: "side-effect", title: "Otra", artist: "Otro")), spotify = ExecutionTestProvider(s)
        let result = try await SyncExecutor(store: try store(), verificationDelays: [0]).execute(plan: plan, selectedIDs: [save.id, create.id], decisions: decisions, providers: [.spotify: spotify, .appleMusic: apple])
        XCTAssertEqual(result.summary.status, .partial)
        XCTAssertEqual(result.executions[1].state, .pending)
        let count = await apple.writeCount(); XCTAssertEqual(count, 1)
    }

    func testLibraryOperationsAreBatchedAndIndividuallyVerified() async throws {
        let (s, a, _, song, decisions) = fixture()
        let another = Track(id: "another", title: "Otra", artist: "Sur")
        let ops = [song, another].map { SyncOperation(service: .appleMusic, kind: .saveTracks, title: $0.title, tracks: [$0]) }
        let plan = SyncPlan(mode: .spotifyBase, snapshots: [s, a], operations: ops)
        let apple = ExecutionTestProvider(a), spotify = ExecutionTestProvider(s)
        let result = try await SyncExecutor(store: try store(), verificationDelays: [0]).execute(plan: plan, selectedIDs: Set(ops.map(\.id)), decisions: decisions, providers: [.spotify: spotify, .appleMusic: apple])
        XCTAssertTrue(result.executions.allSatisfy { $0.state == .verified })
        let count = await apple.writeCount(); XCTAssertEqual(count, 1)
    }

    func testExecutorEnforcesBaseAndMergeInvariantsEvenWithMalformedPlan() async throws {
        let (s, a, source, _, decisions) = fixture()
        let op = SyncOperation(service: .spotify, kind: .removeTracks, title: source.title, tracks: [source])
        let providers: [MusicService: any MusicProvider] = [.spotify: ExecutionTestProvider(s), .appleMusic: ExecutionTestProvider(a)]
        for mode in [SyncMode.spotifyBase, .merge] {
            let plan = SyncPlan(mode: mode, snapshots: [s, a], operations: [op])
            do {
                _ = try await SyncExecutor(store: try store(), verificationDelays: [0]).execute(plan: plan, selectedIDs: [op.id], decisions: decisions, providers: providers)
                XCTFail("Invalid plan was accepted")
            } catch SyncExecutionError.invalidSelection { }
        }
    }

    func testVerificationPreservesOccurrenceCountAndLibraryIDs() {
        let (_, a, _, target, _) = fixture()
        var before = a; before.playlists = [Playlist(id: "p", name: "List", tracks: [target])]
        let op = SyncOperation(service: .appleMusic, kind: .addPlaylistTracks, targetID: "p", title: "List", tracks: [target])
        XCTAssertNil(OperationVerifier.receipt(for: op, before: before, after: before))
        var after = before; after.playlists[0].tracks = [target, target]
        XCTAssertNotNil(OperationVerifier.receipt(for: op, before: before, after: after))
        var libraryTrack = target; libraryTrack.id = "library-id"; libraryTrack.catalogID = target.id
        after.savedTracks = [libraryTrack]
        let save = SyncOperation(service: .appleMusic, kind: .saveTracks, title: target.title, tracks: [target])
        XCTAssertNotNil(OperationVerifier.receipt(for: save, before: before, after: after))
    }
}
