import XCTest
@testable import SyncCore

final class LibraryComparisonTests: XCTestCase {
    func testLargeInventoryKeepsCatalogIdentitySeparateFromSavedMembership() {
        let source = (0..<1_500).map { Track(id: "apple-\($0)", title: "Song \($0)", artist: "Artist", albumTitle: "Album", durationMS: 180_000, explicit: false) }
        let target = source.enumerated().map { index, original -> Track in var track = original; track.id = "spotify-\(index)"; return track }
        let info = Dictionary(uniqueKeysWithValues: source.enumerated().map { ($0.element.id, XMLTrackInfo(referenceID: $0.offset + 1, playlistOnly: false)) })
        let library = ManualMusicLibrary(id: "large-xml", fileName: "Large.xml", tracks: source, inventory: .init(playlists: [], trackInfo: info), documentDigest: "large")
        let spotify = LibrarySnapshot(account: .init(id: "large-spotify", service: .spotify, displayName: "Synthetic"), playlists: [.init(id: "observed", name: "Observed", tracks: target)])
        let result = LibraryComparison.compare(library: library, spotify: spotify,
            configuration: .init(scope: .init(songs: true, albums: false, playlists: false)))
        XCTAssertEqual(result.metrics.matchedSongIdentities, 1_500)
        XCTAssertEqual(result.metrics.spotify.savedSongMemberships, 0)
        XCTAssertEqual(result.metrics.spotify.playlistOccurrences, 1_500)
        XCTAssertEqual(result.spotifyAdditions.count, 1_500)
        XCTAssertEqual(Set(result.differences.map(\.id)).count, result.differences.count)
    }
    private let songs = LibraryComparisonScope(songs: true, albums: false, playlists: false)
    private let playlists = LibraryComparisonScope(songs: false, albums: false, playlists: true)
    private let albums = LibraryComparisonScope(songs: false, albums: true, playlists: false)

    private func track(_ id: String, title: String = "Song A", local: Bool = false) -> Track {
        Track(id: id, title: title, artist: "Artist", albumTitle: "Album", durationMS: 200_000, explicit: false, isLocal: local)
    }
    private func xml(_ tracks: [Track] = [], lists: [XMLMusicPlaylist] = [], complete: Bool = true,
                     playlistsComplete: Bool = true, info: [String: XMLTrackInfo] = [:]) -> ManualMusicLibrary {
        let knownInfo = Dictionary(tracks.enumerated().map { index, track in (track.id, info[track.id] ?? XMLTrackInfo(referenceID: index + 1, playlistOnly: false)) }, uniquingKeysWith: { first, _ in first })
        return .init(id: "xml-library", fileName: "Music.xml", importedAt: Date(timeIntervalSince1970: 0), tracks: tracks,
              complete: complete, inventory: .init(playlists: lists, trackInfo: knownInfo, playlistsComplete: playlistsComplete))
    }
    private func snapshot(_ tracks: [Track] = [], lists: [Playlist] = [], savedAlbums: [Album] = [],
                          coverage: InventoryCoverage = .init(), service: MusicService = .spotify) -> LibrarySnapshot {
        .init(account: .init(id: service.rawValue + "-account", service: service, displayName: "Account", connectionRevision: "r1"),
              fetchedAt: Date(timeIntervalSince1970: 0), playlists: lists, savedTracks: tracks, savedAlbums: savedAlbums, coverage: coverage)
    }
    private func choice(_ source: Track, _ selected: Track, service: MusicService = .appleMusic) -> TrackMatch {
        var result = TrackMatch(sourceService: service, source: source, candidates: [selected], selected: selected, confidence: .review)
        result.decision = .manual; result.manualSelection = true
        return result
    }
    private func config(_ scope: LibraryComparisonScope, mode: SyncMode = .appleMusicBase, paired: Bool = false) -> LibraryComparisonConfiguration {
        .init(mode: mode, scope: scope, playlistPairings: paired ? [.init(spotifyID: "sp-list", appleMusicID: "am-list")] : [])
    }

