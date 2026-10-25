import XCTest
@testable import SyncCore

/// The provider can commit a request while keeping reads stale until reveal().
private actor SnapshotTransferTestProvider: MusicProvider {
    nonisolated let service: MusicService
    nonisolated var mutationLimits: MutationLimits? { .init(libraryItems: 2, playlistItems: 2) }
    private var actual: LibrarySnapshot
    private var visible: LibrarySnapshot
    private let hiddenTimeout: Bool
    private let journal: SyncStore?
    private var sent: [SyncOperation] = []
    private var dispatchRecords: [RunRecord] = []
    private var accountReads = 0
    private var libraryReads = 0
    private var catalogReads = 0

    init(_ snapshot: LibrarySnapshot, hiddenTimeout: Bool = false, journal: SyncStore? = nil) {
        service = snapshot.account.service; actual = snapshot; visible = snapshot
        self.hiddenTimeout = hiddenTimeout; self.journal = journal
    }
    func account() async throws -> ConnectedAccount { accountReads += 1; return visible.account }
    func capabilities() async -> ProviderCapabilities { .spotify }
    func fetchLibrary() async throws -> LibrarySnapshot {
        libraryReads += 1
        var fresh = visible; fresh.id = UUID(); fresh.fetchedAt = Date(); return fresh
    }
    func searchTracks(matching track: Track) async throws -> CatalogSearchResult<Track> {
        catalogReads += 1; return .init()
    }
    func searchAlbums(matching album: Album) async throws -> CatalogSearchResult<Album> {
        catalogReads += 1; return .init()
    }
    func reveal() { visible = actual }
    func writes() -> [SyncOperation] { sent }
    func recordsAtDispatch() -> [RunRecord] { dispatchRecords }
    func reads() -> (account: Int, library: Int, catalog: Int) { (accountReads, libraryReads, catalogReads) }

    func perform(_ operation: SyncOperation) async throws -> MutationReceipt {
        if let journal, let record = try await journal.recent(limit: 1).first { dispatchRecords.append(record) }
        sent.append(operation)
        var receipt = MutationReceipt()
        switch operation.kind {
        case .createPlaylist:
            let id = "synthetic-created-\(sent.count)"
            actual.playlists.append(.init(id: id, name: operation.playlistName ?? "",
                                          description: operation.playlistDescription ?? "", tracks: operation.tracks,
                                          editable: true, ownership: .owned))
            receipt.createdID = id
        case .addPlaylistTracks:
            guard let index = actual.playlists.firstIndex(where: { $0.id == operation.targetID }) else {
                throw ProviderError.unsupported("Synthetic target is missing")
            }
            actual.playlists[index].tracks += operation.tracks
        case .saveTracks:
            actual.savedTracks += operation.tracks.filter { candidate in
                !actual.savedTracks.contains { $0.playableID == candidate.playableID }
            }
        case .saveAlbums:
            actual.savedAlbums += operation.albums.filter { candidate in
                !actual.savedAlbums.contains { $0.playableID == candidate.playableID }
            }
        case .removeTracks:
            let ids = Set(operation.tracks.map(\.playableID)); actual.savedTracks.removeAll { ids.contains($0.playableID) }
        case .replacePlaylistTracks:
            guard let index = actual.playlists.firstIndex(where: { $0.id == operation.targetID }) else { throw ProviderError.unsupported("Missing target") }
            actual.playlists[index].tracks = operation.tracks
        default:
            XCTFail("Snapshot transfer dispatched an unexpected operation: \(operation.kind)")
        }
        if hiddenTimeout { throw ProviderError.uncertainWrite("Synthetic response lost after commit") }
        visible = actual
        return receipt
    }
}

