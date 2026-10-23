import XCTest
@testable import SyncCore

final class ManualChecklistTests: XCTestCase {
    private func track(_ id: String, title: String = "Canción", explicit: Bool? = false) -> Track {
        Track(id: id, title: title, artist: "Artista", albumTitle: "Álbum", durationMS: 200_000, explicit: explicit)
    }

    private func source(_ tracks: [Track], account: String = "spotify-account") -> LibrarySnapshot {
        LibrarySnapshot(account: ConnectedAccount(id: account, service: .spotify, displayName: "Cuenta sintética"),
                        savedTracks: tracks)
    }

    private func library(_ tracks: [Track] = [], id: String = "xml-library", complete: Bool = true) -> ManualMusicLibrary {
        ManualMusicLibrary(id: id, fileName: "Synthetic.xml", tracks: tracks, complete: complete)
    }

    private func report(_ tracks: [Track], candidates: [Track] = [], complete: Bool = true) -> ManualChecklist {
        ManualChecklistPlanner.make(source: source(tracks), library: library(candidates, complete: complete))
    }

    func testOneRowPerSpotifySongIncludesPlaylistsSavedAlbumsAndLooseTracks() {
        let shared = track("shared"), loose = track("loose", title: "Suelta"), albumTrack = track("album", title: "Disco"), listed = track("listed", title: "Lista")
        var snapshot = source([shared, loose, shared])
        snapshot.playlists = [Playlist(id: "p1", name: "Uno", tracks: [shared, shared, listed]),
                              Playlist(id: "p2", name: "Dos", tracks: [shared])]
        snapshot.savedAlbums = [Album(id: "a", title: "Guardado", artist: "Artista", tracks: [shared, albumTrack], isCompleteAlbum: false)]
        let result = ManualChecklistPlanner.make(source: snapshot, library: library())
        XCTAssertEqual(Set(result.items.map { $0.track.id }), Set(snapshot.allTracks.map(\.id)))
        XCTAssertEqual(result.items.count, 4)
        XCTAssertEqual(result.items.first { $0.track.id == "shared" }?.locations,
                       ["Canciones guardadas", "Playlist: Dos", "Playlist: Uno", "Álbum guardado: Guardado — Artista"].sorted())
        XCTAssertEqual(result.items.first { $0.track.id == "loose" }?.locations, ["Canciones guardadas"])
        XCTAssertEqual(result.items.first { $0.track.id == "album" }?.locations, ["Álbum guardado: Guardado — Artista"])
    }

    func testMatchingMetadataIsPresentIncludingImportedLocalFiles() {
        for local in [false, true] {
            var candidate = track("xml-track"); candidate.isLocal = local; candidate.durationMS += 900
            let item = report([track("spotify-track")], candidates: [candidate]).items.first
            XCTAssertEqual(item?.evidence, .present)
            XCTAssertEqual(item?.candidates, [candidate])
            XCTAssertEqual(item?.track.id, "spotify-track")
        }
    }

    func testMissingMeansAbsentFromCompleteXMLAndPartialXMLRequiresReview() {
        XCTAssertEqual(report([track("source")]).items.first?.evidence, .missing)
        let partial = report([track("source")], complete: false)
        XCTAssertEqual(partial.items.first?.evidence, .review)
        XCTAssertTrue(partial.warnings.contains { $0.contains("cobertura parcial") })
        XCTAssertEqual(report([track("source")], candidates: [track("target")], complete: false).items.first?.evidence, .present)
    }

    func testUnknownExplicitAlwaysRequiresReviewEvenWhenBothSidesUnknown() {
        for pair: (Bool?, Bool?) in [(nil, nil), (nil, false), (false, nil), (true, nil)] {
            XCTAssertEqual(report([track("source", explicit: pair.0)], candidates: [track("target", explicit: pair.1)]).items.first?.evidence, .review)
        }
        XCTAssertEqual(report([track("source", explicit: nil)]).items.first?.evidence, .review)
        XCTAssertEqual(report([track("source", explicit: true)], candidates: [track("target", explicit: false)]).items.first?.evidence, .review)
    }

    func testMultipleCandidatesRemainReviewEvenIfOnlyOneEditionMatches() {
        let first = track("one")
        var second = track("two"); second.albumTitle = "Álbum Deluxe"
        let result = report([track("source")], candidates: [first, second]).items.first
        XCTAssertEqual(result?.evidence, .review)
        XCTAssertEqual(result?.candidates.count, 2)
        XCTAssertEqual(report([track("source")], candidates: [first, first]).items.first?.evidence, .present)
        second.id = first.id
        XCTAssertEqual(report([track("source")], candidates: [first, second]).items.first?.evidence, .review)
    }