    func testCatalogEquivalentInPlaylistDoesNotProveSavedMembership() {
        let am = track("am"), sp = track("sp")
        let report = LibraryComparison.compare(library: xml([am]), spotify: snapshot(lists: [.init(id: "p", name: "P", tracks: [sp, sp])]), configuration: config(songs))
        XCTAssertEqual(report.spotifyAdditions.map(\.kind), [.saveTracks])
        XCTAssertEqual(report.spotifyAdditions.first?.tracks.map(\.id), ["sp"])
        XCTAssertEqual(report.metrics.spotify.songIdentities, 1)
        XCTAssertEqual(report.metrics.spotify.savedSongMemberships, 0)
        XCTAssertEqual(report.metrics.spotify.playlistOccurrences, 2)
    }

    func testLocalXMLTrackCanMatchEquivalentInSpotify() {
        let report = LibraryComparison.compare(library: xml([track("am", local: true)]), spotify: snapshot([track("sp")]), configuration: config(songs))
        XCTAssertNotNil(report.matches.first { $0.sourceService == .appleMusic }?.selected)
        XCTAssertTrue(report.differences.isEmpty)
    }

    func testManualCatalogSelectionStillNeedsSaveWhenNotObserved() {
        let am = track("am", local: true), sp = track("sp")
        let report = LibraryComparison.compare(library: xml([am]), spotify: snapshot(), decisions: .init(tracks: [choice(am, sp)]), configuration: config(songs))
        XCTAssertEqual(report.spotifyAdditions.first?.tracks, [sp])
        XCTAssertEqual(report.metrics.spotify.savedSongMemberships, 0)
    }

    func testMissingEmptyPlaylistCreatesEmptyPlaylistRatherThanBeingEqual() {
        let report = LibraryComparison.compare(library: xml(lists: [.init(id: "am-list", name: "Empty")]), spotify: snapshot(), configuration: config(playlists))
        XCTAssertEqual(report.spotifyAdditions.map(\.kind), [.createPlaylist])
        XCTAssertEqual(report.spotifyAdditions.first?.tracks, [])
        XCTAssertEqual(report.spotifyAdditions.first?.playlistName, "Empty")
        XCTAssertNil(report.differences.first?.spotifyTrackIDs)
        XCTAssertEqual(report.differences.first?.appleMusicTrackIDs, [])
    }

    func testUniqueNamesOnlySuggestPairWithoutExistingDestinationWrites() {
        let am = track("am"), sp = track("sp")
        let library = xml([am], lists: [.init(id: "am-list", name: "My List", trackIDs: [am.id])])
        let spotify = snapshot([sp], lists: [.init(id: "sp-list", name: "my list")])
        let suggested = LibraryComparison.compare(library: library, spotify: spotify, configuration: config(playlists))
        XCTAssertEqual(suggested.playlistPairings.map(\.status), [.suggested])
        XCTAssertTrue(suggested.spotifyAdditions.isEmpty)
        let confirmed = LibraryComparison.compare(library: library, spotify: spotify, configuration: config(playlists, paired: true))
        XCTAssertEqual(confirmed.spotifyAdditions.map(\.kind), [.addPlaylistTracks])
    }

    func testRememberedDecisionLinkRequiresConfirmationInConfiguration() {
        let am = track("am"), sp = track("sp")
        let report = LibraryComparison.compare(library: xml([am], lists: [.init(id: "am-list", name: "Apple", trackIDs: [am.id])]),
                                               spotify: snapshot([sp], lists: [.init(id: "sp-list", name: "Spotify")]),
                                               decisions: .init(playlists: [.init(spotifyID: "sp-list", appleMusicID: "am-list")]), configuration: config(playlists))
        XCTAssertEqual(report.playlistPairings.map(\.status), [.suggested])
        XCTAssertTrue(report.spotifyAdditions.isEmpty)
    }