final class SnapshotTransferTests: XCTestCase {
    func testFiniteOfficialBatchDoesNotReplanOrCountUnapprovedDifferences() async throws {
        let f = try fixture(), journal = try store()
        let apple = LibrarySnapshot(account: .init(id: "apple", service: .appleMusic, displayName: "A", connectionRevision: "a-rev"), savedTracks: f.source.library.tracks)
        let spotifyProvider = SnapshotTransferTestProvider(f.destination)
        let appleProvider = SnapshotTransferTestProvider(apple)
        let selected = SyncOperation(service: .spotify, kind: .saveTracks, title: "Only approved song", tracks: [f.tracks[0]])
        let unselected = SyncOperation(service: .spotify, kind: .saveTracks, title: "Later result", tracks: [f.tracks[1]])
        let plan = SyncPlan(mode: .merge, snapshots: [f.destination, apple], operations: [selected, unselected])
        let executor = SyncExecutor(store: journal, verificationDelays: [0])
        let record = try await executor.execute(plan: plan, selectedIDs: [selected.id], decisions: f.decisions,
            providers: [.spotify: spotifyProvider, .appleMusic: appleProvider], scopedApproval: true)
        XCTAssertEqual(record.summary.status, .completed)
        XCTAssertEqual(record.plan.operations.map(\.id), [selected.id])
        XCTAssertTrue(record.remainingPlan?.operations.isEmpty == true)
        let writes = await spotifyProvider.writes()
        XCTAssertEqual(writes.flatMap(\.tracks).map(\.playableID), [f.tracks[0].playableID])
        XCTAssertTrue(record.summary.message.contains("Lote confirmado"))
    }
    func testSeparateExplicitApprovalCanRemoveOneSavedMembershipWithoutRemovingPlaylistOccurrences() async throws {
        let f = try fixture(), journal = try store()
        var destination = f.destination
        destination.savedTracks = f.tracks
        destination.playlists = [.init(id: "kept-playlist", name: "Keep", tracks: [f.tracks[1], f.tracks[0], f.tracks[1]])]
        let provider = SnapshotTransferTestProvider(destination, journal: journal)
        let source = try SnapshotTransferSource(library: f.source.library, differenceIDs: ["explicit-removal"], allowsDestructive: true)
        let operation = SyncOperation(service: .spotify, kind: .removeTracks, title: "Quitar sólo la membresía elegida", tracks: [f.tracks[1]])
        let record = try await SyncExecutor(store: journal, verificationDelays: [0]).executeSnapshotTransfer(
            source: source, destination: destination, operations: [operation], decisions: f.decisions, provider: provider)
        XCTAssertEqual(record.summary.status, .completed)
        XCTAssertEqual(record.finalSnapshots[0].savedTracks.map(\.playableID), [f.tracks[0].playableID])
        XCTAssertEqual(record.finalSnapshots[0].playlists[0].tracks.map(\.playableID), destination.playlists[0].tracks.map(\.playableID))
        XCTAssertEqual(record.snapshotSource?.allowsDestructive, true)
    }

    func testExplicitSequenceApprovalPreservesTheChosenOrderAndRepeatedOccurrences() async throws {
        let f = try fixture(), journal = try store()
        var destination = f.destination
        destination.playlists = [.init(id: "target", name: "Order", tracks: f.tracks)]
        let desired = [f.tracks[1], f.tracks[0], f.tracks[1]]
        let provider = SnapshotTransferTestProvider(destination)
        let source = try SnapshotTransferSource(library: f.source.library, differenceIDs: ["explicit-sequence"], allowsDestructive: true)
        let operation = SyncOperation(service: .spotify, kind: .replacePlaylistTracks, targetID: "target", title: "Igualar secuencia",
                                      tracks: desired, beforeTrackIDs: f.tracks.map(\.playableID))
        let record = try await SyncExecutor(store: journal, verificationDelays: [0]).executeSnapshotTransfer(
            source: source, destination: destination, operations: [operation], decisions: f.decisions, provider: provider)
        XCTAssertEqual(record.summary.status, .completed)
        XCTAssertEqual(record.finalSnapshots[0].playlists[0].tracks.map(\.playableID), desired.map(\.playableID))
    }
    private func store() throws -> SyncStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("snapshot-transfer-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try SyncStore(url: directory.appendingPathComponent("journal.sqlite"))
    }