    func testWrongVersionsDurationsAndContradictoryISRCNeverBecomePresent() {
        var original = track("source"); original.isrc = "TEST-123"
        for suffix in [" (Live)", " (Remastered 2024)", " (Deluxe)", " (Acoustic)", " (Radio Edit)"] {
            var candidate = track("target"); candidate.isrc = "TEST123"; candidate.title += suffix
            XCTAssertEqual(report([original], candidates: [candidate]).items.first?.evidence, .review)
            candidate.title = original.title; candidate.albumTitle += suffix
            XCTAssertEqual(report([original], candidates: [candidate]).items.first?.evidence, .review)
        }
        var candidate = track("target"); candidate.isrc = "CONTRADICTORY"
        XCTAssertEqual(report([original], candidates: [candidate]).items.first?.evidence, .review)
        for duration in [0, 240_000] {
            candidate = track("target"); candidate.durationMS = duration
            XCTAssertEqual(report([original], candidates: [candidate]).items.first?.evidence, .review)
        }
    }

    func testUnknownAlbumDoesNotProvePresenceAndAlbumMetadataNeverCreatesAlbumWork() {
        var candidate = track("target"); candidate.albumTitle = ""
        XCTAssertEqual(report([track("source")], candidates: [candidate]).items.first?.evidence, .review)
        var snapshot = source([])
        snapshot.savedAlbums = [Album(id: "full", title: "Álbum", artist: "Artista", tracks: [track("one"), track("two", title: "Otra canción")])]
        let result = ManualChecklistPlanner.make(source: snapshot, library: library([track("target")]))
        XCTAssertEqual(result.items.count, 2)
        XCTAssertEqual(result.items.filter { $0.evidence == .present }.count, 1)
        XCTAssertTrue(result.warnings.contains { $0.contains("álbum completo") })
    }

    func testLocalUnavailableAndUnknownSpotifyIDsRequireReview() {
        var local = track("local"); local.isLocal = true
        var unavailable = track("unavailable"); unavailable.available = false
        for item in [local, unavailable, track(""), track("unknown:playlist:1")] {
            XCTAssertEqual(report([item]).items.first?.evidence, .review)
            XCTAssertEqual(report([item], candidates: [track("target")]).items.first?.evidence, .review)
        }
    }

    func testOnlySpotifyIsAcceptedAndIncompleteSourceWarnsAboutUnseenRows() {
        var snapshot = source([track("song")]); snapshot.account.service = .appleMusic
        let invalid = ManualChecklistPlanner.make(source: snapshot, library: library())
        XCTAssertTrue(invalid.items.isEmpty)
        XCTAssertTrue(invalid.warnings.contains { $0.contains("origen Spotify") })
        snapshot.account.service = .spotify
        snapshot.playlists = [Playlist(id: "partial", name: "Partial", tracks: [], contentsComplete: false)]
        let partial = ManualChecklistPlanner.make(source: snapshot, library: library())
        XCTAssertEqual(partial.items.count, 1)
        XCTAssertTrue(partial.warnings.contains { $0.contains("lectura de Spotify es parcial") })
    }

    func testRowIdentityChangesForEditionMetadataAndPreservesProgressAcrossRefresh() throws {
        let original = track("same-id")
        let first = try XCTUnwrap(report([original]).items.first)
        XCTAssertEqual(first.id, report([original]).items.first?.id)
        var variants: [Track] = []
        var changed = original; changed.albumTitle += " Deluxe"; variants.append(changed)
        changed = original; changed.title += " Live"; variants.append(changed)
        changed = original; changed.artist += " Guest"; variants.append(changed)
        changed = original; changed.durationMS += 30_000; variants.append(changed)
        changed = original; changed.explicit = true; variants.append(changed)
        changed = original; changed.explicit = nil; variants.append(changed)
        changed = original; changed.isrc = "NEW"; variants.append(changed)
        changed = original; changed.catalogID = "edition"; variants.append(changed)
        for variant in variants { XCTAssertNotEqual(first.id, report([variant]).items.first?.id) }
        let otherAccount = ManualChecklistPlanner.make(source: source([original], account: "other"), library: library())
        XCTAssertNotEqual(first.id, otherAccount.items.first?.id)
    }