    func testDuplicatePlaylistNamesRequireManualPairing() {
        let report = LibraryComparison.compare(library: xml(lists: [.init(id: "a", name: "Same"), .init(id: "b", name: "Same")]),
                                               spotify: snapshot(lists: [.init(id: "s", name: "Same")]), configuration: config(playlists))
        XCTAssertTrue(report.playlistPairings.allSatisfy { $0.status == .ambiguous })
        XCTAssertTrue(report.spotifyAdditions.isEmpty)
        XCTAssertFalse(report.reviews.isEmpty)
    }

    func testRepeatedTrailingOccurrenceIsAddedWithoutDeduplication() {
        let a = track("am-a"), b = track("am-b", title: "Song B"), sa = track("sp-a"), sb = track("sp-b", title: "Song B")
        let report = LibraryComparison.compare(library: xml([a, b], lists: [.init(id: "am-list", name: "List", trackIDs: [a.id, b.id, a.id])]),
                                               spotify: snapshot([sa, sb], lists: [.init(id: "sp-list", name: "List", tracks: [sa, sb])]), configuration: config(playlists, paired: true))
        XCTAssertEqual(report.spotifyAdditions.map(\.kind), [.addPlaylistTracks])
        XCTAssertEqual(report.spotifyAdditions.first?.tracks, [sa])
        XCTAssertEqual(report.spotifyAdditions.first?.beforeTrackIDs, [sa.id, sb.id])
        XCTAssertEqual(report.metrics.appleMusic.songIdentities, 2)
        XCTAssertEqual(report.metrics.appleMusic.playlistOccurrences, 3)
    }

    func testNewPlaylistPreservesAllOccurrencesAndOrder() {
        let a = track("am-a"), b = track("am-b", title: "Song B"), sa = track("sp-a"), sb = track("sp-b", title: "Song B")
        let report = LibraryComparison.compare(library: xml([a, b], lists: [.init(id: "am-list", name: "List", trackIDs: [a.id, b.id, a.id])]),
                                               spotify: snapshot([sa, sb]), configuration: config(playlists))
        XCTAssertEqual(report.spotifyAdditions.first?.tracks, [sa, sb, sa])
    }

    func testMiddleInsertionDoesNotAppendAndCorruptOrder() {
        let a = track("am-a"), b = track("am-b", title: "Song B"), sa = track("sp-a"), sb = track("sp-b", title: "Song B")
        let report = LibraryComparison.compare(library: xml([a, b], lists: [.init(id: "am-list", name: "List", trackIDs: [a.id, b.id, a.id])]),
                                               spotify: snapshot([sa, sb], lists: [.init(id: "sp-list", name: "List", tracks: [sa, sa])]), configuration: config(playlists, paired: true))
        XCTAssertTrue(report.spotifyAdditions.isEmpty)
        XCTAssertEqual(report.reviews.count, 1)
    }

    func testFirstSyncNeverInfersSavedSongOrPlaylistRemovals() {
        let report = LibraryComparison.compare(library: xml(), spotify: snapshot([track("sp")], lists: [.init(id: "p", name: "Extra")]), configuration: .init())
        XCTAssertTrue(report.removals.isEmpty)
        XCTAssertTrue(report.spotifyAdditions.isEmpty)
        XCTAssertFalse(report.reviews.isEmpty)
    }

    func testIgnoringPlaylistDoesNotTurnItsTracksIntoLooseSongs() {
        let am = track("am"), sp = track("sp")
        var scope = playlists; scope.appleMusicPlaylistIDs = []; scope.spotifyPlaylistIDs = []
        let report = LibraryComparison.compare(library: xml([am], lists: [.init(id: "am-list", name: "List", trackIDs: [am.id])]),
                                               spotify: snapshot([sp], lists: [.init(id: "sp-list", name: "List", tracks: [sp])]), configuration: config(scope))
        XCTAssertTrue(report.differences.isEmpty)
        XCTAssertEqual(report.metrics.appleMusic.looseSongIdentities, 0)
        XCTAssertEqual(report.metrics.spotify.looseSongIdentities, 0)
    }

