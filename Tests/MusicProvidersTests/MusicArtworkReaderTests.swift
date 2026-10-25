import XCTest
import AVFoundation
import SyncCore
@testable import MusicProviders

final class MusicArtworkReaderTests: XCTestCase {
    private let libraryPID = "0123456789ABCDEF", trackPID = "FEDCBA9876543210"

    private func xml(location: URL, duplicatePID: Bool = false, hasPID: Bool = true) throws -> Data {
        var entry: [String: Any] = ["Track ID": 1, "Name": "Song", "Artist": "Artist", "Album": "Album", "Total Time": 120000,
            "Track Type": "File", "Location": location.absoluteString]
        if hasPID { entry["Persistent ID"] = trackPID }
        var entries = ["1": entry]
        if duplicatePID { var other = entry; other["Track ID"] = 2; entries["2"] = other }
        return try PropertyListSerialization.data(fromPropertyList: ["Library Persistent ID": libraryPID, "Tracks": entries], format: .xml, options: 0)
    }

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("spotam-artwork-fixture-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    func testDisabledByDefaultDoesNotParseXMLOrInvokeMediaLoader() async {
        let reader = MusicArtworkReader(embeddedArtwork: { _ in XCTFail("Disabled reader accessed media"); return nil })
        let result = await reader.read(for: Track(id: "unknown", title: "Song", artist: "Artist"), xmlData: Data("invalid".utf8))
        XCTAssertEqual(result.state, .disabled); XCTAssertNil(result.image)
    }

    func testReadsOnlyExactPIDBoundLocalFileInsideOptedInFolder() async throws {
        let folder = try temporaryFolder(), file = folder.appendingPathComponent("Song.m4a")
        try Data().write(to: file)
        let data = try xml(location: file), library = try MusicXMLImporter.parse(data, fileName: "Fixture.xml")
        let picture = try artworkFixture(red: 0.5)
        let reader = MusicArtworkReader(embeddedArtwork: { url in XCTAssertEqual(url.path, file.path); return picture })
        let result = await reader.read(for: library.tracks[0], xmlData: data, consent: .enabled, allowedMediaRoots: [folder])
        XCTAssertEqual(result.state, .available); XCTAssertEqual(result.trackPersistentID, trackPID)
        XCTAssertEqual(result.image?.origin, .localMusicFile); XCTAssertEqual(result.image?.data, picture)
    }

    func testRejectsMissingDuplicateForeignOrChangedPIDAndOutOfScopeLocationBeforeLoading() async throws {
        let folder = try temporaryFolder(), file = folder.appendingPathComponent("Song.m4a")
        try Data().write(to: file)
        let reader = MusicArtworkReader(embeddedArtwork: { _ in XCTFail("Unverified binding read a file"); return nil })
        for data in [try xml(location: file, hasPID: false), try xml(location: file, duplicatePID: true)] {
            let library = try MusicXMLImporter.parse(data, fileName: "Fixture.xml")
            let result = await reader.read(for: library.tracks[0], xmlData: data, consent: .enabled, allowedMediaRoots: [folder])
            XCTAssertEqual(result.state, .unavailable)
        }
        let data = try xml(location: file), library = try MusicXMLImporter.parse(data, fileName: "Fixture.xml")
        var foreign = library.tracks[0]; foreign.id = foreign.id.replacingOccurrences(of: libraryPID, with: "AAAAAAAAAAAAAAAA")
        var changed = library.tracks[0]; changed.albumTitle = "Other edition"
        for track in [foreign, changed] {
            let result = await reader.read(for: track, xmlData: data, consent: .enabled, allowedMediaRoots: [folder])
            XCTAssertEqual(result.state, .unavailable)
        }
        for roots in [[], [URL(fileURLWithPath: "/")], [folder.appendingPathComponent("other")]] {
            let result = await reader.read(for: library.tracks[0], xmlData: data, consent: .enabled, allowedMediaRoots: roots)
            XCTAssertEqual(result.state, .unavailable)
        }
    }

    func testSymlinkCannotEscapeSelectedFolderAndRemoteURLIsNeverRead() async throws {
        let folder = try temporaryFolder(), outside = try temporaryFolder()
        let file = outside.appendingPathComponent("outside.m4a"), link = folder.appendingPathComponent("link.m4a")
        try Data().write(to: file); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        let reader = MusicArtworkReader(embeddedArtwork: { _ in XCTFail("Out of scope media read"); return nil })
        for url in [link, URL(string: "https://media.example/song.m4a")!, URL(string: "file://remote.example/song.m4a")!] {
            let data = try xml(location: url), library = try MusicXMLImporter.parse(data, fileName: "Fixture.xml")
            let result = await reader.read(for: library.tracks[0], xmlData: data, consent: .enabled, allowedMediaRoots: [folder])
            XCTAssertEqual(result.state, .unavailable)
        }
    }

    func testNativeAVFoundationReadsSyntheticEmbeddedArtworkWithoutMusicAccess() async throws {
        let folder = try temporaryFolder(), file = folder.appendingPathComponent("Song.mp3")
        let picture = try artworkFixture(red: 0.5)
        // ID3v2.3 APIC front cover + twelve silent MPEG-1 Layer III frames.
        // Build the fixture directly: no encoder, media service or personal file.
        let payload = Data([0]) + Data("image/png".utf8) + Data([0, 3, 0]) + picture
        let size = payload.count
        let frame = Data("APIC".utf8) + Data([UInt8((size >> 24) & 255), UInt8((size >> 16) & 255),
            UInt8((size >> 8) & 255), UInt8(size & 255), 0, 0]) + payload
        let tagSize = frame.count
        var media = Data([0x49, 0x44, 0x33, 3, 0, 0, UInt8((tagSize >> 21) & 127),
            UInt8((tagSize >> 14) & 127), UInt8((tagSize >> 7) & 127), UInt8(tagSize & 127)]) + frame
        for _ in 0..<12 { media += Data([0xFF, 0xFB, 0x90, 0]) + Data(repeating: 0, count: 413) }
        try media.write(to: file)
        let data = try xml(location: file), library = try MusicXMLImporter.parse(data, fileName: "Fixture.xml")
        let result = await MusicArtworkReader().read(for: library.tracks[0], xmlData: data, consent: .enabled, allowedMediaRoots: [folder])
        XCTAssertEqual(result.state, .available); XCTAssertEqual(result.image?.origin, .localMusicFile)
        XCTAssertEqual(ArtworkComparison.compare(result.image, ArtworkImage(data: picture, origin: .appleMusicCatalog)).state, .equal)
    }
}
