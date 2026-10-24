import XCTest
@testable import SyncCore

final class PlannerTests: XCTestCase {
    private let allCapabilities: [MusicService: ProviderCapabilities] = [.spotify: .spotify, .appleMusic: .spotify]

    private func song(_ id: String, _ key: String = "A") -> Track {
        Track(id: id, title: "Tema \(key)", artist: "Artista", albumTitle: "Disco", durationMS: 200_000,
              isrc: "TEST-\(key)", explicit: false)
    }

    private func library(_ service: MusicService, playlists: [Playlist] = [], tracks: [Track] = [], albums: [Album] = [],
                         coverage: InventoryCoverage = .init()) -> LibrarySnapshot {
        LibrarySnapshot(id: UUID(uuidString: service == .spotify ? "10000000-0000-0000-0000-000000000001" : "20000000-0000-0000-0000-000000000002")!,
                        account: ConnectedAccount(id: service.rawValue, service: service, displayName: "Prueba", connectionRevision: "1"),
                        fetchedAt: Date(timeIntervalSince1970: 1), playlists: playlists, savedTracks: tracks, savedAlbums: albums, coverage: coverage)
    }

    private func choices(_ pairs: [(Track, Track)], links: [PlaylistLink] = []) -> MatchDecisions {
        MatchDecisions(tracks: pairs.map { TrackMatch(sourceService: .spotify, source: $0.0, selected: $0.1, confidence: .exact) }, playlists: links)
    }

    private var link: PlaylistLink { PlaylistLink(spotifyID: "sp", appleMusicID: "am") }

    private func plan(_ spotify: LibrarySnapshot, _ apple: LibrarySnapshot, mode: SyncMode = .spotifyBase,
                      decisions: MatchDecisions = .init()) -> SyncPlan {
        SyncPlanner.makePlan(snapshots: [spotify, apple], mode: mode, decisions: decisions, capabilities: allCapabilities)
    }

    func testUnchangedLibrariesAreNoOpInEveryDirectionAndPlannerIsDeterministic() {
        let spA = song("sp-A"), amA = song("am-A")
        let spAlbum = Album(id: "sp-album", title: "Disco", artist: "Artista", tracks: [spA])
        let amAlbum = Album(id: "am-album", title: "Disco", artist: "Artista", tracks: [amA])
        let sp = library(.spotify, playlists: [Playlist(id: "sp", name: "Viaje", tracks: [spA, spA])], tracks: [spA], albums: [spAlbum])
        let am = library(.appleMusic, playlists: [Playlist(id: "am", name: "Viaje", tracks: [amA, amA])], tracks: [amA], albums: [amAlbum])
        for mode in SyncMode.allCases {
            let first = plan(sp, am, mode: mode)
            XCTAssertTrue(first.operations.isEmpty, "\(mode): \(first.operations)")
            XCTAssertTrue(first.issues.isEmpty)
            XCTAssertEqual(first, plan(sp, am, mode: mode))
        }
    }

    func testMirrorPreservesDuplicateOrderAndNeverMutatesBase() {
        let a = song("sp-A"), b = song("sp-B", "B"), aa = song("am-A"), ab = song("am-B", "B"), ac = song("am-C", "C")
        let sp = library(.spotify, playlists: [Playlist(id: "sp", name: "Viaje", tracks: [a, b, a])])
        let am = library(.appleMusic, playlists: [Playlist(id: "am", name: "Viaje", tracks: [ab, aa, ac])])
        let result = plan(sp, am, decisions: choices([(a, aa), (b, ab)], links: [link]))
        let replacement = result.operations.first { $0.kind == .replacePlaylistTracks }
        XCTAssertEqual(replacement?.tracks.map(\.id), ["am-A", "am-B", "am-A"])
        XCTAssertEqual(replacement?.beforeTrackIDs, ["am-B", "am-A", "am-C"])
        XCTAssertNil(replacement?.blockedReason)
        XCTAssertTrue(result.operations.allSatisfy { $0.service == .appleMusic })
        XCTAssertEqual(sp.playlists[0].tracks.map(\.id), ["sp-A", "sp-B", "sp-A"])
    }