    func testXMLAlbumGroupNeverExpandsToSavingCompleteAlbum() {
        let am = track("am"), album = Album(id: "album", title: "Album", artist: "Artist", tracks: [track("sp")])
        let report = LibraryComparison.compare(library: xml([am]), spotify: snapshot(savedAlbums: [album]), configuration: config(albums))
        XCTAssertTrue(report.spotifyAdditions.isEmpty)
        XCTAssertTrue(report.differences.allSatisfy { $0.category == .review })
        XCTAssertTrue(report.differences.flatMap(\.albums).contains { !$0.isCompleteAlbum })
        XCTAssertEqual(report.metrics.appleMusic.completeSavedAlbums, 0)
        XCTAssertEqual(report.metrics.appleMusic.albumGroups, 1)
    }

    func testPlaylistOnlyObservationIsNotSavedSongMembership() {
        let am = track("am"), sp = track("sp")
        let report = LibraryComparison.compare(library: xml([am], info: [am.id: .init(referenceID: 1, playlistOnly: true)]),
                                               spotify: snapshot([sp]), configuration: config(songs))
        XCTAssertEqual(report.metrics.appleMusic.songIdentities, 1)
        XCTAssertEqual(report.metrics.appleMusic.savedSongMemberships, 0)
        XCTAssertTrue(report.spotifyAdditions.isEmpty)
    }

    func testPartialSavedInventoryDoesNotEstablishAbsence() {
        let am = track("am"), sp = track("sp")
        let report = LibraryComparison.compare(library: xml([am]), spotify: snapshot(coverage: .init(tracks: false)),
                                               decisions: .init(tracks: [choice(am, sp)]), configuration: config(songs))
        XCTAssertTrue(report.spotifyAdditions.isEmpty)
        XCTAssertEqual(report.reviews.count, 1)
        XCTAssertNil(report.metrics.spotify.looseSongIdentities)
    }

    func testPartialXMLDoesNotEstablishMissingAppleSong() {
        let report = LibraryComparison.compare(library: xml(complete: false), spotify: snapshot([track("sp")]), configuration: config(songs, mode: .spotifyBase))
        XCTAssertTrue(report.appleMusicTasks.isEmpty)
        XCTAssertEqual(report.reviews.count, 1)
    }

    func testPartialPlaylistCoverageDoesNotCreateApparentlyMissingPlaylist() {
        let report = LibraryComparison.compare(library: xml(lists: [.init(id: "am-list", name: "Empty")]),
                                               spotify: snapshot(coverage: .init(playlists: false)), configuration: config(playlists))
        XCTAssertTrue(report.spotifyAdditions.isEmpty)
        XCTAssertEqual(report.reviews.count, 1)
    }

    func testIncompletePlaylistDoesNotDropUnknownOccurrences() {
        let am = track("am"), sp = track("sp")
        let report = LibraryComparison.compare(library: xml([am], lists: [.init(id: "am-list", name: "List", trackIDs: [am.id, "missing"], contentsComplete: false)]),
                                               spotify: snapshot([sp], lists: [.init(id: "sp-list", name: "List")]), configuration: config(playlists, paired: true))
        XCTAssertTrue(report.spotifyAdditions.isEmpty)
        XCTAssertEqual(report.reviews.count, 1)
    }

    func testPendingAndOmittedMatchesNeverBecomeAdditions() {
        let am = track("am"), sp = track("sp")
        for state in [TrackDecision.pending, .omitted] {
            var match = choice(am, sp); match.decision = state
            let report = LibraryComparison.compare(library: xml([am]), spotify: snapshot([sp]), decisions: .init(tracks: [match]), configuration: config(songs, mode: .merge))
            XCTAssertTrue(report.spotifyAdditions.isEmpty)
            XCTAssertTrue(report.appleMusicTasks.isEmpty)
            XCTAssertTrue(report.matches.filter { $0.sourceService == .appleMusic }.allSatisfy { $0.selected == nil })
        }
    }

    func testStaleAndContradictoryDecisionsDoNotFallBackToAutomaticMatch() {
        let am = track("am"), sp = track("sp")
        var stale = choice(am, sp); stale.source.durationMS += 10_000
        for choices in [[stale], [choice(am, sp), choice(am, track("other"))]] {
            let report = LibraryComparison.compare(library: xml([am]), spotify: snapshot([sp]), decisions: .init(tracks: choices), configuration: config(songs))
            XCTAssertTrue(report.spotifyAdditions.isEmpty)
            XCTAssertNil(report.matches.first { $0.sourceService == .appleMusic }?.selected)
        }
    }