    private func fixture() throws -> (source: SnapshotTransferSource, destination: LibrarySnapshot, tracks: [Track], decisions: MatchDecisions) {
        let exported = Date(timeIntervalSince1970: 1_700_000_000)
        let document: [String: Any] = [
            "Library Persistent ID": "0123456789ABCDEF", "Date": exported,
            "Tracks": [
                "1": ["Track ID": 1, "Persistent ID": "0000000000000001", "Name": "Uno", "Artist": "Sintético",
                      "Album": "Exportación", "Total Time": 180_000, "Clean": true, "Playlist Only": false],
                "2": ["Track ID": 2, "Persistent ID": "0000000000000002", "Name": "Dos", "Artist": "Sintético",
                      "Album": "Exportación", "Total Time": 180_000, "Clean": true, "Playlist Only": true]
            ],
            "Playlists": [["Name": "Secuencia aprobada", "Playlist Persistent ID": "0000000000000101",
                           "Playlist Items": [2, 1, 2, 2, 1].map { ["Track ID": $0] }]]
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: document, format: .xml, options: 0)
        let library = try MusicXMLImporter.parse(data, fileName: "Synthetic.xml", importedAt: exported.addingTimeInterval(30))
        let source = try SnapshotTransferSource(library: library, differenceIDs: ["difference:z", "difference:a"],
                                                approvedAt: exported.addingTimeInterval(60))
        let tracks = library.tracks.enumerated().map { index, observed in
            Track(id: "spotify-\(index + 1)", title: observed.title, artist: observed.artist,
                  albumTitle: observed.albumTitle, durationMS: observed.durationMS, explicit: observed.explicit)
        }
        let decisions = MatchDecisions(tracks: zip(library.tracks, tracks).map { observed, candidate in
            var match = TrackMatch(sourceService: .appleMusic, source: observed, candidates: [candidate],
                                   selected: candidate, confidence: .review)
            match.decision = .manual; match.manualSelection = true
            return match
        })
        let destination = LibrarySnapshot(account: .init(id: "synthetic-spotify", service: .spotify, displayName: "Fixture",
                                                        storefront: "AR", connectionRevision: "synthetic-revision"))
        return (source, destination, tracks, decisions)
    }

    func testApprovalRequiresDigestAndInventoryAndKeepsTheActualXMLPayload() throws {
        let fixture = try fixture(), original = fixture.source.library
        var noDigest = original; noDigest.documentDigest = nil
        var emptyDigest = original; emptyDigest.documentDigest = ""
        var noInventory = original; noInventory.inventory = nil
        for library in [noDigest, emptyDigest, noInventory] {
            XCTAssertThrowsError(try SnapshotTransferSource(library: library, differenceIDs: ["difference:a"])) { error in
                guard case SyncExecutionError.invalidSelection = error else { return XCTFail("Unexpected error: \(error)") }
            }
        }
        XCTAssertEqual(fixture.source.library, original)
        XCTAssertEqual(fixture.source.libraryID, original.id)
        XCTAssertEqual(fixture.source.documentDigest, original.documentDigest)
        XCTAssertEqual(fixture.source.importedAt, original.importedAt)
        XCTAssertEqual(fixture.source.exportedAt, original.exportedAt)
        XCTAssertEqual(fixture.source.differenceIDs, ["difference:a", "difference:z"])
    }

