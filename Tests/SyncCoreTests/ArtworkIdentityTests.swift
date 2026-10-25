import XCTest
@testable import SyncCore

final class ArtworkIdentityTests: XCTestCase {
    private var song: Track {
        Track(id: "track", title: "Song", artist: "Artist", albumTitle: "Album", durationMS: 120000, isrc: "TEST", explicit: false)
    }

    func testArtworkRotationPreservesTrackAndAlbumEqualityHashAndEncoding() throws {
        var first = song, second = song
        first.artworkURL = "https://images.example/old"; second.artworkURL = "https://images.example/new"
        XCTAssertEqual(first, second); XCTAssertEqual(Set([first, second]).count, 1)
        var album = Album(id: "album", title: "Album", artist: "Artist", tracks: [first])
        album.artworkURL = "https://images.example/album-old"
        var rotated = album; rotated.artworkURL = "https://images.example/album-new"; rotated.tracks = [second]
        XCTAssertEqual(album, rotated); XCTAssertEqual(Set([album, rotated]).count, 1)
        XCTAssertEqual(try JSONDecoder().decode(Track.self, from: JSONEncoder().encode(second)).artworkURL, second.artworkURL)
        XCTAssertEqual(try JSONDecoder().decode(Album.self, from: JSONEncoder().encode(rotated)).artworkURL, rotated.artworkURL)
    }

    func testEveryNonArtworkTrackFieldRemainsPartOfEquality() {
        let changes: [(inout Track) -> Void] = [
            { $0.id += "other" }, { $0.catalogID = "other" }, { $0.title += " live" }, { $0.artist += " guest" },
            { $0.albumTitle += " deluxe" }, { $0.durationMS += 5000 }, { $0.isrc = "OTHER" }, { $0.explicit = true },
            { $0.available = false }, { $0.isLocal = true }, { $0.url = "https://music.example/song" },
            { $0.artistNames = ["Other"] }, { $0.albumID = "other" }, { $0.releaseDate = "2026" },
            { $0.discNumber = 2 }, { $0.trackNumber = 2 }
        ]
        for (index, change) in changes.enumerated() {
            var changed = song; change(&changed)
            XCTAssertNotEqual(song, changed, "Non-artwork field \(index) was ignored")
            XCTAssertEqual(Set([song, changed]).count, 2)
        }
    }

    func testNestedArtworkDoesNotChangeFingerprintButOrderAndRepetitionsDo() {
        let account = ConnectedAccount(id: "account", service: .spotify, displayName: "Test")
        let other = Track(id: "other", title: "Other", artist: "Artist")
        let snapshot = LibrarySnapshot(account: account,
            playlists: [Playlist(id: "playlist", name: "Playlist", tracks: [song, other, song])],
            savedTracks: [song], savedAlbums: [Album(id: "album", title: "Album", artist: "Artist", tracks: [song, song])])
        var rotated = snapshot
        rotated.playlists[0].artworkURL = "https://images.example/playlist"
        for index in rotated.playlists[0].tracks.indices { rotated.playlists[0].tracks[index].artworkURL = "https://images.example/track-\(index)" }
        rotated.savedTracks[0].artworkURL = "https://images.example/saved"
        rotated.savedAlbums[0].artworkURL = "https://images.example/album"
        for index in rotated.savedAlbums[0].tracks.indices { rotated.savedAlbums[0].tracks[index].artworkURL = "https://images.example/album-track-\(index)" }
        XCTAssertEqual(snapshot.stateFingerprint, rotated.stateFingerprint)
        rotated.playlists[0].tracks.swapAt(0, 1)
        XCTAssertNotEqual(snapshot.stateFingerprint, rotated.stateFingerprint)
        rotated = snapshot; rotated.playlists[0].tracks.removeLast()
        XCTAssertNotEqual(snapshot.stateFingerprint, rotated.stateFingerprint)
        rotated = snapshot; rotated.savedAlbums[0].tracks[0].durationMS += 10000
        XCTAssertNotEqual(snapshot.stateFingerprint, rotated.stateFingerprint)
    }

    func testCatalogAndManualXMLChoicesSurviveArtworkRefreshButStillRejectChangedMusic() {
        var source = song, candidate = song
        candidate.id = "candidate"
        var previous = TrackMatch(sourceService: .spotify, source: source, candidates: [candidate], selected: candidate)
        previous.decision = .manual; previous.manualSelection = true
        source.artworkURL = "https://images.example/source"; candidate.artworkURL = "https://images.example/candidate"
        let result = CatalogSearch.match(source: source, sourceService: .spotify, result: .init(candidates: [candidate]), previous: previous)
        XCTAssertEqual(result.decision, .manual); XCTAssertEqual(result.selected?.artworkURL, candidate.artworkURL)
        let choice = ManualTrackChoice(source: song, selected: song, decision: .manual)
        let library = ManualMusicLibrary(id: "library", fileName: "Library.xml", tracks: [source])
        XCTAssertNotNil(choice.revalidated(source: source, library: library).selected)
        var changed = source; changed.albumTitle = "Other Edition"
        XCTAssertNil(choice.revalidated(source: changed, library: library).selected)
        XCTAssertEqual(CatalogMatcher.unique([song, source]).count, 1)
        var album = Album(id: "a", title: "Album", artist: "Artist", tracks: [song])
        let before = album; album.artworkURL = "https://images.example/a"; album.tracks = [source]
        XCTAssertEqual(CatalogMatcher.uniqueAlbums([before, album]).count, 1)
    }

    func testPlanAndOperationMusicalProjectionsExcludeCoversButRetainPersistedArtwork() throws {
        let snapshot = LibrarySnapshot(account: ConnectedAccount(id: "account", service: .spotify, displayName: "Test"),
                                       playlists: [Playlist(id: "p", name: "Playlist", tracks: [song])])
        let operation = SyncOperation(service: .appleMusic, kind: .saveTracks, title: "Save", tracks: [song])
        let plan = SyncPlan(mode: .merge, snapshots: [snapshot], operations: [operation])
        var refreshed = plan
        refreshed.snapshots[0].playlists[0].artworkURL = "https://images.example/playlist"
        refreshed.snapshots[0].playlists[0].tracks[0].artworkURL = "https://images.example/song"
        refreshed.operations[0].tracks[0].artworkURL = "https://images.example/candidate"
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(plan, refreshed)
        XCTAssertEqual(try encoder.encode(plan.withoutArtwork), try encoder.encode(refreshed.withoutArtwork))
        XCTAssertEqual(try encoder.encode(operation.withoutArtwork), try encoder.encode(refreshed.operations[0].withoutArtwork))
        XCTAssertNotEqual(try encoder.encode(plan), try encoder.encode(refreshed))
        refreshed.operations[0].tracks[0].albumTitle = "Another edition"
        XCTAssertNotEqual(try encoder.encode(plan.withoutArtwork), try encoder.encode(refreshed.withoutArtwork))
    }
}
