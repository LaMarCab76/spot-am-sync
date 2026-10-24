import XCTest
import SyncCore
@testable import MusicProviders

/// HTTP state, not a MusicProvider mock: exercise planner -> adapter -> journal -> readback.
private actor LibraryHTTP: ProviderHTTPTransport {
    var saved: [String] = []
    var playlist: [String]?
    var playlistName = "List"
    var version = 0
    var failAt: Int?
    let failureStatus: Int?
    var writes: [(String, [String])] = []
    var inspectWrite: (@Sendable () async throws -> Void)?
    init(failAt: Int? = nil, failureStatus: Int? = 403) { self.failAt = failAt; self.failureStatus = failureStatus }
    func permitWrites() { failAt = nil }
    func history() -> [(String, [String])] { writes }
    func inspect(_ action: @escaping @Sendable () async throws -> Void) { inspectWrite = action }
    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        let path = request.url!.path, method = request.httpMethod ?? "GET"
        func json(_ object: Any) throws -> ProviderHTTPResponse {
            .init(statusCode: 200, data: try JSONSerialization.data(withJSONObject: object))
        }
        if method == "GET" {
            switch path {
            case "/v1/me": return try json(["id": "user", "display_name": "Test User"])
            case "/v1/me/playlists":
                return try json(spPage(playlist.map { [["id": "p", "name": playlistName, "description": "", "owner": ["id": "user"], "items": ["total": $0.count], "snapshot_id": String(version)]] } ?? []))
            case "/v1/me/albums": return try json(spPage())
            case "/v1/me/tracks": return try json(spPage(saved.map { ["track": spTrack($0)] }))
            case "/v1/playlists/p/items": return try json(spPage((playlist ?? []).map { ["item": spTrack($0)] }))
            default: XCTFail("Unexpected read: \(path)"); throw ProviderError.invalidResponse("Fixture")
            }
        }
        let ids: [String]
        if path == "/v1/me/library" { ids = (query(request, "uris") ?? "").split(separator: ",").map { String($0.split(separator: ":").last!) } }
        else { ids = ((try body(request)["uris"] as? [String]) ?? []).map { String($0.split(separator: ":").last!) } }
        writes.append((path, ids))
        try await inspectWrite?()
        if writes.count == failAt {
            if let failureStatus { return .init(statusCode: failureStatus) }
            throw URLError(.timedOut)
        }
        switch path {
        case "/v1/me/library": saved += ids; return .init(statusCode: 200)
        case "/v1/me/playlists":
            playlist = []; playlistName = try body(request)["name"] as! String
            return try json(["id": "p"])
        case "/v1/playlists/p/items":
            if method == "PUT" { playlist = ids } else { playlist = (playlist ?? []) + ids }
            version += 1; return try json(["snapshot_id": String(version)])
        default: XCTFail("Unexpected write: \(path)"); throw ProviderError.invalidResponse("Fixture")
        }
    }
}

final class ExecutionIntegrationTests: XCTestCase {
    private func store() throws -> SyncStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("spotam-execution-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try SyncStore(url: directory.appendingPathComponent("journal.sqlite"))
    }
    private func setup(_ http: LibraryHTTP, count: Int, playlist: Bool = false) async throws -> (SpotifyProvider, LibrarySnapshot, LibrarySnapshot, MatchDecisions, SyncPlan) {
        let provider = SpotifyProvider(clientID: "fixture", transport: http, credentialStore: MemoryCredentialStore(), authorizer: RejectBrowser(), retryPolicy: .init(maximumReadAttempts: 1))
        _ = try await provider.connect()
        let spotify = try await provider.fetchLibrary()
        let targets = (0..<count).map { Track(id: "s\($0)", catalogID: "s\($0)", title: "Song s\($0)", artist: "Artist", albumTitle: "Album", durationMS: 120000, isrc: "ARTEST1234567") }
        let sources = targets.enumerated().map { index, track -> Track in var t = track; t.id = "a\(index)"; t.catalogID = t.id; return t }
        let apple = LibrarySnapshot(account: ConnectedAccount(id: "apple-test", service: .appleMusic, displayName: "A", connectionRevision: "fixed"),
                                    playlists: playlist ? [Playlist(id: "source", name: "List", tracks: sources)] : [], savedTracks: playlist ? [] : sources)
        let decisions = MatchDecisions(tracks: zip(sources, targets).map { TrackMatch(sourceService: .appleMusic, source: $0, candidates: [$1], selected: $1, confidence: .exact) })
        let plan = SyncPlanner.makePlan(snapshots: [spotify, apple], mode: .appleMusicBase, decisions: decisions, capabilities: [.spotify: .spotify, .appleMusic: .appleMusic])
        return (provider, spotify, apple, decisions, plan)
    }

