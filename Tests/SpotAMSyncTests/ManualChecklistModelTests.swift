import Darwin
import Foundation
import XCTest
import SyncCore
@testable import SpotAMSync

@MainActor
final class ManualChecklistModelTests: XCTestCase {
    func testManualAlternativePersistsWithoutMarkingOrClaimingXMLPresence() async throws {
        try await withTemporaryStore { store, _ in
            var library = self.library()
            let source = self.spotify()
            var alternative = source.savedTracks[0]
            alternative.id = "xml:alternative"; alternative.albumTitle = "Recopilación"; alternative.isLocal = true
            library.tracks = [alternative]
            let report = ManualChecklistPlanner.make(source: source, library: library)
            try await store.save(.init(library: library, report: report))
            let model = try await self.hydratedModel(), item = try XCTUnwrap(model.report?.items.first)
            XCTAssertNotEqual(item.evidence, .present)
            model.choose(itemID: item.id, candidate: alternative)
            try await self.waitUntil("guardar equivalencia") { !model.isBusy }
            XCTAssertEqual(model.choices[item.id]?.selected, alternative)
            XCTAssertEqual(model.choices[item.id]?.origin, .xml)
            XCTAssertTrue(model.markedIDs.isEmpty)
            XCTAssertNotEqual(model.report?.items.first?.evidence, .present)
            let restored = try await self.hydratedModel()
            XCTAssertEqual(restored.choices[item.id]?.selected, alternative)
            restored.generate(isDemo: false) { self.spotify(accountID: "other-account") }
            try await self.waitUntil("otra cuenta") { !restored.isBusy }
            XCTAssertTrue(restored.choices.isEmpty)
        }
    }

    func testDemoSearchAndChoicesNeverCallNetworkOrOverwriteRealState() async throws {
        try await withTemporaryStore { store, url in
            try await store.save(self.markedState())
            let original = try Data(contentsOf: url), model = try await self.hydratedModel()
            model.loadDemo()
            try await self.waitUntil("demo") { !model.isBusy }
            let item = try XCTUnwrap(model.report?.items.first)
            model.searchCandidates(itemID: item.id, query: TrackSearchQuery(item.track), catalogSearch: { _, _ in
                XCTFail("Demo must not query the supplied catalog"); return .init()
            })
            try await self.waitUntil("búsqueda demo") { !model.isBusy }
            if let candidate = model.candidateResults[item.id]?.candidates.first { model.choose(itemID: item.id, candidate: candidate) }
            XCTAssertEqual(try Data(contentsOf: url), original)
        }
    }

    func testCancelledCandidateSearchDiscardsLateResults() async throws {
        try await withTemporaryStore { store, _ in
            let state = self.markedState(); try await store.save(state)
            let model = try await self.hydratedModel(), item = try XCTUnwrap(model.report?.items.first)
            let delayed = DeferredSnapshot(self.spotify())
            model.searchCandidates(itemID: item.id, query: TrackSearchQuery(item.track), catalogSearch: { _, _ in
                let snapshot = await delayed.fetch()
                return .init(candidates: snapshot.savedTracks)
            })
            try await self.waitUntil("consulta iniciada") { delayed.hasStarted }
            model.cancel(); delayed.release()
            try await self.waitUntil("cancelación") { !model.isBusy }
            XCTAssertNil(model.candidateResults[item.id]); XCTAssertNil(model.choices[item.id])
        }
    }