    func testRealTransferUsesOnlySpotifyAndDurablyJournalsCreationBeforeOrderedRepeatedAppends() async throws {
        let fixture = try fixture(), storage = try store()
        let order = [fixture.tracks[1], fixture.tracks[0], fixture.tracks[1], fixture.tracks[1], fixture.tracks[0]]
        var operation = SyncOperation(service: .spotify, kind: .createPlaylist, title: "Crear secuencia",
                                      playlistName: "Secuencia aprobada", playlistDescription: "Synthetic export", tracks: order)
        operation.sourcePlaylist = .init(service: .appleMusic, playlistID: try XCTUnwrap(fixture.source.library.inventory?.playlists.first?.id))
        let provider = SnapshotTransferTestProvider(fixture.destination, journal: storage)
        let batchRunID = UUID()
        let result = try await SyncExecutor(store: storage, verificationDelays: [0]).executeSnapshotTransfer(
            source: fixture.source, destination: fixture.destination, operations: [operation], decisions: fixture.decisions,
            provider: provider, runID: batchRunID)
        XCTAssertEqual(result.id, batchRunID)
        XCTAssertEqual(result.summary.status, .completed)
        XCTAssertFalse(result.isDemo)
        XCTAssertEqual(result.executions.map(\.state), [.verified, .verified, .verified, .verified])
        XCTAssertEqual(result.summary.verifiedCount, 4)
        XCTAssertEqual(result.executions.map(\.parentOperationID), Array(repeating: operation.id, count: 4))
        XCTAssertEqual(result.executions.dropFirst().map(\.creationDependencyID), Array(repeating: operation.id, count: 3))
        XCTAssertEqual(result.executions[0].receipt?.createdID, "synthetic-created-1")
        XCTAssertEqual(result.executions.dropFirst().map { $0.operation.targetID }, Array(repeating: "synthetic-created-1", count: 3))
        let writes = await provider.writes(), dispatch = await provider.recordsAtDispatch(), reads = await provider.reads()
        XCTAssertEqual(writes.map(\.kind), [.createPlaylist, .addPlaylistTracks, .addPlaylistTracks, .addPlaylistTracks])
        XCTAssertEqual(writes.map { $0.tracks.count }, [0, 2, 2, 1])
        XCTAssertEqual(writes.flatMap(\.tracks), order)
        XCTAssertTrue(writes.allSatisfy { $0.service == .spotify && !$0.kind.isDestructive })
        XCTAssertEqual(dispatch.count, writes.count)
        XCTAssertEqual(dispatch.first?.snapshotSource?.library, fixture.source.library)
        for (index, saved) in dispatch.enumerated() {
            XCTAssertEqual(saved.id, batchRunID)
            XCTAssertEqual(saved.executions[index].state, .applying)
            XCTAssertNotNil(saved.executions[index].before)
            XCTAssertEqual(saved.executions[index].before?.account.service, .spotify)
            if index > 0 {
                XCTAssertEqual(saved.executions[0].state, .verified)
                XCTAssertEqual(saved.executions[0].receipt?.createdID, "synthetic-created-1")
                XCTAssertEqual(saved.executions[index].operation.targetID, "synthetic-created-1")
            }
        }
        XCTAssertGreaterThan(reads.account, 0); XCTAssertGreaterThan(reads.library, 0); XCTAssertEqual(reads.catalog, 0)
        XCTAssertEqual(result.plan.snapshots.map { $0.account.service }, [.spotify])
        XCTAssertEqual(result.checkpoints.map { $0.account.service }, [.spotify])
        XCTAssertEqual(result.finalSnapshots.map { $0.account.service }, [.spotify])
        XCTAssertEqual(result.finalSnapshots.first?.playlists.first?.tracks, order)
        XCTAssertTrue(result.remainingPlan?.operations.isEmpty == true)
        let databaseURL = await storage.url
        let reopened = try SyncStore(url: databaseURL)
        let saved = try await reopened.load(id: result.id)
        let persisted = try XCTUnwrap(saved)
        XCTAssertEqual(persisted.snapshotSource, fixture.source)
        XCTAssertEqual(persisted.snapshotSource?.library, fixture.source.library)
        XCTAssertEqual(persisted.decisions, result.decisions)
        XCTAssertEqual(persisted.executions, result.executions)
    }

    func testDestructiveAndUnapprovedKindsAreRejectedBeforeAnyProviderAccess() async throws {
        let fixture = try fixture(), storage = try store(), provider = SnapshotTransferTestProvider(fixture.destination)
        let allowed: Set<OperationKind> = [.createPlaylist, .addPlaylistTracks, .saveTracks, .saveAlbums]
        for kind in OperationKind.allCases where !allowed.contains(kind) {
            let operation = SyncOperation(service: .spotify, kind: kind, targetID: "synthetic-playlist", title: "Rejected", tracks: fixture.tracks)
            do {
                _ = try await SyncExecutor(store: storage, verificationDelays: [0]).executeSnapshotTransfer(
                    source: fixture.source, destination: fixture.destination, operations: [operation], decisions: fixture.decisions, provider: provider)
                XCTFail("Accepted \(kind)")
            } catch { guard case SyncExecutionError.invalidSelection = error else { return XCTFail("Unexpected error: \(error)") } }
        }
        let writes = await provider.writes(), reads = await provider.reads(), records = try await storage.recent()
        XCTAssertTrue(writes.isEmpty); XCTAssertEqual(reads.account, 0); XCTAssertEqual(reads.library, 0); XCTAssertTrue(records.isEmpty)
    }

