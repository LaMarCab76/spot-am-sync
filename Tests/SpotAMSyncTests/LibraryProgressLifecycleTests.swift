import XCTest
import SyncCore
@testable import SpotAMSync

@MainActor
final class LibraryProgressLifecycleTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("progress-lifecycle-" + UUID().uuidString)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: directory) }

    func testSpotifyProgressEndsBeforeAppleReadAndRejectsLateSpotifyEvents() async throws {
        let (sync, spotify, apple) = try await fixture()
        sync.readSources(xml: nil, useOfficialApple: true, isDemo: false)
        try await wait { await spotify.readCount == 1 }
        let event = LibraryReadProgress(stage: .playlistTracks, received: 1, total: 2, itemName: "Primera")
        await spotify.emit(event, read: 0)
        XCTAssertEqual(sync.libraryProgress, event)
        XCTAssertTrue(sync.isReadingSources)
        await spotify.finish(read: 0)
        try await wait { await apple.readCount == 1 }
        XCTAssertNil(sync.libraryProgress)
        XCTAssertTrue(sync.isReadingSources)
        let presentation = LibraryProgressPresentation(sync: sync)
        XCTAssertEqual(presentation.title, "Leyendo fuentes")
        XCTAssertEqual(presentation.detail, "Leyendo Apple Music…")
        XCTAssertNil(presentation.fraction)
        await spotify.emit(event, read: 0)
        XCTAssertNil(sync.libraryProgress, "A finished provider must not replace the next source's status.")
        await apple.finish(read: 0)
        try await wait { !sync.isWorking }
        XCTAssertFalse(sync.isReadingSources)
        XCTAssertNotNil(sync.library)
        XCTAssertNotNil(sync.lastCompletedSourceReadID)
        XCTAssertNil(sync.libraryProgress)
        try await sync.flush()
        let writes = await spotify.writes + apple.writes
        XCTAssertEqual(writes, 0)
    }

    func testCancellationClearsProgressImmediatelyAndOldObserverCannotReplaceRestart() async throws {
        let (sync, spotify, _) = try await fixture()
        let xml = ManualMusicLibrary(id: "test-xml", fileName: "Test.xml", tracks: [])
        sync.readSources(xml: xml, useOfficialApple: false, isDemo: false)
        try await wait { await spotify.readCount == 1 }
        let old = LibraryReadProgress(stage: .playlistTracks, received: 1, total: 10, itemName: "Anterior")
        await spotify.emit(old, read: 0)
        sync.cancel()
        XCTAssertNil(sync.libraryProgress)
        await spotify.emit(old, read: 0)
        XCTAssertNil(sync.libraryProgress)
        await spotify.finish(read: 0)
        try await wait { !sync.isWorking }
        XCTAssertFalse(sync.isReadingSources)
        XCTAssertNil(sync.library)
        XCTAssertNil(sync.lastCompletedSourceReadID)

        sync.readSources(xml: xml, useOfficialApple: false, isDemo: false)
        try await wait { await spotify.readCount == 2 }
        let fresh = LibraryReadProgress(stage: .savedTracks, received: 50, total: 100)
        await spotify.emit(fresh, read: 1)
        await spotify.emit(old, read: 0)
        XCTAssertEqual(sync.libraryProgress, fresh)
        await spotify.finish(read: 1)
        try await wait { !sync.isWorking }
        XCTAssertNotNil(sync.library)
        XCTAssertNil(sync.libraryProgress)
        let completedRead = try XCTUnwrap(sync.lastCompletedSourceReadID)

        // A cancelled refresh keeps the previous sources, but is not a successful
        // read that should advance the wizard to its next step.
        sync.readSources(xml: xml, useOfficialApple: false, isDemo: false)
        try await wait { await spotify.readCount == 3 }
        await spotify.emit(old, read: 2)
        sync.cancel()
        await spotify.finish(read: 2)
        try await wait { !sync.isWorking }
        XCTAssertNotNil(sync.library)
        XCTAssertEqual(sync.lastCompletedSourceReadID, completedRead)
        XCTAssertNil(sync.libraryProgress)
        try await sync.flush()
        let writes = await spotify.writes
        XCTAssertEqual(writes, 0)
    }

    func testFailedReadStopsIndeterminateProgressAndKeepsFailureVisible() async throws {
        let (sync, spotify, _) = try await fixture()
        sync.readSources(xml: .init(id: "xml", fileName: "Test.xml", tracks: []), useOfficialApple: false, isDemo: false)
        try await wait { await spotify.readCount == 1 }
        await spotify.emit(.init(stage: .playlistList, waitingUntil: Date().addingTimeInterval(30)), read: 0)
        await spotify.finish(read: 0, fail: true)
        try await wait { !sync.isWorking }
        XCTAssertFalse(sync.isReadingSources)
        XCTAssertNil(sync.libraryProgress)
        XCTAssertNotNil(sync.errorMessage)
        XCTAssertNil(sync.lastCompletedSourceReadID)
        let presentation = LibraryProgressPresentation(sync: sync)
        XCTAssertFalse(presentation.isWorking)
        XCTAssertNil(presentation.fraction)
        XCTAssertEqual(presentation.detail, "No se pudieron actualizar las fuentes.")
        await spotify.emit(.init(stage: .savedTracks), read: 0)
        XCTAssertNil(sync.libraryProgress)
        try await sync.flush()
    }

    private func fixture() async throws -> (LibrarySyncCoordinator, ProgressLifecycleProvider, ProgressLifecycleProvider) {
        let spotify = ProgressLifecycleProvider(service: .spotify), apple = ProgressLifecycleProvider(service: .appleMusic)
        let sync = LibrarySyncCoordinator()
        sync.start(store: try SyncStore(url: directory.appendingPathComponent("test.sqlite")), externalBusy: { false })
        try await wait { sync.loaded }
        sync.setProviders([.spotify: spotify, .appleMusic: apple], isDemo: false)
        return (sync, spotify, apple)
    }

    private func wait(_ condition: () async -> Bool) async throws {
        for _ in 0..<300 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Progress lifecycle timed out")
        throw ProviderError.invalidResponse("Test timeout")
    }
}