    func testBaselineAppleAdditionProducesFiniteSpotifyProposal() {
        let am = track("am"), sp = track("sp")
        let report = LibraryComparison.compare(library: xml([am]), spotify: snapshot(), decisions: .init(tracks: [choice(am, sp)]), configuration: config(songs, mode: .merge),
                                               baseline: .init(library: xml(), spotify: snapshot()))
        XCTAssertEqual(report.spotifyAdditions.map(\.kind), [.saveTracks])
        XCTAssertEqual(report.operationsByDifferenceID.count, 1)
        XCTAssertEqual(report.operationsByDifferenceID.values.first?.count, 1)
    }

    func testBaselineAppleDeletionIsSeparateAndNeverResurrectedAsAddition() {
        let am = track("am"), sp = track("sp")
        let report = LibraryComparison.compare(library: xml(), spotify: snapshot([sp]), configuration: config(songs, mode: .merge),
                                               baseline: .init(library: xml([am]), spotify: snapshot([sp])))
        XCTAssertEqual(report.removals.count, 1)
        XCTAssertEqual(report.removals.first?.destination, .spotify)
        XCTAssertTrue(report.spotifyAdditions.isEmpty)
        XCTAssertTrue(report.appleMusicTasks.isEmpty)
        XCTAssertTrue(report.removals.allSatisfy { $0.spotifyOperations.isEmpty && $0.appleMusicTasks.isEmpty })
    }

    func testBaselineOppositeSavedMembershipChangesAreConflict() {
        let am = track("am"), sp = track("sp")
        let report = LibraryComparison.compare(library: xml(), spotify: snapshot([sp]), decisions: .init(tracks: [choice(am, sp)]), configuration: config(songs, mode: .merge),
                                               baseline: .init(library: xml([am]), spotify: snapshot()))
        XCTAssertEqual(report.conflicts.count, 1)
        XCTAssertTrue(report.spotifyAdditions.isEmpty)
        XCTAssertTrue(report.appleMusicTasks.isEmpty)
    }

    func testBaselineUnchangedDivergenceIsNotRepeatedWrite() {
        let am = track("am"), sp = track("sp"), library = xml([track("am")]), spotify = snapshot()
        let report = LibraryComparison.compare(library: library, spotify: spotify, decisions: .init(tracks: [choice(am, sp)]), configuration: config(songs, mode: .merge),
                                               baseline: .init(library: library, spotify: spotify))
        XCTAssertTrue(report.spotifyAdditions.isEmpty)
        XCTAssertEqual(report.reviews.count, 1)
    }

    func testBaselineSimultaneousPlaylistEditsRequireChoice() {
        let a = track("am-a"), b = track("am-b", title: "Song B"), sa = track("sp-a"), sb = track("sp-b", title: "Song B")
        let oldLibrary = xml([a, b], lists: [.init(id: "am-list", name: "List", trackIDs: [a.id])])
        let oldSpotify = snapshot([sa, sb], lists: [.init(id: "sp-list", name: "List", tracks: [sa])])
        let report = LibraryComparison.compare(library: xml([a, b], lists: [.init(id: "am-list", name: "List", trackIDs: [a.id, b.id])]),
                                               spotify: snapshot([sa, sb], lists: [.init(id: "sp-list", name: "List", tracks: [sa, sa])]), configuration: config(playlists, mode: .merge, paired: true),
                                               baseline: .init(library: oldLibrary, spotify: oldSpotify))
        XCTAssertEqual(report.conflicts.count, 1)
        XCTAssertTrue(report.spotifyAdditions.isEmpty)
    }

