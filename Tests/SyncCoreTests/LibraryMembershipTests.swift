import XCTest
@testable import SyncCore

final class LibraryMembershipTests: XCTestCase {
    private func track(_ id: String, catalogID: String? = nil) -> Track {
        Track(id: id, catalogID: catalogID, title: "Mismo título", artist: "Mismo artista", albumTitle: "Mismo álbum", isrc: "MISMO-ISRC")
    }

    private func snapshot(_ service: MusicService = .appleMusic, tracks: [Track] = [], albums: [Album] = [],
                          playlists: [Playlist] = [], coverage: InventoryCoverage = .init()) -> LibrarySnapshot {
        LibrarySnapshot(account: ConnectedAccount(id: service.rawValue, service: service, displayName: "Prueba"),
                        playlists: playlists, savedTracks: tracks, savedAlbums: albums, coverage: coverage)
    }

    func testLibraryAndCatalogIDsMatchInBothDirectionsAndThroughSharedCatalog() {
        let cases: [(Track, Track)] = [
            (track("library", catalogID: "catalog"), track("catalog")),
            (track("catalog"), track("library", catalogID: "catalog")),
            (track("library"), track("library", catalogID: "catalog")),
            (track("library-a", catalogID: "catalog"), track("library-b", catalogID: "catalog"))
        ]
        for (saved, listed) in cases {
            let result = snapshot(tracks: [saved], playlists: [Playlist(id: "p", name: "P", tracks: [listed])]).libraryMembership
            XCTAssertEqual(result.tracks.first?.membership, .inPlaylist, "\(saved.id) / \(listed.id)")
            XCTAssertEqual(result.outsideTrackCount, 0)
        }
    }

    func testAlbumTrackCanBridgeAliasesWithoutDiscardingRicherDuplicate() {
        let result = snapshot(tracks: [track("library"), track("catalog")],
                              albums: [Album(id: "album", title: "Disco", artist: "Artista", tracks: [track("library", catalogID: "catalog")])],
                              playlists: [Playlist(id: "p", name: "P", tracks: [track("catalog")])]).libraryMembership
        XCTAssertEqual(result.tracks.count, 1)
        XCTAssertEqual(result.tracks.first?.membership, .inPlaylist)
        XCTAssertEqual(result.albums.first?.membership, .inPlaylist)
    }

    func testNamesISRCAndAlbumIDsDoNotEstablishSongMembership() {
        let result = snapshot(tracks: [track("saved")],
                              albums: [Album(id: "saved", catalogID: "listed", title: "Mismo álbum", artist: "Mismo artista", tracks: [track("other")])],
                              playlists: [Playlist(id: "p", name: "P", tracks: [track("listed")])]).libraryMembership
        XCTAssertEqual(result.tracks.first?.membership, .outsidePlaylists)
        XCTAssertEqual(result.albums.first?.membership, .outsidePlaylists)
        XCTAssertEqual(result.outsideTrackCount, 1)
        XCTAssertEqual(result.outsideCompleteAlbumCount, 1)
    }

    func testIdentityEvidenceStaysWithinEachServiceSnapshot() {
        let spotify = snapshot(.spotify, tracks: [track("saved", catalogID: "listed")],
                               playlists: [Playlist(id: "p", name: "P", tracks: [track("listed")])])
        let apple = snapshot(.appleMusic, tracks: [track("saved")],
                             playlists: [Playlist(id: "p", name: "P", tracks: [track("listed")])])
        XCTAssertEqual(spotify.libraryMembership.tracks.first?.membership, .inPlaylist)
        XCTAssertEqual(apple.libraryMembership.tracks.first?.membership, .outsidePlaylists)
        XCTAssertEqual(spotify.libraryMembership.tracks.first?.membership, .inPlaylist)
    }

    func testIncompletePlaylistInventoryCannotProveAbsenceButPreservesPresence() {
        let saved = [track("present"), track("unseen")]
        let album = Album(id: "a", title: "Disco", artist: "Artista", tracks: [saved[1]])
        let result = snapshot(tracks: saved, albums: [album],
                              playlists: [Playlist(id: "p", name: "P", tracks: [saved[0]])],
                              coverage: InventoryCoverage(playlists: false)).libraryMembership
        XCTAssertFalse(result.playlistsComplete)
        XCTAssertEqual(result.tracks.map(\.membership), [.inPlaylist, .unknown])
        XCTAssertEqual(result.albums.first?.membership, .unknown)
        XCTAssertNil(result.outsideTrackCount)
        XCTAssertNil(result.outsideCompleteAlbumCount)
    }

    func testOneUnreadPlaylistPreventsAbsenceEvenWhenInventoryIsComplete() {
        let result = snapshot(tracks: [track("unseen")], playlists: [
            Playlist(id: "read", name: "Leída"), Playlist(id: "unread", name: "Pendiente", contentsComplete: false)
        ]).libraryMembership
        XCTAssertFalse(result.playlistsComplete)
        XCTAssertEqual(result.tracks.first?.membership, .unknown)
        XCTAssertNil(result.outsideTrackCount)
    }