    func testDefinitiveInitialRejectionsDoNotBlockNewApprovedRun() async throws {
        for status in [400, 401, 403, 429] {
            let http = LibraryHTTP(failAt: 1, failureStatus: status)
            let (provider, spotify, apple, decisions, plan) = try await setup(http, count: 1)
            let store = try store(), executor = SyncExecutor(store: store, verificationDelays: [0])
            let providers: [MusicService: any MusicProvider] = [.spotify: provider, .appleMusic: DemoMusicProvider(snapshot: apple)]
            let first = try await executor.execute(plan: plan, selectedIDs: Set(plan.executable.map(\.id)), decisions: decisions, providers: providers)
            XCTAssertEqual(first.executions.map(\.state), [.rejected], "HTTP \(status)")
            let recovered = try await executor.reconcile(id: first.id, providers: providers)
            XCTAssertEqual(recovered.executions.map(\.state), [.rejected])
            let unresolved = try await store.unresolvedRuns(accountIDs: [.spotify: spotify.account.id])
            XCTAssertTrue(unresolved.isEmpty)
            await http.permitWrites()
            let next = try await executor.execute(plan: plan, selectedIDs: Set(plan.executable.map(\.id)), decisions: decisions, providers: providers)
            XCTAssertEqual(next.executions.map(\.state), [.verified])
        }
    }

    func testFortyOfFortyOneAppliedSurviveRestartAndOnlyMissingSongIsSent() async throws {
        let http = LibraryHTTP(failAt: 2)
        let (provider, spotify, apple, decisions, plan) = try await setup(http, count: 41)
        XCTAssertEqual(plan.executable.count, 1)
        let store = try store(), executor = SyncExecutor(store: store, verificationDelays: [0])
        let providers: [MusicService: any MusicProvider] = [.spotify: provider, .appleMusic: DemoMusicProvider(snapshot: apple)]
        let first = try await executor.execute(plan: plan, selectedIDs: Set(plan.executable.map(\.id)), decisions: decisions, providers: providers)
        XCTAssertEqual(first.executions.filter { $0.state == .verified }.count, 40)
        XCTAssertEqual(first.executions.last?.state, .rejected)
        let storageURL = await store.url
        let restarted = SyncExecutor(store: try SyncStore(url: storageURL), verificationDelays: [0])
        let recovered = try await restarted.reconcile(id: first.id, providers: providers)
        XCTAssertEqual(recovered.summary.verifiedCount, 40)
        let unresolved = try await store.unresolvedRuns(accountIDs: [.spotify: spotify.account.id])
        XCTAssertTrue(unresolved.isEmpty)
        let fresh = try await provider.fetchLibrary()
        let newPlan = SyncPlanner.makePlan(snapshots: [fresh, apple], mode: .appleMusicBase, decisions: decisions, capabilities: [.spotify: .spotify, .appleMusic: .appleMusic])
        XCTAssertEqual(newPlan.executable.flatMap(\.tracks).map(\.id), ["s40"])
        await http.permitWrites()
        let next = try await restarted.execute(plan: newPlan, selectedIDs: Set(newPlan.executable.map(\.id)), decisions: decisions, providers: providers)
        XCTAssertEqual(next.executions.map(\.state), [.verified])
        let writes = await http.history()
        XCTAssertEqual(writes.map { $0.1.count }, [40, 1, 1])
        XCTAssertEqual(writes.last?.1, ["s40"])
    }