    func testMergeUsesMaximumMultiplicityWithoutDeletionOrReorderingAndIsIdempotent() {
        let a = song("sp-A"), b = song("sp-B", "B"), c = song("sp-C", "C")
        let aa = song("am-A"), ab = song("am-B", "B"), ac = song("am-C", "C")
        var sp = library(.spotify, playlists: [Playlist(id: "sp", name: "Viaje", tracks: [a, b, a])])
        var am = library(.appleMusic, playlists: [Playlist(id: "am", name: "Viaje", tracks: [ab, ac])])
        let decisions = choices([(a, aa), (b, ab), (c, ac)], links: [link])
        let first = plan(sp, am, mode: .merge, decisions: decisions)
        XCTAssertFalse(first.operations.contains { $0.kind.isDestructive })
        XCTAssertEqual(first.operations.first { $0.service == .appleMusic }?.tracks.map(\.id), ["am-A", "am-A"])
        XCTAssertEqual(first.operations.first { $0.service == .spotify }?.tracks.map(\.id), ["sp-C"])
        sp.playlists[0].tracks = [a, b, a, c]
        am.playlists[0].tracks = [ab, ac, aa, aa]
        XCTAssertTrue(plan(sp, am, mode: .merge, decisions: decisions).operations.isEmpty)
    }

    func testCreateContainsEveryMappedOccurrenceAndDescription() {
        let a = song("sp-A"), b = song("sp-B", "B"), aa = song("am-A"), ab = song("am-B", "B")
        let sp = library(.spotify, playlists: [Playlist(id: "sp", name: "Nueva", description: "Para viajar", tracks: [a, b, a])])
        let result = plan(sp, library(.appleMusic), decisions: choices([(a, aa), (b, ab)]))
        let create = result.executable.first { $0.kind == .createPlaylist }
        XCTAssertEqual(create?.tracks.map(\.id), ["am-A", "am-B", "am-A"])
        XCTAssertEqual(create?.playlistDescription, "Para viajar")
        XCTAssertNil(create?.targetID)
    }

    func testLinkedMetadataChangesPreserveTargetID() {
        let a = song("sp-A"), aa = song("am-A")
        let sp = library(.spotify, playlists: [Playlist(id: "sp", name: "Nombre nuevo", description: "Nueva descripción", tracks: [a])])
        let am = library(.appleMusic, playlists: [Playlist(id: "am", name: "Nombre anterior", tracks: [aa])])
        let result = plan(sp, am, decisions: choices([(a, aa)], links: [link]))
        XCTAssertEqual(result.operations.map(\.kind), [.renamePlaylist])
        XCTAssertEqual(result.operations.first?.targetID, "am")
        XCTAssertEqual(result.operations.first?.playlistName, "Nombre nuevo")
        XCTAssertEqual(result.operations.first?.playlistDescription, "Nueva descripción")
    }

    func testMergeMetadataConflictUsesStableSpotifyAuthority() {
        let a = song("sp-A"), aa = song("am-A")
        let sp = library(.spotify, playlists: [Playlist(id: "sp", name: "Nombre Spotify", description: "Descripción", tracks: [a])])
        var am = library(.appleMusic, playlists: [Playlist(id: "am", name: "Nombre Apple", tracks: [aa])])
        let decisions = choices([(a, aa)], links: [link])
        let first = plan(sp, am, mode: .merge, decisions: decisions)
        XCTAssertEqual(first.operations.count, 1)
        XCTAssertEqual(first.operations[0].service, .appleMusic)
        am.playlists[0].name = sp.playlists[0].name
        am.playlists[0].description = sp.playlists[0].description
        XCTAssertTrue(plan(sp, am, mode: .merge, decisions: decisions).operations.isEmpty)
    }

    func testSameNameDifferentContentRequiresManualLinkInAllModes() {
        let sp = library(.spotify, playlists: [Playlist(id: "sp", name: "Viaje", tracks: [song("sp-A")])])
        let am = library(.appleMusic, playlists: [Playlist(id: "am", name: "Viaje", tracks: [song("am-B", "B")])])
        for mode in SyncMode.allCases {
            let result = plan(sp, am, mode: mode)
            XCTAssertTrue(result.operations.isEmpty)
            XCTAssertTrue(result.issues.contains { $0.title.contains("vínculo") || $0.title.contains("identidad") })
        }
    }

