import XCTest
import SyncCore
@testable import MusicProviders

final class CatalogSearchTests: XCTestCase {
    private func source(isrc: String? = "TEST") -> Track {
        Track(id: "source", title: "Song", artist: "Artist", albumTitle: "Album", durationMS: 120000, isrc: isrc, explicit: false)
    }
    private func candidate(_ id: String) -> [String: Any] {
        ["id": id, "type": "songs", "attributes": ["name": "Song", "artistName": "Artist", "albumName": "Album", "durationInMillis": 120000, "isrc": "TEST", "contentRating": "clean", "playParams": ["id": id]]]
    }
    private var emptyAppleSearch: ScriptedTransport.Step {
        .init("/v1/catalog/ar/search", json: ["results": ["songs": ["data": []]]])
    }
    private var references: [String: Any] {
        ["filters": ["isrc": ["TEST": [["id": "1", "type": "songs"], ["id": "2", "type": "songs"]]]]]
    }
    func testAppleHydratesEveryISRCReferenceAndDoesNotSelectFirstEdition() async throws {
        let t = ScriptedTransport([appleStorefront,
            .init("/v1/catalog/ar/songs", json: ["data": [candidate("1")], "meta": references], validate: { XCTAssertNil(query($0, "limit")); XCTAssertEqual(query($0, "filter[isrc]"), "TEST") }),
            .init("/v1/catalog/ar/songs", json: ["data": [candidate("2")]], validate: { XCTAssertEqual(query($0, "ids"), "2") }),
            emptyAppleSearch, emptyAppleSearch])
        let p = try await apple(t), result = try await p.searchTracks(matching: source())
        XCTAssertEqual(Set(result.candidates.map(\.id)), ["1", "2"])
        XCTAssertEqual(result.coverage, .complete)
        XCTAssertNil(CatalogMatcher.track(source(), candidates: result.candidates, sourceService: .spotify, coverage: result.coverage).selected)
        await t.assertExhausted()
    }
    func testMissingISRCReferencePreservesCandidateButCannotProveUniqueness() async throws {
        for status in [200, 403] {
            let t = ScriptedTransport([appleStorefront,
                .init("/v1/catalog/ar/songs", json: ["data": [candidate("1")], "meta": references]),
                .init("/v1/catalog/ar/songs", status: status, json: status == 200 ? ["data": []] : nil), emptyAppleSearch, emptyAppleSearch])
            let p = try await apple(t), result = try await p.searchTracks(matching: source())
            XCTAssertEqual(result.candidates.map(\.id), ["1"])
            XCTAssertEqual(result.coverage, .partialFailure)
            XCTAssertNil(CatalogMatcher.track(source(), candidates: result.candidates, sourceService: .spotify, coverage: result.coverage).selected)
            await t.assertExhausted()
        }
    }
    func testAppleEmptyISRCFallsBackToMetadataAndSelectsCompatibleResult() async throws {
        let t = ScriptedTransport([appleStorefront, .init("/v1/catalog/ar/songs", json: ["data": []]),
            .init("/v1/catalog/ar/search", json: ["results": ["songs": ["data": [candidate("1")]]]], validate: { XCTAssertEqual(query($0, "term"), "Song Artist Album") })])
        let p = try await apple(t), result = try await p.searchTracks(matching: source())
        XCTAssertEqual(result.coverage, .complete)
        XCTAssertEqual(CatalogMatcher.track(source(), candidates: result.candidates, sourceService: .spotify, coverage: result.coverage).selected?.id, "1")
        await t.assertExhausted()
    }
    func testSpotifyEmptyISRCFallsBackToMetadata() async throws {
        var track = spTrack("one", isrc: "TEST"); track["name"] = "Song"; track["explicit"] = false
        let t = ScriptedTransport([spotifyMe, .init("/v1/search", json: ["tracks": spPage()], validate: { XCTAssertEqual(query($0, "q"), "isrc:TEST") }),
            .init("/v1/search", json: ["tracks": spPage([track])], validate: { XCTAssertEqual(query($0, "q"), "track:Song artist:Artist album:Album") })])
        let p = try await spotify(t), result = try await p.searchTracks(matching: source())
        XCTAssertEqual(result.coverage, .complete); XCTAssertEqual(result.candidates.map(\.id), ["one"])
        await t.assertExhausted()
    }
    func testLaterPageFailureKeepsCandidatesAndCoverageDistinctFromEmpty() async throws {
        let t = ScriptedTransport([appleStorefront,
            .init("/v1/catalog/ar/search", json: ["results": ["songs": ["data": [candidate("1")], "next": "/v1/catalog/ar/search?offset=1"]]]),
            .init("/v1/catalog/ar/search", status: 403), emptyAppleSearch])
        let p = try await apple(t), result = try await p.searchTracks(matching: source(isrc: nil))
        XCTAssertEqual(result.candidates.map(\.id), ["1"]); XCTAssertEqual(result.coverage, .partialFailure)
        XCTAssertFalse(result.notes.isEmpty)
        await t.assertExhausted()
    }