    func testGenerateAndMarkPersistAcrossModelInstances() async throws {
        try await withTemporaryStore { store, _ in
            let library = self.library()
            try await store.save(ManualChecklistState(library: library))
            let model = try await self.hydratedModel()
            XCTAssertNil(model.report)
            XCTAssertEqual(model.library?.id, library.id)

            let source = self.spotify()
            var fetchCount = 0
            model.generate(isDemo: false) {
                fetchCount += 1
                return source
            }
            XCTAssertTrue(model.isBusy)
            try await self.waitUntil("generación del checklist") { !model.isBusy }
            XCTAssertEqual(fetchCount, 1)
            XCTAssertNil(model.errorMessage)
            XCTAssertFalse(model.hasUnsavedChanges)
            let report = try XCTUnwrap(model.report)
            let item = try XCTUnwrap(report.items.first)
            XCTAssertEqual(report.items.count, 1)
            XCTAssertEqual(item.track, source.savedTracks[0])
            XCTAssertEqual(item.evidence, .missing)
            XCTAssertEqual(report.sourceAccountID, source.account.id)
            XCTAssertEqual(report.libraryID, library.id)
            XCTAssertEqual(report.sourceFetchedAt, source.fetchedAt)
            XCTAssertFalse(report.isDemo)

            let generated = try await self.savedState(store)
            XCTAssertEqual(try self.encoded(generated.report), try self.encoded(report))
            XCTAssertTrue(model.markedIDs.isEmpty)
            model.setMarked(itemID: item.id, marked: true, scopeID: report.scopeID)
            XCTAssertTrue(model.isBusy)
            XCTAssertFalse(model.canCancel)
            try await self.waitUntil("guardado de la marca") { !model.isBusy }
            XCTAssertEqual(model.markedIDs, [item.id])
            XCTAssertFalse(model.hasUnsavedChanges)
            XCTAssertNil(model.errorMessage)
            let saved = try await self.savedState(store)
            XCTAssertEqual(saved.markedIDsByScope[report.scopeID], [item.id])
            XCTAssertEqual(try self.encoded(saved.report), try self.encoded(report))

            let restored = try await self.hydratedModel()
            XCTAssertEqual(restored.markedIDs, [item.id])
            XCTAssertEqual(try self.encoded(restored.report), try self.encoded(report))
            XCTAssertEqual(try self.encoded(restored.library), try self.encoded(library))
            XCTAssertFalse(restored.isDemo)
            XCTAssertFalse(restored.hasUnsavedChanges)
        }
    }

    func testUnmarkPersistsAcrossModelInstances() async throws {
        try await withTemporaryStore { store, _ in
            let state = self.markedState()
            try await store.save(state)
            let report = try XCTUnwrap(state.report)
            let item = try XCTUnwrap(report.items.first)
            let model = try await self.hydratedModel()
            XCTAssertEqual(model.markedIDs, [item.id])

            model.setMarked(itemID: item.id, marked: false, scopeID: report.scopeID)
            try await self.waitUntil("guardado al desmarcar") { !model.isBusy }
            XCTAssertTrue(model.markedIDs.isEmpty)
            XCTAssertFalse(model.hasUnsavedChanges)
            XCTAssertNil(model.errorMessage)
            let saved = try await self.savedState(store)
            XCTAssertEqual(saved.markedIDsByScope[report.scopeID], Set<String>())
            XCTAssertEqual(try self.encoded(saved.report), try self.encoded(report))

            let restored = try await self.hydratedModel()
            XCTAssertTrue(restored.markedIDs.isEmpty)
            XCTAssertEqual(try self.encoded(restored.report), try self.encoded(report))
        }
    }

