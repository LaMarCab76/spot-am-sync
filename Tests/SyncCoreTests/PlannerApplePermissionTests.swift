import XCTest
@testable import SyncCore

final class PlannerApplePermissionTests: XCTestCase {
    func testAppleCanEditPermitsOnlyDocumentedAppendWithoutInventingOwnership() {
        let s = Track(id: "s", title: "Luz", artist: "Sur", durationMS: 180000, isrc: "AR0000000001", explicit: false)
        let a = Track(id: "a", title: "Luz", artist: "Sur", durationMS: 180000, isrc: "AR0000000001", explicit: false)
        let left = LibrarySnapshot(account: ConnectedAccount(id: "s-user", service: .spotify, displayName: "S"), playlists: [Playlist(id: "sp", name: "Lista", tracks: [s, s])])
        let right = LibrarySnapshot(account: ConnectedAccount(id: "a-user", service: .appleMusic, displayName: "A"), playlists: [Playlist(id: "ap", name: "Lista", tracks: [a], editable: true, ownership: .unknown)])
        let decisions = MatchDecisions(tracks: [TrackMatch(sourceService: .spotify, source: s, candidates: [a], selected: a, confidence: .exact)], playlists: [PlaylistLink(spotifyID: "sp", appleMusicID: "ap")])
        let plan = SyncPlanner.makePlan(snapshots: [left, right], mode: .spotifyBase, decisions: decisions, capabilities: [.spotify: .spotify, .appleMusic: .appleMusic])
        XCTAssertEqual(plan.executable.map(\.kind), [.addPlaylistTracks])
        var uneditable = right; uneditable.playlists[0].editable = false
        XCTAssertTrue(SyncPlanner.makePlan(snapshots: [left, uneditable], mode: .spotifyBase, decisions: decisions, capabilities: [.spotify: .spotify, .appleMusic: .appleMusic]).executable.isEmpty)
        var reorder = left; reorder.playlists[0].tracks = []
        XCTAssertTrue(SyncPlanner.makePlan(snapshots: [reorder, right], mode: .spotifyBase, decisions: decisions, capabilities: [.spotify: .spotify, .appleMusic: .appleMusic]).executable.isEmpty)
    }
}
