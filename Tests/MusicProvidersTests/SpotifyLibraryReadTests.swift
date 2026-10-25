import Foundation
import XCTest
import SyncCore
@testable import MusicProviders

final class SpotifyLibraryReadTests: XCTestCase {
    func testStagesFinishSavedLibraryAndListingBeforeReadingPlaylistContents() async throws {
        let album: [String: Any] = ["id": "album", "type": "album", "name": "Album", "artists": [["name": "Artist"]], "total_tracks": 2,
            "tracks": spPage([spTrack("a", isrc: nil)], total: 2, next: "/v1/albums/album/tracks?offset=1")]
        func playlist(_ id: String) -> [String: Any] { ["id": id, "name": id, "owner": ["id": "user"], "items": ["total": 1]] }
        let t = ScriptedTransport([spotifyMe,
            .init("/v1/me/tracks", json: spPage([["track": spTrack("saved")]], total: 2, next: "/v1/me/tracks?offset=1")),
            .init("/v1/me/tracks", json: spPage([["track": spTrack("saved2")]], offset: 1, total: 2)),
            .init("/v1/me/albums", json: spPage([["album": album]])),
            .init("/v1/albums/album/tracks", json: spPage([spTrack("b", isrc: nil)], offset: 1, total: 2)),
            .init("/v1/me/playlists", json: spPage([playlist("p")], total: 2, next: "/v1/me/playlists?offset=1")),
            .init("/v1/me/playlists", json: spPage([playlist("q")], offset: 1, total: 2)),
            .init("/v1/playlists/p/items", json: spPage([["item": spTrack("a", isrc: nil)]])),
            .init("/v1/playlists/q/items", json: spPage([["item": spTrack("b", isrc: nil)]]))])
        let provider = try await spotify(t), recorder = ProgressRecorder()
        let result = try await provider.fetchLibrary { update in
            let requests = await t.requests
            if update.stage == .playlistList {
                XCTAssertFalse(requests.contains { $0.url?.path.hasPrefix("/v1/playlists/") == true })
                XCTAssertTrue(update.playlists.allSatisfy { $0.state == .pending })
            }
            if update.stage == .savedTracks && update.received == 1 { XCTAssertEqual(requests.count, 2) }
            await recorder.add(update)
        }
        XCTAssertTrue(result.complete)
        let events = await recorder.events
        var stages: [LibraryReadProgress.Stage] = []
        for e in events where stages.last != e.stage { stages.append(e.stage) }
        XCTAssertEqual(stages, [.savedTracks, .savedAlbums, .playlistList, .playlistTracks])
        XCTAssertEqual(events.last?.playlists.map(\.state), [.complete, .complete])
        XCTAssertEqual(events.last?.received, 2)
        await t.assertExhausted()
    }

