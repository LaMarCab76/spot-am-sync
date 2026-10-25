import XCTest
import SyncCore
@testable import SpotAMSync

final class LibrarySyncViewsTests: XCTestCase {
    private func track(_ id: String) -> Track { Track(id: id, title: id, artist: "Artist") }
    private func difference(_ id: String, unit: String? = nil) -> LibraryDifference {
        let operation = SyncOperation(service: .spotify, kind: .saveTracks, title: id, tracks: [track(id)])
        return .init(id: id, unitID: unit ?? id, scope: .songs, category: .addition, destination: .spotify, title: id, tracks: [track(id)], spotifyOperations: [operation])
    }

    func testConfirmationCapturesFiniteIDsWhileLaterResultsRemainUnapproved() {
        let first = difference("first"), later = difference("later")
        let preview = LibraryApprovalPreview(differences: [first], operationsByID: [first.id: first.spotifyOperations])
        XCTAssertTrue(preview.stillMatches([first, later], operations: [first.id: first.spotifyOperations, later.id: later.spotifyOperations]))
        XCTAssertEqual(preview.differenceIDs, [first.id])
        XCTAssertEqual(preview.operations.flatMap(\.tracks).map(\.id), ["first"])
    }

    func testChangedOperationInvalidatesOpenConfirmationEvenWhenDifferenceIDSurvives() {
        let first = difference("first")
        let preview = LibraryApprovalPreview(differences: [first], operationsByID: [first.id: first.spotifyOperations])
        var changed = first.spotifyOperations
        changed[0].targetID = "different-target"
        XCTAssertFalse(preview.stillMatches([first], operations: [first.id: changed]))
        XCTAssertFalse(preview.stillMatches([], operations: [:]))
    }

    func testChangedManualTaskInvalidatesOpenConfirmation() {
        let task = LibraryManualTask(id: "task", differenceID: "difference", kind: .createPlaylist, title: "Original", tracks: [track("a")])
        let original = LibraryDifference(id: "difference", unitID: "playlist", scope: .playlists, category: .addition,
                                         destination: .appleMusic, title: "Playlist", appleMusicTasks: [task])
        let preview = LibraryApprovalPreview(differences: [original], operationsByID: [:])
        var changed = original; changed.appleMusicTasks[0].tracks.append(track("later"))
        XCTAssertFalse(preview.stillMatches([changed], operations: [:]))
        XCTAssertEqual(preview.manualTasks.flatMap(\.tracks).map(\.id), ["a"])
    }

    func testOfficialAppleOperationDoesNotAlsoAppearAsManualTask() {
        let operation = SyncOperation(service: .appleMusic, kind: .saveTracks, title: "Save", tracks: [track("apple")])
        let executable = LibraryManualTask(id: "official", differenceID: "difference", kind: .saveTracks, title: "Official", operation: operation)
        let manual = LibraryManualTask(id: "manual", differenceID: "difference", kind: .replacePlaylistTracks, title: "Manual")
        let difference = LibraryDifference(id: "difference", unitID: "unit", scope: .playlists, category: .addition, title: "Mixed", appleMusicTasks: [executable, manual])
        let preview = LibraryApprovalPreview(differences: [difference], operationsByID: [difference.id: [operation]])
        XCTAssertEqual(preview.operations.count, 1)
        XCTAssertEqual(preview.manualTasks.map(\.id), [manual.id])
    }

    func testDistinctDifferencesInSameUnitDoNotInflateUnitCount() {
        let first = difference("one", unit: "playlist"), second = difference("two", unit: "playlist")
        let preview = LibraryApprovalPreview(differences: [first, second], operationsByID: [:])
        XCTAssertEqual(preview.differenceIDs.count, 2)
        XCTAssertEqual(preview.unitCount, 1)
    }

    func testRemovalAndConflictGroupsRemainSeparateFromPlaylistAdditions() {
        var playlist = difference("playlist")
        playlist.scope = .playlists
        playlist.spotifyOperations = [.init(service: .spotify, kind: .createPlaylist, title: "Empty", tracks: [])]
        XCTAssertEqual(LibraryChangeGroup.of(playlist), .missingPlaylists)
        playlist.category = .removal
        XCTAssertEqual(LibraryChangeGroup.of(playlist), .removals)
        playlist.category = .conflict
        XCTAssertEqual(LibraryChangeGroup.of(playlist), .conflicts)
    }

    func testManualCheckmarkCannotEnableBaselineBeforeReadVerification() {
        var session = completeSession()
        let task = LibraryManualTask(id: "manual", differenceID: "difference", kind: .saveTracks, title: "Song")
        var batch = LibraryApprovalBatch(sourceDigest: "xml", differenceIDs: ["difference"], unitIDs: ["unit"], scope: .init(), operations: [], manualTasks: [task])
        batch.state = .manual
        session.batches = [batch]; session.manualMarks = [task.id]
        XCTAssertFalse(LibrarySyncPresentation.canEstablishBaseline(session, working: false))
        session.batches[0].state = .verified
        XCTAssertTrue(LibrarySyncPresentation.canEstablishBaseline(session, working: false))
    }

    func testBaselineRequiresExplicitlyHandledDifferencesAndIdleState() {
        var session = completeSession()
        let change = difference("unresolved")
        session.report.differences = [change]
        XCTAssertFalse(LibrarySyncPresentation.canEstablishBaseline(session, working: false))
        session.ignored[change.id] = [change.id, change.detail].joined(separator: "|")
        XCTAssertTrue(LibrarySyncPresentation.canEstablishBaseline(session, working: false))
        XCTAssertFalse(LibrarySyncPresentation.canEstablishBaseline(session, working: true))
    }

    func testSeparateConfirmationDescribesRenameAndSequenceWithoutCallingThemPlaylistDeletion() {
        var change = difference("playlist")
        change.scope = .playlists; change.category = .removal
        let rename = SyncOperation(service: .spotify, kind: .renamePlaylist, title: "Rename", playlistName: "Chosen name")
        let sequence = SyncOperation(service: .spotify, kind: .replacePlaylistTracks, title: "List", tracks: [track("a"), track("b"), track("a")])
        let summary = LibrarySyncPresentation.separateChangeSummary(change, operations: [rename, sequence])
        XCTAssertTrue(summary.contains("Chosen name"))
        XCTAssertTrue(summary.contains("Igualar secuencia"))
        XCTAssertTrue(summary.contains("3 apariciones"))
        XCTAssertFalse(summary.contains(OperationKind.removePlaylist.label))
        XCTAssertFalse(LibrarySyncPresentation.requiresDestructiveConfirmation(change, operations: [rename]))
        XCTAssertTrue(LibrarySyncPresentation.requiresDestructiveConfirmation(change, operations: [sequence]))
    }

    private func completeSession() -> LibrarySyncSession {
        var session = LibrarySyncSession()
        session.library = ManualMusicLibrary(id: "library", fileName: "Music.xml", tracks: [], documentDigest: "xml")
        session.spotify = LibrarySnapshot(account: .init(id: "spotify", service: .spotify, displayName: "Spotify"))
        return session
    }
}
