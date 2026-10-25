import XCTest
import SyncCore
@testable import SpotAMSync

/// Independent integration regressions. All providers and storage are synthetic;
/// these assertions describe the safe behavior and expose the current defects.
@MainActor
final class LibrarySyncReviewRegressionTests: XCTestCase {
    private struct Fixture {
        let coordinator: LibrarySyncCoordinator
        let provider: ReviewRegressionProvider
        let library: ManualMusicLibrary
        let snapshot: LibrarySnapshot
        let store: SyncStore
        let first: Track
        let candidate: Track
    }
    private enum TestFailure: Error { case timeout }
    private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<600 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("The controlled review state was not reached.")
        throw TestFailure.timeout
    }
    private func waitAt(_ gate: ReviewRegressionGate) async throws {
        for _ in 0..<600 {
            if await gate.waiting { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("The controlled provider gate was not reached.")
        throw TestFailure.timeout
    }
    private func fixture(twoSongs: Bool = false, threeSongs: Bool = false) async throws -> Fixture {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("library-review-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let first = Track(id: "xml-first", title: "First", artist: "Artist", albumTitle: "Album", durationMS: 120_000, explicit: false)
        var second = first; second.id = "xml-second"; second.title = "Second"
        var candidate = first; candidate.id = "spotify-first"; candidate.catalogID = candidate.id
        var other = second; other.id = "spotify-second"; other.catalogID = other.id
        var third = first; third.id = "xml-third"; third.title = "Third"
        var thirdCandidate = third; thirdCandidate.id = "spotify-third"; thirdCandidate.catalogID = thirdCandidate.id
        let snapshot = LibrarySnapshot(account: .init(id: "review-user", service: .spotify, displayName: "Fixture", connectionRevision: "review-revision"),
                                       playlists: [.init(id: "existing", name: "Other playlist", tracks: threeSongs ? [candidate, other] : [candidate])])
        let tracks = threeSongs ? [first, second, third] : twoSongs ? [first, second] : [first]
        let library = ManualMusicLibrary(id: "apple-music-xml:0123456789ABCDEF", fileName: "Fixture.xml", tracks: tracks,
            inventory: .init(playlists: [], trackInfo: Dictionary(uniqueKeysWithValues: tracks.enumerated().map {
                ($0.element.id, XMLTrackInfo(referenceID: $0.offset + 1, playlistOnly: false))
            })), documentDigest: "review-document")
        let provider = ReviewRegressionProvider(snapshot: snapshot, catalog: [candidate, other, thirdCandidate])
        let store = try SyncStore(url: folder.appendingPathComponent("review.sqlite"))
        let coordinator = LibrarySyncCoordinator()
        coordinator.start(store: store, externalBusy: { false })
        try await wait { coordinator.loaded }
        coordinator.setProviders([.spotify: provider], isDemo: false)
        coordinator.readSources(xml: library, useOfficialApple: false, isDemo: false)
        try await wait { !coordinator.isWorking && coordinator.library != nil }
        return .init(coordinator: coordinator, provider: provider, library: library, snapshot: snapshot,
                     store: store, first: first, candidate: candidate)
    }

    func testCancelAnalysisDoesNotStartTheQueuedApprovedBatch() async throws {
        let f = try await fixture(twoSongs: true), gate = ReviewRegressionGate()
        await f.provider.setGate(gate, for: "Second")
        f.coordinator.configure(mode: .appleMusicBase, songs: .prepare, albums: .exclude)
        try await waitAt(gate)
        try await wait { f.coordinator.isAnalyzing && !f.coordinator.readyDifferences.isEmpty }
        let approved = try XCTUnwrap(f.coordinator.readyDifferences.first)
        f.coordinator.approve([approved.id])
        XCTAssertEqual(f.coordinator.session.batches.first?.state, .queued)
        f.coordinator.cancel()
        await gate.release()
        try await wait { !f.coordinator.isWorking }
        let writes = await f.provider.writeCount()
        XCTAssertEqual(writes, 0, "Cancelling must not launch a queued batch from analysisTask's defer.")
        XCTAssertNotEqual(f.coordinator.session.batches.first?.state, .verified)
    }

    func testFailedManualRevalidationDoesNotApplyAQueuedStaleChoice() async throws {
        let f = try await fixture()
        f.coordinator.configure(mode: .appleMusicBase, songs: .prepare, albums: .exclude)
        try await wait { !f.coordinator.isWorking && !f.coordinator.readyDifferences.isEmpty }
        var manualCandidate = f.candidate
        manualCandidate.id = "spotify-manual"; manualCandidate.catalogID = manualCandidate.id
        await f.provider.addCatalogCandidate(manualCandidate)
        f.coordinator.choose(matchID: "appleMusic:" + f.first.id, candidate: manualCandidate, decision: .manual)
        let gate = ReviewRegressionGate()
        await f.provider.failManualValidation(after: gate)
        f.coordinator.prepare()
        try await waitAt(gate)
        let approved = try XCTUnwrap(f.coordinator.readyDifferences.first)
        f.coordinator.approve([approved.id])
        await gate.release()
        try await wait { !f.coordinator.isWorking }
        let writes = await f.provider.writeCount()
        XCTAssertEqual(writes, 0, "A failed catalog revalidation must invalidate the cached manual choice and its queued approval.")
        XCTAssertFalse(f.coordinator.readyDifferences.contains { $0.tracks.contains { $0.playableID == manualCandidate.playableID } })
    }

    func testCancellingLastInFlightWriteDoesNotStartTheNextApprovedBatch() async throws {
        let f = try await fixture(threeSongs: true), analysisGate = ReviewRegressionGate(), writeGate = ReviewRegressionGate()
        await f.provider.setGate(analysisGate, for: "Third")
        await f.provider.setFirstWriteGate(writeGate)
        f.coordinator.configure(mode: .appleMusicBase, songs: .prepare, albums: .exclude)
        try await waitAt(analysisGate)
        let first = try XCTUnwrap(f.coordinator.readyDifferences.first { $0.tracks.contains { $0.playableID == "spotify-first" } })
        let second = try XCTUnwrap(f.coordinator.readyDifferences.first { $0.tracks.contains { $0.playableID == "spotify-second" } })
        f.coordinator.approve([first.id]); f.coordinator.approve([second.id])
        XCTAssertEqual(f.coordinator.session.batches.filter { $0.state == .queued }.count, 2)
        await analysisGate.release()
        try await waitAt(writeGate)
        XCTAssertTrue(f.coordinator.isApplying)
        f.coordinator.cancel()
        // The request cannot finish while gated; let the executor receive cancel.
        try await Task.sleep(nanoseconds: 50_000_000)
        await writeGate.release()
        try await wait { !f.coordinator.isWorking }
        let writes = await f.provider.writeCount()
        XCTAssertEqual(writes, 1, "Readback may verify the in-flight write, but cancellation must stop the next approved batch.")
        XCTAssertNotEqual(f.coordinator.session.batches.last?.state, .verified)
    }

    func testCancelledOldSearchCannotClearTheReplacementSearchBusyState() async throws {
        let f = try await fixture(), oldGate = ReviewRegressionGate(), newGate = ReviewRegressionGate()
        await f.provider.setGate(oldGate, for: "old-query")
        await f.provider.setGate(newGate, for: "new-query")
        let matchID = "appleMusic:" + f.first.id
        f.coordinator.search(matchID: matchID, query: .init(title: "old-query", artist: "Artist"))
        try await waitAt(oldGate)
        f.coordinator.search(matchID: matchID, query: .init(title: "new-query", artist: "Artist"))
        try await waitAt(newGate)
        await oldGate.release()
        // Wait until the obsolete task has returned and run its defer.
        for _ in 0..<20 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(f.coordinator.searchingIDs.contains(matchID), "The new request is still inside its provider gate.")
        XCTAssertTrue(f.coordinator.isWorking, "Busy state must track the replacement search, not the cancelled request.")
        await newGate.release()
        try await wait { !f.coordinator.isWorking }
    }

    func testRestartBeforeRunCreationCanReleaseAnOrphanedApproval() async throws {
        let f = try await fixture()
        f.coordinator.configure(mode: .appleMusicBase, songs: .prepare, albums: .exclude)
        try await wait { !f.coordinator.isWorking && !f.coordinator.readyDifferences.isEmpty }
        let difference = try XCTUnwrap(f.coordinator.readyDifferences.first)
        var session = f.coordinator.session
        let batch = LibraryApprovalBatch(sourceDigest: f.library.documentDigest!, differenceIDs: [difference.id],
            unitIDs: [difference.unitID], scope: session.configuration.scope,
            operations: difference.spotifyOperations, manualTasks: [], state: .applying, runID: UUID())
        session.batches = [batch]
        // Exact persisted state between coordinator's second save and executor's
        // first RunRecord save: applying approval exists, no run journal exists.
        var activeKey: String?
        for _ in 0..<600 {
            activeKey = try await f.store.loadDocument(ReviewRegressionArchive.self, key: "library-comparison-v1")?.activeKey
            if activeKey != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let key = try XCTUnwrap(activeKey)
        let originalURL = await f.store.url
        let recoveredStore = try SyncStore(url: originalURL.deletingLastPathComponent().appendingPathComponent("crash.sqlite"))
        let archive = ReviewRegressionArchive(sessions: [key: session], activeKey: key)
        try await recoveredStore.saveDocument(archive, key: "library-comparison-v1")
        let restored = LibrarySyncCoordinator()
        restored.start(store: recoveredStore, externalBusy: { false })
        try await wait { restored.loaded }
        restored.setProviders([.spotify: f.provider], isDemo: false)
        XCTAssertEqual(restored.session.batches.first?.state, .attention)
        restored.reconcile(batch.id)
        try await wait { !restored.isWorking }
        XCTAssertFalse(restored.hasApproval(difference.id), "A missing journal proves no dispatch was recorded; the orphan cannot block this difference forever.")
        XCTAssertTrue(restored.readyDifferences.contains { $0.id == difference.id })
        let writes = await f.provider.writeCount(); XCTAssertEqual(writes, 0)
    }
}

private struct ReviewRegressionArchive: Codable, Sendable {
    var version = 1
    var sessions: [String: LibrarySyncSession]
    var activeKey: String?
}

private actor ReviewRegressionGate {
    private(set) var waiting = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        waiting = true
        if !released { await withCheckedContinuation { continuation = $0 } }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}

private actor ReviewRegressionProvider: MusicProvider {
    nonisolated let service = MusicService.spotify
    private var snapshot: LibrarySnapshot
    private var catalog: [Track]
    private var gates: [String: ReviewRegressionGate] = [:]
    private var validationFailureGate: ReviewRegressionGate?
    private var firstWriteGate: ReviewRegressionGate?
    private var writes = 0
    init(snapshot: LibrarySnapshot, catalog: [Track]) { self.snapshot = snapshot; self.catalog = catalog }
    func setGate(_ gate: ReviewRegressionGate, for query: String) { gates[query] = gate }
    func addCatalogCandidate(_ track: Track) { catalog.append(track) }
    func failManualValidation(after gate: ReviewRegressionGate) { validationFailureGate = gate }
    func setFirstWriteGate(_ gate: ReviewRegressionGate) { firstWriteGate = gate }
    func account() async throws -> ConnectedAccount { snapshot.account }
    func capabilities() async -> ProviderCapabilities { .spotify }
    func fetchLibrary() async throws -> LibrarySnapshot { snapshot }
    func catalogTrack(id: String) async throws -> Track? {
        if let gate = validationFailureGate {
            await gate.wait()
            throw ProviderError.forbidden("Synthetic catalog revalidation failure")
        }
        return catalog.first { $0.playableID == id }
    }
    func searchTracks(matching track: Track) async throws -> CatalogSearchResult<Track> {
        .init(candidates: catalog.filter { $0.title == track.title })
    }
    func searchAlbums(matching album: Album) async throws -> CatalogSearchResult<Album> { .init() }
    func searchCatalog(_ query: TrackSearchQuery, budget: CatalogRequestBudget) async throws -> TrackSearchResult {
        if let gate = gates[query.title] { await gate.wait() }
        if query.title.hasSuffix("-query") {
            var result = TrackSearchResult(coverage: .failed); result.authorizationFailed = true; return result
        }
        return .init(candidates: catalog.filter { $0.title == query.title })
    }
    func perform(_ operation: SyncOperation) async throws -> MutationReceipt {
        writes += 1
        if writes == 1, let gate = firstWriteGate { await gate.wait() }
        guard operation.kind == .saveTracks else { throw ProviderError.unsupported("Only synthetic song saves are supported") }
        for track in operation.tracks where !snapshot.savedTracks.contains(where: { $0.playableID == track.playableID }) {
            snapshot.savedTracks.append(track)
        }
        return .init()
    }
    func writeCount() -> Int { writes }
}
