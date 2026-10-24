import XCTest
@testable import SyncCore

private actor SearchProvider: MusicProvider {
    nonisolated let service: MusicService = .appleMusic
    var queries: [TrackSearchQuery] = []
    let responses: [SearchStage: TrackSearchResult]
    let failsIdentifier: Bool
    init(_ responses: [SearchStage: TrackSearchResult], failsIdentifier: Bool = false) { self.responses = responses; self.failsIdentifier = failsIdentifier }
    func account() async throws -> ConnectedAccount { .init(id: "fixture", service: service, displayName: "Fixture") }
    func capabilities() async -> ProviderCapabilities { .appleMusic }
    func fetchLibrary() async throws -> LibrarySnapshot { .init(account: try await account()) }
    func searchTracks(matching track: Track) async throws -> CatalogSearchResult<Track> { .init() }
    func searchAlbums(matching album: Album) async throws -> CatalogSearchResult<Album> { .init() }
    func perform(_ operation: SyncOperation) async throws -> MutationReceipt { XCTFail("Search must never write"); return .init() }
    func searchCatalog(_ query: TrackSearchQuery) async throws -> TrackSearchResult {
        queries.append(query)
        if failsIdentifier && query.stage == .identifier { throw ProviderError.network("Fixture unavailable") }
        return responses[query.stage] ?? .init()
    }
}