    func testDifferentNamesEquivalentContentRequireManualLink() {
        let sp = library(.spotify, playlists: [Playlist(id: "sp", name: "Viejo", tracks: [song("sp-A")])])
        let am = library(.appleMusic, playlists: [Playlist(id: "am", name: "Nuevo", tracks: [song("am-A")])])
        for mode in SyncMode.allCases {
            let result = plan(sp, am, mode: mode)
            XCTAssertTrue(result.operations.isEmpty)
            XCTAssertTrue(result.issues.contains { $0.title == "Posible playlist renombrada" })
        }
    }

    func testMultiplePotentialRenamedPairsAreAllProtected() {
        let a = song("sp-A"), aa = song("am-A")
        let sp = library(.spotify, playlists: [Playlist(id: "sp", name: "Uno", tracks: [a]), Playlist(id: "sp2", name: "Dos", tracks: [a])])
        let am = library(.appleMusic, playlists: [Playlist(id: "am", name: "Tres", tracks: [aa])])
        for mode in SyncMode.allCases {
            XCTAssertTrue(plan(sp, am, mode: mode).operations.isEmpty)
        }
    }

    func testRenamedAndReorderedPotentialPairCannotBeDeletedAndRecreated() {
        let a = song("sp-A"), b = song("sp-B", "B"), aa = song("am-A"), ab = song("am-B", "B")
        let sp = library(.spotify, playlists: [Playlist(id: "sp", name: "Nombre anterior", tracks: [a, b, a])])
        let am = library(.appleMusic, playlists: [Playlist(id: "am", name: "Nombre actual", tracks: [ab, aa, aa])])
        for mode in SyncMode.allCases {
            let result = plan(sp, am, mode: mode)
            XCTAssertTrue(result.operations.isEmpty)
            XCTAssertTrue(result.issues.contains { $0.title == "Posible playlist renombrada" })
        }
    }

    func testAppleBaseUsesInverseConfirmedMappingsAndLeavesAppleUnchanged() {
        let a = song("sp-A"), b = song("sp-B", "B"), aa = song("am-A"), ab = song("am-B", "B")
        let sp = library(.spotify, playlists: [Playlist(id: "sp", name: "Anterior", tracks: [b, a])], tracks: [a])
        let am = library(.appleMusic, playlists: [Playlist(id: "am", name: "Nuevo", description: "Desde Apple", tracks: [aa, ab, aa])], tracks: [ab])
        let result = plan(sp, am, mode: .appleMusicBase, decisions: choices([(a, aa), (b, ab)], links: [link]))
        XCTAssertTrue(result.operations.allSatisfy { $0.service == .spotify })
        XCTAssertEqual(result.executable.first { $0.kind == .replacePlaylistTracks }?.tracks.map(\.id), ["sp-A", "sp-B", "sp-A"])
        XCTAssertEqual(result.executable.first { $0.kind == .saveTracks }?.tracks.map(\.id), ["sp-B"])
        XCTAssertEqual(result.executable.first { $0.kind == .removeTracks }?.tracks.map(\.id), ["sp-A"])
        XCTAssertEqual(result.executable.first { $0.kind == .renamePlaylist }?.playlistDescription, "Desde Apple")
    }

    func testMergeSavedLibrariesOnlyAddsInBothDirections() {
        let a = song("sp-A"), b = song("sp-B", "B"), aa = song("am-A"), ab = song("am-B", "B")
        let spAlbum = Album(id: "sp-album", title: "Disco", artist: "Artista", tracks: [a])
        let amAlbum = Album(id: "am-album", title: "Disco", artist: "Artista", tracks: [aa])
        let sp = library(.spotify, tracks: [a], albums: [spAlbum])
        let am = library(.appleMusic, tracks: [ab])
        var decisions = choices([(a, aa), (b, ab)])
        decisions.albums = [AlbumMatch(sourceService: .spotify, source: spAlbum, selected: amAlbum, confidence: .exact)]
        let result = plan(sp, am, mode: .merge, decisions: decisions)
        XCTAssertFalse(result.operations.contains { $0.kind.isDestructive })
        XCTAssertEqual(result.executable.first { $0.service == .spotify }?.tracks.map(\.id), ["sp-B"])
        XCTAssertEqual(result.executable.first { $0.service == .appleMusic && $0.kind == .saveTracks }?.tracks.map(\.id), ["am-A"])
        XCTAssertEqual(result.executable.first { $0.kind == .saveAlbums }?.albums.map(\.id), ["am-album"])
    }

