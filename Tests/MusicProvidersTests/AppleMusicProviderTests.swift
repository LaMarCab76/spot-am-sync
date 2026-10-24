import Foundation
import XCTest
import SyncCore
@testable import MusicProviders

final class AppleMusicProviderTests: XCTestCase {
    func testGenuineEmptyAndForbiddenLibrariesHaveDifferentCoverage() async throws {
        for forbidden in [false, true] {
            let t = ScriptedTransport([appleStorefront,
                .init("/v1/me/library/playlists", status: forbidden ? 403 : 200, json: forbidden ? nil : ["data": []]),
                .init("/v1/me/library/songs", json: ["data": []]), .init("/v1/me/library/albums", json: ["data": []])])
            let p = try await apple(t), s = try await p.fetchLibrary()
            XCTAssertEqual(s.complete, !forbidden); XCTAssertEqual(s.playlists.count, 0); XCTAssertEqual(s.savedTracks.count, 0)
            await t.assertExhausted()
        }
    }
    func testEveryCollectionAndNestedRelationshipIsPaginatedAndUnknownsRemain() async throws {
        let playlist: [String: Any] = ["id": "p.one", "type": "library-playlists", "attributes": ["name": "P", "canEdit": true],
            "relationships": ["tracks": ["data": [amSong("1", libraryID: "i.one")], "next": "/v1/me/library/playlists/p.one/tracks?offset=1", "meta": ["total": 2]]]]
        let t = ScriptedTransport([appleStorefront,
            .init("/v1/me/library/playlists", json: ["data": [playlist], "next": "/v1/me/library/playlists?offset=1", "meta": ["total": 2]]),
            .init("/v1/me/library/playlists", json: ["data": [NSNull()], "meta": ["total": 2]]),
            .init("/v1/me/library/playlists/p.one/tracks", json: ["data": [NSNull()], "meta": ["total": 2]]),
            .init("/v1/me/library/songs", json: ["data": [amSong("1", libraryID: "i.one")], "next": "/v1/me/library/songs?offset=1", "meta": ["total": 2]]),
            .init("/v1/me/library/songs", json: ["data": [amSong("2", libraryID: "i.two")], "meta": ["total": 2]]),
            .init("/v1/me/library/albums", json: ["data": [NSNull()], "next": "/v1/me/library/albums?offset=1", "meta": ["total": 2]]),
            .init("/v1/me/library/albums", json: ["data": [NSNull()], "meta": ["total": 2]])])
        let p = try await apple(t), s = try await p.fetchLibrary()
        XCTAssertEqual(s.playlists.count, 2); XCTAssertEqual(s.playlists[0].tracks.count, 2)
        XCTAssertEqual(s.playlists[0].tracks[0].catalogID, "1"); XCTAssertFalse(s.playlists[0].tracks[1].available)
        XCTAssertFalse(s.playlists[0].contentsComplete); XCTAssertEqual(s.savedTracks.count, 2)
        XCTAssertTrue(s.playlists[0].editable); XCTAssertEqual(s.playlists[0].ownership, .unknown)
        XCTAssertEqual(s.savedAlbums.count, 2); XCTAssertFalse(s.coverage.albums); XCTAssertTrue(s.coverage.tracks)
        await t.assertExhausted()
    }
    func testCatalogRelationshipAndReferenceHydrationPreserveLibraryID() async throws {
        let library: [String: Any] = ["id": "i.one", "type": "library-songs", "attributes": ["name": "One", "artistName": "Artist", "durationInMillis": 120000]]
        let t = ScriptedTransport([appleStorefront, .init("/v1/me/library/playlists", json: ["data": []]),
            .init("/v1/me/library/songs", json: ["data": [library]]),
            .init("/v1/me/library/songs/i.one/catalog", json: ["data": [["id": "1", "type": "songs"]]]),
            .init("/v1/catalog/ar/songs/1", json: ["data": [amSong("1")]]), .init("/v1/me/library/albums", json: ["data": []])])
        let p = try await apple(t), s = try await p.fetchLibrary()
        XCTAssertEqual(s.savedTracks[0].id, "i.one"); XCTAssertEqual(s.savedTracks[0].catalogID, "1")
        XCTAssertEqual(s.savedTracks[0].isrc, "ARTEST1234567"); XCTAssertTrue(s.complete); await t.assertExhausted()
    }
    func testAlbumCompletenessComparedAgainstFullPaginatedCatalog() async throws {
        for complete in [false, true] {
            let catalog: [String: Any] = ["id": "10", "type": "albums", "attributes": ["name": "Album", "artistName": "Artist", "trackCount": 2],
                "relationships": ["tracks": ["data": [amSong("1")], "next": "/v1/catalog/ar/albums/10/tracks?offset=1", "meta": ["total": 2]]]]
            let libraryTracks: [Any] = complete ? [amSong("1", libraryID: "i.one"), amSong("2", libraryID: "i.two")] : [amSong("1", libraryID: "i.one")]
            let album: [String: Any] = ["id": "l.album", "type": "library-albums", "attributes": ["name": "Album", "artistName": "Artist", "trackCount": libraryTracks.count],
                "relationships": ["catalog": ["data": [catalog]], "tracks": ["data": libraryTracks]]]
            let t = ScriptedTransport([appleStorefront, .init("/v1/me/library/playlists", json: ["data": []]), .init("/v1/me/library/songs", json: ["data": []]),
                .init("/v1/me/library/albums", json: ["data": [album]]),
                .init("/v1/catalog/ar/albums/10/tracks", json: ["data": [amSong("2")], "meta": ["total": 2]])])
            let p = try await apple(t), s = try await p.fetchLibrary()
            XCTAssertEqual(s.savedAlbums[0].isCompleteAlbum, complete); XCTAssertEqual(s.savedAlbums[0].tracks.count, libraryTracks.count)
            XCTAssertTrue(s.coverage.albums, "A known partial saved album is not a failed read")
            await t.assertExhausted()
        }
    }
    func testAlbumCatalogFailureCannotClaimCompleteAlbum() async throws {
        let album: [String: Any] = ["id": "l.album", "type": "library-albums", "attributes": ["name": "Album", "artistName": "Artist"], "relationships": ["tracks": ["data": [amSong("1", libraryID: "i.one")]]]]
        let t = ScriptedTransport([appleStorefront, .init("/v1/me/library/playlists", json: ["data": []]), .init("/v1/me/library/songs", json: ["data": []]),
            .init("/v1/me/library/albums", json: ["data": [album]]), .init("/v1/me/library/albums/l.album/catalog", status: 403)])
        let p = try await apple(t), s = try await p.fetchLibrary()
        XCTAssertEqual(s.savedAlbums[0].tracks.count, 1); XCTAssertFalse(s.savedAlbums[0].isCompleteAlbum); XCTAssertFalse(s.coverage.albums)
    }
    func testSupportedRESTWritesAndCreatedID() async throws {
        let t = ScriptedTransport([appleStorefront,
            .init("POST", "/v1/me/library/playlists", status: 201, json: ["data": [["id": "p.created", "type": "library-playlists"]]], validate: {
                XCTAssertEqual((try body($0)["attributes"] as? [String: Any])?["isPublic"] as? Bool, false)
            }),
            .init("POST", "/v1/me/library/playlists/p.created/tracks", status: 204, validate: {
                XCTAssertEqual(try body($0)["data"] as? [[String: String]], [["id": "1", "type": "songs"]])
            }),
            .init("POST", "/v1/me/library", status: 202, validate: { XCTAssertEqual(query($0, "ids[songs]"), "1"); XCTAssertNil($0.httpBody) }),
            .init("POST", "/v1/me/library", status: 202, validate: { XCTAssertEqual(query($0, "ids[albums]"), "10") })])
        let p = try await apple(t), track = Track(id: "i.one", catalogID: "1", title: "One", artist: "Artist")
        let receipt = try await p.perform(.init(service: .appleMusic, kind: .createPlaylist, title: "Create", playlistName: "New", tracks: [track]))
        XCTAssertEqual(receipt.createdID, "p.created")
        _ = try await p.perform(.init(service: .appleMusic, kind: .saveTracks, title: "Save", tracks: [track]))
        _ = try await p.perform(.init(service: .appleMusic, kind: .saveAlbums, title: "Save", albums: [Album(id: "l.album", catalogID: "10", title: "Album", artist: "Artist")]))
        let requests = await t.requests; XCTAssertFalse(requests.contains { $0.url!.absoluteString.contains("favorite") }); await t.assertExhausted()
    }
    func testIgnoredLibraryAdditionIsAcceptedButNeverClaimedVerified() async throws {
        let t = ScriptedTransport([appleStorefront, .init("POST", "/v1/me/library", status: 202),
            .init("/v1/me/library/playlists", json: ["data": []]), .init("/v1/me/library/songs", json: ["data": []]), .init("/v1/me/library/albums", json: ["data": []])])
        let p = try await apple(t), account = try await p.account()
        let operation = SyncOperation(service: .appleMusic, kind: .saveTracks, title: "Save", tracks: [Track(id: "1", catalogID: "1", title: "One", artist: "Artist")])
        let receipt = try await p.perform(operation)
        XCTAssertTrue(receipt.message.contains("no está verificado"))
        let after = try await p.fetchLibrary()
        XCTAssertNil(OperationVerifier.receipt(for: operation, before: LibrarySnapshot(account: account), after: after, receipt: receipt))
        await t.assertExhausted()
    }
    func testUndocumentedMutationsThrowWithoutAnyRequest() async throws {
        let t = ScriptedTransport([appleStorefront]), p = try await apple(t)
        for kind in [OperationKind.removeTracks, .removeAlbums, .removePlaylist, .renamePlaylist, .replacePlaylistTracks] {
            await expectError({ _ = try await p.perform(.init(service: .appleMusic, kind: kind, targetID: "p", title: "Unsupported")) }, matches: { if case .unsupported = $0 { return true }; return false })
        }
        let requests = await t.requests; XCTAssertEqual(requests.count, 1)
    }
    func testCreateThenAppendFailureIsUncertainAndIncludesRecoveryID() async throws {
        let t = ScriptedTransport([appleStorefront, .init("POST", "/v1/me/library/playlists", status: 201, json: ["data": [["id": "p.created", "type": "library-playlists"]]]),
            .init("POST", "/v1/me/library/playlists/p.created/tracks", status: 403)])
        let p = try await apple(t)
        await expectError({ _ = try await p.perform(.init(service: .appleMusic, kind: .createPlaylist, title: "Create", playlistName: "New", tracks: [Track(id: "1", title: "One", artist: "Artist")])) }, matches: {
            if case .uncertainWrite(let message) = $0 { return message.contains("p.created") }; return false
        }); await t.assertExhausted()
    }
}
