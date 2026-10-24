import XCTest
@testable import SyncCore

private actor BatchProvider: MusicProvider {
    nonisolated let service: MusicService
    var snapshot: LibrarySnapshot
    var sent: [SyncOperation] = []
    let rejectAt: Int?
    let uncertain: Bool
    init(_ snapshot: LibrarySnapshot, rejectAt: Int? = nil, uncertain: Bool = false) {
        self.snapshot = snapshot; service = snapshot.account.service; self.rejectAt = rejectAt; self.uncertain = uncertain
    }
    func account() async throws -> ConnectedAccount { snapshot.account }
    func capabilities() async -> ProviderCapabilities { .spotify }
    func fetchLibrary() async throws -> LibrarySnapshot { snapshot }
    func searchTracks(matching track: Track) async throws -> [Track] { [] }
    func searchAlbums(matching album: Album) async throws -> [Album] { [] }
    func perform(_ operation: SyncOperation) async throws -> MutationReceipt {
        sent.append(operation)
        if sent.count == rejectAt {
            if uncertain { throw ProviderError.uncertainWrite("Fixture timeout") }
            throw ProviderError.forbidden("Fixture 403")
        }
        switch operation.kind {
        case .saveTracks: snapshot.savedTracks += operation.tracks
        case .createPlaylist:
            snapshot.playlists.append(.init(id: "created", name: operation.playlistName ?? "", description: operation.playlistDescription ?? "", tracks: operation.tracks))
            return .init(createdID: "created")
        case .addPlaylistTracks:
            let index = snapshot.playlists.firstIndex { $0.id == operation.targetID }!
            snapshot.playlists[index].tracks += operation.tracks
        case .replacePlaylistTracks:
            let index = snapshot.playlists.firstIndex { $0.id == operation.targetID }!
            snapshot.playlists[index].tracks = operation.tracks
        default: break
        }
        return .init()
    }
}