    func testManyToOneManualTrackMappingsCannotBeInvertedDestructively() {
        let a = song("sp-A"), second = song("sp-second"), aa = song("am-A")
        let sp = library(.spotify, tracks: [a, second]), am = library(.appleMusic, tracks: [aa])
        let result = plan(sp, am, mode: .appleMusicBase, decisions: choices([(a, aa), (second, aa)]))
        XCTAssertTrue(result.executable.isEmpty)
        XCTAssertNotNil(result.operations.first { $0.kind == .removeTracks }?.blockedReason)
    }

    func testIncompleteSourceContentsCannotClearDestinationPlaylist() {
        let sp = library(.spotify, playlists: [Playlist(id: "sp", name: "Viaje", tracks: [], contentsComplete: false)])
        let am = library(.appleMusic, playlists: [Playlist(id: "am", name: "Viaje", tracks: [song("am-A")])])
        let result = plan(sp, am, decisions: MatchDecisions(playlists: [link]))
        XCTAssertNotNil(result.operations.first { $0.kind == .replacePlaylistTracks }?.blockedReason)
        XCTAssertTrue(result.executable.isEmpty)
    }

    func testTwoEmptySameNamePlaylistsAreNotAutomaticallyLinkedByTitle() {
        let sp = library(.spotify, playlists: [Playlist(id: "sp", name: "Vacía")])
        let am = library(.appleMusic, playlists: [Playlist(id: "am", name: "Vacía")])
        let result = plan(sp, am)
        XCTAssertTrue(result.operations.isEmpty)
        XCTAssertFalse(result.issues.isEmpty)
    }

    func testDuplicateNamesDoNotCreateCounterpartsWhenAppleIsBase() {
        let sp = library(.spotify, playlists: [Playlist(id: "sp", name: "Viaje"), Playlist(id: "sp2", name: "Viaje")])
        let am = library(.appleMusic, playlists: [Playlist(id: "am", name: "Viaje", tracks: [song("am-A")])])
        let result = plan(sp, am, mode: .appleMusicBase)
        XCTAssertTrue(result.operations.isEmpty)
        XCTAssertFalse(result.issues.isEmpty)
    }

    func testConflictingAndStaleExplicitLinksReserveTheirEndpoints() {
        let sp = library(.spotify, playlists: [Playlist(id: "sp", name: "Uno", tracks: [song("sp-A")])])
        let am = library(.appleMusic, playlists: [Playlist(id: "am", name: "Dos")])
        let decisions = MatchDecisions(playlists: [link, PlaylistLink(spotifyID: "sp", appleMusicID: "missing")])
        let result = plan(sp, am, decisions: decisions)
        XCTAssertTrue(result.operations.isEmpty)
        XCTAssertTrue(result.issues.contains { $0.title == "Vínculo manual pendiente" })
    }

    func testExplicitLinksOverrideDuplicateNames() {
        let a = song("sp-A"), aa = song("am-A"), b = song("sp-B", "B"), ab = song("am-B", "B")
        let sp = library(.spotify, playlists: [Playlist(id: "sp", name: "Viaje", tracks: [a]), Playlist(id: "sp2", name: "Viaje", tracks: [b])])
        let am = library(.appleMusic, playlists: [Playlist(id: "am", name: "Viaje", tracks: [aa]), Playlist(id: "am2", name: "Viaje", tracks: [ab])])
        let decisions = choices([(a, aa), (b, ab)], links: [link, PlaylistLink(spotifyID: "sp2", appleMusicID: "am2")])
        XCTAssertTrue(plan(sp, am, decisions: decisions).operations.isEmpty)
    }