private actor ProgressLifecycleProvider: MusicProvider {
    nonisolated let service: MusicService
    private(set) var readCount = 0
    private(set) var writes = 0
    private var observers: [Int: LibraryReadObserver] = [:]
    private var gates: [Int: CheckedContinuation<Void, Never>] = [:]
    private var failures = Set<Int>()

    init(service: MusicService) { self.service = service }
    func account() async throws -> ConnectedAccount { .init(id: "test-\(service.rawValue)", service: service, displayName: "Synthetic") }
    func capabilities() async -> ProviderCapabilities { service == .spotify ? .spotify : .appleMusic }
    func fetchLibrary() async throws -> LibrarySnapshot { try await fetchLibrary(progress: { _ in }) }
    func fetchLibrary(progress: @escaping LibraryReadObserver) async throws -> LibrarySnapshot {
        let index = readCount; readCount += 1; observers[index] = progress
        // Deliberately returns even after cancellation to exercise the coordinator's guard.
        await withCheckedContinuation { gates[index] = $0 }
        if failures.contains(index) { throw ProviderError.invalidResponse("Synthetic read failure") }
        return LibrarySnapshot(account: try await account())
    }
    func emit(_ progress: LibraryReadProgress, read: Int) async { await observers[read]?(progress) }
    func finish(read: Int, fail: Bool = false) {
        if fail { failures.insert(read) }
        gates.removeValue(forKey: read)?.resume()
    }
    func searchTracks(matching track: Track) async throws -> CatalogSearchResult<Track> { .init() }
    func searchAlbums(matching album: Album) async throws -> CatalogSearchResult<Album> { .init() }
    func catalogTrack(id: String) async throws -> Track? { nil }
    func perform(_ operation: SyncOperation) async throws -> MutationReceipt {
        writes += 1; throw ProviderError.unsupported("No writes in progress tests")
    }
}
