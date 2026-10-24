import XCTest
import SyncCore
@testable import SpotAMSync

@MainActor
final class PlaylistLinkModelTests: XCTestCase {
    func testUnlinkStalePlaylistPersistsRevokesApprovalAndRebuildsPreview() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("spotam-unlink-\(UUID().uuidString)")
        let previous = getenv("SPOTAM_DATA_DIR").map { String(cString: $0) }
        setenv("SPOTAM_DATA_DIR", directory.path, 1)
        defer {
            if let previous { setenv("SPOTAM_DATA_DIR", previous, 1) } else { unsetenv("SPOTAM_DATA_DIR") }
            try? FileManager.default.removeItem(at: directory)
        }
        let model = AppModel()
        for _ in 0..<500 where model.isBusy { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertFalse(model.isBusy)
        let spotify = LibrarySnapshot(account: ConnectedAccount(id: "s", service: .spotify, displayName: "S"), playlists: [Playlist(id: "source", name: "List")])
        let apple = LibrarySnapshot(account: ConnectedAccount(id: "a", service: .appleMusic, displayName: "A"))
        let link = PlaylistLink(spotifyID: "source", appleMusicID: "deleted")
        model.accounts = [.spotify: spotify.account, .appleMusic: apple.account]
        model.snapshots = [spotify, apple]
        model.decisions = MatchDecisions(playlists: [link])
        model.rebuildPlan()
        XCTAssertTrue(model.plan!.operations.isEmpty)
        let store = try SyncStore(url: directory.appendingPathComponent("library-sync.sqlite"))
        let record = RunRecord(summary: RunSummary(), plan: model.plan!, decisions: model.decisions, executions: [], checkpoints: model.snapshots)
        try await store.save(record)
        model.unlinkPlaylists(link)
        XCTAssertTrue(model.decisions.playlists.isEmpty)
        XCTAssertEqual(model.plan?.executable.map(\.kind), [.createPlaylist])
        let key = "appleMusic:a:|spotify:s:"
        var saved: MatchDecisions?, revoked = false
        for _ in 0..<500 {
            saved = try await store.loadDecisions(accountPair: key)
            revoked = try await store.load(id: record.id)?.approvalRevoked == true
            if saved?.playlists.isEmpty == true && revoked { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(saved?.playlists, [])
        XCTAssertTrue(revoked)
        model.phase = .syncing
        model.decisions.playlists = [link]
        model.unlinkPlaylists(link)
        XCTAssertEqual(model.decisions.playlists, [link], "No se cambia la política mientras se ejecuta")
    }
}