    func testBaselinePlaylistDeletionAgainstEditIsConflict() {
        let a = track("am"), sa = track("sp")
        let report = LibraryComparison.compare(library: xml([a]), spotify: snapshot([sa], lists: [.init(id: "sp-list", name: "Renamed", tracks: [sa])]), configuration: config(playlists, mode: .merge, paired: true),
                                               baseline: .init(library: xml([a], lists: [.init(id: "am-list", name: "List", trackIDs: [a.id])]),
                                                               spotify: snapshot([sa], lists: [.init(id: "sp-list", name: "List", tracks: [sa])])))
        XCTAssertEqual(report.conflicts.count, 1)
        XCTAssertTrue(report.spotifyAdditions.isEmpty)
    }

    func testBaselineRemovingRepeatedOccurrenceProducesRemovalWithoutOperations() {
        let a = track("am"), sa = track("sp")
        let oldLibrary = xml([a], lists: [.init(id: "am-list", name: "List", trackIDs: [a.id, a.id])])
        let spotify = snapshot([sa], lists: [.init(id: "sp-list", name: "List", tracks: [sa, sa])])
        let report = LibraryComparison.compare(library: xml([a], lists: [.init(id: "am-list", name: "List", trackIDs: [a.id])]), spotify: spotify, configuration: config(playlists, mode: .merge, paired: true),
                                               baseline: .init(library: oldLibrary, spotify: spotify))
        XCTAssertEqual(report.removals.count, 1)
        XCTAssertTrue(report.spotifyAdditions.isEmpty)
    }

    func testBaselineOtherAccountIsRejected() {
        var old = snapshot(); old.account.id = "different"
        let report = LibraryComparison.compare(library: xml([track("am")]), spotify: snapshot(), configuration: config(songs), baseline: .init(library: xml(), spotify: old))
        XCTAssertEqual(report.conflicts.count, 1)
        XCTAssertTrue(report.spotifyAdditions.isEmpty)
    }

    func testDifferenceAndOperationIDsSurviveDatesFilenamesAndArtworkChanges() {
        var am = track("am"), sp = track("sp")
        var library = xml([am]), spotify = snapshot()
        let initial = LibraryComparison.compare(library: library, spotify: spotify, decisions: .init(tracks: [choice(am, sp)]), configuration: config(songs))
        am.artworkURL = "https://example.test/new"; library.tracks = [am]; library.fileName = "renamed.xml"; library.importedAt = Date()
        spotify.id = UUID(); spotify.fetchedAt = Date()
        let refreshed = LibraryComparison.compare(library: library, spotify: spotify, decisions: .init(tracks: [choice(am, sp)]), configuration: config(songs))
        XCTAssertEqual(initial.differences.map(\.id), refreshed.differences.map(\.id))
        XCTAssertEqual(initial.spotifyAdditions.map(\.id), refreshed.spotifyAdditions.map(\.id))
    }

    func testDuplicatePersistentIDsDoNotCollapseXMLSongIdentities() {
        let a = track("am-a"), b = track("am-b", title: "Song B")
        let report = LibraryComparison.compare(library: xml([a, b], complete: false,
                                                          info: [a.id: .init(persistentID: "DUPLICATE", referenceID: 1, playlistOnly: false), b.id: .init(persistentID: "DUPLICATE", referenceID: 2, playlistOnly: false)]),
                                               spotify: snapshot(), configuration: config(songs))
        XCTAssertEqual(report.metrics.appleMusic.songIdentities, 2)
        XCTAssertEqual(report.metrics.appleMusic.savedSongMemberships, 2)
    }

    func testOfficialAppleCatalogMatchIsNotSavedMembershipAndUsesAppleIDs() {
        let sp = track("sp"), appleCatalog = track("apple-catalog")
        let report = LibraryComparison.compare(library: xml(), spotify: snapshot([sp]), decisions: .init(tracks: [choice(sp, appleCatalog, service: .spotify)]),
                                               configuration: config(songs, mode: .spotifyBase), appleSnapshot: snapshot(service: .appleMusic))
        XCTAssertEqual(report.appleMusicTasks.count, 1)
        XCTAssertEqual(report.appleMusicTasks.first?.operation?.kind, .saveTracks)
        XCTAssertEqual(report.appleMusicTasks.first?.operation?.tracks, [appleCatalog])
        XCTAssertEqual(report.metrics.appleMusic.savedSongMemberships, 0)
    }