final class MutationBatchTests: XCTestCase {
    func snapshots() -> [LibrarySnapshot] {
        MusicService.allCases.map { .init(account: .init(id: "fixture-\($0.rawValue)", service: $0, displayName: "Fixture")) }
    }
    func store() throws -> SyncStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try .init(url: directory.appendingPathComponent("test.sqlite"))
    }
    func songs(_ count: Int) -> [Track] { (0..<count).map { .init(id: "song\($0)", title: "Song \($0)", artist: "Artist") } }

    func testSecondLibraryChunkRejectedCanReplanWithoutRepeatingFirstForty() async throws {
        let inventory = snapshots(), tracks = songs(41)
        let operation = SyncOperation(service: .spotify, kind: .saveTracks, title: "Save 41", tracks: tracks)
        let plan = SyncPlan(mode: .appleMusicBase, snapshots: inventory, operations: [operation])
        let sp = BatchProvider(inventory[0], rejectAt: 2), am = BatchProvider(inventory[1])
        let providers: [MusicService: any MusicProvider] = [.spotify: sp, .appleMusic: am]
        let storage = try store(), executor = SyncExecutor(store: storage, verificationDelays: [0])
        let run = try await executor.execute(plan: plan, selectedIDs: [operation.id], decisions: .init(), providers: providers)
        XCTAssertEqual(run.executions.map(\.state), [.verified, .rejected])
        XCTAssertEqual(run.executions.map { $0.operation.tracks.count }, [40, 1])
        let recovered = try await executor.reconcile(id: run.id, providers: providers)
        XCTAssertEqual(recovered.executions.map(\.state), [.verified, .rejected])
        let unresolved = try await storage.unresolvedRuns(accountIDs: [.spotify: inventory[0].account.id, .appleMusic: inventory[1].account.id])
        XCTAssertTrue(unresolved.isEmpty)
        let fresh = try await sp.fetchLibrary()
        var remainder = operation; remainder.id = UUID(); remainder.tracks = [tracks.last!]
        let next = SyncPlan(mode: .appleMusicBase, snapshots: [fresh, inventory[1]], operations: [remainder])
        let result = try await executor.execute(plan: next, selectedIDs: [remainder.id], decisions: .init(), providers: providers)
        XCTAssertEqual(result.executions.first?.state, .verified)
        let final = try await sp.fetchLibrary(), sent = await sp.sent
        XCTAssertEqual(final.savedTracks, tracks); XCTAssertEqual(sent.map { $0.tracks.count }, [40, 1, 1])
    }
    func testFirst403DoesNotCreateUncertainHistory() async throws {
        let inventory = snapshots(), op = SyncOperation(service: .spotify, kind: .saveTracks, title: "Save", tracks: songs(1))
        let storage = try store(), sp = BatchProvider(inventory[0], rejectAt: 1)
        let run = try await SyncExecutor(store: storage, verificationDelays: [0]).execute(
            plan: .init(mode: .appleMusicBase, snapshots: inventory, operations: [op]), selectedIDs: [op.id], decisions: .init(),
            providers: [.spotify: sp, .appleMusic: BatchProvider(inventory[1])])
        XCTAssertEqual(run.executions.first?.state, .rejected)
        let blocked = try await storage.unresolvedRuns(accountIDs: [.spotify: inventory[0].account.id])
        XCTAssertTrue(blocked.isEmpty)
    }
    func testUncertainAppendRemainsBlockedAndNeverRepeatsVerifiedPrefix() async throws {
        var inventory = snapshots(); inventory[0].playlists = [.init(id: "p", name: "Playlist")]
        let op = SyncOperation(service: .spotify, kind: .addPlaylistTracks, targetID: "p", title: "Append", tracks: songs(101))
        let storage = try store(), sp = BatchProvider(inventory[0], rejectAt: 2, uncertain: true)
        let executor = SyncExecutor(store: storage, verificationDelays: [0])
        let providers: [MusicService: any MusicProvider] = [.spotify: sp, .appleMusic: BatchProvider(inventory[1])]
        let run = try await executor.execute(plan: .init(mode: .appleMusicBase, snapshots: inventory, operations: [op]), selectedIDs: [op.id], decisions: .init(), providers: providers)
        XCTAssertEqual(run.executions.map(\.state), [.verified, .unknown])
        _ = try await executor.reconcile(id: run.id, providers: providers)
        let sent = await sp.sent, current = try await sp.fetchLibrary()
        XCTAssertEqual(sent.count, 2); XCTAssertEqual(current.playlists[0].tracks.count, 100)
        let blocked = try await storage.unresolvedRuns(accountIDs: [.spotify: inventory[0].account.id])
        XCTAssertEqual(blocked.count, 1)
    }
    func testCreateIDIsDurableBeforeAppendFailure() async throws {
        var inventory = snapshots(); let tracks = songs(101)
        inventory[1].playlists = [.init(id: "source", name: "Playlist", tracks: tracks)]
        let op = SyncOperation(service: .spotify, kind: .createPlaylist, title: "Create", playlistName: "Playlist", tracks: tracks)
        let storage = try store(), sp = BatchProvider(inventory[0], rejectAt: 2)
        let run = try await SyncExecutor(store: storage, verificationDelays: [0]).execute(
            plan: .init(mode: .appleMusicBase, snapshots: inventory, operations: [op]), selectedIDs: [op.id], decisions: .init(),
            providers: [.spotify: sp, .appleMusic: BatchProvider(inventory[1])])
        XCTAssertEqual(run.executions.map(\.state), [.verified, .rejected, .pending])
        XCTAssertEqual(run.executions[0].receipt?.createdID, "created")
        XCTAssertEqual(run.executions[1].operation.targetID, "created")
        XCTAssertEqual(run.decisions.playlists, [.init(spotifyID: "created", appleMusicID: "source")])
        let saved = try await storage.load(id: run.id)
        XCTAssertEqual(saved?.executions[2].createdByOperationID, run.executions[0].id)
    }
    func testLongReplacementPreservesOrderAndMultiplicityAcrossChunks() async throws {
        var inventory = snapshots(); inventory[0].playlists = [.init(id: "p", name: "Playlist")]
        let tracks = Array(repeating: songs(3), count: 67).flatMap { $0 }
        let op = SyncOperation(service: .spotify, kind: .replacePlaylistTracks, targetID: "p", title: "Replace", tracks: tracks, beforeTrackIDs: [])
        let sp = BatchProvider(inventory[0])
        let run = try await SyncExecutor(store: store(), verificationDelays: [0]).execute(
            plan: .init(mode: .appleMusicBase, snapshots: inventory, operations: [op]), selectedIDs: [op.id], decisions: .init(),
            providers: [.spotify: sp, .appleMusic: BatchProvider(inventory[1])])
        XCTAssertEqual(run.executions.map { $0.operation.tracks.count }, [100, 100, 1])
        XCTAssertTrue(run.executions.allSatisfy { $0.state == .verified })
        let final = try await sp.fetchLibrary(); XCTAssertEqual(final.playlists[0].tracks, tracks)
    }
}