    func testDemoMarksNeverOverwriteSavedBytesAndRestoreRecoversRealMarks() async throws {
        try await withTemporaryStore { store, url in
            let state = self.markedState()
            try await store.save(state)
            let originalBytes = try Data(contentsOf: url)
            let realReport = try XCTUnwrap(state.report)
            let model = try await self.hydratedModel()

            model.loadDemo()
            try await self.waitUntil("carga de la demo") { !model.isBusy }
            XCTAssertTrue(model.isDemo)
            XCTAssertNil(model.errorMessage)
            let demoReport = try XCTUnwrap(model.report)
            XCTAssertTrue(demoReport.isDemo)
            XCTAssertNotEqual(demoReport.scopeID, realReport.scopeID)
            let item = try XCTUnwrap(demoReport.items.first { $0.evidence != .present })
            XCTAssertTrue(model.markedIDs.isEmpty)
            XCTAssertEqual(try Data(contentsOf: url), originalBytes)

            model.setMarked(itemID: item.id, marked: true, scopeID: demoReport.scopeID)
            XCTAssertEqual(model.markedIDs, [item.id])
            XCTAssertFalse(model.isBusy)
            XCTAssertFalse(model.hasUnsavedChanges)
            XCTAssertEqual(try Data(contentsOf: url), originalBytes)

            var fetchCount = 0
            model.generate(isDemo: true) {
                fetchCount += 1
                return self.spotify()
            }
            try await self.waitUntil("recarga local de la demo") { !model.isBusy }
            XCTAssertEqual(fetchCount, 0, "La demo no debe invocar el proveedor suministrado")
            XCTAssertEqual(model.markedIDs, [item.id])
            XCTAssertEqual(try Data(contentsOf: url), originalBytes)
            model.setMarked(itemID: item.id, marked: false, scopeID: demoReport.scopeID)
            XCTAssertTrue(model.markedIDs.isEmpty)
            XCTAssertEqual(try Data(contentsOf: url), originalBytes)
            model.setMarked(itemID: item.id, marked: true, scopeID: demoReport.scopeID)

            model.restoreSavedState()
            try await self.waitUntil("restauración después de la demo") { !model.isBusy }
            XCTAssertTrue(model.isHydrated)
            XCTAssertFalse(model.isDemo)
            XCTAssertEqual(model.markedIDs, state.markedIDsByScope[realReport.scopeID])
            XCTAssertEqual(try self.encoded(model.report), try self.encoded(realReport))
            XCTAssertEqual(try self.encoded(model.library), try self.encoded(state.library))
            XCTAssertEqual(try Data(contentsOf: url), originalBytes)
            let restored = try await self.hydratedModel()
            XCTAssertFalse(restored.isDemo)
            XCTAssertEqual(restored.markedIDs, model.markedIDs)
            XCTAssertEqual(try self.encoded(restored.report), try self.encoded(realReport))
        }
    }

    func testAccountChangeDoesNotInheritMarksAndReturningRecoversPreviousScope() async throws {
        try await withTemporaryStore { store, url in
            let state = self.markedState()
            try await store.save(state)
            let original = try XCTUnwrap(state.report)
            let model = try await self.hydratedModel()
            model.generate(isDemo: false) { self.spotify(accountID: "spotify-account-B") }
            try await self.waitUntil("generación para otra cuenta") { !model.isBusy }
            let other = try XCTUnwrap(model.report)
            let otherItem = try XCTUnwrap(other.items.first)
            XCTAssertEqual(other.sourceAccountID, "spotify-account-B")
            XCTAssertNotEqual(other.scopeID, original.scopeID)
            XCTAssertTrue(model.markedIDs.isEmpty)

            let beforeStaleMark = try Data(contentsOf: url)
            model.setMarked(itemID: otherItem.id, marked: true, scopeID: original.scopeID)
            XCTAssertFalse(model.isBusy)
            XCTAssertTrue(model.markedIDs.isEmpty)
            XCTAssertEqual(try Data(contentsOf: url), beforeStaleMark)

            model.setMarked(itemID: otherItem.id, marked: true, scopeID: other.scopeID)
            try await self.waitUntil("marca de la segunda cuenta") { !model.isBusy }
            model.generate(isDemo: false) { self.spotify() }
            try await self.waitUntil("regreso a la primera cuenta") { !model.isBusy }
            XCTAssertEqual(model.report?.scopeID, original.scopeID)
            XCTAssertEqual(model.markedIDs, state.markedIDsByScope[original.scopeID])
            let saved = try await self.savedState(store)
            XCTAssertEqual(saved.markedIDsByScope[original.scopeID], state.markedIDsByScope[original.scopeID])
            XCTAssertEqual(saved.markedIDsByScope[other.scopeID], [otherItem.id])
            let restored = try await self.hydratedModel()
            XCTAssertEqual(restored.report?.scopeID, original.scopeID)
            XCTAssertEqual(restored.markedIDs, model.markedIDs)
        }
    }

