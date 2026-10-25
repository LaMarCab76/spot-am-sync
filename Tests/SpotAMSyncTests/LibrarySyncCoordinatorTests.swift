import XCTest
import SyncCore
@testable import SpotAMSync

@MainActor
final class LibrarySyncCoordinatorTests: XCTestCase {
    private var directory: URL!
    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("comparison-ui-" + UUID().uuidString)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: directory) }

    private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<600 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("No se alcanzó el estado esperado de la comparación."); throw TestError.timeout
    }
    private enum TestError: Error { case timeout }

    private func fixture(gated: Bool = false) async throws -> (LibrarySyncCoordinator, ComparisonUIProvider, ComparisonSearchGate, ManualMusicLibrary, SyncStore) {
        let first = Track(id: "apple-a", title: "Luz", artist: "Sur", albumTitle: "Disco", durationMS: 180_000, explicit: false)
        let second = Track(id: "apple-b", title: "Mar", artist: "Sur", albumTitle: "Disco", durationMS: 180_000, explicit: false)
        var spotifyFirst = first; spotifyFirst.id = "spotify-a"; spotifyFirst.catalogID = "spotify-a"
        var spotifySecond = second; spotifySecond.id = "spotify-b"; spotifySecond.catalogID = "spotify-b"
        let snapshot = LibrarySnapshot(account: .init(id: "spotify-user", service: .spotify, displayName: "S", connectionRevision: "rev"),
                                       playlists: [.init(id: "spotify-list", name: "Otra lista", tracks: [spotifyFirst])])
        let tracks = gated ? [first, second] : [first]
        let library = ManualMusicLibrary(id: "apple-music-xml:0123456789ABCDEF", fileName: "Music.xml", tracks: tracks,
            inventory: .init(playlists: [], trackInfo: Dictionary(uniqueKeysWithValues: tracks.enumerated().map {
                ($0.element.id, XMLTrackInfo(referenceID: $0.offset + 1, playlistOnly: false))
            })), documentDigest: "approved-document")
        let gate = ComparisonSearchGate(enabled: gated)
        let provider = ComparisonUIProvider(snapshot: snapshot, catalog: [spotifyFirst, spotifySecond], gate: gate)
        let store = try SyncStore(url: directory.appendingPathComponent("library-sync.sqlite"))
        let coordinator = LibrarySyncCoordinator()
        coordinator.start(store: store, externalBusy: { false })
        try await wait { coordinator.loaded }
        coordinator.setProviders([.spotify: provider], isDemo: false)
        coordinator.readSources(xml: library, useOfficialApple: false, isDemo: false)
        try await wait { !coordinator.isWorking && coordinator.library != nil }
        return (coordinator, provider, gate, library, store)
    }

    func testReviewCanApproveWhileAnalysisRunsAndOnlyFrozenItemsApply() async throws {
        let (coordinator, provider, gate, _, _) = try await fixture(gated: true)
        coordinator.configure(mode: .appleMusicBase, songs: .prepare, albums: .exclude)
        try await wait { coordinator.isAnalyzing && !coordinator.readyDifferences.isEmpty }
        let approved = try XCTUnwrap(coordinator.readyDifferences.first)
        coordinator.approve([approved.id])
        XCTAssertEqual(coordinator.session.batches.count, 1)
        XCTAssertEqual(coordinator.session.batches[0].differenceIDs, [approved.id])
        XCTAssertTrue(coordinator.isAnalyzing)
        let before = await provider.writeCount(); XCTAssertEqual(before, 0)
        await gate.release()
        try await wait { !coordinator.isWorking && coordinator.session.batches.first?.state == .verified }
        let after = await provider.savedIDs()
        XCTAssertEqual(after, ["spotify-a"])
        XCTAssertTrue(coordinator.readyDifferences.contains { $0.tracks.contains { $0.playableID == "spotify-b" } })
        let calls = await provider.writeCount(); XCTAssertEqual(calls, 1)
    }

    func testAnalysisAndConfigurationNeverAuthorizeWrites() async throws {
        let (coordinator, provider, _, _, _) = try await fixture()
        coordinator.configure(mode: .appleMusicBase, songs: .prepare, albums: .exclude)
        try await wait { !coordinator.isWorking }
        XCTAssertFalse(coordinator.readyDifferences.isEmpty)
        let calls = await provider.writeCount(); XCTAssertEqual(calls, 0)
        XCTAssertTrue(coordinator.session.batches.isEmpty)
    }

    func testConfirmedTransferIsIdempotentOnSecondComparison() async throws {
        let (coordinator, provider, _, _, _) = try await fixture()
        coordinator.configure(mode: .appleMusicBase, songs: .prepare, albums: .exclude)
        try await wait { !coordinator.isWorking }
        coordinator.approve(Set(coordinator.readyDifferences.map(\.id)))
        try await wait { !coordinator.isWorking && coordinator.session.batches.first?.state == .verified }
        coordinator.prepare(); try await wait { !coordinator.isWorking }
        XCTAssertTrue(coordinator.readyDifferences.isEmpty)
        let calls = await provider.writeCount(); XCTAssertEqual(calls, 1)
    }

    func testRestoredReviewDoesNotResumeApprovedWrites() async throws {
        let (coordinator, provider, _, _, store) = try await fixture()
        coordinator.configure(mode: .appleMusicBase, songs: .notify, albums: .exclude)
        try await wait { !coordinator.isWorking }
        try await coordinator.flush()
        let restored = LibrarySyncCoordinator()
        restored.start(store: store, externalBusy: { false })
        try await wait { restored.loaded }
        XCTAssertNotNil(restored.library)
        XCTAssertEqual(restored.session.songPolicy, .notify)
        XCTAssertFalse(restored.isWorking)
        let calls = await provider.writeCount(); XCTAssertEqual(calls, 0)
    }

    func testBaselineRequiresResolvedDifferences() async throws {
        let (coordinator, _, _, _, _) = try await fixture()
        coordinator.configure(mode: .appleMusicBase, songs: .prepare, albums: .exclude)
        try await wait { !coordinator.isWorking }
        coordinator.establishBaseline()
        XCTAssertNil(coordinator.session.baseline)
        XCTAssertNotNil(coordinator.errorMessage)
        for difference in coordinator.report.differences { coordinator.omit(difference) }
        coordinator.establishBaseline()
        XCTAssertNotNil(coordinator.session.baseline)
    }

    func testChoosingMissingSideOfLinkedPlaylistPreparesSeparateRemovalWithoutWriting() async throws {
        let (coordinator, provider, _, _, _) = try await fixture()
        coordinator.link(appleID: "missing-apple-playlist", spotifyID: "spotify-list")
        coordinator.selectPlaylists(apple: ["missing-apple-playlist"], spotify: ["spotify-list"])
        try await wait { !coordinator.isWorking }
        let difference = try XCTUnwrap(coordinator.report.differences.first { $0.scope == .playlists && $0.appleMusicTrackIDs == nil && $0.spotifyTrackIDs != nil })
        coordinator.resolve(difference, prefer: .appleMusic)
        try await wait { coordinator.report.removals.contains { $0.unitID == difference.unitID } }
        let proposal = try XCTUnwrap(coordinator.report.removals.first { $0.unitID == difference.unitID })
        XCTAssertEqual(proposal.spotifyOperations.first?.kind, .removePlaylist)
        XCTAssertEqual(proposal.spotifyOperations.first?.targetID, "spotify-list")
        XCTAssertFalse(coordinator.readyDifferences.contains { $0.unitID == difference.unitID })
        let writes = await provider.writeCount(); XCTAssertEqual(writes, 0)
    }
}