    func testUnknownTrackProtectsSavedTracksAndBlocksReplacementButAllowsKnownAdditions() {
        let a = song("sp-A"), unknown = song("sp-unknown", "X"), aa = song("am-A"), other = song("am-B", "B")
        let sp = library(.spotify, playlists: [Playlist(id: "sp", name: "Viaje", tracks: [a, unknown])], tracks: [unknown])
        let am = library(.appleMusic, playlists: [Playlist(id: "am", name: "Viaje", tracks: [other])], tracks: [other])
        let result = plan(sp, am, decisions: choices([(a, aa)], links: [link]))
        XCTAssertNotNil(result.operations.first { $0.kind == .replacePlaylistTracks }?.blockedReason)
        XCTAssertNotNil(result.operations.first { $0.kind == .removeTracks }?.blockedReason)
        XCTAssertEqual(result.executable.first { $0.kind == .addPlaylistTracks }?.tracks.map(\.id), ["am-A"])
        XCTAssertFalse(result.executable.contains { $0.kind.isDestructive })
    }

    func testUnresolvedSuppliedDecisionIsNotSilentlyOverriddenByLocalInference() {
        let a = song("sp-A"), aa = song("am-A")
        let sp = library(.spotify, tracks: [a]), am = library(.appleMusic, tracks: [aa])
        let unresolved = MatchDecisions(tracks: [TrackMatch(sourceService: .spotify, source: a, candidates: [aa], reason: "Revisión pendiente")])
        let result = plan(sp, am, decisions: unresolved)
        XCTAssertNotNil(result.operations.first { $0.kind == .removeTracks }?.blockedReason)
        XCTAssertTrue(result.executable.isEmpty)
    }

    func testManualSelectedReviewCandidateIsAuthoritativeInBothDirections() {
        let a = song("sp-A"), ab = song("am-B", "B")
        let decisions = MatchDecisions(tracks: [TrackMatch(sourceService: .spotify, source: a, candidates: [ab], selected: ab, confidence: .review)])
        XCTAssertTrue(plan(library(.spotify, tracks: [a]), library(.appleMusic, tracks: [ab]), mode: .merge, decisions: decisions).operations.isEmpty)
    }

    func testMappingsCompareSavedCatalogIDsInsteadOfSourceIDs() {
        let a = song("sp-A")
        var aa = song("apple-library-A"); aa.catalogID = "apple-catalog-A"
        var selected = aa; selected.id = "apple-search-A"
        let sp = library(.spotify, tracks: [a]), am = library(.appleMusic, tracks: [aa])
        XCTAssertTrue(plan(sp, am, decisions: choices([(a, selected)])).operations.isEmpty)
    }

    func testSelectedAlbumMappingPreventsSpuriousRemoval() {
        let spAlbum = Album(id: "sp-album", title: "Disco", artist: "Artista")
        let amAlbum = Album(id: "am-library", catalogID: "am-catalog", title: "Disco", artist: "Artista")
        var selected = amAlbum; selected.id = "am-search"
        let decisions = MatchDecisions(albums: [AlbumMatch(sourceService: .spotify, source: spAlbum, selected: selected, confidence: .review)])
        XCTAssertTrue(plan(library(.spotify, albums: [spAlbum]), library(.appleMusic, albums: [amAlbum]), decisions: decisions).operations.isEmpty)
    }

    func testUnknownAlbumBlocksDestinationAlbumRemoval() {
        let spAlbum = Album(id: "sp-album", title: "Disco", artist: "Artista")
        let amAlbum = Album(id: "am-album", title: "Otra edición", artist: "Artista")
        let result = plan(library(.spotify, albums: [spAlbum]), library(.appleMusic, albums: [amAlbum]))
        XCTAssertNotNil(result.operations.first { $0.kind == .removeAlbums }?.blockedReason)
        XCTAssertFalse(result.executable.contains { $0.kind == .removeAlbums })
    }

