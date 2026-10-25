import XCTest
@testable import SyncCore

final class MusicXMLImporterTests: XCTestCase {
    private func song(_ id: Int, extra: [String: Any] = [:]) -> [String: Any] {
        var result: [String: Any] = ["Track ID": id, "Name": "Canción sintética \(id)", "Artist": "Artista de prueba",
                                     "Album": "Álbum de prueba", "Total Time": 180_000, "Track Type": "Remote",
                                     "Persistent ID": String(format: "%016X", id)]
        result.merge(extra) { _, new in new }
        return result
    }

    private func root(tracks: [String: Any] = [:], extra: [String: Any] = [:]) -> [String: Any] {
        var result: [String: Any] = ["Library Persistent ID": "0123456789ABCDEF", "Tracks": tracks, "Playlists": []]
        result.merge(extra) { _, new in new }
        return result
    }

    private func xml(_ root: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: root, format: .xml, options: 0)
    }

    private func parse(_ root: [String: Any]) throws -> ManualMusicLibrary {
        try MusicXMLImporter.parse(xml(root), fileName: "Synthetic.xml")
    }

    private func playlist(_ id: Int, name: String? = nil, extra: [String: Any] = [:]) -> [String: Any] {
        var result: [String: Any] = ["Name": name ?? "Playlist \(id)",
                                     "Playlist Persistent ID": String(format: "%016X", 256 + id)]
        result.merge(extra) { _, new in new }
        return result
    }

    func testInvalidFilesNeverBecomeEmptyLibraries() throws {
        for data in [Data(), Data("not XML".utf8), Data("<plist><dict>".utf8), try xml([:]),
                     try xml(["Library Persistent ID": "0123456789ABCDEF"]),
                     try xml(root(extra: ["Tracks": []]))] {
            XCTAssertThrowsError(try MusicXMLImporter.parse(data, fileName: "Invalid.xml"))
        }
        let binary = try PropertyListSerialization.data(fromPropertyList: root(), format: .binary, options: 0)
        XCTAssertThrowsError(try MusicXMLImporter.parse(binary, fileName: "Binary.xml"))
    }

    func testPersistentLibraryIdentityIsRequiredAndNeverCoerced() throws {
        let invalid: [Any] = [1234567890123456, true, "", "123", "0000000000000000", "G123456789ABCDEF", " 0123456789ABCDEF"]
        for value in invalid {
            XCTAssertThrowsError(try parse(root(extra: ["Library Persistent ID": value]))) { error in
                XCTAssertEqual(error as? MusicXMLImportError, .invalidLibraryIdentity)
            }
        }
        let result = try parse(root(extra: ["Library Persistent ID": "0123456789abcdef"]))
        XCTAssertEqual(result.id, "apple-music-xml:0123456789ABCDEF")
        XCTAssertTrue(result.complete)
        XCTAssertTrue(result.tracks.isEmpty)
    }

    func testIdentitySurvivesRenameAndPreservesDatesAndSnapshotWarnings() throws {
        let exported = Date(timeIntervalSince1970: 1_700_000_000), imported = exported.addingTimeInterval(60)
        let data = try xml(root(tracks: ["1": song(1)], extra: ["Date": exported]))
        let first = try MusicXMLImporter.parse(data, fileName: "First.xml", importedAt: imported)
        let renamed = try MusicXMLImporter.parse(data, fileName: "Renamed.xml")
        XCTAssertEqual(first.id, renamed.id)
        XCTAssertEqual(first.tracks.map(\.id), renamed.tracks.map(\.id))
        XCTAssertEqual(first.documentDigest, renamed.documentDigest)
        XCTAssertEqual(first.fileName, "First.xml")
        XCTAssertEqual(first.importedAt, imported)
        XCTAssertEqual(first.exportedAt, exported)
        XCTAssertTrue(first.warnings.contains { $0.contains("snapshot") && $0.contains("nube") })
        XCTAssertTrue(first.warnings.contains { $0.contains("álbum completo") })
    }

    func testRemoteCloudAndPlaylistOnlyAreRetainedAndNotLocal() throws {
        let result = try parse(root(tracks: [
            "1": song(1, extra: ["Playlist Only": true, "Location": "https://example.invalid/stream?token=synthetic-private"]),
            "2": song(2, extra: ["Kind": "Apple Music AAC audio file", "Track Type": "Remote"]),
            "3": song(3, extra: ["Track Type": "File", "Location": "file:///synthetic/song.m4a"])
        ], extra: ["Playlists": [playlist(1, extra: ["Playlist Items": [["Track ID": 1], ["Track ID": 1], ["Track ID": 2]]])]]))
        XCTAssertTrue(result.complete)
        XCTAssertEqual(result.tracks.count, 3)
        XCTAssertFalse(result.tracks[0].isLocal)
        XCTAssertFalse(result.tracks[1].isLocal)
        XCTAssertTrue(result.tracks[2].isLocal)
        XCTAssertTrue(result.tracks.allSatisfy(\.available))
        XCTAssertEqual(result.inventory?.trackInfo[result.tracks[0].id]?.playlistOnly, true)
        XCTAssertNil(result.inventory?.trackInfo[result.tracks[1].id]?.playlistOnly)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(result), as: UTF8.self).contains("synthetic-private"))
    }

    func testExportIDsAndStoreIdentifiersAreNotCoercedIntoCatalogOrISRC() throws {
        let result = try parse(root(tracks: ["1": song(1, extra: [
            "Persistent ID": "ABCDEF0123456789", "Store ID": 12345678, "Store Track ID": 98765432,
            "ISRC": "NOT-AN-INFERRED-IDENTITY"
        ])]))
        let track = try XCTUnwrap(result.tracks.first)
        XCTAssertTrue(track.id.hasPrefix(result.id + ":track:"))
        XCTAssertNotEqual(track.id, "1")
        XCTAssertNotEqual(track.id, "ABCDEF0123456789")
        XCTAssertNil(track.catalogID)
        XCTAssertNil(track.isrc)
        let another = try parse(root(tracks: ["1": song(1)], extra: ["Library Persistent ID": "1111111111111111"]))
        XCTAssertNotEqual(track.id, another.tracks.first?.id)
    }

    func testExplicitCleanAndUnknownEvidenceRemainDistinct() throws {
        let cases: [([String: Any], Bool?)] = [([:], nil), (["Explicit": true], true), (["Explicit": false], false),
                                             (["Clean": true], false), (["Clean": false], nil),
                                             (["Explicit": false, "Clean": true], false)]
        for (fields, expected) in cases {
            let result = try parse(root(tracks: ["1": song(1, extra: fields)]))
            XCTAssertEqual(result.tracks.first?.explicit, expected)
            XCTAssertTrue(result.complete)
        }
        for fields: [String: Any] in [["Explicit": true, "Clean": true], ["Explicit": 1], ["Clean": "true"]] {
            let result = try parse(root(tracks: ["1": song(1, extra: fields)]))
            XCTAssertNil(result.tracks.first?.explicit)
            XCTAssertFalse(result.complete)
        }
    }

    func testKnownNonMusicIsFilteredAndPlaylistProjectionReportsPartialContents() throws {
        let result = try parse(root(tracks: [
            "1": song(1, extra: ["Podcast": true]), "2": song(2, extra: ["Movie": true]),
            "3": song(3, extra: ["TV Show": true]), "4": song(4, extra: ["Media Kind": "Audiobook"]),
            "5": song(5, extra: ["Video Kind": "Music Video", "Has Video": true]),
            "6": song(6, extra: ["Podcast": false, "Kind": "Apple Music AAC audio file"])
        ], extra: ["Playlists": [playlist(1, extra: ["Playlist Items": (1...6).map { ["Track ID": $0] }])]]))
        XCTAssertEqual(result.tracks.map(\.title), ["Canción sintética 5", "Canción sintética 6"])
        XCTAssertFalse(result.complete)
        XCTAssertEqual(result.inventory?.playlists.first?.trackIDs, result.tracks.map(\.id))
        XCTAssertEqual(result.inventory?.playlists.first?.contentsComplete, false)
    }

    func testMalformedTrackIdentityDoesNotCoerceStringsBooleansOrReals() throws {
        let invalid: [Any] = ["1", true, 1.5, -1, 2]
        for value in invalid {
            let result = try parse(root(tracks: ["1": song(1, extra: ["Track ID": value])]))
            XCTAssertFalse(result.complete)
            XCTAssertTrue(result.tracks.isEmpty)
            XCTAssertTrue(result.warnings.contains { $0.contains("identidad inválida") })
        }
        for entries: [String: Any] in [["01": song(1)], ["invalid": song(1)], ["1": "invalid-entry"]] {
            XCTAssertFalse(try parse(root(tracks: entries)).complete)
        }
    }

    func testBrokenPlaylistReferencesAndShapesMakeCoveragePartial() throws {
        let invalid: [Any] = ["not-an-array", ["not-a-dictionary"], [["Playlist Items": "invalid"]],
                              [["Playlist Items": ["invalid"]]], [["Playlist Items": [["Track ID": 9]]]],
                              [["Playlist Items": [["Track ID": "1"]]]], [["Playlist Items": [["Track ID": true]]]],
                              [["Playlist Items": [["Track ID": 1.5]]]], [["Playlist Items": [[:]]]]]
        for playlists in invalid {
            let result = try parse(root(tracks: ["1": song(1)], extra: ["Playlists": playlists]))
            XCTAssertFalse(result.complete)
            XCTAssertEqual(result.tracks.count, 1)
        }
        let valid = try parse(root(tracks: ["1": song(1)], extra: ["Playlists": [
            playlist(1, name: "Empty"), playlist(2, extra: ["Folder": true]),
            playlist(3, extra: ["Playlist Items": []]), playlist(4, extra: ["Playlist Items": [["Track ID": 1]]])
        ]]))
        XCTAssertTrue(valid.complete)
    }

    func testIncompleteMetadataAndInvalidDatesAreReportedWithoutLeakingValues() throws {
        let result = try parse(root(tracks: [
            "1": song(1, extra: ["Name": "", "Artist": 123, "Total Time": "private-token", "Persistent ID": "private-token"]),
            "2": song(2)
        ], extra: ["Date": "private-token"]))
        XCTAssertFalse(result.complete)
        XCTAssertEqual(result.tracks.count, 2)
        XCTAssertEqual(result.tracks[0].durationMS, 0)
        XCTAssertEqual(result.tracks[0].artist, "")
        XCTAssertNil(result.exportedAt)
        XCTAssertFalse(result.warnings.joined().contains("private-token"))
    }

    func testDuplicatePersistentIDsRemainSeparateReviewCandidates() throws {
        let result = try parse(root(tracks: [
            "1": song(1, extra: ["Persistent ID": "ABCDEF0123456789"]),
            "2": song(2, extra: ["Persistent ID": "ABCDEF0123456789"])
        ]))
        XCTAssertFalse(result.complete)
        XCTAssertEqual(result.tracks.count, 2)
        XCTAssertEqual(Set(result.tracks.map(\.id)).count, 2)
        XCTAssertTrue(result.warnings.contains { $0.contains("duplicadas") })
    }

    func testDuplicateXMLKeysAreNotSilentlyOverwritten() throws {
        let data = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict>
        <key>Library Persistent ID</key><string>0123456789ABCDEF</string>
        <key>Tracks</key><dict/><key>Tracks</key><dict/>
        </dict></plist>
        """.utf8)
        XCTAssertThrowsError(try MusicXMLImporter.parse(data, fileName: "Duplicate.xml")) { error in
            XCTAssertEqual(error as? MusicXMLImportError, .duplicateKeys)
        }
    }

    func testInventoryPreservesNamesKindsParentOrderRepeatedItemsAndEmptyPlaylists() throws {
        let result = try parse(root(tracks: ["1": song(1), "2": song(2)], extra: ["Playlists": [
            playlist(1, name: "  Carpeta exacta  ", extra: ["Folder": true]),
            playlist(2, name: "Mismo nombre", extra: ["Parent Persistent ID": "0000000000000101",
                "Playlist Items": [["Track ID": 2], ["Track ID": 1], ["Track ID": 2]]]),
            playlist(3, name: "Mismo nombre"),
            playlist(4, extra: ["Smart Info": Data([1, 2]), "Smart Criteria": Data([3])]),
            playlist(5, extra: ["Master": true]),
            playlist(6, extra: ["Distinguished Kind": 4])
        ]]))
        let inventory = try XCTUnwrap(result.inventory)
        XCTAssertEqual(inventory.playlists.count, 6)
        XCTAssertEqual(inventory.playlists.map(\.kind), [.folder, .regular, .regular, .smart, .system, .system])
        XCTAssertEqual(inventory.playlists[0].name, "  Carpeta exacta  ")
        XCTAssertEqual(inventory.playlists[1].parentID, inventory.playlists[0].id)
        XCTAssertEqual(inventory.playlists[1].trackIDs, [result.tracks[1].id, result.tracks[0].id, result.tracks[1].id])
        XCTAssertNotEqual(inventory.playlists[1].id, inventory.playlists[2].id)
        XCTAssertTrue(inventory.playlists[2].trackIDs.isEmpty)
        XCTAssertTrue(inventory.playlists.allSatisfy(\.contentsComplete))
        XCTAssertTrue(inventory.playlistsComplete)
        XCTAssertTrue(result.complete)
    }

    func testUniquePersistentIDsSurviveRenumberingReorderingAndReexport() throws {
        let first = try parse(root(tracks: ["1": song(1), "2": song(2)], extra: ["Playlists": [
            playlist(1, extra: ["Playlist Items": [["Track ID": 2], ["Track ID": 1], ["Track ID": 2]]])
        ]]))
        var renumberedFirst = song(1, extra: ["Track ID": 71])
        renumberedFirst["Name"] = "Nombre actualizado"
        let second = try parse(root(tracks: ["71": renumberedFirst, "54": song(2, extra: ["Track ID": 54])], extra: [
            "Playlists": [playlist(1, name: "Nombre de playlist actualizado", extra: [
                "Playlist ID": 999, "Playlist Items": [["Track ID": 54], ["Track ID": 71], ["Track ID": 54]]])]
        ]))
        XCTAssertEqual(Set(first.tracks.map(\.id)), Set(second.tracks.map(\.id)))
        XCTAssertEqual(first.inventory?.playlists.first?.id, second.inventory?.playlists.first?.id)
        XCTAssertEqual(first.inventory?.playlists.first?.trackIDs, second.inventory?.playlists.first?.trackIDs)
        XCTAssertNotEqual(first.documentDigest, second.documentDigest)
        let trackID = try XCTUnwrap(first.tracks.first?.id)
        XCTAssertEqual(first.inventory?.trackInfo[trackID]?.referenceID, 1)
        XCTAssertEqual(second.inventory?.trackInfo[trackID]?.referenceID, 71)
        XCTAssertEqual(first.inventory?.trackInfo[trackID]?.persistentID, "0000000000000001")
        XCTAssertTrue(second.complete)
    }

    func testMissingAndDuplicateTrackIdentitiesAreDocumentScopedAndPartial() throws {
        var missingPID = song(1)
        missingPID.removeValue(forKey: "Persistent ID")
        for tracks in [
            ["1": missingPID],
            ["1": song(1, extra: ["Persistent ID": "ABCDEF0123456789"]),
             "2": song(2, extra: ["Persistent ID": "abcdef0123456789"])]
        ] {
            let document = root(tracks: tracks, extra: ["Playlists": [
                playlist(1, extra: ["Playlist Items": [["Track ID": 1], ["Track ID": 1]]])]
            ])
            let first = try parse(document)
            var changedDocument = document
            changedDocument["Date"] = Date(timeIntervalSince1970: 1_700_000_000)
            let second = try parse(changedDocument)
            XCTAssertFalse(first.complete)
            XCTAssertFalse(try XCTUnwrap(first.inventory).playlistsComplete)
            XCTAssertEqual(first.inventory?.playlists.first?.contentsComplete, false)
            XCTAssertEqual(first.inventory?.playlists.first?.trackIDs.count, 2)
            XCTAssertEqual(Set(first.tracks.map(\.id)).count, tracks.count)
            XCTAssertTrue(Set(first.tracks.map(\.id)).isDisjoint(with: second.tracks.map(\.id)))
        }
    }

    func testMissingPlaylistsDoesNotClaimEmptyCompleteInventory() throws {
        var document = root(tracks: ["1": song(1)])
        document.removeValue(forKey: "Playlists")
        let result = try parse(document)
        XCTAssertFalse(result.complete)
        XCTAssertEqual(result.inventory?.playlists, [])
        XCTAssertEqual(result.inventory?.playlistsComplete, false)
        let explicitlyEmpty = try parse(root(tracks: ["1": song(1)]))
        XCTAssertTrue(explicitlyEmpty.complete)
        XCTAssertEqual(explicitlyEmpty.inventory?.playlistsComplete, true)
    }

    func testPartialPlaylistKeepsKnownSequenceAndOtherPlaylists() throws {
        let result = try parse(root(tracks: ["1": song(1), "2": song(2)], extra: ["Playlists": [
            playlist(1, extra: ["Playlist Items": [["Track ID": 2], ["Track ID": 99], ["Track ID": 1],
                                                  ["Track ID": "1"], ["Track ID": 2]]]),
            playlist(2)
        ]]))
        XCTAssertFalse(result.complete)
        XCTAssertEqual(result.inventory?.playlists[0].trackIDs,
                       [result.tracks[1].id, result.tracks[0].id, result.tracks[1].id])
        XCTAssertEqual(result.inventory?.playlists[0].contentsComplete, false)
        XCTAssertEqual(result.inventory?.playlists[1].contentsComplete, true)
        XCTAssertEqual(result.inventory?.playlistsComplete, false)
    }

    func testDuplicateMissingAndInvalidPlaylistIdentityPreservesAllRowsWithPartialCoverage() throws {
        var missing = playlist(1)
        missing.removeValue(forKey: "Playlist Persistent ID")
        let result = try parse(root(extra: ["Playlists": [playlist(1), playlist(1), missing,
            playlist(2, extra: ["Playlist Persistent ID": "invalid", "Name": 123])]]))
        let playlists = try XCTUnwrap(result.inventory).playlists
        XCTAssertEqual(playlists.count, 4)
        XCTAssertEqual(Set(playlists.map(\.id)).count, 4)
        XCTAssertFalse(result.complete)
        XCTAssertTrue(playlists.allSatisfy { !$0.contentsComplete })
    }

    func testInvalidHierarchyAndKindsRemainPartialWithoutDroppingPlaylists() throws {
        let cases: [[[String: Any]]] = [
            [playlist(1, extra: ["Parent Persistent ID": "0000000000000999"])],
            [playlist(1), playlist(2, extra: ["Parent Persistent ID": "0000000000000101"])],
            [playlist(1, extra: ["Folder": true, "Parent Persistent ID": "0000000000000102"]),
             playlist(2, extra: ["Folder": true, "Parent Persistent ID": "0000000000000101"])],
            [playlist(1, extra: ["Folder": true, "Parent Persistent ID": "0000000000000101"])],
            [playlist(1, extra: ["Folder": "true"])],
            [playlist(1, extra: ["Folder": true, "Master": true])],
            [playlist(1, extra: ["Smart Info": "invalid"])],
            [playlist(1, extra: ["Distinguished Kind": true])],
            [playlist(1, extra: ["Parent Persistent ID": true])]
        ]
        for playlists in cases {
            let result = try parse(root(extra: ["Playlists": playlists]))
            XCTAssertEqual(result.inventory?.playlists.count, playlists.count)
            XCTAssertFalse(result.complete)
            XCTAssertEqual(result.inventory?.playlistsComplete, false)
        }
        let invalidType = try parse(root(extra: ["Playlists": [playlist(1, extra: ["Folder": 1])]]))
        XCTAssertEqual(invalidType.inventory?.playlists.first?.kind, .unknown)
    }

    func testInventoryCodableRoundTripAndLegacyChecklistMarks() throws {
        let result = try parse(root(tracks: ["1": song(1, extra: ["Playlist Only": false])], extra: [
            "Playlists": [playlist(1, extra: ["Playlist Items": [["Track ID": 1], ["Track ID": 1]]])]
        ]))
        XCTAssertEqual(try JSONDecoder().decode(ManualMusicLibrary.self, from: JSONEncoder().encode(result)), result)
        let legacyData = Data("""
        {"library":{"id":"legacy-library","fileName":"Old.xml","importedAt":0,"tracks":[],"warnings":[],"complete":true},
         "markedIDsByScope":{"legacy-scope":["legacy-mark"]}}
        """.utf8)
        let state = try JSONDecoder().decode(ManualChecklistState.self, from: legacyData)
        XCTAssertNil(state.library?.inventory)
        XCTAssertNil(state.library?.documentDigest)
        XCTAssertEqual(state.markedIDsByScope, ["legacy-scope": ["legacy-mark"]])
        let reopened = try JSONDecoder().decode(ManualChecklistState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(reopened.library, state.library)
        XCTAssertEqual(reopened.markedIDsByScope, state.markedIDsByScope)
    }

    func testChecklistMarkIdentitySurvivesRenumberedXML() throws {
        let track = Track(id: "spotify-source", title: "Canción sintética 1", artist: "Artista de prueba",
                          albumTitle: "Álbum de prueba", durationMS: 180_000, explicit: false)
        let source = LibrarySnapshot(account: .init(id: "synthetic", service: .spotify, displayName: "Synthetic"), savedTracks: [track])
        let first = try parse(root(tracks: ["1": song(1, extra: ["Clean": true])]))
        let reexport = try parse(root(tracks: ["88": song(1, extra: ["Track ID": 88, "Clean": true])]))
        let oldReport = ManualChecklistPlanner.make(source: source, library: first)
        let newReport = ManualChecklistPlanner.make(source: source, library: reexport)
        XCTAssertEqual(oldReport.scopeID, newReport.scopeID)
        XCTAssertEqual(oldReport.items.map(\.id), newReport.items.map(\.id))
        XCTAssertEqual(newReport.items.first?.evidence, .present)
    }

    func testImportFlowsIntoPresenceAndPartialAbsenceReview() throws {
        var first = song(1, extra: ["Clean": true, "Playlist Only": true])
        first["Name"] = "Tema"
        let library = try parse(root(tracks: ["1": first], extra: ["Playlists": [["Playlist Items": [["Track ID": 2]]]]]))
        let source = LibrarySnapshot(account: ConnectedAccount(id: "synthetic", service: .spotify, displayName: "Synthetic"),
                                     savedTracks: [
                                        Track(id: "one", title: "Tema", artist: "Artista de prueba", albumTitle: "Álbum de prueba", durationMS: 180_000, explicit: false),
                                        Track(id: "two", title: "Otro tema", artist: "Artista de prueba", albumTitle: "Álbum de prueba", durationMS: 180_000, explicit: false)
                                     ])
        let result = ManualChecklistPlanner.make(source: source, library: library)
        XCTAssertEqual(result.items.first { $0.track.id == "one" }?.evidence, .present)
        XCTAssertEqual(result.items.first { $0.track.id == "two" }?.evidence, .review)
    }
}