    func testXMLAppleTasksNeverContainExecutableOfficialOperation() {
        let report = LibraryComparison.compare(library: xml(), spotify: snapshot([track("sp")]), configuration: config(songs, mode: .spotifyBase))
        XCTAssertEqual(report.appleMusicTasks.count, 1)
        XCTAssertNil(report.appleMusicTasks.first?.operation)
    }

    func testOfficialPlaylistCreationIncludesNameAndResolvedAppleTracks() {
        let sp = track("sp"), appleCatalog = track("apple-catalog")
        let report = LibraryComparison.compare(library: xml(), spotify: snapshot([sp], lists: [.init(id: "sp-list", name: "New Apple", tracks: [sp, sp])]),
                                               decisions: .init(tracks: [choice(sp, appleCatalog, service: .spotify)]), configuration: config(playlists, mode: .spotifyBase),
                                               appleSnapshot: snapshot(service: .appleMusic))
        let operation = report.appleMusicTasks.first?.operation
        XCTAssertEqual(operation?.kind, .createPlaylist)
        XCTAssertEqual(operation?.playlistName, "New Apple")
        XCTAssertEqual(operation?.tracks, [appleCatalog, appleCatalog])
    }

    func testConflictingConfirmedPlaylistLinksProduceNoWrites() {
        let configuration = LibraryComparisonConfiguration(scope: playlists, playlistPairings: [.init(spotifyID: "sp-list", appleMusicID: "a"), .init(spotifyID: "sp-list", appleMusicID: "b")])
        let report = LibraryComparison.compare(library: xml(lists: [.init(id: "a", name: "A"), .init(id: "b", name: "B")]),
                                               spotify: snapshot(lists: [.init(id: "sp-list", name: "List")]), configuration: configuration)
        XCTAssertEqual(report.conflicts.count, 2)
        XCTAssertTrue(report.spotifyAdditions.isEmpty)
    }

    func testOfficialAlbumAdditionUsesSuppliedCompleteEdition() {
        let apple = Album(id: "apple-album", title: "Album", artist: "Artist", upc: "UPC"), sp = Album(id: "sp-album", title: "Album", artist: "Artist", upc: "UPC")
        var match = AlbumMatch(sourceService: .appleMusic, source: apple, candidates: [sp], selected: sp, confidence: .exact)
        match.searchCoverage = .complete
        let report = LibraryComparison.compare(library: xml(), spotify: snapshot(), decisions: .init(albums: [match]), configuration: config(albums),
                                               appleSnapshot: snapshot(savedAlbums: [apple], service: .appleMusic))
        XCTAssertEqual(report.spotifyAdditions.map(\.kind), [.saveAlbums])
        XCTAssertEqual(report.spotifyAdditions.first?.albums, [sp])
    }

    func testSavedAliasesAreOneIdentityAndOneMembership() {
        var saved = track("row"); saved.catalogID = "catalog"
        let playlistTrack = track("catalog")
        let report = LibraryComparison.compare(library: xml(), spotify: snapshot([saved], lists: [.init(id: "p", name: "P", tracks: [playlistTrack, playlistTrack])]), configuration: config(songs))
        XCTAssertEqual(report.metrics.spotify.songIdentities, 1)
        XCTAssertEqual(report.metrics.spotify.savedSongMemberships, 1)
        XCTAssertEqual(report.metrics.spotify.playlistOccurrences, 2)
        XCTAssertEqual(report.metrics.spotify.looseSongIdentities, 0)
    }