private actor ComparisonSearchGate {
    private var enabled: Bool
    private var continuations: [CheckedContinuation<Void, Never>] = []
    init(enabled: Bool) { self.enabled = enabled }
    func wait() async {
        if enabled { await withCheckedContinuation { continuations.append($0) } }
    }
    func release() { enabled = false; let pending = continuations; continuations = []; pending.forEach { $0.resume() } }
}

private actor ComparisonUIProvider: MusicProvider {
    nonisolated let service = MusicService.spotify
    private var snapshot: LibrarySnapshot
    private let catalog: [Track]
    private let gate: ComparisonSearchGate
    private var writes = 0
    init(snapshot: LibrarySnapshot, catalog: [Track], gate: ComparisonSearchGate) { self.snapshot = snapshot; self.catalog = catalog; self.gate = gate }
    func account() async throws -> ConnectedAccount { snapshot.account }
    func capabilities() async -> ProviderCapabilities { .spotify }
    func fetchLibrary() async throws -> LibrarySnapshot { snapshot }
    func searchTracks(matching track: Track) async throws -> CatalogSearchResult<Track> {
        await gate.wait(); return .init(candidates: catalog.filter { $0.title == track.title })
    }
    func searchAlbums(matching album: Album) async throws -> CatalogSearchResult<Album> { .init() }
    func catalogTrack(id: String) async throws -> Track? { catalog.first { $0.playableID == id } }
    func perform(_ operation: SyncOperation) async throws -> MutationReceipt {
        writes += 1
        guard operation.kind == .saveTracks else { throw ProviderError.unsupported("Sólo altas de canciones en esta prueba.") }
        for track in operation.tracks where !snapshot.savedTracks.contains(where: { $0.playableID == track.playableID }) { snapshot.savedTracks.append(track) }
        return .init()
    }
    func writeCount() -> Int { writes }
    func savedIDs() -> Set<String> { Set(snapshot.savedTracks.map(\.playableID)) }
}
