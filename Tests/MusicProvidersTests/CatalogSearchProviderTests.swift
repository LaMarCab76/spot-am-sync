import XCTest
import SyncCore
@testable import MusicProviders

final class CatalogSearchProviderTests: XCTestCase {
    func testAppleIdentifierRateLimitStopsCallsAcrossSongs() async throws {
        let transport = ScriptedTransport([appleStorefront, .init("/v1/catalog/ar/songs", status: 429, headers: ["Retry-After": "60"])])
        let provider = try await apple(transport)
        for title in ["First", "Second"] {
            await expectError({ _ = try await provider.searchCatalog(.init(title: title, artist: "Artist", isrc: "TEST", stage: .identifier)) }, matches: {
                if case .rateLimited = $0 { return true }; return false
            })
        }
        await transport.assertExhausted()
    }
    func testAppleHydratesEveryISRCReferenceBeforeReturningCandidates() async throws {
        let references = [["id": "1", "type": "songs"], ["id": "2", "type": "songs"]]
        let response: [String: Any] = ["data": [amSong("1")], "meta": ["filters": ["isrc": ["TEST": references]]]]
        let t = ScriptedTransport([appleStorefront,
            .init("/v1/catalog/ar/songs", json: response, validate: {
                XCTAssertEqual(query($0, "filter[isrc]"), "TEST"); XCTAssertNil(query($0, "limit"))
            }),
            .init("/v1/catalog/ar/songs", json: ["data": [amSong("2")]])])
        let provider = try await apple(t)
        let result = try await provider.searchCatalog(.init(title: "Song", artist: "Artist", isrc: "TEST", stage: .identifier))
        XCTAssertEqual(result.candidates.map(\.id), ["1", "2"]); XCTAssertEqual(result.coverage, .complete)
        await t.assertExhausted()
    }
    func testAppleUnavailableISRCReferencePreservesPartialEvidence() async throws {
        let references = [["id": "2", "type": "songs"]]
        let response: [String: Any] = ["data": [amSong("1")], "meta": ["filters": ["isrc": ["TEST": references]]]]
        let t = ScriptedTransport([appleStorefront,
            .init("/v1/catalog/ar/songs", json: response),
            .init("/v1/catalog/ar/songs", status: 404)])
        let provider = try await apple(t)
        let result = try await provider.searchCatalog(.init(title: "Song", artist: "Artist", isrc: "TEST", stage: .identifier))
        XCTAssertEqual(result.candidates.count, 1); XCTAssertEqual(result.coverage, .partialFailure)
        XCTAssertFalse(result.notes.isEmpty); await t.assertExhausted()
    }
    func testSpotifyCombinesAllFieldsAndCachesOnlyCompleteResults() async throws {
        let t = ScriptedTransport([spotifyMe, .init("/v1/search", json: ["tracks": spPage([spTrack("1")])], validate: {
            XCTAssertEqual(query($0, "q"), "artist:\"Artist\" album:\"Album\" track:\"Title\"")
            XCTAssertEqual(query($0, "limit"), "10")
        })])
        let provider = try await spotify(t), request = TrackSearchQuery(title: "Title", artist: "Artist", album: "Album")
        let first = try await provider.searchCatalog(request), second = try await provider.searchCatalog(request)
        XCTAssertEqual(first, second); XCTAssertEqual(first.coverage, .complete); await t.assertExhausted()
    }
    func testSpotifyBoundedPaginationKeepsCandidatesAndMarksPartial() async throws {
        let pages = (0..<2).map { index in
            ScriptedTransport.Step("/v1/search", json: ["tracks": spPage([spTrack("\(index)")], offset: index, total: 4, next: "/v1/search?offset=\(index + 1)")])
        }
        let t = ScriptedTransport([spotifyMe] + pages), provider = try await spotify(t)
        let result = try await provider.searchCatalog(.init(title: "Song", artist: "Artist"))
        XCTAssertEqual(result.candidates.count, 2); XCTAssertEqual(result.coverage, .limited)
        XCTAssertTrue(result.notes.contains { $0.contains("límite") }); await t.assertExhausted()
    }
    func testSpotifyRateLimitStopsRepeatedCallsAcrossSongs() async throws {
        let t = ScriptedTransport([spotifyMe, .init("/v1/search", status: 429, headers: ["Retry-After": "60"])])
        let provider = try await spotify(t)
        let result = try await provider.searchCatalog(.init(title: "Song", artist: "Artist"))
        XCTAssertEqual(result.retryAfterSeconds, 60)
        await expectError({ _ = try await provider.searchCatalog(.init(title: "Other", artist: "Artist")) }, matches: {
            if case .rateLimited = $0 { return true }; return false
        })
        await t.assertExhausted()
    }
    func testStagedSearchPreservesEvidenceAndStopsAfterAuthorizationFailure() async throws {
        let transport = ScriptedTransport([appleStorefront,
            .init("/v1/catalog/ar/search", json: ["results": ["songs": ["data": [amSong("1")], "next": "/v1/catalog/ar/search?offset=1"]]]),
            .init("/v1/catalog/ar/search", status: 401)])
        let provider = try await apple(transport)
        let result = try await CatalogSearch.search(source: .init(id: "s", title: "Song", artist: "Artist", albumTitle: "Album"), provider: provider)
        XCTAssertEqual(result.candidates.map(\.id), ["1"])
        XCTAssertEqual(result.coverage, .partialFailure); XCTAssertEqual(result.authorizationFailed, true)
        XCTAssertEqual(result.stages, [.metadata]); await transport.assertExhausted()
    }