    func testConflictingObservationsOfSameSpotifyIDAreOneStableReviewRow() {
        let original = track("shared")
        var variant = original; variant.albumTitle += " Deluxe"
        var snapshot = source([original]); snapshot.playlists = [Playlist(id: "p", name: "P", tracks: [variant])]
        let first = ManualChecklistPlanner.make(source: snapshot, library: library([track("target")]))
        snapshot.savedTracks = [variant]; snapshot.playlists[0].tracks = [original]
        let reordered = ManualChecklistPlanner.make(source: snapshot, library: library([track("target")]))
        XCTAssertEqual(first.items.count, 1)
        XCTAssertEqual(first.items.first?.evidence, .review)
        XCTAssertEqual(first.items.first?.id, reordered.items.first?.id)
        XCTAssertNotEqual(first.items.first?.id, report([original]).items.first?.id)
    }

    func testScopesSeparateAccountsLibrariesAndDemoButIgnoreFilenamesAndDates() {
        let snapshot = source([track("song")]), imported = library()
        let first = ManualChecklistPlanner.make(source: snapshot, library: imported)
        var reconnected = snapshot; reconnected.account.connectionRevision = "reconnected"; reconnected.fetchedAt = .distantFuture
        var renamed = imported; renamed.fileName = "Renamed.xml"; renamed.importedAt = .distantFuture
        XCTAssertEqual(first.scopeID, ManualChecklistPlanner.make(source: reconnected, library: renamed).scopeID)
        var otherAccount = snapshot; otherAccount.account.id = "different-account"
        var otherLibrary = imported; otherLibrary.id = "different-library"
        let scopes = [first.scopeID, ManualChecklistPlanner.make(source: otherAccount, library: imported).scopeID,
                      ManualChecklistPlanner.make(source: snapshot, library: otherLibrary).scopeID,
                      ManualChecklistPlanner.make(source: snapshot, library: imported, isDemo: true).scopeID]
        XCTAssertEqual(Set(scopes).count, 4)
        // Delimiter-shaped user IDs cannot collide with another account/library pair.
        let left = ManualChecklistPlanner.make(source: source([], account: "a:b"), library: library(id: "c"))
        let right = ManualChecklistPlanner.make(source: source([], account: "a"), library: library(id: "b:c"))
        XCTAssertNotEqual(left.scopeID, right.scopeID)
    }

    func testItemCandidateAndLocationOrderingIsDeterministic() {
        let tracks = [track("b", title: "Beta"), track("a", title: "Alfa")]
        var snapshot = source(tracks)
        snapshot.playlists = [Playlist(id: "z", name: "Zeta", tracks: tracks), Playlist(id: "a", name: "Alfa", tracks: tracks)]
        let candidates = [track("x", title: "Beta"), track("y", title: "Beta"), track("z", title: "Alfa")]
        let first = ManualChecklistPlanner.make(source: snapshot, library: library(candidates))
        snapshot.savedTracks.reverse(); snapshot.playlists.reverse()
        let second = ManualChecklistPlanner.make(source: snapshot, library: library(candidates.reversed()))
        XCTAssertEqual(first.items.map(\.id), second.items.map(\.id))
        XCTAssertEqual(first.items.map(\.candidates), second.items.map(\.candidates))
        XCTAssertEqual(first.items.map(\.locations), second.items.map(\.locations))
        XCTAssertEqual(first.items.map { $0.track.title }, ["Alfa", "Beta"])
    }

    func testLargeLibraryUsesIndexedCandidates() {
        let tracks = (0..<4_000).map { track("spotify-\($0)", title: "Tema sintético \($0)") }
        let candidates = (0..<4_000).map { track("xml-\($0)", title: "Tema sintético \($0)") }
        let result = report(tracks, candidates: candidates)
        XCTAssertEqual(result.items.count, 4_000)
        XCTAssertTrue(result.items.allSatisfy { $0.evidence == .present && $0.candidates.count == 1 })
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("manual-checklist-tests-\(UUID().uuidString)", isDirectory: true)
    }