    func testTimeoutRemainsUnknownAndBlocksNewRun() async throws {
        let http = LibraryHTTP(failAt: 1, failureStatus: nil)
        let (provider, _, apple, decisions, plan) = try await setup(http, count: 1)
        let store = try store(), executor = SyncExecutor(store: store, verificationDelays: [0])
        let providers: [MusicService: any MusicProvider] = [.spotify: provider, .appleMusic: DemoMusicProvider(snapshot: apple)]
        let first = try await executor.execute(plan: plan, selectedIDs: Set(plan.executable.map(\.id)), decisions: decisions, providers: providers)
        let recovered = try await executor.reconcile(id: first.id, providers: providers)
        XCTAssertEqual(recovered.executions.map(\.state), [.unknown])
        let next = try await executor.execute(plan: plan, selectedIDs: Set(plan.executable.map(\.id)), decisions: decisions, providers: providers)
        XCTAssertEqual(next.summary.status, .failed)
        let writes = await http.history(); XCTAssertEqual(writes.count, 1)
    }

    func testLegacyUnknownCompoundWriteCannotResumeWithNewAdapter() async throws {
        let http = LibraryHTTP()
        let (provider, spotify, apple, decisions, plan) = try await setup(http, count: 41)
        let store = try store()
        let record = RunRecord(summary: RunSummary(status: .interrupted), plan: plan, decisions: decisions,
                               executions: [OperationExecution(operation: plan.executable[0], state: .unknown, before: spotify)], checkpoints: [spotify, apple])
        try await store.save(record)
        let providers: [MusicService: any MusicProvider] = [.spotify: provider, .appleMusic: DemoMusicProvider(snapshot: apple)]
        let result = try await SyncExecutor(store: store, verificationDelays: [0]).resume(id: record.id, providers: providers)
        XCTAssertEqual(result.summary.status, .failed); XCTAssertEqual(result.executions[0].state, .unknown)
        let writes = await http.history(); XCTAssertTrue(writes.isEmpty)
        let unresolved = try await store.unresolvedRuns(accountIDs: [.spotify: "user"])
        XCTAssertEqual(unresolved.count, 1)
    }

    func testCreateReceiptIsDurableAndCancelRestartDoesNotRecreatePlaylist() async throws {
        let http = LibraryHTTP()
        let (provider, _, apple, decisions, plan) = try await setup(http, count: 205, playlist: true)
        let store = try store(), executor = SyncExecutor(store: store, verificationDelays: [0])
        let providers: [MusicService: any MusicProvider] = [.spotify: provider, .appleMusic: DemoMusicProvider(snapshot: apple)]
        let first = try await executor.execute(plan: plan, selectedIDs: Set(plan.executable.map(\.id)), decisions: decisions, providers: providers) { progress in
            if progress.completed == 1 { await executor.cancel() }
        }
        XCTAssertEqual(first.summary.status, .cancelled)
        XCTAssertEqual(first.executions.map(\.state), [.verified, .pending, .pending, .pending])
        let saved = try await store.load(id: first.id)
        XCTAssertEqual(saved?.executions.first?.receipt?.createdID, "p")
        let storageURL = await store.url
        let restarted = SyncExecutor(store: try SyncStore(url: storageURL), verificationDelays: [0])
        let recovered = try await restarted.reconcile(id: first.id, providers: providers)
        XCTAssertEqual(recovered.decisions.playlists, [PlaylistLink(spotifyID: "p", appleMusicID: "source")])
        let newPlan = SyncPlanner.makePlan(snapshots: recovered.finalSnapshots, mode: .appleMusicBase, decisions: recovered.decisions, capabilities: [.spotify: .spotify, .appleMusic: .appleMusic])
        XCTAssertEqual(newPlan.executable.map(\.kind), [.addPlaylistTracks])
        await http.inspect {
            let saved = try await store.load(id: first.id)
            XCTAssertEqual(saved?.executions.first?.receipt?.createdID, "p")
        }
        let final = try await restarted.execute(plan: newPlan, selectedIDs: Set(newPlan.executable.map(\.id)), decisions: recovered.decisions, providers: providers)
        XCTAssertTrue(final.executions.allSatisfy { $0.state == .verified })
        let writes = await http.history()
        XCTAssertEqual(writes.map { $0.1.count }, [0, 100, 100, 5])
        XCTAssertEqual(writes.filter { $0.0 == "/v1/me/playlists" }.count, 1)
        let library = try await provider.fetchLibrary()
        XCTAssertEqual(library.playlists[0].tracks.map(\.id), (0..<205).map { "s\($0)" })
    }
}