    func testPartialAlbumNeverExpandsEvenWithManualFullAlbumSelection() {
        let a = song("sp-A"), aa = song("am-A"), ab = song("am-B", "B")
        let partial = Album(id: "sp-album", title: "Disco", artist: "Artista", tracks: [a], isCompleteAlbum: false)
        let full = Album(id: "am-album", title: "Disco", artist: "Artista", tracks: [aa, ab])
        var decisions = choices([(a, aa)])
        decisions.albums = [AlbumMatch(sourceService: .spotify, source: partial, selected: full, confidence: .exact)]
        let result = plan(library(.spotify, albums: [partial]), library(.appleMusic, albums: [full]), decisions: decisions)
        XCTAssertFalse(result.operations.contains { $0.kind == .saveAlbums })
        XCTAssertEqual(result.executable.first { $0.kind == .saveTracks }?.tracks.map(\.id), ["am-A"])
        XCTAssertNotNil(result.operations.first { $0.kind == .removeAlbums }?.blockedReason)
        XCTAssertFalse(result.operations.flatMap(\.tracks).contains { $0.id == ab.id })
    }

    func testIncompleteSavedCollectionsBlockRemovalsButPermitSafeSaves() {
        let a = song("sp-A"), aa = song("am-A"), ab = song("am-B", "B")
        let sp = library(.spotify, tracks: [a], coverage: InventoryCoverage(tracks: false, albums: false))
        let am = library(.appleMusic, tracks: [ab], albums: [Album(id: "old", title: "Anterior", artist: "Artista")])
        let result = plan(sp, am, decisions: choices([(a, aa)]))
        XCTAssertEqual(result.executable.map(\.kind), [.saveTracks])
        XCTAssertTrue(result.operations.filter { $0.kind.isDestructive }.allSatisfy { $0.blockedReason != nil })
    }

    func testIncompleteSourcePlaylistCollectionBlocksDependentReplacement() {
        let a = song("sp-A"), b = song("sp-B", "B"), aa = song("am-A"), ab = song("am-B", "B")
        let sp = library(.spotify, playlists: [Playlist(id: "sp", name: "Viaje", tracks: [a, b])], coverage: InventoryCoverage(playlists: false))
        let am = library(.appleMusic, playlists: [Playlist(id: "am", name: "Viaje", tracks: [ab])])
        let result = plan(sp, am, decisions: choices([(a, aa), (b, ab)], links: [link]))
        XCTAssertNotNil(result.operations.first { $0.kind == .replacePlaylistTracks }?.blockedReason)
        XCTAssertFalse(result.executable.contains { $0.kind.isDestructive })
    }

    func testInaccessibleDestinationDoesNotGuessDuplicateCounts() {
        let a = song("sp-A"), aa = song("am-A")
        let sp = library(.spotify, playlists: [Playlist(id: "sp", name: "Viaje", tracks: [a, a])])
        let am = library(.appleMusic, playlists: [Playlist(id: "am", name: "Viaje", tracks: [], contentsComplete: false)])
        for mode in SyncMode.allCases {
            let result = plan(sp, am, mode: mode, decisions: choices([(a, aa)], links: [link]))
            XCTAssertFalse(result.executable.contains { $0.service == .appleMusic })
            XCTAssertFalse(result.issues.isEmpty)
        }
    }

    func testIncompleteDestinationInventoryBlocksCreationAndPlaylistRemoval() {
        let a = song("sp-A"), aa = song("am-A")
        let sp = library(.spotify, playlists: [Playlist(id: "sp", name: "Nueva", tracks: [a])])
        let am = library(.appleMusic, playlists: [Playlist(id: "old", name: "Anterior")], coverage: InventoryCoverage(playlists: false))
        let result = plan(sp, am, decisions: choices([(a, aa)]))
        XCTAssertNotNil(result.operations.first { $0.kind == .createPlaylist }?.blockedReason)
        XCTAssertNotNil(result.operations.first { $0.kind == .removePlaylist }?.blockedReason)
        XCTAssertTrue(result.executable.isEmpty)
    }