    func testAlteredApprovalEvidenceFailsBeforeProviderReadOrWrite() async throws {
        let fixture = try fixture(), storage = try store(), provider = SnapshotTransferTestProvider(fixture.destination)
        var wrongID = fixture.source; wrongID.libraryID = "different-library"
        var wrongDigest = fixture.source; wrongDigest.documentDigest = "different-document"
        var noInventory = fixture.source; noInventory.library.inventory = nil
        var noDigest = fixture.source; noDigest.library.documentDigest = nil
        let operation = SyncOperation(service: .spotify, kind: .saveTracks, title: "Save", tracks: [fixture.tracks[0]])
        for source in [wrongID, wrongDigest, noInventory, noDigest] {
            let result = try await SyncExecutor(store: storage, verificationDelays: [0]).executeSnapshotTransfer(
                source: source, destination: fixture.destination, operations: [operation], decisions: fixture.decisions, provider: provider)
            XCTAssertEqual(result.summary.status, .failed)
            XCTAssertTrue(result.executions.allSatisfy { $0.state == .pending && $0.before == nil })
        }
        let writes = await provider.writes(), reads = await provider.reads()
        XCTAssertTrue(writes.isEmpty); XCTAssertEqual(reads.account, 0); XCTAssertEqual(reads.library, 0)
    }

    func testNonSpotifyOrInvalidSelectionsCannotReachAProvider() async throws {
        let fixture = try fixture(), storage = try store()
        let spotify = SnapshotTransferTestProvider(fixture.destination)
        var appleDestination = fixture.destination; appleDestination.account.service = .appleMusic
        let apple = SnapshotTransferTestProvider(appleDestination)
        let save = SyncOperation(service: .spotify, kind: .saveTracks, title: "Save", tracks: [fixture.tracks[0]])
        var appleOperation = save; appleOperation.service = .appleMusic
        var blocked = save; blocked.blockedReason = "Requires review"
        var local = save; local.tracks[0].isLocal = true
        var unavailable = save; unavailable.tracks[0].available = false
        var missingID = save; missingID.tracks[0].id = ""
        var partialDestination = fixture.destination; partialDestination.coverage.tracks = false
        let cases: [(LibrarySnapshot, [SyncOperation], SnapshotTransferTestProvider)] = [
            (fixture.destination, [], spotify), (fixture.destination, [save, save], spotify),
            (fixture.destination, [appleOperation], spotify), (appleDestination, [save], spotify),
            (fixture.destination, [save], apple), (partialDestination, [save], spotify),
            (fixture.destination, [blocked], spotify), (fixture.destination, [local], spotify),
            (fixture.destination, [unavailable], spotify), (fixture.destination, [missingID], spotify)
        ]
        for (destination, operations, provider) in cases {
            do {
                _ = try await SyncExecutor(store: storage, verificationDelays: [0]).executeSnapshotTransfer(
                    source: fixture.source, destination: destination, operations: operations, decisions: fixture.decisions, provider: provider)
                XCTFail("Invalid transfer selection was accepted")
            } catch { guard case SyncExecutionError.invalidSelection = error else { return XCTFail("Unexpected error: \(error)") } }
        }
        for provider in [spotify, apple] {
            let writes = await provider.writes(), reads = await provider.reads()
            XCTAssertTrue(writes.isEmpty); XCTAssertEqual(reads.account, 0); XCTAssertEqual(reads.library, 0)
        }
    }

    func testStaleDestinationOrChangedConnectionNeverMutates() async throws {
        let fixture = try fixture()
        var changedTracks = fixture.destination; changedTracks.savedTracks = [fixture.tracks[1]]
        var changedAccount = fixture.destination; changedAccount.account.id = "another-user"
        var changedRevision = fixture.destination; changedRevision.account.connectionRevision = "reconnected"
        var partial = fixture.destination; partial.coverage.playlists = false
        let operation = SyncOperation(service: .spotify, kind: .saveTracks, title: "Save", tracks: [fixture.tracks[0]])
        for actual in [changedTracks, changedAccount, changedRevision, partial] {
            let provider = SnapshotTransferTestProvider(actual), storage = try store()
            let result = try await SyncExecutor(store: storage, verificationDelays: [0]).executeSnapshotTransfer(
                source: fixture.source, destination: fixture.destination, operations: [operation], decisions: fixture.decisions, provider: provider)
            XCTAssertEqual(result.summary.status, .failed)
            let writes = await provider.writes()
            XCTAssertTrue(writes.isEmpty)
            XCTAssertNil(result.executions.first?.before)
        }
    }

