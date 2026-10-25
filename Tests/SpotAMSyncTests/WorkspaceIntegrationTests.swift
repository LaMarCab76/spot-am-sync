import XCTest
import SyncCore
@testable import SpotAMSync

@MainActor
final class WorkspaceIntegrationTests: XCTestCase {
    func testAutomaticLibraryReadDisplaysProgressAndDiscardsCancelledUpdates() async throws {
        let gate = ReadGate(), (model, providers) = try await model(gate: gate)
        model.refreshLibraries()
        try await wait { model.libraryProgress?.received == 50 }
        XCTAssertTrue(model.displayedStatusText.contains("Tus me gusta"))
        XCTAssertTrue(model.snapshots.isEmpty)
        model.cancel(); XCTAssertNil(model.libraryProgress)
        await gate.release(); try await wait { !model.isBusy }
        XCTAssertNil(model.libraryProgress); XCTAssertTrue(model.snapshots.isEmpty)
        for provider in providers.values { let writes = await provider.writes; XCTAssertEqual(writes, 0) }
    }
    private var directory: URL!
    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: directory) }
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("La operación no alcanzó el estado esperado.")
        throw TestError.timeout
    }
    private func model(gate: ReadGate? = nil) async throws -> (AppModel, [MusicService: CountingProvider]) {
        let choices = DemoFixtures.decisions()
        var providers: [MusicService: CountingProvider] = [:]
        for snapshot in DemoFixtures.snapshots() {
            let catalog = choices.tracks.filter { $0.sourceService.other == snapshot.account.service }.compactMap(\.selected)
            providers[snapshot.account.service] = CountingProvider(snapshot: snapshot, catalog: catalog, gate: snapshot.account.service == .spotify ? gate : nil)
        }
        let model = AppModel(storageDirectory: directory, initialProviders: providers.mapValues { $0 as any MusicProvider }, systemServices: false)
        try await wait { model.workspace.loaded && model.canAnalyze }
        return (model, providers)
    }

    func testScheduledProposalReadsAndPersistsWithoutWriting() async throws {
        let (model, providers) = try await model()
        let request = SyncRequest(name: "Programada", mode: .spotifyBase, playlists: [.init(service: .spotify, playlistID: "sp-ruta")], accounts: Array(model.accounts.values))
        var schedule = ReviewSchedule(); schedule.enabled = true; schedule.nextReview = Date(timeIntervalSince1970: 1)
        let profile = model.workspace.addProfile(request: request, schedule: schedule)
        model.workspace.scheduleTick(accounts: Array(model.accounts.values), now: Date().addingTimeInterval(86_400 * 3))
        model.workspaceTick()
        try await wait { model.workspace.state.jobs.first?.state == .ready }
        for provider in providers.values { let writes = await provider.writes; XCTAssertEqual(writes, 0) }
        XCTAssertEqual(model.workspace.state.jobs.first?.request.profileID, profile.id)
        XCTAssertTrue(model.workspace.state.jobs.first?.scheduled == true)
        try await model.workspace.flush()
        let store = try SyncStore(url: directory.appendingPathComponent("library-sync.sqlite"))
        let state = try await store.loadWorkspace()
        XCTAssertEqual(state.jobs.first?.state, .ready)
        XCTAssertNotNil(state.jobs.first?.plan)
    }

    func testCopyConfirmationPersistsTargetAndDoesNotCreateAgain() async throws {
        let (model, providers) = try await model()
        var options = SyncOptions(); options.existingPlaylist = .copy
        model.createSync(name: "Copia", mode: .spotifyBase, playlists: [.init(service: .spotify, playlistID: "sp-cafe")], options: options, schedule: .init())
        try await wait { model.workspace.state.jobs.first?.state == .ready }
        XCTAssertTrue(model.canExecute)
        let initialWrites = await providers[.appleMusic]!.writes; XCTAssertEqual(initialWrites, 0)
        model.executeApproved()
        try await wait { model.lastResult != nil }
        XCTAssertEqual(model.lastResult?.status, .completed)
        let writes = await providers[.appleMusic]!.writes; XCTAssertEqual(writes, 2)
        let profile = try XCTUnwrap(model.workspace.state.profiles.first)
        XCTAssertEqual(profile.request.copyTargets.count, 1)
        let createdID = try XCTUnwrap(profile.request.copyTargets.first?.targetID)
        model.workspace.prepareAgain(model.workspace.state.jobs[0].id)
        try await wait { model.workspace.state.jobs[0].state == .completed }
        XCTAssertFalse(model.plan?.operations.contains { $0.kind == .createPlaylist } ?? true)
        XCTAssertEqual(model.workspace.state.profiles[0].request.copyTargets[0].targetID, createdID)
        let afterWrites = await providers[.appleMusic]!.writes; XCTAssertEqual(afterWrites, writes)
    }

    func testEditingProfileRevokesReadyPreviewAndWritesNothing() async throws {
        let (model, providers) = try await model()
        model.createSync(name: "Revisión", mode: .spotifyBase, playlists: [.init(service: .spotify, playlistID: "sp-ruta")], options: .init(), schedule: .init())
        try await wait { model.workspace.state.jobs.first?.state == .ready }
        let profile = try XCTUnwrap(model.workspace.state.profiles.first)
        model.changeProfile(profile.id) { $0.request.options.skipDuplicates = true }
        XCTAssertFalse(model.canExecute)
        XCTAssertNil(model.plan)
        XCTAssertEqual(model.workspace.state.jobs[0].state, .attention)
        model.executeApproved()
        for provider in providers.values { let writes = await provider.writes; XCTAssertEqual(writes, 0) }
    }

    func testPausedJobCannotBeAppliedFromStaleReviewScreen() async throws {
        let (model, providers) = try await model()
        model.createSync(name: "Pausa", mode: .spotifyBase, playlists: [.init(service: .spotify, playlistID: "sp-ruta")], options: .init(), schedule: .init())
        try await wait { model.workspace.state.jobs.first?.state == .ready }
        model.pauseJob(model.workspace.state.jobs[0])
        XCTAssertFalse(model.canExecute)
        model.executeApproved()
        for provider in providers.values { let writes = await provider.writes; XCTAssertEqual(writes, 0) }
    }

    func testDemoWorkspaceDoesNotOverwriteRealConfigurations() async throws {
        let (model, _) = try await model()
        let request = SyncRequest(name: "Real", mode: .merge, playlists: [.init(service: .spotify, playlistID: "sp-ruta")], accounts: Array(model.accounts.values))
        _ = model.workspace.addProfile(request: request, schedule: .init())
        try await model.workspace.flush()
        model.loadDemo()
        try await wait { !model.isBusy }
        XCTAssertTrue(model.workspace.state.profiles.isEmpty)
        _ = model.workspace.addProfile(request: request, schedule: .init())
        try await model.workspace.flush()
        let store = try SyncStore(url: directory.appendingPathComponent("library-sync.sqlite"))
        let restored = try await store.loadWorkspace()
        XCTAssertEqual(restored.profiles.count, 1)
        XCTAssertEqual(restored.profiles[0].request.name, "Real")
        XCTAssertFalse(restored.profiles[0].isDemo)
    }

    func testScopedAnalysisPreservesEarlierDecisionsOutsideScope() async throws {
        let (model, _) = try await model()
        model.loadDemo()
        try await wait { !model.isBusy }
        let previous = try XCTUnwrap(model.decisions.tracks.first { $0.source.id == "sp-musica" })
        model.createSync(name: "Otra playlist", mode: .spotifyBase, playlists: [.init(service: .spotify, playlistID: "sp-cafe")], options: .init(), schedule: .init())
        try await wait { model.workspace.state.jobs.first?.state == .ready }
        XCTAssertEqual(model.decisions.tracks.first { $0.id == previous.id }, previous)
    }

    func testLegacyImportIgnoresConnectivityAndAutomaticWrites() throws {
        let data = Data(#"{"appleConnected":true,"accounts":{"spotify":{"connected":true}},"settings":{"auto":true,"defaultDirection":"a2s","ifExists":"copy","notifyDone":false,"preferStudio":true}}"#.utf8)
        let prefs = try LegacyPreferencesImporter.decode(data, current: .init())
        XCTAssertEqual(prefs.defaultMode, .appleMusicBase)
        XCTAssertEqual(prefs.options.existingPlaylist, .copy)
        XCTAssertFalse(prefs.notifyDone)
        XCTAssertEqual(prefs.candidateOrder, .studio)
        XCTAssertEqual(prefs.spotifyClientID, "")
    }

    func testCancelledReadDiscardsLateProviderResponse() async throws {
        let gate = ReadGate()
        let (model, providers) = try await model(gate: gate)
        model.createSync(name: "Lectura lenta", mode: .spotifyBase, playlists: [.init(service: .spotify, playlistID: "sp-cafe")], options: .init(), schedule: .init())
        for _ in 0..<200 {
            if await gate.entered { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let entered = await gate.entered; XCTAssertTrue(entered)
        model.cancel(); await gate.release()
        try await wait { model.workspace.state.jobs[0].state == .paused }
        XCTAssertNil(model.plan)
        for provider in providers.values { let writes = await provider.writes; XCTAssertEqual(writes, 0) }
    }

    func testRebindingConfigurationToOtherAccountDropsOldCopyTargets() async throws {
        let (model, providers) = try await model()
        var options = SyncOptions(); options.existingPlaylist = .copy
        let ref = PlaylistReference(service: .spotify, playlistID: "sp-cafe")
        let request = SyncRequest(name: "Cuenta anterior", mode: .spotifyBase, playlists: [ref], options: options, accounts: Array(model.accounts.values), copyTargets: [PlaylistTarget(source: ref, targetID: "old-account-copy")])
        let profile = model.workspace.addProfile(request: request, schedule: .init())
        model.editingProfileID = profile.id
        model.accounts[.appleMusic]?.id = "different-account"
        model.createSync(name: "Cuenta nueva", mode: .spotifyBase, playlists: [ref], options: options, schedule: .init())
        let changed = try XCTUnwrap(model.workspace.state.profiles.first)
        XCTAssertTrue(changed.request.copyTargets.isEmpty)
        XCTAssertEqual(changed.request.accountIDs[.appleMusic], "different-account")
        try await wait { !model.isBusy }
        for provider in providers.values { let writes = await provider.writes; XCTAssertEqual(writes, 0) }
    }
    private enum TestError: Error { case timeout }
}

private actor CountingProvider: MusicProvider {
    nonisolated let service: MusicService
    let inner: DemoMusicProvider
    let gate: ReadGate?
    private(set) var writes = 0
    init(snapshot: LibrarySnapshot, catalog: [Track], gate: ReadGate? = nil) { service = snapshot.account.service; inner = DemoMusicProvider(snapshot: snapshot, catalogTracks: catalog); self.gate = gate }
    func account() async throws -> ConnectedAccount { try await inner.account() }
    func capabilities() async -> ProviderCapabilities { await inner.capabilities() }
    func fetchLibrary() async throws -> LibrarySnapshot { await gate?.wait(); return try await inner.fetchLibrary() }
    func fetchLibrary(progress: @escaping LibraryReadObserver) async throws -> LibrarySnapshot {
        if service == .spotify { await progress(.init(stage: .savedTracks, received: 50, total: 100)) }
        await gate?.wait()
        if service == .spotify { await progress(.init(stage: .playlistTracks, received: 2, total: 2)) }
        return try await inner.fetchLibrary()
    }
    func searchTracks(matching track: Track) async throws -> CatalogSearchResult<Track> { try await inner.searchTracks(matching: track) }
    func searchAlbums(matching album: Album) async throws -> CatalogSearchResult<Album> { try await inner.searchAlbums(matching: album) }
    func perform(_ operation: SyncOperation) async throws -> MutationReceipt { writes += 1; return try await inner.perform(operation) }
}

private actor ReadGate {
    private(set) var entered = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        entered = true
        if !released { await withCheckedContinuation { continuation = $0 } }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}
