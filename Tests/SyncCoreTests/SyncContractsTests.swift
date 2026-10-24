import XCTest
@testable import SyncCore

final class SyncContractsTests: XCTestCase {
    private func song(_ id: String) -> Track {
        Track(id: id, catalogID: id, title: "Song", artist: "Artist", albumTitle: "Album", durationMS: 180000, isrc: "TEST", explicit: false)
    }
    func testCatalogAndLibraryAliasesMatchButConflictingAliasesRequireReview() {
        let source = song("source"), catalog = song("100")
        var library = catalog; library.id = "i.library"
        let match = CatalogMatcher.track(source, candidates: [catalog, library], sourceService: .spotify)
        XCTAssertEqual(match.candidates.count, 1)
        XCTAssertEqual(match.selected?.playableID, "100")
        library.explicit = true
        XCTAssertNil(CatalogMatcher.track(source, candidates: [catalog, library], sourceService: .spotify).selected)
        let sourceAlbum = Album(id: "source", title: "Album", artist: "Artist", tracks: [source])
        let catalogAlbum = Album(id: "200", title: "Album", artist: "Artist", tracks: [catalog])
        library = catalog; library.id = "i.library"
        var libraryAlbum = catalogAlbum; libraryAlbum.id = "l.album"; libraryAlbum.catalogID = "200"; libraryAlbum.tracks = [library]
        XCTAssertNotNil(CatalogMatcher.album(sourceAlbum, candidates: [catalogAlbum, libraryAlbum], sourceService: .spotify).selected)
    }

    func testIncompleteSearchNeverMeansUnavailableOrUniqueAndRequiresExplicitSelection() {
        let source = song("s"), target = song("a")
        let snapshots = [LibrarySnapshot(account: ConnectedAccount(id: "S", service: .spotify, displayName: "S"), savedTracks: [source]),
                         LibrarySnapshot(account: ConnectedAccount(id: "A", service: .appleMusic, displayName: "A"))]
        for coverage in [CatalogSearchCoverage.limited, .failed, .partialFailure] {
            for candidates in [[Track](), [target]] {
                let match = CatalogMatcher.track(source, candidates: candidates, sourceService: .spotify, coverage: coverage)
                XCTAssertNil(match.selected); XCTAssertEqual(match.confidence, .review)
                XCTAssertEqual(match.searchCoverage, coverage)
            }
            var match = CatalogMatcher.track(source, candidates: [target], sourceService: .spotify, coverage: coverage)
            match.selected = target; match.confidence = .exact
            var decisions = MatchDecisions(tracks: [match])
            var plan = SyncPlanner.makePlan(snapshots: snapshots, mode: .spotifyBase, decisions: decisions, capabilities: [.spotify: .spotify, .appleMusic: .appleMusic])
            XCTAssertTrue(plan.executable.isEmpty)
            decisions.tracks[0].manualSelection = true
            plan = SyncPlanner.makePlan(snapshots: snapshots, mode: .spotifyBase, decisions: decisions, capabilities: [.spotify: .spotify, .appleMusic: .appleMusic])
            XCTAssertEqual(plan.executable.map(\.kind), [.saveTracks])
        }
    }

    func testStagedManualDecisionSurvivesCoverageAndLegacyJSON() throws {
        let s = song("s"), a = song("a")
        var choice = TrackMatch(sourceService: .spotify, source: s, candidates: [a], selected: a)
        choice.decision = .manual; choice.searchCoverage = .partial
        let decoded = try JSONDecoder().decode(TrackMatch.self, from: JSONEncoder().encode(choice))
        let updated = CatalogSearch.match(source: s, sourceService: .spotify, result: .init(candidates: [a], coverage: .limited), previous: decoded)
        XCTAssertEqual(updated.decision, .manual); XCTAssertEqual(updated.selected, a)
        let snapshots = [LibrarySnapshot(account: .init(id: "s", service: .spotify, displayName: "S"), savedTracks: [s]),
                         LibrarySnapshot(account: .init(id: "a", service: .appleMusic, displayName: "A"))]
        let plan = SyncPlanner.makePlan(snapshots: snapshots, mode: .spotifyBase, decisions: .init(tracks: [decoded]), capabilities: [.spotify: .spotify, .appleMusic: .appleMusic])
        XCTAssertEqual(plan.executable.map(\.kind), [.saveTracks])
    }

    func testReplacementStepsPreserveOrderMultiplicityAndPreconditions() {
        let tracks = (0..<205).map { song("\($0 % 3)") }
        let operation = SyncOperation(service: .spotify, kind: .replacePlaylistTracks, targetID: "p", title: "List", tracks: tracks, beforeTrackIDs: ["old"])
        let steps = MutationSteps.prepare(operation, limits: .init(libraryItems: 40, playlistItems: 100))
        XCTAssertEqual(steps.map { $0.operation.kind }, [.replacePlaylistTracks, .addPlaylistTracks, .addPlaylistTracks])
        XCTAssertEqual(steps.flatMap { $0.operation.tracks }, tracks)
        XCTAssertEqual(steps[0].operation.beforeTrackIDs, ["old"])
        XCTAssertEqual(steps[1].operation.beforeTrackIDs, Array(tracks.prefix(100)).map(\.playableID))
        XCTAssertEqual(steps[2].operation.beforeTrackIDs, Array(tracks.prefix(200)).map(\.playableID))
        XCTAssertTrue(steps.allSatisfy { $0.parentOperationID == operation.id })
        XCTAssertEqual(Set(steps.map(\.id)).count, 3)
    }