    func testUnknownXMLSavedMembershipRequiresExplicitOptIn() {
        let am = track("am"), sp = track("sp")
        let library = xml([am], info: [am.id: .init(referenceID: 1)])
        let decisions = MatchDecisions(tracks: [choice(am, sp)])
        let defaultReport = LibraryComparison.compare(library: library, spotify: snapshot(), decisions: decisions, configuration: config(songs))
        XCTAssertTrue(defaultReport.spotifyAdditions.isEmpty)
        XCTAssertEqual(defaultReport.reviews.count, 1)
        XCTAssertFalse(defaultReport.metrics.appleMusic.savedSongsKnown)
        XCTAssertEqual(defaultReport.metrics.appleMusic.savedSongMemberships, 0)
        XCTAssertEqual(defaultReport.metrics.appleMusic.uncertainSongMemberships, 1)
        var optIn = config(songs); optIn.includeUncertainXMLSongs = true
        let included = LibraryComparison.compare(library: library, spotify: snapshot(), decisions: decisions, configuration: optIn)
        XCTAssertEqual(included.spotifyAdditions.map(\.kind), [.saveTracks])
        XCTAssertEqual(included.metrics.appleMusic.savedSongMemberships, 0)
        XCTAssertEqual(included.metrics.appleMusic.selectedUncertainSongs, 1)
        XCTAssertFalse(included.metrics.appleMusic.savedSongsKnown)
        XCTAssertNil(included.metrics.appleMusic.looseSongIdentities)
    }

    func testXMLUncertainOptInStillExcludesPlaylistOnlySongs() {
        let am = track("am"), sp = track("sp")
        var configuration = config(songs); configuration.includeUncertainXMLSongs = true
        let report = LibraryComparison.compare(library: xml([am], info: [am.id: .init(referenceID: 1, playlistOnly: true)]),
                                               spotify: snapshot(), decisions: .init(tracks: [choice(am, sp)]), configuration: configuration)
        XCTAssertTrue(report.spotifyAdditions.isEmpty)
        XCTAssertEqual(report.metrics.appleMusic.selectedUncertainSongs, 0)
    }

    func testUnknownXMLMembershipDoesNotProveMissingAppleSavedSong() {
        let am = track("am"), sp = track("sp")
        let report = LibraryComparison.compare(library: xml([am], info: [am.id: .init(referenceID: 1)]), spotify: snapshot([sp]), configuration: config(songs, mode: .spotifyBase))
        XCTAssertTrue(report.appleMusicTasks.isEmpty)
        XCTAssertFalse(report.reviews.isEmpty)
    }

    func testSpotifyDeletionIsDetectedUsingHistoricalCatalogIdentity() {
        let am = track("am"), sp = track("sp")
        let library = xml([am])
        let report = LibraryComparison.compare(library: library, spotify: snapshot(), configuration: config(songs, mode: .merge), baseline: .init(library: library, spotify: snapshot([sp])))
        XCTAssertEqual(report.removals.count, 1)
        XCTAssertEqual(report.removals.first?.destination, .appleMusic)
        XCTAssertTrue(report.spotifyAdditions.isEmpty)
        XCTAssertTrue(report.appleMusicTasks.isEmpty)
    }

    func testOfficialAppleAliasesAreOneIdentityAndMembership() {
        var saved = track("apple-row"); saved.catalogID = "apple-catalog"
        let report = LibraryComparison.compare(library: xml(), spotify: snapshot(), configuration: config(playlists),
                                               appleSnapshot: snapshot([saved], lists: [.init(id: "apple-p", name: "P", tracks: [track("apple-catalog"), track("apple-catalog")])], service: .appleMusic))
        XCTAssertEqual(report.metrics.appleMusic.songIdentities, 1)
        XCTAssertEqual(report.metrics.appleMusic.savedSongMemberships, 1)
        XCTAssertEqual(report.metrics.appleMusic.playlistOccurrences, 2)
        XCTAssertEqual(report.metrics.appleMusic.looseSongIdentities, 0)
    }

    func testUnavailableAndLocalSpotifySourcesStayReview() {
        var unavailable = track("unavailable"); unavailable.available = false
        for source in [unavailable, track("local", local: true)] {
            let report = LibraryComparison.compare(library: xml(), spotify: snapshot([source]), configuration: config(songs, mode: .spotifyBase))
            XCTAssertTrue(report.appleMusicTasks.isEmpty)
            XCTAssertEqual(report.reviews.count, 1)
        }
    }
}
