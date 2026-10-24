import XCTest
@testable import SyncCore

final class MusicXMLImporterTests: XCTestCase {
    private func song(_ id: Int, extra: [String: Any] = [:]) -> [String: Any] {
        var result: [String: Any] = ["Track ID": id, "Name": "Canción sintética \(id)", "Artist": "Artista de prueba",
                                     "Album": "Álbum de prueba", "Total Time": 180_000, "Track Type": "Remote"]
        result.merge(extra) { _, new in new }
        return result
    }

    private func root(tracks: [String: Any] = [:], extra: [String: Any] = [:]) -> [String: Any] {
        var result: [String: Any] = ["Library Persistent ID": "0123456789ABCDEF", "Tracks": tracks]
        result.merge(extra) { _, new in new }
        return result
    }

    private func xml(_ root: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: root, format: .xml, options: 0)
    }

    private func parse(_ root: [String: Any]) throws -> ManualMusicLibrary {
        try MusicXMLImporter.parse(xml(root), fileName: "Synthetic.xml")
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
        ], extra: ["Playlists": [["Playlist Items": [["Track ID": 1], ["Track ID": 1], ["Track ID": 2]]]]]))
        XCTAssertTrue(result.complete)
        XCTAssertEqual(result.tracks.count, 3)
        XCTAssertFalse(result.tracks[0].isLocal)
        XCTAssertFalse(result.tracks[1].isLocal)
        XCTAssertTrue(result.tracks[2].isLocal)
        XCTAssertTrue(result.tracks.allSatisfy(\.available))
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

    func testKnownNonMusicIsFilteredWithoutBreakingValidPlaylistReferences() throws {
        let result = try parse(root(tracks: [
            "1": song(1, extra: ["Podcast": true]), "2": song(2, extra: ["Movie": true]),
            "3": song(3, extra: ["TV Show": true]), "4": song(4, extra: ["Media Kind": "Audiobook"]),
            "5": song(5, extra: ["Video Kind": "Music Video", "Has Video": true]),
            "6": song(6, extra: ["Podcast": false, "Kind": "Apple Music AAC audio file"])
        ], extra: ["Playlists": [["Playlist Items": (1...6).map { ["Track ID": $0] }]]]))
        XCTAssertEqual(result.tracks.map(\.title), ["Canción sintética 5", "Canción sintética 6"])
        XCTAssertTrue(result.complete)
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
            ["Name": "Empty"], ["Folder": true], ["Playlist Items": []], ["Playlist Items": [["Track ID": 1]]]
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