    func testAuthorizationFailurePreservesEarlierSearchEvidenceWithoutReconnecting() async throws {
        let t = ScriptedTransport([appleStorefront,
            .init("/v1/catalog/ar/search", json: ["results": ["songs": ["data": [candidate("1")], "next": "/v1/catalog/ar/search?offset=1"]]]),
            .init("/v1/catalog/ar/search", status: 401)])
        let p = try await apple(t), result = try await p.searchTracks(matching: source(isrc: nil))
        XCTAssertEqual(result.candidates.map(\.id), ["1"])
        XCTAssertEqual(result.coverage, .partialFailure)
        await expectError({ _ = try await p.account() }, matches: { if case .notConnected = $0 { return true }; return false })
        await t.assertExhausted()
    }
    func testSearchPaginationIsBoundedAndDoesNotClaimCompleteCoverage() async throws {
        let page: [String: Any] = ["results": ["songs": ["data": [candidate("1")], "next": "/v1/catalog/ar/search?offset=2"]]]
        let t = ScriptedTransport([appleStorefront,
            .init("/v1/catalog/ar/search", json: ["results": ["songs": ["data": [candidate("1")], "next": "/v1/catalog/ar/search?offset=1"]]]),
            .init("/v1/catalog/ar/search", json: page), emptyAppleSearch])
        let p = try await apple(t), result = try await p.searchTracks(matching: source(isrc: nil))
        XCTAssertEqual(result.coverage, .limited); XCTAssertEqual(result.candidates.count, 1)
        XCTAssertNil(CatalogMatcher.track(source(), candidates: result.candidates, sourceService: .spotify, coverage: result.coverage).selected)
        await t.assertExhausted()
    }
    func testAllSearchesFailedIsNotAnEmptySuccessfulSearch() async throws {
        let t = ScriptedTransport([appleStorefront, .init("/v1/catalog/ar/songs", status: 403),
            .init("/v1/catalog/ar/search", status: 403), .init("/v1/catalog/ar/search", status: 403)])
        let p = try await apple(t), result = try await p.searchTracks(matching: source())
        XCTAssertEqual(result.coverage, .failed); XCTAssertTrue(result.candidates.isEmpty)
        await t.assertExhausted()
    }

    func testAlbumExpansionIsBoundedWithoutDroppingUnexpandedEditions() async throws {
        let albums = (1...4).map { id in ["id": String(id), "type": "albums", "attributes": ["name": "Album", "artistName": "Artist", "trackCount": 1]] as [String: Any] }
        var steps = [appleStorefront, ScriptedTransport.Step("/v1/catalog/ar/search", json: ["results": ["albums": ["data": albums]]])]
        steps += (1...3).map { .init("/v1/catalog/ar/albums/\($0)/tracks", json: ["data": [candidate("100")]]) }
        let t = ScriptedTransport(steps), p = try await apple(t)
        let result = try await p.searchAlbums(matching: Album(id: "s", title: "Album", artist: "Artist", tracks: [source()]))
        XCTAssertEqual(result.coverage, .limited)
        XCTAssertEqual(result.candidates.count, 4)
        XCTAssertEqual(result.candidates.filter(\.isCompleteAlbum).count, 3)
        await t.assertExhausted()
    }

    func testAlbumAuthorizationFailureKeepsEarlierEditionMetadata() async throws {
        let album: [String: Any] = ["id": "1", "type": "albums", "attributes": ["name": "Album", "artistName": "Artist", "trackCount": 1]]
        let t = ScriptedTransport([appleStorefront,
            .init("/v1/catalog/ar/search", json: ["results": ["albums": ["data": [album], "next": "/v1/catalog/ar/search?offset=1"]]]),
            .init("/v1/catalog/ar/search", status: 401)])
        let p = try await apple(t), result = try await p.searchAlbums(matching: Album(id: "s", title: "Album", artist: "Artist"))
        XCTAssertEqual(result.coverage, .partialFailure)
        XCTAssertEqual(result.candidates.map(\.id), ["1"])
        XCTAssertFalse(result.candidates[0].isCompleteAlbum)
        await t.assertExhausted()
    }
    func testHTTPRetriesConsumeSharedSearchBudget() async throws {
        let steps = (0..<12).map { _ in ScriptedTransport.Step("/v1/search", status: 500) }
        let t = ScriptedTransport(steps)
        let budget = CatalogRequestBudget()
        var http = ProviderHTTP(transport: t, retry: .init()); http.sleep = { _ in }
        var request = URLRequest(url: URL(string: "https://api.spotify.com/v1/search")!); request.httpMethod = "GET"
        for _ in 0..<4 { do { _ = try await http.send(request, budget: budget) } catch is ProviderError {} }
        do { _ = try await http.send(request, budget: budget); XCTFail("Exceeded budget") } catch is CatalogBudgetExceeded {}
        let sent = await t.requests; XCTAssertEqual(sent.count, 12)
        await t.assertExhausted()
    }

    func testManualChecklistInventoryIsNotLimitedByCatalogSearchPageBudget() async throws {
        func track(_ id: String) -> [String: Any] { var result = spTrack(id); result["explicit"] = false; return result }
        let t = ScriptedTransport([spotifyMe, .init("/v1/me/playlists", json: spPage()),
            .init("/v1/me/tracks", json: spPage([["track": track("a")]], total: 3, next: "/v1/me/tracks?offset=1")),
            .init("/v1/me/tracks", json: spPage([["track": track("b")]], offset: 1, total: 3, next: "/v1/me/tracks?offset=2")),
            .init("/v1/me/tracks", json: spPage([["track": track("c")]], offset: 2, total: 3)),
            .init("/v1/me/albums", json: spPage())])
        let provider = try await spotify(t), inventory = try await provider.fetchLibrary()
        let report = ManualChecklistPlanner.make(source: inventory, library: ManualMusicLibrary(id: "xml:fixture", fileName: "Fixture.xml", tracks: []))
        XCTAssertTrue(inventory.complete)
        XCTAssertEqual(Set(report.items.map { $0.track.id }), ["a", "b", "c"])
        XCTAssertTrue(report.items.allSatisfy { $0.evidence == .missing })
        await t.assertExhausted()
    }
}