    func testLibraryChangeDoesNotInheritMarksEvenWhenItemIDIsUnchanged() async throws {
        try await withTemporaryStore { store, url in
            let state = self.markedState()
            try await store.save(state)
            let original = try XCTUnwrap(state.report)
            let model = try await self.hydratedModel()
            let otherLibrary = self.library(id: "apple-music-xml:BBBBBBBBBBBBBBBB")
            let other = ManualChecklistPlanner.make(source: self.spotify(), library: otherLibrary)
            let item = try XCTUnwrap(other.items.first)
            XCTAssertEqual(item.id, original.items.first?.id)
            XCTAssertNotEqual(other.scopeID, original.scopeID)

            // Seed another imported library through the actor; no file picker is opened.
            try await store.save(ManualChecklistState(library: otherLibrary, report: other,
                                                     markedIDsByScope: state.markedIDsByScope))
            model.restoreSavedState()
            try await self.waitUntil("restauración de otra biblioteca") { !model.isBusy }
            XCTAssertTrue(model.isHydrated)
            XCTAssertEqual(model.library?.id, otherLibrary.id)
            XCTAssertEqual(model.report?.scopeID, other.scopeID)
            XCTAssertTrue(model.markedIDs.isEmpty)
            let beforeStaleMark = try Data(contentsOf: url)
            model.setMarked(itemID: item.id, marked: true, scopeID: original.scopeID)
            XCTAssertFalse(model.isBusy)
            XCTAssertTrue(model.markedIDs.isEmpty)
            XCTAssertEqual(try Data(contentsOf: url), beforeStaleMark)

            model.setMarked(itemID: item.id, marked: true, scopeID: other.scopeID)
            try await self.waitUntil("marca de otra biblioteca") { !model.isBusy }
            var saved = try await self.savedState(store)
            XCTAssertEqual(saved.markedIDsByScope[original.scopeID], state.markedIDsByScope[original.scopeID])
            XCTAssertEqual(saved.markedIDsByScope[other.scopeID], [item.id])
            saved.library = state.library
            saved.report = original
            try await store.save(saved)
            model.restoreSavedState()
            try await self.waitUntil("regreso a la biblioteca original") { !model.isBusy }
            XCTAssertEqual(model.report?.scopeID, original.scopeID)
            XCTAssertEqual(model.markedIDs, state.markedIDsByScope[original.scopeID])
            let restored = try await self.hydratedModel()
            XCTAssertEqual(restored.markedIDs, model.markedIDs)
            XCTAssertEqual(restored.library?.id, state.library?.id)
        }
    }

    func testCancelledGenerateDiscardsLateResponseAndPreservesReportAndSavedBytes() async throws {
        try await withTemporaryStore { store, url in
            let state = self.markedState()
            try await store.save(state)
            let originalBytes = try Data(contentsOf: url)
            let original = try XCTUnwrap(state.report)
            let model = try await self.hydratedModel()
            let response = DeferredSnapshot(self.spotify(accountID: "late-account", trackID: "late-track"))
            defer { response.release() }

            model.generate(isDemo: false) { await response.fetch() }
            try await self.waitUntil("entrada al fetch sintético") { response.hasStarted }
            XCTAssertTrue(model.isBusy)
            XCTAssertTrue(model.canCancel)
            model.cancel()
            XCTAssertFalse(model.canCancel)
            XCTAssertEqual(try self.encoded(model.report), try self.encoded(original))
            XCTAssertEqual(model.markedIDs, state.markedIDsByScope[original.scopeID])
            XCTAssertEqual(try Data(contentsOf: url), originalBytes)

            // This fetch deliberately ignores cancellation and returns only after cancel().
            response.release()
            try await self.waitUntil("descarte de la respuesta tardía") { response.hasReturned && !model.isBusy }
            XCTAssertTrue(response.returnedWhileCancelled)
            XCTAssertTrue(model.isHydrated)
            XCTAssertFalse(model.canCancel)
            XCTAssertFalse(model.hasUnsavedChanges)
            XCTAssertNil(model.errorMessage)
            XCTAssertEqual(try self.encoded(model.report), try self.encoded(original))
            XCTAssertEqual(model.markedIDs, state.markedIDsByScope[original.scopeID])
            XCTAssertEqual(try Data(contentsOf: url), originalBytes)
            let restored = try await self.hydratedModel()
            XCTAssertEqual(try self.encoded(restored.report), try self.encoded(original))
            XCTAssertEqual(restored.markedIDs, model.markedIDs)
        }
    }

