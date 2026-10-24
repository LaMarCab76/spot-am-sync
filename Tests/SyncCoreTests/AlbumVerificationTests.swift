import XCTest
@testable import SyncCore

final class AlbumVerificationTests: XCTestCase {
    func testPartialLibraryAlbumDoesNotVerifyWholeAlbumSave() {
        let account = ConnectedAccount(id: "apple-grant", service: .appleMusic, displayName: "Ejemplo")
        let song = Track(id: "catalog-song", title: "Tema", artist: "Artista")
        let full = Album(id: "catalog-album", title: "Álbum", artist: "Artista", tracks: [song])
        let before = LibrarySnapshot(account: account)
        let partial = Album(id: "library-album", catalogID: full.id, title: full.title, artist: full.artist, tracks: [song], isCompleteAlbum: false)
        let after = LibrarySnapshot(account: account, savedAlbums: [partial])
        let operation = SyncOperation(service: .appleMusic, kind: .saveAlbums, title: "Guardar álbum", albums: [full])
        XCTAssertNil(OperationVerifier.receipt(for: operation, before: before, after: after))
    }

    func testCompleteLibraryAlbumVerifiesUsingCatalogIdentity() {
        let account = ConnectedAccount(id: "apple-grant", service: .appleMusic, displayName: "Ejemplo")
        let full = Album(id: "catalog-album", title: "Álbum", artist: "Artista")
        let before = LibrarySnapshot(account: account)
        var saved = full; saved.id = "library-album"; saved.catalogID = full.id
        let after = LibrarySnapshot(account: account, savedAlbums: [saved])
        let operation = SyncOperation(service: .appleMusic, kind: .saveAlbums, title: "Guardar álbum", albums: [full])
        XCTAssertNotNil(OperationVerifier.receipt(for: operation, before: before, after: after))
    }
}