final class CatalogSearchTests: XCTestCase {
    func song(_ id: String, album: String = "Original") -> Track {
        Track(id: id, title: "Canción", artist: "Artista", albumTitle: album, durationMS: 200000, isrc: "TEST", explicit: false)
    }
    func testEmptyISRCContinuesThroughMetadataAlbumAndArtist() async throws {
        let source = song("s"), alternative = song("a", album: "Recopilación")
        let provider = SearchProvider([.metadata: .init(candidates: [alternative]), .artistTitle: .init(candidates: [alternative])])
        let result = try await CatalogSearch.search(source: source, provider: provider)
        let queries = await provider.queries
        XCTAssertEqual(queries.map(\.stage), [.identifier, .metadata, .albumTracks, .artistTitle])
        XCTAssertEqual(result.candidates, [alternative])
        let match = CatalogSearch.match(source: source, sourceService: .spotify, result: result)
        XCTAssertNil(match.selected, "A different album always requires a choice, even with the same ISRC")
    }
    func testExactKnownEditionStopsFurtherQueries() async throws {
        let provider = SearchProvider([.identifier: .init(candidates: [song("a")])])
        let result = try await CatalogSearch.search(source: song("s"), provider: provider)
        let queries = await provider.queries
        XCTAssertEqual(queries.count, 1)
        XCTAssertNotNil(CatalogSearch.match(source: song("s"), sourceService: .spotify, result: result).selected)
    }
    func testFailedStageDoesNotBecomeAutomaticMatchOrAbsence() async throws {
        let provider = SearchProvider([.metadata: .init(candidates: [song("a")])], failsIdentifier: true)
        let result = try await CatalogSearch.search(source: song("s"), provider: provider)
        XCTAssertEqual(result.coverage, .partialFailure)
        let match = CatalogSearch.match(source: song("s"), sourceService: .spotify, result: result)
        XCTAssertNil(match.selected); XCTAssertEqual(match.confidence, .review)
        let empty = try await CatalogSearch.search(source: song("s"), provider: SearchProvider([:], failsIdentifier: true))
        XCTAssertEqual(empty.coverage, .failed)
    }
    func testUnknownExplicitMetadataAndUnknownAlbumNeverAutoSelect() {
        var s = song("s"), a = song("a")
        s.explicit = nil; a.explicit = nil
        XCTAssertNil(CatalogMatcher.track(s, candidates: [a], sourceService: .spotify).selected)
        s = song("s", album: ""); a = song("a", album: "")
        XCTAssertNil(CatalogMatcher.track(s, candidates: [a], sourceService: .spotify).selected)
    }
    func testLimitedEmptySearchIsNotReportedAsFailedOrComplete() async throws {
        let provider = SearchProvider([.identifier: .init(coverage: .partial, notes: ["Budget reached"])])
        let result = try await CatalogSearch.search(source: song("s"), provider: provider)
        XCTAssertEqual(result.coverage, .partial)
        XCTAssertTrue(result.candidates.isEmpty)
        XCTAssertNil(CatalogSearch.match(source: song("s"), sourceService: .spotify, result: result).selected)
    }
    func testArtistVariantsRemainReviewCandidatesWithoutISRC() {
        var s = song("s"), a = song("a")
        s.isrc = nil; a.isrc = nil; s.artist = "Artista, Invitado"; a.artist = "Artista feat. Invitado"
        let match = CatalogMatcher.track(s, candidates: [a], sourceService: .spotify)
        XCTAssertEqual(match.candidates, [a]); XCTAssertNil(match.selected)
    }
    func testPendingOmittedAndRejectedChoicesSurviveARefresh() {
        let s = song("s"), a = song("a"), result = TrackSearchResult(candidates: [a])
        for decision in [TrackDecision.pending, .omitted] {
            var previous = TrackMatch(sourceService: .spotify, source: s)
            previous.decision = decision
            let updated = CatalogSearch.match(source: s, sourceService: .spotify, result: result, previous: previous)
            XCTAssertNil(updated.selected); XCTAssertEqual(updated.decision, decision)
        }
        var previous = TrackMatch(sourceService: .spotify, source: s); previous.rejectedCandidateIDs = [a.playableID]
        let updated = CatalogSearch.match(source: s, sourceService: .spotify, result: result, previous: previous)
        XCTAssertTrue(updated.candidates.isEmpty); XCTAssertNil(updated.selected)
    }
    func testManualSelectionRevalidatesIdentityAndKeepsManualProvenance() {
        let s = song("s"), a = song("a", album: "Recopilación")
        var previous = TrackMatch(sourceService: .spotify, source: s, candidates: [a], selected: a)
        previous.decision = .manual
        var fresh = a; fresh.url = "https://music.apple.com/ar/album/example"
        let updated = CatalogSearch.match(source: s, sourceService: .spotify, result: .init(candidates: [fresh]), previous: previous)
        XCTAssertEqual(updated.selected, fresh); XCTAssertEqual(updated.decision, .manual); XCTAssertEqual(updated.confidence, .review)
        fresh.durationMS += 30000
        XCTAssertNil(CatalogSearch.match(source: s, sourceService: .spotify, result: .init(candidates: [fresh]), previous: previous).selected)
    }
    func testLibraryAndCatalogAliasesDoNotCreateFalseAmbiguity() {
        var library = song("library.1"), catalog = song("1")
        library.catalogID = "1"; catalog.url = "https://music.apple.com/ar/album/example"
        let result = CatalogMatcher.track(song("source"), candidates: [library, catalog], sourceService: .spotify)
        XCTAssertEqual(result.candidates.count, 1); XCTAssertNotNil(result.selected)
    }
    func testManualXMLChoiceInvalidatesWhenTheChosenRecordingChanges() throws {
        let s = song("s"), a = song("xml")
        let choice = ManualTrackChoice(source: s, selected: a, decision: .manual)
        let library = ManualMusicLibrary(id: "library", fileName: "Library.xml", tracks: [a])
        XCTAssertNotNil(choice.revalidated(source: s, library: library).selected)
        var changed = library; changed.tracks[0].albumTitle = "Otra edición"
        XCTAssertNil(choice.revalidated(source: s, library: changed).selected)
        var state = ManualChecklistState(library: library)
        state.choicesByScope = ["scope": ["row": choice]]
        let decoded = try JSONDecoder().decode(ManualChecklistState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded.choicesByScope?["scope"]?["row"]?.selected, a)
        let legacy = Data(#"{"markedIDsByScope":{}}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(ManualChecklistState.self, from: legacy).choicesByScope)
    }
    func testRateLimitStopsFurtherStages() async throws {
        var limited = TrackSearchResult(coverage: .partial); limited.retryAfterSeconds = 60
        let provider = SearchProvider([.identifier: limited])
        let result = try await CatalogSearch.search(source: song("s"), provider: provider)
        let queries = await provider.queries
        XCTAssertEqual(queries.count, 1); XCTAssertEqual(result.retryAfterSeconds, 60)
    }
}