    func testProtectedAndFollowedLinkedPlaylistsCannotBeMutated() {
        let a = song("sp-A"), aa = song("am-A")
        let sp = library(.spotify, playlists: [Playlist(id: "sp", name: "Nuevo", tracks: [a])])
        for ownership in [PlaylistOwnership.owned, .followed, .system] {
            let am = library(.appleMusic, playlists: [Playlist(id: "am", name: "Viejo", editable: true, ownership: ownership)])
            var decisions = choices([(a, aa)], links: [link])
            if ownership == .owned { decisions.protectedPlaylistIDs = [.appleMusic: ["am"]] }
            let result = plan(sp, am, decisions: decisions)
            XCTAssertFalse(result.operations.isEmpty)
            XCTAssertTrue(result.executable.isEmpty)
        }
    }

    func testOnlyExclusivelyOwnedEditableUnprotectedExtrasCanBeRemoved() {
        let am = library(.appleMusic, playlists: [
            Playlist(id: "owned", name: "Propia"),
            Playlist(id: "collab", name: "Compartida", ownership: .collaborative),
            Playlist(id: "followed", name: "Seguida", ownership: .followed),
            Playlist(id: "locked", name: "Bloqueada", editable: false),
            Playlist(id: "protected", name: "Protegida")
        ])
        let result = plan(library(.spotify), am, decisions: MatchDecisions(protectedPlaylistIDs: [.appleMusic: ["protected"]]))
        XCTAssertEqual(result.executable.map(\.targetID), ["owned"])
        XCTAssertEqual(result.executable.map(\.kind), [.removePlaylist])
        XCTAssertEqual(Set(result.operations.filter { $0.kind == .removePlaylist }.compactMap(\.targetID)), Set(am.playlists.map(\.id)))
        XCTAssertEqual(result.operations.filter { $0.blockedReason != nil }.count, 4)
    }

    func testUnknownAppleOwnershipRemainsVisibleAsPendingMirrorDifference() {
        let source = library(.spotify)
        let destination = library(.appleMusic, playlists: [Playlist(id: "unknown", name: "Extra", editable: true, ownership: .unknown)])
        let result = SyncPlanner.makePlan(snapshots: [source, destination], mode: .spotifyBase,
                                          decisions: MatchDecisions(), capabilities: [.spotify: .spotify, .appleMusic: .appleMusic])
        XCTAssertTrue(result.executable.isEmpty)
        XCTAssertEqual(result.operations.count, 1)
        XCTAssertEqual(result.operations.first?.kind, .removePlaylist)
        XCTAssertNotNil(result.operations.first?.blockedReason)
    }

    func testUnknownPlaylistMappingPreventsRemovingOtherDestinationPlaylists() {
        let sp = library(.spotify, playlists: [Playlist(id: "sp", name: "Desconocida", tracks: [song("sp-X", "X")])])
        let am = library(.appleMusic, playlists: [Playlist(id: "am", name: "Posible contraparte", tracks: [song("am-A")])])
        let result = plan(sp, am)
        XCTAssertNotNil(result.operations.first { $0.kind == .removePlaylist }?.blockedReason)
        XCTAssertFalse(result.executable.contains { $0.kind == .removePlaylist })
    }

    func testAppleUnsupportedOperationsRemainVisibleAndBlocked() {
        let a = song("sp-A"), b = song("sp-B", "B"), aa = song("am-A"), ab = song("am-B", "B")
        let sp = library(.spotify, playlists: [Playlist(id: "sp", name: "Nuevo", tracks: [a, b])])
        let am = library(.appleMusic, playlists: [Playlist(id: "am", name: "Viejo", tracks: [ab, aa])], tracks: [aa])
        let result = SyncPlanner.makePlan(snapshots: [sp, am], mode: .spotifyBase,
                                          decisions: choices([(a, aa), (b, ab)], links: [link]),
                                          capabilities: [.spotify: .spotify, .appleMusic: .appleMusic])
        for kind in [OperationKind.renamePlaylist, .replacePlaylistTracks, .removeTracks] {
            XCTAssertNotNil(result.operations.first { $0.kind == kind })
            XCTAssertNotNil(result.operations.first { $0.kind == kind }?.blockedReason)
        }
        XCTAssertTrue(result.executable.isEmpty)
    }

