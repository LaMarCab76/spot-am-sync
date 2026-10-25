import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import SyncCore
@testable import MusicProviders

func artworkFixture(red: CGFloat, green: CGFloat = 0, blue: CGFloat = 0, size: Int = 96, jpeg: Bool = false) throws -> Data {
    let context = try XCTUnwrap(CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: size, height: size))
    let data = NSMutableData()
    let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, (jpeg ? UTType.jpeg.identifier : UTType.png.identifier) as CFString, 1, nil))
    CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return data as Data
}

final class ArtworkComparisonTests: XCTestCase {
    private func image(_ data: Data, origin: ArtworkOrigin = .spotifyCatalog) -> ArtworkImage { .init(data: data, origin: origin) }

    func testDecodesImageRatherThanComparingEncodedBytes() throws {
        let png = try artworkFixture(red: 0), jpeg = try artworkFixture(red: 0, jpeg: true)
        XCTAssertNotEqual(png, jpeg)
        XCTAssertEqual(ArtworkComparison.compare(image(png), image(jpeg)).state, .equal)
    }

    func testNormalizesImageResolutionAndReportsLargeVisualDifferences() throws {
        let small = try artworkFixture(red: 0, size: 32), large = try artworkFixture(red: 0, size: 512)
        XCTAssertEqual(ArtworkComparison.compare(image(small), image(large)).state, .equal)
        let white = try artworkFixture(red: 1, green: 1, blue: 1)
        XCTAssertEqual(ArtworkComparison.compare(image(small), image(white)).state, .different)
    }

    func testSmallDifferencesStayPossibleAndMissingOrCorruptImagesStayUnavailable() throws {
        let black = try artworkFixture(red: 0), dark = try artworkFixture(red: 0.08)
        XCTAssertEqual(ArtworkComparison.compare(image(black), image(dark)).state, .possible)
        XCTAssertEqual(ArtworkComparison.compare(image(black), nil).state, .unavailable)
        XCTAssertEqual(ArtworkComparison.compare(image(Data("invalid".utf8)), image(Data("invalid".utf8))).state, .unavailable)
        XCTAssertEqual(ArtworkComparison.compare(image(Data(repeating: 0, count: 8 * 1024 * 1024 + 1)), image(black)).state, .unavailable)
    }

    func testSpotifyReferenceNeverBecomesEvidenceOfAppleArtwork() throws {
        let data = try artworkFixture(red: 0)
        let result = ArtworkComparison.compare(image(data, origin: .spotifyReference), image(data, origin: .appleMusicCatalog))
        XCTAssertEqual(result.state, .unavailable); XCTAssertTrue(result.detail.contains("referencia"))
    }

    func testDifferentURLsWithSameImageAreEqualAndSameURLWithDifferentImagesIsDifferent() async throws {
        actor Images: ProviderHTTPTransport {
            var values: [Data]
            private(set) var calls = 0
            init(_ values: [Data]) { self.values = values }
            func send(_ request: URLRequest) throws -> ProviderHTTPResponse {
                XCTAssertEqual(request.url?.scheme, "https")
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                XCTAssertNil(request.value(forHTTPHeaderField: "Music-User-Token"))
                XCTAssertFalse(request.httpShouldHandleCookies)
                calls += 1
                return .init(statusCode: 200, data: values.removeFirst())
            }
        }
        let black = try artworkFixture(red: 0), white = try artworkFixture(red: 1, green: 1, blue: 1)
        let same = Images([black, black])
        let equal = await ArtworkComparison.compare(sourceURL: "https://images.example/old", sourceOrigin: .spotifyCatalog,
            candidateURL: "https://images.example/new", candidateOrigin: .appleMusicCatalog, transport: same)
        XCTAssertEqual(equal.state, .equal)
        let different = Images([black, white])
        let changed = await ArtworkComparison.compare(sourceURL: "https://images.example/same", sourceOrigin: .spotifyCatalog,
            candidateURL: "https://images.example/same", candidateOrigin: .appleMusicCatalog, transport: different)
        XCTAssertEqual(changed.state, .different)
        let calls = await different.calls; XCTAssertEqual(calls, 2)
    }

    func testLoaderDoesNotReadFilesOrInsecureURLs() async {
        let transport = ScriptedTransport([])
        for url in ["file:///tmp/picture.png", "http://images.example/picture.png", "https://user:secret@images.example/picture.png"] {
            let result = await ArtworkComparison.load(url: url, origin: .spotifyCatalog, transport: transport)
            XCTAssertNil(result)
        }
        await transport.assertExhausted()
    }

    func testReferenceUsesOnlyAConfirmedMappingAndNeverSelectsAnAmbiguousEdition() {
        let source = Track(id: "apple-music-xml:0123456789ABCDEF:track:persistent:FEDCBA9876543210",
                           title: "Song", artist: "Artist", albumTitle: "Album", durationMS: 120000, explicit: false, isLocal: true)
        var candidate = Track(id: "spotify", title: "Song", artist: "Artist", albumTitle: "Album", durationMS: 120000, explicit: false)
        candidate.artworkURL = "https://images.example/reference.jpg"
        XCTAssertEqual(ArtworkComparison.spotifyReference(for: source, candidates: [candidate])?.id, candidate.id)
        var second = candidate; second.id = "other-edition"
        XCTAssertNil(ArtworkComparison.spotifyReference(for: source, candidates: [candidate, second]))
        var match = TrackMatch(sourceService: .appleMusic, source: source, candidates: [candidate], selected: candidate)
        XCTAssertNil(ArtworkComparison.spotifyReference(for: source, confirmedMatch: match))
        match.decision = .manual
        XCTAssertEqual(ArtworkComparison.spotifyReference(for: source, confirmedMatch: match)?.id, candidate.id)
        match.decision = .pending
        XCTAssertNil(ArtworkComparison.spotifyReference(for: source, confirmedMatch: match))
        XCTAssertNil(source.artworkURL, "The reference is never installed as Apple artwork")
    }
}