    func testTimeoutBlocksNewXMLAndOfficialRunsAcrossExecutorRestart() async throws {
        let fixture = try fixture(), storage = try store()
        let provider = SnapshotTransferTestProvider(fixture.destination, hiddenTimeout: true)
        let operation = SyncOperation(service: .spotify, kind: .saveTracks, title: "Uncertain save", tracks: [fixture.tracks[0]])
        let first = try await SyncExecutor(store: storage, verificationDelays: [0]).executeSnapshotTransfer(
            source: fixture.source, destination: fixture.destination, operations: [operation], decisions: fixture.decisions, provider: provider)
        XCTAssertEqual(first.executions.map(\.state), [.unknown])
        XCTAssertNotNil(first.executions[0].before)
        let databaseURL = await storage.url
        let reopened = try SyncStore(url: databaseURL), executor = SyncExecutor(store: reopened, verificationDelays: [0])
        let next = SyncOperation(service: .spotify, kind: .saveTracks, title: "Other save", tracks: [fixture.tracks[1]])
        let blockedXML = try await executor.executeSnapshotTransfer(source: fixture.source, destination: fixture.destination,
            operations: [next], decisions: fixture.decisions, provider: provider)
        XCTAssertEqual(blockedXML.summary.status, .failed)
        XCTAssertNil(blockedXML.executions.first?.before)
        let apple = LibrarySnapshot(account: .init(id: "synthetic-apple", service: .appleMusic, displayName: "Unused", connectionRevision: "apple-revision"))
        let appleProvider = SnapshotTransferTestProvider(apple)
        let officialOperation = SyncOperation(service: .appleMusic, kind: .saveTracks, title: "Official save", tracks: [fixture.tracks[1]])
        let officialPlan = SyncPlan(mode: .spotifyBase, snapshots: [fixture.destination, apple], operations: [officialOperation])
        let blockedOfficial = try await executor.execute(plan: officialPlan, selectedIDs: [officialOperation.id], decisions: .init(),
                                                        providers: [.spotify: provider, .appleMusic: appleProvider])
        XCTAssertEqual(blockedOfficial.summary.status, .failed)
        XCTAssertNil(blockedOfficial.executions.first?.before)
        let writes = await provider.writes(), appleWrites = await appleProvider.writes(), appleReads = await appleProvider.reads()
        XCTAssertEqual(writes.count, 1); XCTAssertTrue(appleWrites.isEmpty)
        XCTAssertEqual(appleReads.account, 0); XCTAssertEqual(appleReads.library, 0)
        let unresolved = try await reopened.unresolvedRuns(accountIDs: [.spotify: fixture.destination.account.id])
        XCTAssertEqual(unresolved.map(\.id), [first.id])
    }

    func testReconcileOnlyReadsAndResumeNeverResendsOrAppendsPendingTransferSteps() async throws {
        let fixture = try fixture(), storage = try store()
        var destination = fixture.destination
        destination.playlists = [.init(id: "existing", name: "Existing", editable: true, ownership: .owned)]
        let order = [fixture.tracks[1], fixture.tracks[0], fixture.tracks[1]]
        let operation = SyncOperation(service: .spotify, kind: .addPlaylistTracks, targetID: "existing", title: "Append",
                                      tracks: order, beforeTrackIDs: [])
        let provider = SnapshotTransferTestProvider(destination, hiddenTimeout: true)
        let first = try await SyncExecutor(store: storage, verificationDelays: [0]).executeSnapshotTransfer(
            source: fixture.source, destination: destination, operations: [operation], decisions: fixture.decisions, provider: provider)
        XCTAssertEqual(first.executions.map(\.state), [.unknown, .pending])
        let databaseURL = await storage.url
        let executor = SyncExecutor(store: try SyncStore(url: databaseURL), verificationDelays: [0])
        for reveal in [false, true] {
            if reveal { await provider.reveal() }
            let reconciled = try await executor.reconcile(id: first.id, providers: [.spotify: provider])
            XCTAssertEqual(reconciled.executions.map(\.state), [reveal ? .verified : .unknown, .pending])
            XCTAssertTrue(reconciled.approvalRevoked)
            XCTAssertNil(reconciled.remainingPlan)
            XCTAssertEqual(reconciled.snapshotSource?.library, fixture.source.library)
            XCTAssertEqual(reconciled.executions[0].before, first.executions[0].before)
            do {
                _ = try await executor.resume(id: first.id, providers: [.spotify: provider])
                XCTFail("XML approval was reused")
            } catch { guard case SyncExecutionError.unsafeResume = error else { return XCTFail("Unexpected error: \(error)") } }
            let writes = await provider.writes()
            XCTAssertEqual(writes.count, 1)
        }
        let visible = try await provider.fetchLibrary(), writes = await provider.writes()
        XCTAssertEqual(visible.playlists[0].tracks, Array(order.prefix(2)))
        XCTAssertEqual(writes.flatMap(\.tracks), Array(order.prefix(2)))
        let unresolved = try await storage.unresolvedRuns(accountIDs: [.spotify: destination.account.id])
        XCTAssertTrue(unresolved.isEmpty)
    }