    func testSearchURLKeepsSpecialCharactersInOneTermWithoutChangingOrigin() async throws {
        let tracks = [
            Track(id: "symbols", title: "  ¿Canción &term=inyectado/#🎵?  ",
                  artist: "  Björk &host=evil.invalid  ", albumTitle: "  日本語 + 100% /#  "),
            Track(id: "url-text", title: "https://evil.invalid/path?term=otro&redirect=//evil.invalid#fragment",
                  artist: "AC/DC", albumTitle: "Señales & sonidos"),
            Track(id: "blank-fields", title: "  Único término  ", artist: " \n ", albumTitle: "\t")
        ]
        for track in tracks {
            let url = try XCTUnwrap(ManualChecklistModel.searchURL(for: track))
            let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
            XCTAssertEqual(components.scheme, "https")
            XCTAssertEqual(components.host, "music.apple.com")
            XCTAssertEqual(components.path, "/search")
            XCTAssertNil(components.port)
            XCTAssertNil(components.user)
            XCTAssertNil(components.password)
            XCTAssertNil(components.fragment)
            XCTAssertEqual(components.queryItems?.count, 1)
            XCTAssertEqual(components.queryItems?.first?.name, "term")
        }
        let expectedTerms = [
            "¿Canción &term=inyectado/#🎵? Björk &host=evil.invalid 日本語 + 100% /#",
            "https://evil.invalid/path?term=otro&redirect=//evil.invalid#fragment AC/DC Señales & sonidos",
            "Único término"
        ]
        for (track, expected) in zip(tracks, expectedTerms) {
            let url = try XCTUnwrap(ManualChecklistModel.searchURL(for: track))
            XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, expected)
        }
    }

    func testCorruptJSONBlocksHydrationAndActionsWithoutOverwritingBytes() async throws {
        try await withTemporaryStore { _, url in
            let corrupt = Data("{\"library\": [invalid-json".utf8)
            try corrupt.write(to: url)
            let model = ManualChecklistModel()
            try await self.waitUntil("lectura del JSON corrupto") { !model.isBusy }
            XCTAssertFalse(model.isHydrated)
            XCTAssertNotNil(model.errorMessage)
            XCTAssertNil(model.library)
            XCTAssertNil(model.report)
            XCTAssertTrue(model.markedIDs.isEmpty)
            try await self.assertActionsBlocked(model, url: url, bytes: corrupt)

            model.restoreSavedState()
            try await self.waitUntil("reintento de lectura del JSON corrupto") { !model.isBusy }
            XCTAssertFalse(model.isHydrated)
            XCTAssertNotNil(model.errorMessage)
            XCTAssertEqual(try Data(contentsOf: url), corrupt)
        }
    }

    func testCorruptReloadBlocksMutationsOfPreviouslyHydratedReport() async throws {
        try await withTemporaryStore { store, url in
            let state = self.markedState()
            try await store.save(state)
            let model = try await self.hydratedModel()
            let corrupt = Data("{\"report\": truncated".utf8)
            try corrupt.write(to: url)
            model.restoreSavedState()
            try await self.waitUntil("recarga de JSON corrupto") { !model.isBusy }
            XCTAssertFalse(model.isHydrated)
            XCTAssertNotNil(model.errorMessage)
            try await self.assertActionsBlocked(model, url: url, bytes: corrupt)
        }
    }

    private func assertActionsBlocked(_ model: ManualChecklistModel, url: URL, bytes: Data) async throws {
        let previousReport = try encoded(model.report)
        let previousMarks = model.markedIDs
        var fetchCount = 0
        model.generate(isDemo: false) {
            fetchCount += 1
            return self.spotify()
        }
        try await waitUntil("rechazo de generación sin hidratar") { !model.isBusy }
        XCTAssertEqual(fetchCount, 0)
        model.loadDemo()
        try await waitUntil("rechazo de demo sin hidratar") { !model.isBusy }
        model.generate(isDemo: true) {
            fetchCount += 1
            return self.spotify()
        }
        try await waitUntil("rechazo de generación demo sin hidratar") { !model.isBusy }
        let itemID = model.report?.items.first?.id ?? "unavailable-item"
        model.setMarked(itemID: itemID, marked: !previousMarks.contains(itemID),
                        scopeID: model.report?.scopeID ?? "unavailable-scope")
        try await waitUntil("rechazo de marca sin hidratar") { !model.isBusy }
        model.retrySave()
        try await waitUntil("rechazo de guardado sin hidratar") { !model.isBusy }
        XCTAssertEqual(fetchCount, 0)
        XCTAssertFalse(model.isHydrated)
        XCTAssertFalse(model.isDemo)
        XCTAssertFalse(model.canCancel)
        XCTAssertFalse(model.hasUnsavedChanges)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(try encoded(model.report), previousReport)
        XCTAssertEqual(model.markedIDs, previousMarks)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    // XCTest runs these cases serially in a process. Each case restores the environment,
    // and swift test --parallel uses separate worker processes rather than sharing it.
    private func withTemporaryStore(_ body: @MainActor (ManualChecklistStore, URL) async throws -> Void) async throws {
        let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("spot-am-manual-checklist-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let previous = getenv("SPOTAM_DATA_DIR").map { String(cString: $0) }
        guard setenv("SPOTAM_DATA_DIR", directory.path, 1) == 0 else {
            throw POSIXError(.EINVAL)
        }
        defer {
            if let previous { setenv("SPOTAM_DATA_DIR", previous, 1) }
            else { unsetenv("SPOTAM_DATA_DIR") }
        }
        let url = directory.appendingPathComponent("manual-checklist.json")
        try await body(ManualChecklistStore(url: url), url)
    }

    private func hydratedModel() async throws -> ManualChecklistModel {
        let model = ManualChecklistModel()
        XCTAssertTrue(model.isBusy)
        XCTAssertFalse(model.isHydrated)
        try await waitUntil("hidratación del modelo") { !model.isBusy }
        XCTAssertTrue(model.isHydrated)
        XCTAssertNil(model.errorMessage)
        return model
    }

    private func waitUntil(_ description: String, file: StaticString = #filePath, line: UInt = #line,
                           _ condition: @MainActor () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while !condition() {
            guard clock.now < deadline else {
                XCTFail("Tiempo de espera agotado: \(description)", file: file, line: line)
                throw WaitError.timedOut
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func savedState(_ store: ManualChecklistStore) async throws -> ManualChecklistState {
        let state = try await store.load()
        return try XCTUnwrap(state)
    }

    private func encoded<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private func library(id: String = "apple-music-xml:AAAAAAAAAAAAAAAA") -> ManualMusicLibrary {
        ManualMusicLibrary(id: id, fileName: "Biblioteca sintética.xml",
                           importedAt: Date(timeIntervalSince1970: 100),
                           exportedAt: Date(timeIntervalSince1970: 90), tracks: [])
    }

    private func spotify(accountID: String = "spotify-account-A", trackID: String = "spotify-track-A") -> LibrarySnapshot {
        LibrarySnapshot(account: ConnectedAccount(id: accountID, service: .spotify,
                                                  displayName: "Cuenta sintética", connectionRevision: "fixture-revision"),
                        fetchedAt: Date(timeIntervalSince1970: 200),
                        savedTracks: [Track(id: trackID, title: "Tema sintético", artist: "Artista sintético",
                                            albumTitle: "Álbum sintético", durationMS: 180_000, explicit: false)])
    }

    private func markedState() -> ManualChecklistState {
        let library = library()
        let report = ManualChecklistPlanner.make(source: spotify(), library: library)
        return ManualChecklistState(library: library, report: report,
                                    markedIDsByScope: [report.scopeID: Set(report.items.map(\.id))])
    }

    private enum WaitError: Error { case timedOut }
}

@MainActor
private final class DeferredSnapshot {
    private let snapshot: LibrarySnapshot
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var hasStarted = false
    private(set) var hasReturned = false
    private(set) var returnedWhileCancelled = false

    init(_ snapshot: LibrarySnapshot) { self.snapshot = snapshot }

    func fetch() async -> LibrarySnapshot {
        hasStarted = true
        if !released { await withCheckedContinuation { continuation = $0 } }
        returnedWhileCancelled = Task.isCancelled
        hasReturned = true
        return snapshot
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
