import XCTest
import SyncCore
@testable import MusicProviders

final class ArtworkMappingTests: XCTestCase {
    func testSpotifySongsSavedAlbumsAndSimplifiedAlbumTracksGetTheirCovers() async throws {
        var track = spTrack("song")
        track["album"] = ["name": "Album", "images": [["url": "https://images.example/song.jpg"]]]
        let album: [String: Any] = ["id": "album", "type": "album", "name": "Album", "artists": [["name": "Artist"]],
            "total_tracks": 1, "images": [["url": "https://images.example/album.jpg"]], "tracks": spPage([spTrack("simple")])]
        let transport = ScriptedTransport([spotifyMe,
            .init("/v1/me/tracks", json: spPage([["track": track]])),
            .init("/v1/me/albums", json: spPage([["album": album]])),
            .init("/v1/me/playlists", json: spPage())])
        let provider = try await spotify(transport), library = try await provider.fetchLibrary()
        XCTAssertEqual(library.savedTracks[0].artworkURL, "https://images.example/song.jpg")
        XCTAssertEqual(library.savedAlbums[0].artworkURL, "https://images.example/album.jpg")
        XCTAssertEqual(library.savedAlbums[0].tracks[0].artworkURL, "https://images.example/album.jpg")
        await transport.assertExhausted()
    }

    func testSpotifyAlbumSearchKeepsArtworkOnCandidateAndExpandedTracks() async throws {
        let album: [String: Any] = ["id": "album", "type": "album", "name": "Album", "artists": [["name": "Artist"]],
            "total_tracks": 1, "images": [["url": "https://images.example/album.jpg"]], "tracks": spPage([spTrack("simple")])]
        let transport = ScriptedTransport([spotifyMe, .init("/v1/search", json: ["albums": spPage([album])])])
        let provider = try await spotify(transport)
        let result = try await provider.searchAlbums(matching: Album(id: "source", title: "Album", artist: "Artist"))
        XCTAssertEqual(result.candidates[0].artworkURL, "https://images.example/album.jpg")
        XCTAssertEqual(result.candidates[0].tracks[0].artworkURL, "https://images.example/album.jpg")
        await transport.assertExhausted()
    }

    func testAppleLibraryArtworkTakesPrecedenceOverCatalogAndExpandsTemplates() async throws {
        var librarySong = amSong("1", libraryID: "i.1"), catalogSong = amSong("2")
        var attributes = try XCTUnwrap(librarySong["attributes"] as? [String: Any])
        attributes["artwork"] = ["url": "https://images.example/library/{w}x{h}.jpg"]; librarySong["attributes"] = attributes
        attributes = try XCTUnwrap(catalogSong["attributes"] as? [String: Any])
        attributes["artwork"] = ["url": "https://images.example/catalog/{w}x{h}.jpg"]; catalogSong["attributes"] = attributes
        var fallback = amSong("2", libraryID: "i.2"); fallback["relationships"] = ["catalog": ["data": [catalogSong]]]
        let transport = ScriptedTransport([appleStorefront, .init("/v1/me/library/playlists", json: ["data": []]),
            .init("/v1/me/library/songs", json: ["data": [librarySong, fallback]]),
            .init("/v1/me/library/albums", json: ["data": []])])
        let provider = try await apple(transport), library = try await provider.fetchLibrary()
        XCTAssertEqual(library.savedTracks.map(\.artworkURL), ["https://images.example/library/600x600.jpg", "https://images.example/catalog/600x600.jpg"])
        await transport.assertExhausted()
    }

    func testAppleAlbumSearchMapsArtworkAndUsesItForSimplifiedSongs() async throws {
        let album: [String: Any] = ["id": "a", "type": "albums", "attributes": ["name": "Album", "artistName": "Artist", "trackCount": 1,
            "artwork": ["url": "https://images.example/album/{w}x{h}.jpg"]], "relationships": ["tracks": ["data": [amSong("1")]]]]
        let transport = ScriptedTransport([appleStorefront, .init("/v1/catalog/ar/search", json: ["results": ["albums": ["data": [album]]]])])
        let provider = try await apple(transport)
        let result = try await provider.searchAlbums(matching: Album(id: "source", title: "Album", artist: "Artist"))
        XCTAssertEqual(result.candidates[0].artworkURL, "https://images.example/album/600x600.jpg")
        XCTAssertEqual(result.candidates[0].tracks[0].artworkURL, "https://images.example/album/600x600.jpg")
        await transport.assertExhausted()
    }

    func testITunesUsesReturnedArtworkWithoutInventingResolutionOrCatalogIdentity() async throws {
        let song: [String: Any] = ["wrapperType": "track", "kind": "song", "trackId": 123, "trackName": "Song", "artistName": "Artist",
            "artworkUrl100": "https://images.example/100x100bb.jpg", "artworkUrl60": "https://images.example/60x60bb.jpg"]
        let transport = ScriptedTransport([.init("/search", json: ["resultCount": 1, "results": [song]])])
        let provider = ITunesCatalogSearch(transport: transport)
        var query = TrackSearchQuery(title: "Song", artist: "Artist"); query.country = "AR"
        let result = try await provider.search(query)
        XCTAssertEqual(result.candidates[0].artworkURL, "https://images.example/100x100bb.jpg")
        XCTAssertEqual(result.candidates[0].id, "itunes:123"); XCTAssertNil(result.candidates[0].catalogID)
        await transport.assertExhausted()
    }
}