    func testOneRequestBudgetCoversAllStagedQueriesAndAlbumExpansions() async throws {
        let album: (String) -> [String: Any] = { ["id": $0, "type": "album", "name": "Album", "artists": [["name": "Artist"]]] }
        var steps = [spotifyMe, ScriptedTransport.Step("/v1/search", json: ["tracks": spPage()])]
        steps += (0..<2).map { .init("/v1/search", json: ["tracks": spPage([spTrack("t\($0)")], offset: $0, total: 2, next: $0 == 0 ? "/v1/search?offset=1" : nil)]) }
        steps += [.init("/v1/search", json: ["albums": spPage([album("a"), album("b")], total: 3, next: "/v1/search?offset=2")]),
                  .init("/v1/search", json: ["albums": spPage([album("c")], offset: 2, total: 3)])]
        for id in ["a", "b", "c"] {
            steps += (0..<2).map { .init("/v1/albums/\(id)/tracks", json: spPage([spTrack("\(id)\($0)")], offset: $0, total: 2, next: $0 == 0 ? "/v1/albums/\(id)/tracks?offset=1" : nil)) }
        }
        steps += [.init("/v1/search", json: ["tracks": spPage([spTrack("last")], total: 2, next: "/v1/search?offset=1")])]
        let transport = ScriptedTransport(steps), provider = try await spotify(transport)
        let result = try await CatalogSearch.search(source: .init(id: "s", title: "Missing", artist: "Artist", albumTitle: "Album", isrc: "TEST"), provider: provider)
        XCTAssertEqual(result.coverage, .limited); XCTAssertEqual(result.stages, SearchStage.allCases)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 13, "One account read and twelve catalog requests")
        XCTAssertFalse(result.candidates.isEmpty); await transport.assertExhausted()
    }

    func testPublicSearchKeepsITunesNamespaceAndNeverSendsCredentials() async throws {
        let value: [String: Any] = ["wrapperType": "track", "kind": "song", "trackId": 123, "trackName": "Title", "artistName": "Artist",
                                   "collectionName": "Compilation", "trackTimeMillis": 120000, "trackExplicitness": "notExplicit",
                                   "trackViewUrl": "https://music.apple.com/ar/album/example?i=123"]
        let t = ScriptedTransport([.init("/search", json: ["resultCount": 1, "results": [value]], validate: {
            XCTAssertEqual($0.url?.host, "itunes.apple.com"); XCTAssertEqual(query($0, "country"), "AR")
            XCTAssertEqual(query($0, "entity"), "song"); XCTAssertNil($0.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil($0.value(forHTTPHeaderField: "Music-User-Token"))
        })])
        let provider = ITunesCatalogSearch(transport: t)
        var request = TrackSearchQuery(title: "Title", artist: "Artist"); request.country = "AR"
        let result = try await provider.search(request)
        XCTAssertEqual(result.candidates.first?.id, "itunes:123"); XCTAssertNil(result.candidates.first?.catalogID)
        XCTAssertEqual(result.coverage, .partial)
        _ = try await provider.search(request)
        await t.assertExhausted()
    }
    func testPublicSearchRejectsMissingTerritoryWithoutNetwork() async throws {
        let t = ScriptedTransport([]), provider = ITunesCatalogSearch(transport: t)
        await expectError({ _ = try await provider.search(.init(title: "Song", artist: "Artist")) }, matches: {
            if case .invalidResponse = $0 { return true }; return false
        })
        await t.assertExhausted()
    }
}