    func testStoreRoundTripReopensOfflineAndRestoresMarksWhenReturningToScope() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.json")
        let store = ManualChecklistStore(url: url)
        let absent = try await store.load()
        XCTAssertNil(absent)
        let imported = library(), snapshot = source([track("one")])
        let first = ManualChecklistPlanner.make(source: snapshot, library: imported)
        let second = ManualChecklistPlanner.make(source: source([track("two")], account: "other-account"), library: library(id: "other-library"))
        let firstID = try XCTUnwrap(first.items.first?.id), secondID = try XCTUnwrap(second.items.first?.id)
        var state = ManualChecklistState(library: imported, report: first, markedIDsByScope: [first.scopeID: [firstID]])
        try await store.save(state)
        state.report = second; state.markedIDsByScope[second.scopeID] = [secondID]
        try await store.save(state)
        let reopened = try await ManualChecklistStore(url: url).load()
        let restored = try XCTUnwrap(reopened)
        XCTAssertEqual(restored.library?.tracks, imported.tracks)
        XCTAssertEqual(restored.report?.items.map(\.id), second.items.map(\.id))
        XCTAssertEqual(restored.report?.sourceFetchedAt, second.sourceFetchedAt)
        XCTAssertEqual(restored.markedIDsByScope[first.scopeID], [firstID])
        XCTAssertEqual(restored.markedIDsByScope[second.scopeID], [secondID])
        let returned = ManualChecklistPlanner.make(source: snapshot, library: imported)
        XCTAssertEqual(restored.markedIDsByScope[returned.scopeID], [firstID])
    }

    func testStoreUsesPrivatePermissionsForInitialAndReplacementWrites() async throws {
        let directory = temporaryDirectory().appendingPathComponent("private", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let url = directory.appendingPathComponent("state.json"), manager = FileManager.default
        let store = ManualChecklistStore(url: url)
        try await store.save(ManualChecklistState())
        try manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        try await store.save(ManualChecklistState(markedIDsByScope: ["scope": ["one"]]))
        let fileAttributes = try manager.attributesOfItem(atPath: url.path)
        let directoryAttributes = try manager.attributesOfItem(atPath: directory.path)
        XCTAssertEqual((fileAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual(try manager.contentsOfDirectory(atPath: directory.path), ["state.json"])
        let decoded = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        XCTAssertNotNil(decoded?["markedIDsByScope"])
    }

    func testCorruptJSONThrowsDescriptiveErrorWithoutPrivateContents() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("private-token.json")
        try Data("private-token: malformed JSON".utf8).write(to: url)
        do {
            _ = try await ManualChecklistStore(url: url).load()
            XCTFail("Corrupt state must not be interpreted as absent")
        } catch {
            XCTAssertEqual(error as? ManualChecklistStoreError, .invalidState)
            XCTAssertFalse(error.localizedDescription.contains("private-token"))
        }
    }

    func testFailedEncodingKeepsPreviousStateAndDoesNotLeaveTemporaryFiles() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.json")
        let store = ManualChecklistStore(url: url)
        try await store.save(ManualChecklistState(markedIDsByScope: ["scope": ["kept"]]))
        let original = try Data(contentsOf: url)
        var invalid = library(); invalid.importedAt = Date(timeIntervalSince1970: .infinity)
        do {
            try await store.save(ManualChecklistState(library: invalid))
            XCTFail("Non-finite JSON dates must fail")
        } catch { XCTAssertEqual(error as? ManualChecklistStoreError, .invalidState) }
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["state.json"])
    }

    func testStoreRejectsSymlinkDestinationsWithoutTouchingTarget() async throws {
        let directory = temporaryDirectory(), manager = FileManager.default
        defer { try? manager.removeItem(at: directory) }
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent("target.json"), link = directory.appendingPathComponent("state.json")
        let original = Data("keep-target".utf8)
        try original.write(to: target)
        try manager.createSymbolicLink(at: link, withDestinationURL: target)
        let store = ManualChecklistStore(url: link)
        do { try await store.save(ManualChecklistState()); XCTFail("Symlink write must fail") }
        catch { XCTAssertEqual(error as? ManualChecklistStoreError, .unsafeLocation) }
        do { _ = try await store.load(); XCTFail("Symlink read must fail") }
        catch { XCTAssertEqual(error as? ManualChecklistStoreError, .unsafeLocation) }
        XCTAssertEqual(try Data(contentsOf: target), original)
    }

    func testIndependentStoresAlwaysReadWholeJSONDuringAtomicReplacement() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.json")
        let writer = ManualChecklistStore(url: url), reader = ManualChecklistStore(url: url)
        try await writer.save(ManualChecklistState(markedIDsByScope: ["initial": ["initial"]]))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for number in 0..<20 {
                group.addTask {
                    try await writer.save(ManualChecklistState(markedIDsByScope: ["scope": [String(number)]]))
                }
                group.addTask {
                    let loaded = try await reader.load()
                    XCTAssertEqual(loaded?.markedIDsByScope.count, 1)
                }
            }
            try await group.waitForAll()
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["state.json"])
    }
}