    func testThousandTracksWithoutISRCUseOnlyPagedInventoryRequests() async throws {
        var steps = [spotifyMe]
        for offset in stride(from: 0, to: 1_000, by: 50) {
            let items = (offset..<(offset + 50)).map { ["track": spTrack("t\($0)", isrc: nil)] }
            steps.append(.init("/v1/me/tracks", json: spPage(items, offset: offset, total: 1_000,
                next: offset < 950 ? "/v1/me/tracks?offset=\(offset + 50)" : nil)))
        }
        steps += [.init("/v1/me/albums", json: spPage()), .init("/v1/me/playlists", json: spPage())]
        let transport = ScriptedTransport(steps), provider = try await spotify(transport)
        let result = try await provider.fetchLibrary()
        XCTAssertEqual(result.savedTracks.count, 1_000); XCTAssertTrue(result.complete)
        XCTAssertTrue(result.savedTracks.allSatisfy { $0.isrc == nil })
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 23) // profile + 20 saved-track pages + albums + playlists
        await transport.assertExhausted()
    }

    func testQuotaStopsWholeReadAndImmediateRetryWithoutMoreRequests() async throws {
        let t = ScriptedTransport([spotifyMe, .init("/v1/me/tracks", status: 429, headers: ["Retry-After": "120"])])
        let provider = try await spotify(t), recorder = ProgressRecorder()
        for _ in 0..<2 {
            await expectError({ _ = try await provider.fetchLibrary { await recorder.add($0) } }, matches: {
                if case .rateLimited(let seconds) = $0 { return seconds > 0 }; return false
            })
        }
        let events = await recorder.events, requests = await t.requests
        XCTAssertTrue(events.contains { $0.waitingUntil != nil }); XCTAssertEqual(requests.count, 2)
        XCTAssertFalse(events.contains { $0.stage != .savedTracks })
        await t.assertExhausted()
    }

    func testCancellationAtPageProgressPreventsNextRequestAndReleasesProvider() async throws {
        let t = ScriptedTransport([spotifyMe,
            .init("/v1/me/tracks", json: spPage([["track": spTrack("a")]], total: 2, next: "/v1/me/tracks?offset=1")),
            .init("/v1/me/tracks", json: spPage()), .init("/v1/me/albums", json: spPage()), .init("/v1/me/playlists", json: spPage())])
        let provider = try await spotify(t), gate = ReadProgressGate()
        let task = Task {
            try await provider.fetchLibrary { update in
                if update.stage == .savedTracks && update.received == 1 { await gate.pause() }
            }
        }
        await gate.waitUntilEntered(); task.cancel(); await gate.release()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {}
        let afterCancel = await t.requests; XCTAssertEqual(afterCancel.count, 2)
        let fresh = try await provider.fetchLibrary(); XCTAssertTrue(fresh.complete)
        await t.assertExhausted()
    }

    func testChangingTotalAndForbiddenPlaylistRemainPartial() async throws {
        let t = ScriptedTransport([spotifyMe,
            .init("/v1/me/tracks", json: spPage([["track": spTrack("a")]], total: 3, next: "/v1/me/tracks?offset=1")),
            .init("/v1/me/tracks", json: spPage([["track": spTrack("b")]], offset: 1, total: 2)),
            .init("/v1/me/albums", json: spPage()),
            .init("/v1/me/playlists", json: spPage([["id": "p", "name": "P"]])),
            .init("/v1/playlists/p/items", status: 403)])
        let provider = try await spotify(t), recorder = ProgressRecorder()
        let result = try await provider.fetchLibrary { await recorder.add($0) }
        let events = await recorder.events
        XCTAssertNil(events.first { $0.stage == .savedTracks && $0.received == 2 }?.total)
        XCTAssertEqual(events.last?.playlists.first?.state, .partial)
        XCTAssertFalse(result.complete); XCTAssertEqual(result.savedTracks.count, 2)
        await t.assertExhausted()
    }

    func testMetadataReuseKeepsConflictsUnavailableTracksAndDuplicatePositions() async throws {
        var conflicting = spTrack("a"); conflicting["external_ids"] = ["isrc": "OTHER"]
        var restricted = spTrack("b", isrc: nil); restricted["is_playable"] = false
        let t = ScriptedTransport([spotifyMe,
            .init("/v1/me/tracks", json: spPage([["track": spTrack("a")], ["track": spTrack("b")]])),
            .init("/v1/me/albums", json: spPage()),
            .init("/v1/me/playlists", json: spPage([["id": "p", "name": "P"]])),
            .init("/v1/playlists/p/items", json: spPage([["item": spTrack("a", isrc: nil)], ["item": conflicting],
                ["item": spTrack("a", isrc: nil)], ["item": restricted]]))])
        let provider = try await spotify(t), result = try await provider.fetchLibrary()
        let tracks = result.playlists[0].tracks
        XCTAssertEqual(tracks.map(\.id), ["a", "a", "a", "b"])
        XCTAssertEqual(tracks.map(\.isrc), [nil, "OTHER", nil, nil]); XCTAssertFalse(tracks[3].available)
        await t.assertExhausted()
    }
}

private actor ProgressRecorder {
    var events: [LibraryReadProgress] = []
    func add(_ event: LibraryReadProgress) { events.append(event) }
}

private actor ReadProgressGate {
    private var entered = false
    private var pauseContinuation: CheckedContinuation<Void, Never>?
    private var enteredContinuation: CheckedContinuation<Void, Never>?
    func pause() async {
        entered = true; enteredContinuation?.resume(); enteredContinuation = nil
        await withCheckedContinuation { pauseContinuation = $0 }
    }
    func waitUntilEntered() async {
        if !entered { await withCheckedContinuation { enteredContinuation = $0 } }
    }
    func release() { pauseContinuation?.resume(); pauseContinuation = nil }
}