    func testLegacyDecisionsAndExecutionDecodeWithoutInventingManualApproval() throws {
        let match = CatalogMatcher.track(song("s"), candidates: [song("a")], sourceService: .spotify)
        let data = try JSONEncoder().encode(match)
        let restored = try JSONDecoder().decode(TrackMatch.self, from: data)
        XCTAssertNil(restored.manualSelection); XCTAssertNil(restored.searchCoverage)
        let operation = SyncOperation(service: .spotify, kind: .saveTracks, title: "Song", tracks: [song("a")])
        let old = OperationExecution(operation: operation, state: .unknown)
        let execution = try JSONDecoder().decode(OperationExecution.self, from: JSONEncoder().encode(old))
        XCTAssertEqual(execution.state, .unknown)
        XCTAssertNil(execution.parentOperationID); XCTAssertNil(execution.creationDependencyID)
    }

    func testJournalStoresSharedEvidenceOnceAndReadsLegacyInlineSnapshots() throws {
        let snapshot = LibrarySnapshot(account: ConnectedAccount(id: "s", service: .spotify, displayName: "S"))
        let operation = SyncOperation(service: .spotify, kind: .saveTracks, title: "Song", tracks: [song("a")])
        let executions = (0..<40).map { _ in OperationExecution(operation: operation, state: .applying, before: snapshot) }
        let record = RunRecord(summary: RunSummary(), plan: SyncPlan(mode: .merge, snapshots: [snapshot], operations: [operation]), decisions: MatchDecisions(), executions: executions, checkpoints: [snapshot])
        let data = try JSONEncoder().encode(record)
        XCTAssertEqual(try JSONDecoder().decode(RunRecord.self, from: data), record)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual((object["executionSnapshots"] as? [Any])?.count, 1)
        let encodedExecutions = try XCTUnwrap(object["executions"] as? [[String: Any]])
        XCTAssertTrue(encodedExecutions.allSatisfy { $0["before"] == nil && $0["beforeSnapshotID"] != nil })
        object["executionSnapshots"] = []
        XCTAssertThrowsError(try JSONDecoder().decode(RunRecord.self, from: JSONSerialization.data(withJSONObject: object)))
        object.removeValue(forKey: "executionSnapshots")
        object["executions"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(executions))
        XCTAssertEqual(try JSONDecoder().decode(RunRecord.self, from: JSONSerialization.data(withJSONObject: object)), record)
    }

    func testRejectedRetryCannotEraseEarlierUncertainty() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("spotam-rejected-retry-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SyncStore(url: directory.appendingPathComponent("journal.sqlite"))
        let s = LibrarySnapshot(account: ConnectedAccount(id: "s", service: .spotify, displayName: "S"))
        let a = LibrarySnapshot(account: ConnectedAccount(id: "a", service: .appleMusic, displayName: "A"))
        let operation = SyncOperation(service: .spotify, kind: .saveTracks, title: "Song", tracks: [song("s1")])
        let record = RunRecord(summary: RunSummary(status: .interrupted), plan: SyncPlan(mode: .appleMusicBase, snapshots: [s, a], operations: [operation]), decisions: MatchDecisions(), executions: [OperationExecution(operation: operation, state: .unknown, before: s)], checkpoints: [s, a])
        try await store.save(record)
        let result = try await SyncExecutor(store: store, verificationDelays: [0]).resume(id: record.id, providers: [.spotify: RejectedRetryProvider(snapshot: s), .appleMusic: DemoMusicProvider(snapshot: a)])
        XCTAssertEqual(result.executions.map(\.state), [.unknown])
        XCTAssertEqual(result.executions[0].before, s)
        let unresolved = try await store.unresolvedRuns(accountIDs: [.spotify: "s"])
        XCTAssertEqual(unresolved.count, 1)
    }
}

private struct RejectedRetryProvider: MusicProvider {
    let snapshot: LibrarySnapshot
    var service: MusicService { snapshot.account.service }
    func account() async throws -> ConnectedAccount { snapshot.account }
    func capabilities() async -> ProviderCapabilities { .spotify }
    func fetchLibrary() async throws -> LibrarySnapshot { snapshot }
    func searchTracks(matching track: Track) async throws -> CatalogSearchResult<Track> { .init() }
    func searchAlbums(matching album: Album) async throws -> CatalogSearchResult<Album> { .init() }
    func perform(_ operation: SyncOperation) async throws -> MutationReceipt { throw ProviderError.forbidden("HTTP 403") }
}
