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
            .init("/v1/catalog/ar/songs/2", json: ["data": [amSong("2")]])])
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
            .init("/v1/catalog/ar/songs/2", status: 404)])
        let provider = try await apple(t)
        let result = try await provider.searchCatalog(.init(title: "Song", artist: "Artist", isrc: "TEST", stage: .identifier))
        XCTAssertEqual(result.candidates.count, 1); XCTAssertEqual(result.coverage, .partial)
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
        let pages = (0..<3).map { index in
            ScriptedTransport.Step("/v1/search", json: ["tracks": spPage([spTrack("\(index)")], offset: index, total: 4, next: "/v1/search?offset=\(index + 1)")])
        }
        let t = ScriptedTransport([spotifyMe] + pages), provider = try await spotify(t)
        let result = try await provider.searchCatalog(.init(title: "Song", artist: "Artist"))
        XCTAssertEqual(result.candidates.count, 3); XCTAssertEqual(result.coverage, .partial)
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
