import Foundation
import XCTest
import SyncCore
@testable import MusicProviders

final class SpotifyProviderTests: XCTestCase {
    func testDeclaredPlaylistCountDisagreementCannotBecomeGenuineEmpty() async throws {
        let playlist: [String: Any] = ["id": "p", "name": "P", "owner": ["id": "user"], "items": ["total": 2]]
        let t = ScriptedTransport([spotifyMe, .init("/v1/me/tracks", json: spPage()), .init("/v1/me/albums", json: spPage()),
            .init("/v1/me/playlists", json: spPage([playlist])), .init("/v1/playlists/p/items", json: spPage())])
        let p = try await spotify(t), s = try await p.fetchLibrary()
        XCTAssertFalse(s.coverage.playlists); XCTAssertFalse(s.playlists[0].contentsComplete)
        await t.assertExhausted()
    }
    func testSearchTraversesEveryPageWith2026Limit() async throws {
        let t = ScriptedTransport([spotifyMe,
            .init("/v1/search", json: ["tracks": spPage([spTrack("a")], total: 2, next: "/v1/search?q=isrc%3Atest&type=track&limit=10&offset=1")], validate: {
                XCTAssertEqual(query($0, "limit"), "10"); XCTAssertEqual(query($0, "q"), "isrc:test")
            }), .init("/v1/search", json: ["tracks": spPage([spTrack("b")], offset: 1, total: 2)]),
            .init("/v1/search", json: ["tracks": spPage()])])
        let p = try await spotify(t), tracks = try await p.searchTracks(matching: Track(id: "source", title: "T", artist: "A", isrc: "test"))
        XCTAssertEqual(tracks.candidates.map(\.id), ["a", "b"]); await t.assertExhausted()
    }
    func testRenameDoesNotEraseAnUnspecifiedDescription() async throws {
        let t = ScriptedTransport([spotifyMe, .init("PUT", "/v1/playlists/p", validate: {
            XCTAssertEqual(try body($0) as? [String: String], ["name": "New"])
        }), .init("PUT", "/v1/playlists/p", validate: {
            XCTAssertEqual(try body($0) as? [String: String], ["description": "Description"])
        })])
        let p = try await spotify(t)
        _ = try await p.perform(.init(service: .spotify, kind: .renamePlaylist, targetID: "p", title: "Rename", playlistName: "New"))
        _ = try await p.perform(.init(service: .spotify, kind: .renamePlaylist, targetID: "p", title: "Describe", playlistDescription: "Description"))
        await t.assertExhausted()
    }
    func testGenuineEmptyLibraryHasCompleteZeroCounts() async throws {
        let t = ScriptedTransport([spotifyMe, .init("/v1/me/tracks", json: spPage()), .init("/v1/me/albums", json: spPage()), .init("/v1/me/playlists", json: spPage())])
        let p = try await spotify(t), snapshot = try await p.fetchLibrary()
        XCTAssertTrue(snapshot.complete); XCTAssertEqual(snapshot.playlists.count, 0); XCTAssertEqual(snapshot.savedTracks.count, 0); XCTAssertEqual(snapshot.savedAlbums.count, 0)
        await t.assertExhausted()
    }
    func testForbiddenCollectionsAreIncompleteNotGenuineEmpty() async throws {
        let t = ScriptedTransport([spotifyMe, .init("/v1/me/tracks", json: spPage()), .init("/v1/me/albums", status: 404), .init("/v1/me/playlists", status: 403)])
        let p = try await spotify(t), snapshot = try await p.fetchLibrary()
        XCTAssertFalse(snapshot.coverage.playlists); XCTAssertTrue(snapshot.coverage.tracks); XCTAssertFalse(snapshot.coverage.albums)
        XCTAssertFalse(snapshot.complete); XCTAssertGreaterThan(snapshot.coverage.notes.count, 1)
    }
    func testAllPagesNestedItemsAndNullPlaceholdersAreRetained() async throws {
        let playlist: [String: Any] = ["id": "p", "name": "Playlist", "owner": ["id": "user"]]
        let t = ScriptedTransport([spotifyMe,
            .init("/v1/me/tracks", json: spPage([["track": spTrack("b")]], total: 2, next: "/v1/me/tracks?offset=1")),
            .init("/v1/me/tracks", status: 403), .init("/v1/me/albums", json: spPage()),
            .init("/v1/me/playlists", json: spPage([playlist], total: 2, next: "/v1/me/playlists?offset=1")),
            .init("/v1/me/playlists", json: spPage([NSNull()], offset: 1, total: 2)),
            .init("/v1/playlists/p/items", json: spPage([["item": spTrack("a")]], total: 4, next: "/v1/playlists/p/items?offset=1")),
            .init("/v1/playlists/p/items", json: spPage([["item": NSNull(), "track": spTrack("mustNotFallback")], ["item": ["id": "episode", "type": "episode"]], ["item": ["type": "track", "name": "local", "is_local": true]]], offset: 1, total: 4))])
        let p = try await spotify(t), s = try await p.fetchLibrary()
        XCTAssertEqual(s.playlists.count, 2); XCTAssertEqual(s.playlists[0].tracks.count, 4)
        XCTAssertEqual(s.playlists[0].tracks[0].id, "a"); XCTAssertFalse(s.playlists[0].tracks[1].available)
        XCTAssertTrue(s.playlists[0].tracks[3].isLocal); XCTAssertFalse(s.playlists[0].contentsComplete)
        XCTAssertEqual(s.savedTracks.count, 1); XCTAssertFalse(s.coverage.tracks); await t.assertExhausted()
    }
    func testReceivedMetadataIsReusedAndSavedAlbumTracksArePaginated() async throws {
        let a: [String: Any] = ["id": "album", "type": "album", "name": "Album", "artists": [["name": "Artist"]], "total_tracks": 2,
                               "tracks": spPage([spTrack("a", isrc: nil)], total: 2, next: "/v1/albums/album/tracks?offset=1")]
        let playlist: [String: Any] = ["id": "p", "name": "Playlist", "owner": ["id": "user"]]
        let t = ScriptedTransport([spotifyMe,
            .init("/v1/me/tracks", json: spPage([["track": spTrack("a")]])),
            .init("/v1/me/albums", json: spPage([["album": a]])),
            .init("/v1/albums/album/tracks", json: spPage([spTrack("b")], offset: 1, total: 2)),
            .init("/v1/me/playlists", json: spPage([playlist])),
            .init("/v1/playlists/p/items", json: spPage([["item": spTrack("a", isrc: nil)], ["item": spTrack("a", isrc: nil)]]))])
        let p = try await spotify(t), s = try await p.fetchLibrary()
        XCTAssertEqual(s.playlists[0].tracks.map(\.isrc), ["ARTEST1234567", "ARTEST1234567"])
        XCTAssertEqual(s.savedAlbums[0].tracks.count, 2); XCTAssertTrue(s.savedAlbums[0].isCompleteAlbum)
        let requests = await t.requests; XCTAssertFalse(requests.contains { $0.url?.path.hasPrefix("/v1/tracks/") == true })
        await t.assertExhausted()
    }
    func testLibraryWritesUse2026URIQueryAndBatchesOfForty() async throws {
        let tracks = (0..<41).map { Track(id: "t\($0)", title: "T", artist: "A") }
        let t = ScriptedTransport([spotifyMe,
            .init("PUT", "/v1/me/library", validate: { r in XCTAssertNil(r.httpBody); XCTAssertEqual(query(r, "uris")?.split(separator: ",").count, 40) }),
            .init("PUT", "/v1/me/library", validate: { XCTAssertEqual(query($0, "uris"), "spotify:track:t40") }),
            .init("DELETE", "/v1/me/library", validate: { XCTAssertEqual(query($0, "uris"), "spotify:album:album") }),
            .init("DELETE", "/v1/me/library", validate: { XCTAssertEqual(query($0, "uris"), "spotify:playlist:playlist") })])
        let p = try await spotify(t)
        _ = try await p.perform(.init(service: .spotify, kind: .saveTracks, title: "Save", tracks: tracks))
        _ = try await p.perform(.init(service: .spotify, kind: .removeAlbums, title: "Remove", albums: [Album(id: "album", title: "A", artist: "B")]))
        _ = try await p.perform(.init(service: .spotify, kind: .removePlaylist, targetID: "playlist", title: "Remove"))
        await t.assertExhausted()
    }
    func testCreateUsesMeEndpointAndReturnsEssentialID() async throws {
        let t = ScriptedTransport([spotifyMe, .init("POST", "/v1/me/playlists", status: 201, json: ["id": "new"], validate: { r in
            XCTAssertEqual(try body(r)["public"] as? Bool, false)
        })])
        let p = try await spotify(t), receipt = try await p.perform(.init(service: .spotify, kind: .createPlaylist, title: "Create", playlistName: "New"))
        XCTAssertEqual(receipt.createdID, "new"); await t.assertExhausted()
    }
    func testCreateWithoutIDIsUncertainAndMustNotRetry() async throws {
        let t = ScriptedTransport([spotifyMe, .init("POST", "/v1/me/playlists", status: 201, json: ["name": "New"])])
        let p = try await spotify(t)
        await expectError({ _ = try await p.perform(.init(service: .spotify, kind: .createPlaylist, title: "Create", playlistName: "New")) }, matches: { if case .uncertainWrite = $0 { return true }; return false })
        await t.assertExhausted()
    }
    func testReplaceChecksExpectedOrderAndUsesAtMost100PerChunk() async throws {
        let tracks = (0..<201).map { Track(id: "t\($0)", title: "T", artist: "A") }
        let t = ScriptedTransport([spotifyMe,
            .init("/v1/playlists/p/items", json: spPage([["item": spTrack("old")]])),
            .init("PUT", "/v1/playlists/p/items", json: ["snapshot_id": "s1"], validate: { XCTAssertEqual(try body($0)["uris"] as? [String], tracks.prefix(100).map { "spotify:track:\($0.id)" }) }),
            .init("POST", "/v1/playlists/p/items", json: ["snapshot_id": "s2"], validate: { XCTAssertEqual((try body($0)["uris"] as? [String])?.count, 100) }),
            .init("POST", "/v1/playlists/p/items", json: ["snapshot_id": "s3"], validate: { XCTAssertEqual(try body($0)["uris"] as? [String], ["spotify:track:t200"]) })])
        let p = try await spotify(t)
        _ = try await p.perform(.init(service: .spotify, kind: .replacePlaylistTracks, targetID: "p", title: "Replace", tracks: tracks, beforeTrackIDs: ["old"]))
        await t.assertExhausted()
    }
    func testStaleReplaceAndMissingExpectedStateDoNotWrite() async throws {
        let t = ScriptedTransport([spotifyMe, .init("/v1/playlists/p/items", json: spPage([["item": spTrack("newExternal")]]))])
        let p = try await spotify(t)
        for expected in [nil, ["old"]] as [[String]?] {
            await expectError({ _ = try await p.perform(.init(service: .spotify, kind: .replacePlaylistTracks, targetID: "p", title: "Replace", beforeTrackIDs: expected)) }, matches: { if case .unsupported = $0 { return true }; return false })
        }
        let requests = await t.requests; XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" }); await t.assertExhausted()
    }
    func testSecondChunkFailureIsUncertainEvenOnDefinitive403() async throws {
        let t = ScriptedTransport([spotifyMe, .init("POST", "/v1/playlists/p/items", json: ["snapshot_id": "s1"]), .init("POST", "/v1/playlists/p/items", status: 403)])
        let p = try await spotify(t)
        await expectError({ _ = try await p.perform(.init(service: .spotify, kind: .addPlaylistTracks, targetID: "p", title: "Add",
            tracks: (0..<101).map { Track(id: "t\($0)", title: "T", artist: "A") })) }, matches: { if case .uncertainWrite = $0 { return true }; return false })
        await t.assertExhausted()
    }
    func testWrite401DoesNotRefreshAndRetryMutation() async throws {
        let t = ScriptedTransport([spotifyMe, .init("PUT", "/v1/me/library", status: 401)])
        let p = try await spotify(t)
        await expectError({ _ = try await p.perform(.init(service: .spotify, kind: .saveTracks, title: "Save", tracks: [Track(id: "a", title: "A", artist: "B")])) }, matches: { if case .unauthorized = $0 { return true }; return false })
        await t.assertExhausted()
    }
}