    func testReusingRunIDCannotOverwriteUncertainXMLJournalOrDispatchAnotherTransferOrOfficialRun() async throws {
        for official in [false, true] {
            let fixture = try fixture(), storage = try store(), batchRunID = UUID()
            var destination = fixture.destination
            destination.playlists = [.init(id: "existing", name: "Existing", editable: true, ownership: .owned)]
            let spotify = SnapshotTransferTestProvider(destination, hiddenTimeout: true)
            let operation = SyncOperation(service: .spotify, kind: .addPlaylistTracks, targetID: "existing", title: "Append once",
                                          tracks: fixture.tracks, beforeTrackIDs: [])
            let first = try await SyncExecutor(store: storage, verificationDelays: [0]).executeSnapshotTransfer(
                source: fixture.source, destination: destination, operations: [operation], decisions: fixture.decisions,
                provider: spotify, runID: batchRunID)
            XCTAssertEqual(first.executions.map(\.state), [.unknown])
            let appleSnapshot = LibrarySnapshot(account: .init(id: "synthetic-apple", service: .appleMusic,
                                                               displayName: "Unused", connectionRevision: "synthetic-revision"))
            let apple = SnapshotTransferTestProvider(appleSnapshot)
            let databaseURL = await storage.url
            let executor = SyncExecutor(store: try SyncStore(url: databaseURL), verificationDelays: [0])
            do {
                if official {
                    let save = SyncOperation(service: .appleMusic, kind: .saveTracks, title: "Other approval", tracks: fixture.tracks)
                    _ = try await executor.execute(plan: .init(mode: .spotifyBase, snapshots: [destination, appleSnapshot], operations: [save]),
                        selectedIDs: [save.id], decisions: .init(), providers: [.spotify: spotify, .appleMusic: apple], runID: batchRunID)
                } else {
                    _ = try await executor.executeSnapshotTransfer(source: fixture.source, destination: destination,
                        operations: [operation], decisions: fixture.decisions, provider: spotify, runID: batchRunID)
                }
            } catch { XCTAssertTrue(error is SyncExecutionError) }
            let spotifyWrites = await spotify.writes(), appleWrites = await apple.writes()
            XCTAssertEqual(spotifyWrites.count, 1, "Reusing a known run ID must never resend an uncertain request")
            XCTAssertTrue(appleWrites.isEmpty, "A new official run must not replace the XML journal with the same ID")
            let preserved = try await storage.load(id: batchRunID)
            XCTAssertEqual(preserved?.snapshotSource?.library, first.snapshotSource?.library)
            XCTAssertEqual(preserved?.plan, first.plan)
            XCTAssertEqual(preserved?.executions, first.executions)
        }
    }

    func testResumeRejectsEvenIdempotentUnknownXMLLibrarySaveBeforeProviderAccess() async throws {
        let fixture = try fixture(), storage = try store(), provider = SnapshotTransferTestProvider(fixture.destination, hiddenTimeout: true)
        let operation = SyncOperation(service: .spotify, kind: .saveTracks, title: "Save", tracks: [fixture.tracks[0]])
        let first = try await SyncExecutor(store: storage, verificationDelays: [0]).executeSnapshotTransfer(
            source: fixture.source, destination: fixture.destination, operations: [operation], decisions: fixture.decisions, provider: provider)
        let readsBefore = await provider.reads()
        let databaseURL = await storage.url
        do {
            _ = try await SyncExecutor(store: try SyncStore(url: databaseURL), verificationDelays: [0]).resume(id: first.id, providers: [.spotify: provider])
            XCTFail("Unknown XML library write was retried")
        } catch { guard case SyncExecutionError.unsafeResume = error else { return XCTFail("Unexpected error: \(error)") } }
        let readsAfter = await provider.reads(), writes = await provider.writes()
        XCTAssertEqual(readsBefore.account, readsAfter.account); XCTAssertEqual(readsBefore.library, readsAfter.library)
        XCTAssertEqual(writes.count, 1)
        let saved = try await storage.load(id: first.id)
        XCTAssertEqual(saved?.executions.first?.state, .unknown)
    }
}