    func testPrefixOnlyMirrorUsesSafeAppendSupportedByApple() {
        let a = song("sp-A"), b = song("sp-B", "B"), aa = song("am-A"), ab = song("am-B", "B")
        let sp = library(.spotify, playlists: [Playlist(id: "sp", name: "Viaje", tracks: [a, b, a])])
        let am = library(.appleMusic, playlists: [Playlist(id: "am", name: "Viaje", tracks: [aa])])
        let result = SyncPlanner.makePlan(snapshots: [sp, am], mode: .spotifyBase,
                                          decisions: choices([(a, aa), (b, ab)], links: [link]),
                                          capabilities: [.spotify: .spotify, .appleMusic: .appleMusic])
        XCTAssertEqual(result.operations.map(\.kind), [.addPlaylistTracks])
        XCTAssertEqual(result.executable.first?.tracks.map(\.id), ["am-B", "am-A"])
    }

    func testMissingCapabilitiesBlockOperations() {
        let a = song("sp-A"), aa = song("am-A")
        let result = SyncPlanner.makePlan(snapshots: [library(.spotify, tracks: [a]), library(.appleMusic)], mode: .spotifyBase,
                                          decisions: choices([(a, aa)]), capabilities: [:])
        XCTAssertEqual(result.operations.count, 1)
        XCTAssertNotNil(result.operations[0].blockedReason)
    }

    func testMissingOrAmbiguousAccountsProduceIssuesWithoutOperations() {
        let sp = library(.spotify, tracks: [song("sp-A")]), am = library(.appleMusic)
        for snapshots in [[sp], [sp, sp, am], []] {
            let result = SyncPlanner.makePlan(snapshots: snapshots, mode: .merge, decisions: .init(), capabilities: allCapabilities)
            XCTAssertTrue(result.operations.isEmpty)
            XCTAssertFalse(result.issues.isEmpty)
        }
    }

    func testContradictorySourceMetadataCannotReplaceDestination() {
        let a = song("sp-A"), aa = song("am-A"), conflicting = song("sp-A", "B")
        let sp = library(.spotify, playlists: [Playlist(id: "sp", name: "Viaje", tracks: [a])], tracks: [conflicting])
        let am = library(.appleMusic, playlists: [Playlist(id: "am", name: "Viaje")])
        let result = plan(sp, am, decisions: choices([(a, aa)], links: [link]))
        XCTAssertNotNil(result.operations.first { $0.kind == .replacePlaylistTracks }?.blockedReason)
        XCTAssertTrue(result.executable.isEmpty)
    }

    func testLocalCatalogCanInferConfidentCandidatesWithoutSuppliedDecision() {
        let a = song("sp-A"), aa = song("am-A")
        let sp = library(.spotify, playlists: [Playlist(id: "sp", name: "Nueva", tracks: [a, a])])
        let am = library(.appleMusic, tracks: [aa])
        let result = plan(sp, am, mode: .merge)
        XCTAssertEqual(result.executable.first { $0.kind == .createPlaylist }?.tracks.map(\.id), ["am-A", "am-A"])
    }

    func testDemoContainsDuplicatesLooseTracksMissingMatchesAndUnsupportedOperations() {
        let snapshots = DemoFixtures.snapshots()
        XCTAssertEqual(snapshots, DemoFixtures.snapshots())
        XCTAssertTrue(snapshots.allSatisfy { !$0.looseTracks.isEmpty })
        let result = SyncPlanner.makePlan(snapshots: snapshots, mode: .spotifyBase, decisions: DemoFixtures.decisions(),
                                          capabilities: [.spotify: .spotify, .appleMusic: .appleMusic])
        let create = result.executable.first { $0.playlistName == "Café de mañana" }
        XCTAssertEqual(create?.tracks.count, 3)
        XCTAssertEqual(create?.tracks.first, create?.tracks.last)
        XCTAssertTrue(result.operations.contains { $0.kind == .replacePlaylistTracks && $0.blockedReason != nil })
        XCTAssertTrue(result.issues.contains { $0.title == "Canción sin coincidencia confirmada" })
        XCTAssertTrue(result.executable.contains { $0.kind == .saveAlbums })
    }
}
