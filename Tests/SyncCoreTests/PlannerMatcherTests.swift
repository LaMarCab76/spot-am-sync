import XCTest
@testable import SyncCore

final class PlannerMatcherTests: XCTestCase {
    private func track(_ id: String) -> Track {
        Track(id: id, title: "Canción", artist: "Artista", albumTitle: "Álbum", durationMS: 200_000, isrc: "TEST-123", explicit: false)
    }

    func testISRCIsNotAUniqueIdentifier() {
        let result = CatalogMatcher.track(track("source"), candidates: [track("one"), track("two")], sourceService: .spotify)
        XCTAssertNil(result.selected)
        XCTAssertEqual(result.confidence, .review)
        XCTAssertEqual(result.candidates.count, 2)
    }

    func testMatchingRequiresDurationAndConsistentArtistEvenWithISRC() {
        let source = track("source")
        var missingDuration = track("missing"); missingDuration.durationMS = 0
        var wrongDuration = track("long"); wrongDuration.durationMS = 235_000
        var wrongArtist = track("other"); wrongArtist.artist = "Otro artista"
        for candidate in [missingDuration, wrongDuration, wrongArtist] {
            XCTAssertNil(CatalogMatcher.track(source, candidates: [candidate], sourceService: .spotify).selected)
        }
    }

    func testDifferentEditionsAndExplicitVersionsAreNeverAutomaticallySelected() {
        let source = track("source")
        for suffix in [" (Live)", " (Remastered 2024)", " (Deluxe)", " (Acoustic)", " (Radio Edit)"] {
            var candidate = track("candidate"); candidate.title += suffix
            XCTAssertNil(CatalogMatcher.track(source, candidates: [candidate], sourceService: .spotify).selected)
            candidate.title = source.title; candidate.albumTitle += suffix
            XCTAssertNil(CatalogMatcher.track(source, candidates: [candidate], sourceService: .spotify).selected)
        }
        var explicit = track("explicit"); explicit.explicit = true
        var unknown = track("unknown"); unknown.explicit = nil
        XCTAssertNil(CatalogMatcher.track(source, candidates: [explicit], sourceService: .spotify).selected)
        XCTAssertNil(CatalogMatcher.track(source, candidates: [unknown], sourceService: .spotify).selected)
    }

    func testMatchingDoesNotUseNameAloneOrContradictoryIdentifiers() {
        var source = track("source"); source.isrc = nil; source.albumTitle = ""
        var candidate = track("candidate"); candidate.isrc = nil; candidate.albumTitle = ""
        XCTAssertNil(CatalogMatcher.track(source, candidates: [candidate], sourceService: .spotify).selected)
        source = track("source"); candidate = track("candidate"); candidate.isrc = "DIFFERENT"
        XCTAssertNil(CatalogMatcher.track(source, candidates: [candidate], sourceService: .spotify).selected)
    }

    func testCompleteMetadataWithoutISRCAndMinorDurationVariationCanMatch() {
        var source = track("source"); source.isrc = nil
        var candidate = track("candidate"); candidate.isrc = nil; candidate.title = "CANCION"; candidate.durationMS += 900
        let result = CatalogMatcher.track(source, candidates: [candidate], sourceService: .spotify)
        XCTAssertEqual(result.selected, candidate)
        XCTAssertEqual(result.confidence, .exact)
    }

    func testLocalAndUnavailableTracksAreNotAutomaticMatches() {
        var local = track("source"); local.isLocal = true
        var unavailable = track("destination"); unavailable.available = false
        XCTAssertEqual(CatalogMatcher.track(local, candidates: [track("target")], sourceService: .spotify).confidence, .unavailable)
        XCTAssertNil(CatalogMatcher.track(track("source"), candidates: [unavailable], sourceService: .spotify).selected)
    }

    func testIdenticalDuplicateSearchRowsAreDeduplicatedButConflictingIDsAreNot() {
        let candidate = track("candidate")
        XCTAssertEqual(CatalogMatcher.track(track("source"), candidates: [candidate, candidate], sourceService: .spotify).selected, candidate)
        var conflicting = candidate; conflicting.durationMS += 30_000
        XCTAssertNil(CatalogMatcher.track(track("source"), candidates: [candidate, conflicting], sourceService: .spotify).selected)
    }

    func testAlbumTitleAloneIsInsufficientAndPartialAlbumCannotExpand() {
        let source = Album(id: "source", title: "Álbum", artist: "Artista")
        let target = Album(id: "target", title: "Álbum", artist: "Artista")
        XCTAssertNil(CatalogMatcher.album(source, candidates: [target], sourceService: .spotify).selected)
        let partial = Album(id: "partial", title: "Álbum", artist: "Artista", upc: "UPC", tracks: [track("sp-A")], isCompleteAlbum: false)
        let full = Album(id: "full", title: "Álbum", artist: "Artista", upc: "UPC", tracks: [track("am-A")])
        XCTAssertNil(CatalogMatcher.album(partial, candidates: [full], sourceService: .spotify).selected)
    }

    func testAlbumContentsAndEditionMustAgreeEvenWithSameUPC() {
        let source = Album(id: "source", title: "Álbum", artist: "Artista", upc: "UPC", tracks: [track("sp-A")])
        var remaster = Album(id: "remaster", title: "Álbum (Remastered)", artist: "Artista", upc: "UPC", tracks: [track("am-A")])
        XCTAssertNil(CatalogMatcher.album(source, candidates: [remaster], sourceService: .spotify).selected)
        remaster.title = source.title; remaster.tracks[0].explicit = true
        XCTAssertNil(CatalogMatcher.album(source, candidates: [remaster], sourceService: .spotify).selected)
    }

    func testAlbumTrackSequenceProvidesEvidenceAndDuplicateUPCNeedsReview() {
        let source = Album(id: "source", title: "Álbum", artist: "Artista", tracks: [track("sp-A")])
        let target = Album(id: "target", title: "Álbum", artist: "Artista", tracks: [track("am-A")])
        XCTAssertEqual(CatalogMatcher.album(source, candidates: [target], sourceService: .spotify).selected, target)
        var duplicate = target; duplicate.id = "other-edition"
        XCTAssertNil(CatalogMatcher.album(source, candidates: [target, duplicate], sourceService: .spotify).selected)
    }
}