    func testZeroPlaylistsMeansAbsenceOnlyAfterCompleteInventoryRead() {
        let complete = snapshot(tracks: [track("saved")]).libraryMembership
        let incomplete = snapshot(tracks: [track("saved")], coverage: InventoryCoverage(playlists: false)).libraryMembership
        XCTAssertEqual(complete.tracks.first?.membership, .outsidePlaylists)
        XCTAssertEqual(complete.outsideTrackCount, 1)
        XCTAssertEqual(incomplete.tracks.first?.membership, .unknown)
        XCTAssertNil(incomplete.outsideTrackCount)
    }

    func testEmptyAlbumIsUnknownRegardlessOfCompletenessFlag() {
        for isComplete in [true, false] {
            let result = snapshot(albums: [Album(id: "empty", title: "Vacío", artist: "Artista", isCompleteAlbum: isComplete)]).libraryMembership
            XCTAssertEqual(result.albums.first?.membership, .unknown)
            if isComplete { XCTAssertNil(result.outsideCompleteAlbumCount) }
        }
    }

    func testAnyPresentAlbumTrackRulesOutLooseAlbumEvenDuringPartialRead() {
        for isComplete in [true, false] {
            let album = Album(id: "a", title: "Disco", artist: "Artista", tracks: [track("absent"), track("library", catalogID: "catalog")], isCompleteAlbum: isComplete)
            for contentsComplete in [true, false] {
                let result = snapshot(albums: [album], playlists: [Playlist(id: "p", name: "P", tracks: [track("catalog")], contentsComplete: contentsComplete)]).libraryMembership
                XCTAssertEqual(result.albums.first?.membership, .inPlaylist)
            }
        }
    }

    func testPartialAlbumsClassifySavedTracksAndNeverCountAsCompleteLooseAlbums() {
        let partial = Album(id: "partial", title: "Disco parcial", artist: "Artista", tracks: [track("library", catalogID: "catalog"), track("other")], isCompleteAlbum: false)
        let full = Album(id: "full", title: "Disco completo", artist: "Artista", tracks: [track("album-only")])
        let result = snapshot(tracks: [track("catalog")], albums: [partial, full]).libraryMembership
        XCTAssertEqual(result.tracks.map { $0.track.id }, ["catalog", "other"])
        XCTAssertTrue(result.tracks.allSatisfy { $0.membership == .outsidePlaylists })
        XCTAssertEqual(result.outsideTrackCount, 2)
        XCTAssertEqual(result.outsideCompleteAlbumCount, 1)
        XCTAssertEqual(result.albums.map(\.classifiesSavedTracksOnly), [true, false])
        XCTAssertTrue(result.albums.allSatisfy { $0.membership == .outsidePlaylists })
    }

    func testIncompleteSavedInventoryKeepsKnownClassificationButHidesExactTotals() {
        let album = Album(id: "a", title: "Disco", artist: "Artista", tracks: [track("album-track")])
        for coverage in [InventoryCoverage(tracks: false), InventoryCoverage(albums: false)] {
            let result = snapshot(tracks: [track("saved")], albums: [album], coverage: coverage).libraryMembership
            XCTAssertTrue(result.playlistsComplete)
            XCTAssertEqual(result.tracks.first?.membership, .outsidePlaylists)
            XCTAssertEqual(result.albums.first?.membership, .outsidePlaylists)
            XCTAssertNil(result.outsideTrackCount)
            if !coverage.albums { XCTAssertNil(result.outsideCompleteAlbumCount) }
        }
    }

    func testMissingAndPlaceholderIdentifiersAreUnknownAndCannotMatchEachOther() {
        for id in ["", "  ", "unknown:missing"] {
            let result = snapshot(tracks: [track(id)], playlists: [Playlist(id: "p", name: "P", tracks: [track(id)])]).libraryMembership
            XCTAssertEqual(result.tracks.first?.membership, .unknown)
            XCTAssertFalse(result.playlistsComplete)
            XCTAssertNil(result.outsideTrackCount)
        }
        let catalogOnly = snapshot(tracks: [track("", catalogID: "catalog")],
                                   playlists: [Playlist(id: "p", name: "P", tracks: [track("catalog")])]).libraryMembership
        XCTAssertEqual(catalogOnly.tracks.first?.membership, .inPlaylist)
    }

    func testUnidentifiedPlaylistTrackPreventsFalseAbsenceForIdentifiedSavedTrack() {
        let result = snapshot(tracks: [track("saved")], playlists: [Playlist(id: "p", name: "P", tracks: [track("unknown:p:0")])]).libraryMembership
        XCTAssertEqual(result.tracks.first?.membership, .unknown)
        XCTAssertNil(result.outsideTrackCount)
    }

    func testUnidentifiedAlbumTrackPreventsFalseLooseAlbum() {
        let result = snapshot(albums: [Album(id: "a", title: "Disco", artist: "Artista", tracks: [track("known"), track("")])]).libraryMembership
        XCTAssertEqual(result.albums.first?.membership, .unknown)
        XCTAssertNil(result.outsideCompleteAlbumCount)
    }
}
