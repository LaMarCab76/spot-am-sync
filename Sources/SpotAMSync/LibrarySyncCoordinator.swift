import AppKit
import Combine
import CryptoKit
import SyncCore
import MusicProviders

enum LibrarySyncPolicy: String, Codable, CaseIterable, Sendable {
    case prepare, notify, exclude
    var title: String {
        switch self { case .prepare: return "Preparar todas las diferencias"; case .notify: return "Avisarme para elegir"; case .exclude: return "No incluir" }
    }
}

enum LibraryApprovalState: String, Codable, Sendable { case queued, applying, verified, manual, attention, revoked }
struct LibraryApprovalBatch: Codable, Sendable, Identifiable {
    var id = UUID()
    var approvedAt = Date()
    var sourceDigest: String
    var expectedSourceDigest: String?
    var differenceIDs: Set<String>
    var unitIDs: Set<String>
    var scope: LibraryComparisonScope
    var operations: [SyncOperation]
    var manualTasks: [LibraryManualTask]
    var state: LibraryApprovalState = .queued
    var runID: UUID?
    var message = "Confirmado; esperando que termine el análisis."
    var separateReview = false
}

struct LibraryUnitResolution: Codable, Sendable {
    var sourceDigest: String
    var spotifyFingerprint: String
    var differences: [LibraryDifference]
}

struct LibrarySyncSession: Codable, Sendable {
    var library: ManualMusicLibrary?
    var spotify: LibrarySnapshot?
    var appleSnapshot: LibrarySnapshot?
    var configuration = LibraryComparisonConfiguration(scope: .init(playlists: false, appleMusicPlaylistIDs: [], spotifyPlaylistIDs: []))
    var songPolicy = LibrarySyncPolicy.prepare
    var albumPolicy = LibrarySyncPolicy.prepare
    var decisions = MatchDecisions()
    var report = LibraryComparisonReport()
    var baseline: LibraryComparisonBaseline?
    var baselineScope: LibraryComparisonScope?
    var baselineIncludesUncertainSongs = false
    var ignored: [String: String] = [:]
    var deferred: [String: String] = [:]
    var manualMarks: Set<String> = []
    var batches: [LibraryApprovalBatch] = []
    var resolutions: [String: LibraryUnitResolution] = [:]
    var isDemo = false
}

private struct LibrarySyncArchive: Codable, Sendable {
    var version = 1
    var sessions: [String: LibrarySyncSession] = [:]
    var activeKey: String?
}

/// Owns analysis, review and application independently. Reviews never require
/// the analysis task to finish; provider writes hold the exclusive application slot.
@MainActor
final class LibrarySyncCoordinator: ObservableObject {
    @Published private(set) var session = LibrarySyncSession()
    @Published private(set) var loaded = false
    @Published private(set) var isAnalyzing = false
    @Published private(set) var isReadingSources = false
    @Published private(set) var lastCompletedSourceReadID: UUID?
    @Published private(set) var isApplying = false
    @Published private(set) var statusText = "Elegí las fuentes para empezar."
    @Published private(set) var progress: Double = 0
    @Published private(set) var libraryProgress: LibraryReadProgress?
    @Published var errorMessage: String?
    @Published var candidateMatchID: String?
    @Published private(set) var searchResults: [String: TrackSearchResult] = [:]
    @Published private(set) var searchingIDs: Set<String> = []
    @Published private(set) var albumCandidates: [String: [Album]] = [:]
    @Published private(set) var searchingAlbumIDs: Set<String> = []
    private var store: SyncStore?
    private var executor: SyncExecutor?
    private var archive = LibrarySyncArchive()
    private var analysisTask: Task<Void, Never>?
    private var applicationTask: Task<Void, Never>?
    private var searches: [String: Task<Void, Never>] = [:]
    private var searchGenerations: [String: UUID] = [:]
    private var saveTask: Task<Void, Error>?
    private var generation = UUID()
    private var libraryReadID: UUID?
    private var revision = 0
    private var decisionRevisions: [String: Int] = [:]
    private var providers: [MusicService: any MusicProvider] = [:]
    private let publicSearch = ITunesCatalogSearch()
    private var externalBusy: () -> Bool = { false }
    var onSnapshots: (([LibrarySnapshot]) -> Void)?
    var onRun: (() -> Void)?
    var isWorking: Bool { isAnalyzing || isApplying || !searchingIDs.isEmpty || !searchingAlbumIDs.isEmpty }
    var library: ManualMusicLibrary? { session.library }
    var spotify: LibrarySnapshot? { session.spotify }
    var report: LibraryComparisonReport { session.report }
    var readyDifferences: [LibraryDifference] {
        report.additions.filter { !isIgnored($0) && !isDeferred($0) && !hasApproval($0.id) &&
            !operations(for: $0).contains(where: { $0.kind.isDestructive || $0.kind == .renamePlaylist }) &&
            (!operations(for: $0).isEmpty || !$0.appleMusicTasks.isEmpty) }
    }
    var outstanding: [LibraryDifference] { report.differences.filter { !isIgnored($0) } }

    func start(store: SyncStore, externalBusy: @escaping () -> Bool) {
        self.store = store; executor = SyncExecutor(store: store); self.externalBusy = externalBusy
        Task {
            do {
                archive = try await store.loadDocument(LibrarySyncArchive.self, key: "library-comparison-v1") ?? .init()
                guard archive.version == 1 else { throw SyncExecutionError.persistence("Versión de comparación incompatible.") }
                for key in archive.sessions.keys {
                    for i in archive.sessions[key]!.batches.indices {
                        if archive.sessions[key]!.batches[i].state == .queued {
                            archive.sessions[key]!.batches[i].state = .revoked
                            archive.sessions[key]!.batches[i].message = "La app se reinició. Reanalizá y confirmá este lote otra vez."
                        } else if archive.sessions[key]!.batches[i].state == .applying {
                            archive.sessions[key]!.batches[i].state = .attention
                            archive.sessions[key]!.batches[i].message = "Ejecución interrumpida. Comprobá el historial mediante lectura."
                        }
                    }
                }
                if let key = archive.activeKey, let saved = archive.sessions[key] { session = saved }
                loaded = true; persist()
                statusText = library == nil ? "Elegí las fuentes para empezar." : "Comparación recuperada. Actualizá las fuentes antes de preparar cambios."
            } catch { errorMessage = error.localizedDescription; statusText = "No se pudo recuperar la comparación. Los datos guardados se conservan." }
        }
    }

    /// Only explicitly connected providers are supplied by AppModel. Credentials never enter persisted state.
    func setProviders(_ value: [MusicService: any MusicProvider], isDemo: Bool) {
        guard !isWorking else { return }
        providers = value
        if session.isDemo != isDemo {
            if let key = archive.activeKey { archive.sessions[key] = session }
            archive.activeKey = nil; session = LibrarySyncSession(); session.isDemo = isDemo
        }
    }

    func readSources(xml: ManualMusicLibrary?, useOfficialApple: Bool, isDemo: Bool) {
        guard loaded, !isWorking, !externalBusy(), let spotifyProvider = providers[.spotify] else { return }
        if !useOfficialApple && xml == nil { errorMessage = "Importá una exportación XML de Música o elegí la integración oficial."; return }
        if useOfficialApple && providers[.appleMusic] == nil { errorMessage = "Conectá Apple Music para leer su integración oficial."; return }
        let token = UUID(); generation = token; isReadingSources = true; isAnalyzing = true
        libraryReadID = token
        libraryProgress = nil; errorMessage = nil; progress = 0
        statusText = "Leyendo Spotify…"
        analysisTask = Task {
            defer {
                if generation == token {
                    libraryReadID = nil; isReadingSources = false; isAnalyzing = false; libraryProgress = nil
                    scheduleApplication()
                }
            }
            do {
                let fresh = try await spotifyProvider.fetchLibrary(progress: { [self] update in
                    await receiveProgress(update, generation: token)
                })
                try Task.checkCancellation()
                guard generation == token, fresh.account.service == .spotify else { return }
                libraryReadID = nil; libraryProgress = nil
                var apple: LibrarySnapshot?
                var source = xml
                if useOfficialApple, let provider = providers[.appleMusic] {
                    statusText = "Leyendo Apple Music…"
                    apple = try await provider.fetchLibrary()
                    try Task.checkCancellation()
                    source = Self.importedRepresentation(apple!)
                }
                guard let source, generation == token else { return }
                let key = Self.scopeKey(source: source, spotify: fresh, demo: isDemo)
                if let previous = archive.activeKey { archive.sessions[previous] = session }
                var next = archive.sessions[key] ?? LibrarySyncSession()
                if next.library?.documentDigest != source.documentDigest || next.spotify?.stateFingerprint != fresh.stateFingerprint {
                    for i in next.batches.indices where next.batches[i].state == .queued {
                        next.batches[i].state = .revoked; next.batches[i].message = "Las fuentes cambiaron; requiere otra confirmación."
                    }
                }
                next.library = source; next.spotify = fresh; next.appleSnapshot = apple; next.isDemo = isDemo
                session = next; archive.activeKey = key; revision += 1
                await publishReport()
                try Task.checkCancellation()
                guard generation == token else { return }
                onSnapshots?([fresh] + (apple.map { [$0] } ?? []))
                statusText = "Fuentes disponibles. Elegí la base y el alcance."
                lastCompletedSourceReadID = token
                persist()
            } catch is CancellationError {
                if generation == token { statusText = "Lectura cancelada. Se conserva la comparación anterior." }
            } catch {
                if generation == token { errorMessage = error.localizedDescription; statusText = "No se pudieron actualizar las fuentes." }
            }
        }
    }

    func configure(mode: SyncMode, songs: LibrarySyncPolicy, albums: LibrarySyncPolicy,
                   applePlaylists: Set<String>? = nil, spotifyPlaylists: Set<String>? = nil,
                   includeUncertainXMLSongs: Bool = false) {
        guard !isApplying else { return }
        session.configuration.mode = mode; session.songPolicy = songs; session.albumPolicy = albums
        session.configuration.includeUncertainXMLSongs = includeUncertainXMLSongs
        session.configuration.scope.songs = songs != .exclude; session.configuration.scope.albums = albums != .exclude
        if let applePlaylists { session.configuration.scope.appleMusicPlaylistIDs = applePlaylists }
        if let spotifyPlaylists { session.configuration.scope.spotifyPlaylistIDs = spotifyPlaylists }
        revokeQueued("Cambió el alcance o la modalidad; requiere otra confirmación.")
        prepare()
    }

    func selectPlaylists(apple: Set<String>, spotify: Set<String>) {
        guard !isApplying else { return }
        session.configuration.scope.playlists = true
        session.configuration.scope.appleMusicPlaylistIDs = apple; session.configuration.scope.spotifyPlaylistIDs = spotify
        revokeQueued("Cambió la selección de playlists; requiere otra confirmación.")
        prepare()
    }

    func link(appleID: String, spotifyID: String?) {
        guard !isApplying else { return }
        session.configuration.playlistPairings.removeAll { link in link.appleMusicID == appleID || (spotifyID != nil && link.spotifyID == spotifyID) }
        if let spotifyID, !spotifyID.isEmpty { session.configuration.playlistPairings.append(.init(spotifyID: spotifyID, appleMusicID: appleID)) }
        revokeQueued("Cambió una correspondencia de playlist."); prepare()
    }

    func prepare() {
        guard loaded, !isApplying, !externalBusy(), let library, let spotify else { return }
        analysisTask?.cancel(); generation = UUID(); let token = generation
        libraryReadID = nil; isReadingSources = false; libraryProgress = nil
        isAnalyzing = true; errorMessage = nil; progress = 0; statusText = "Comparando el alcance seleccionado…"
        analysisTask = Task {
            defer { if generation == token { isAnalyzing = false; scheduleApplication() } }
            await publishReport()
            let sourceTracks = relevantAppleTracks(library)
            var requests: [(Track, MusicService)] = sourceTracks.map { ($0, .appleMusic) }
            if session.configuration.mode != .appleMusicBase {
                requests += relevantSpotifyTracks(spotify).map { ($0, .spotify) }
            }
            if session.configuration.scope.albums, session.appleSnapshot != nil {
                let inventories = [session.appleSnapshot, session.spotify].compactMap { $0 }
                for inventory in inventories {
                    guard let provider = providers[inventory.account.service.other] else { continue }
                    for album in inventory.savedAlbums where album.isCompleteAlbum {
                        if Task.isCancelled || generation != token { return }
                        do {
                            let search = try await provider.searchAlbums(matching: album)
                            try Task.checkCancellation()
                            var match = CatalogMatcher.album(album, candidates: search.candidates, sourceService: inventory.account.service, coverage: search.coverage)
                            if let previous = session.decisions.albums.first(where: { $0.id == match.id }), previous.manualSelection == true,
                               let selected = previous.selected, let candidate = search.candidates.first(where: { $0.playableID == selected.playableID && $0 == selected }) {
                                match.selected = candidate; match.manualSelection = true
                            }
                            session.decisions.albums.removeAll { $0.id == match.id }; session.decisions.albums.append(match)
                            revision += 1; await publishReport()
                        } catch is CancellationError { return }
                        catch {
                            session.decisions.albums.removeAll { $0.id == "\(inventory.account.service.rawValue):\(album.id)" }
                            revokeQueued("No se pudo revalidar una edición de álbum.")
                            statusText = "Edición de álbum pendiente: \(error.localizedDescription)"
                        }
                    }
                }
            }
            var completed = 0
            var lastPublication = Date.distantPast
            for (track, service) in requests {
                if Task.isCancelled || generation != token { return }
                let matchID = "\(service.rawValue):\(track.id)"
                let decisionVersion = decisionRevisions[matchID, default: 0]
                guard let provider = providers[service.other] else { completed += 1; continue }
                if let existing = session.decisions.tracks.first(where: { $0.id == matchID }),
                   CatalogMatcher.sameIdentityMetadata(existing.source, track),
                   existing.decision == .omitted || existing.decision == .pending { completed += 1; continue }
                do {
                    statusText = "Buscando equivalencia: \(track.title)"
                    let match = try await resolve(track, service: service, provider: provider)
                    try Task.checkCancellation()
                    guard generation == token else { return }
                    if decisionRevisions[matchID, default: 0] == decisionVersion {
                        session.decisions.tracks.removeAll { $0.id == matchID }; session.decisions.tracks.append(match)
                        revision += 1
                    }
                    if let wait = searchResults[matchID]?.retryAfterSeconds {
                        statusText = "El catálogo pidió esperar \(wait) s. Los resultados incompletos quedan para revisión."
                        break
                    }
                } catch is CancellationError { return }
                catch {
                    if decisionRevisions[matchID, default: 0] == decisionVersion {
                        var invalid = TrackMatch(sourceService: service, source: track, confidence: .review,
                            reason: "No se pudo revalidar la equivalencia: \(error.localizedDescription)")
                        invalid.searchCoverage = .failed
                        session.decisions.tracks.removeAll { $0.id == matchID }; session.decisions.tracks.append(invalid)
                        revokeQueued("No se pudo revalidar una equivalencia utilizada por el lote.")
                    }
                    statusText = "Equivalencia pendiente: \(error.localizedDescription)"
                }
                completed += 1; progress = requests.isEmpty ? 1 : Double(completed) / Double(requests.count)
                if completed == 1 || Date().timeIntervalSince(lastPublication) >= 0.35 {
                    await publishReport(); persist(); lastPublication = Date()
                }
            }
            guard generation == token else { return }
            progress = 1; await publishReport(); persist()
            statusText = "Comparación lista: \(report.additions.count) incorporaciones, \(report.conflicts.count) conflictos y \(report.reviews.count) revisiones."
        }
    }

    func choose(matchID: String, candidate: Track?, decision: TrackDecision) {
        guard !isApplying, let source = sourceTrack(matchID: matchID) else { return }
        var match = session.decisions.tracks.first(where: { $0.id == matchID }) ?? TrackMatch(sourceService: source.1, source: source.0)
        match.selected = candidate; match.decision = decision; match.manualSelection = candidate != nil
        match.confidence = .review
        if let candidate, !match.candidates.contains(where: { $0.playableID == candidate.playableID }) { match.candidates.append(candidate) }
        session.decisions.tracks.removeAll { $0.id == matchID }; session.decisions.tracks.append(match)
        decisionRevisions[matchID, default: 0] += 1; revision += 1
        revokeQueued("Cambió una equivalencia utilizada por el lote.")
        Task { await publishReport(); persist(); scheduleApplication() }
    }

    func reject(matchID: String, candidate: Track) {
        guard !isApplying else { return }
        if let i = session.decisions.tracks.firstIndex(where: { $0.id == matchID }) {
            session.decisions.tracks[i].rejectedCandidateIDs = Array(Set((session.decisions.tracks[i].rejectedCandidateIDs ?? []) + [candidate.playableID]))
            if session.decisions.tracks[i].selected?.playableID == candidate.playableID { choose(matchID: matchID, candidate: nil, decision: .pending) }
        }
        revision += 1; Task { await publishReport(); persist() }
    }

    func search(matchID: String, query: TrackSearchQuery) {
        guard !isApplying, query.valid, let source = sourceTrack(matchID: matchID) else { return }
        let provider = providers[source.1.other]
        guard provider != nil || (source.1 == .spotify && session.appleSnapshot == nil) else {
            errorMessage = "Conectá el servicio de destino para buscar equivalencias."; return
        }
        searches[matchID]?.cancel(); searchingIDs.insert(matchID)
        let requestID = UUID(); searchGenerations[matchID] = requestID
        searches[matchID] = Task {
            defer {
                if searchGenerations[matchID] == requestID {
                    searchingIDs.remove(matchID); searches[matchID] = nil; searchGenerations[matchID] = nil; scheduleApplication()
                }
            }
            do {
                var searchable = source.0; searchable.isLocal = false
                let result: TrackSearchResult
                if let provider { result = try await CatalogSearch.search(source: searchable, provider: provider, query: query) }
                else if session.isDemo {
                    result = .init(candidates: library?.tracks ?? [], coverage: .partial, notes: ["Referencias locales de demostración."])
                } else {
                    var request = query
                    if request.country == nil { request.country = Locale.current.region?.identifier ?? "AR" }
                    result = try await publicSearch.search(request)
                }
                try Task.checkCancellation()
                guard searchGenerations[matchID] == requestID else { return }
                searchResults[matchID] = result
                var match = session.decisions.tracks.first(where: { $0.id == matchID }) ?? .init(sourceService: source.1, source: source.0)
                match.candidates = CatalogMatcher.unique(match.candidates + result.candidates)
                match.searchCoverage = result.coverage; match.searchNotes = result.notes
                session.decisions.tracks.removeAll { $0.id == matchID }; session.decisions.tracks.append(match)
                revision += 1; await publishReport(); persist()
            } catch is CancellationError { }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func restoreRejected(matchID: String) {
        guard !isApplying, let i = session.decisions.tracks.firstIndex(where: { $0.id == matchID }) else { return }
        session.decisions.tracks[i].rejectedCandidateIDs = []
        decisionRevisions[matchID, default: 0] += 1; revision += 1
        Task { await publishReport(); persist() }
    }

    func cancelSearch(matchID: String) { searches[matchID]?.cancel() }

    func flush() async throws { try await saveTask?.value }

    func searchAlbum(_ difference: LibraryDifference) {
        guard !isApplying, let source = difference.albums.first else { return }
        let destination = albumDestination(difference)
        guard let provider = providers[destination] else { errorMessage = "Para elegir una edición de catálogo Apple conectá su integración oficial. El XML no demuestra un álbum completo guardado."; return }
        guard !searchingAlbumIDs.contains(difference.id) else { return }
        searchingAlbumIDs.insert(difference.id)
        searches[difference.id] = Task {
            defer { searchingAlbumIDs.remove(difference.id); searches[difference.id] = nil; scheduleApplication() }
            do {
                let result = try await provider.searchAlbums(matching: source)
                try Task.checkCancellation()
                albumCandidates[difference.id] = CatalogMatcher.uniqueAlbums(result.candidates)
                if result.coverage != .complete { statusText = "Búsqueda de álbumes incompleta; revisá las ediciones disponibles." }
            } catch is CancellationError { }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func chooseAlbum(_ album: Album, for difference: LibraryDifference) {
        guard !isApplying, album.available, album.isCompleteAlbum, let library, let spotify,
              albumCandidates[difference.id]?.contains(album) == true else { return }
        let destination = albumDestination(difference)
        var proposal = difference
        proposal.id = difference.id + ":album:" + album.playableID
        proposal.category = .addition; proposal.destination = destination; proposal.albums = [album]
        proposal.detail = "Edición completa elegida por vos: \(album.title) — \(album.artist), \(album.tracks.count) pistas. Confirmá esta incorporación para guardar el álbum completo."
        proposal.spotifyOperations = []; proposal.appleMusicTasks = []
        let operation = SyncOperation(service: destination, kind: .saveAlbums, title: album.title, detail: proposal.detail, albums: [album])
        if destination == .spotify { proposal.spotifyOperations = [operation] }
        else { proposal.appleMusicTasks = [.init(id: "manual:" + proposal.id, differenceID: proposal.id, kind: .saveAlbums,
            title: album.title, detail: proposal.detail, albums: [album], operation: session.appleSnapshot == nil ? nil : operation)] }
        session.resolutions[difference.unitID] = .init(sourceDigest: library.documentDigest ?? "", spotifyFingerprint: spotify.stateFingerprint, differences: [proposal])
        revokeQueued("Cambió la edición de un álbum.")
        Task { await publishReport(); persist() }
    }

    func albumDestination(_ difference: LibraryDifference) -> MusicService {
        difference.destination ?? (difference.albums.first.map { album in spotify?.savedAlbums.contains(where: { $0.id == album.id }) == true } == true ? .appleMusic : .spotify)
    }

    private func receiveProgress(_ update: LibraryReadProgress, generation token: UUID) {
        guard generation == token, libraryReadID == token, analysisTask?.isCancelled != true else { return }
        if libraryProgress != update { libraryProgress = update }
    }

    func omit(_ difference: LibraryDifference) {
        guard !isApplying else { return }
        session.ignored[difference.id] = Self.signature(difference); persist()
    }
    func restoreIgnored() { guard !isApplying else { return }; session.ignored = [:]; persist() }
    func isIgnored(_ difference: LibraryDifference) -> Bool { session.ignored[difference.id] == Self.signature(difference) }
    func deferDifference(_ difference: LibraryDifference) {
        guard !isApplying else { return }
        session.deferred[difference.id] = Self.signature(difference)
        revokeQueued("Un cambio fue dejado pendiente por vos."); persist()
    }
    func isDeferred(_ difference: LibraryDifference) -> Bool { session.deferred[difference.id] == Self.signature(difference) }
    func restoreDeferred() { guard !isApplying else { return }; session.deferred = [:]; persist() }
    func hasApproval(_ differenceID: String) -> Bool {
        session.batches.contains { [.queued, .applying, .manual, .attention].contains($0.state) && $0.differenceIDs.contains(differenceID) }
    }
    func operations(for difference: LibraryDifference) -> [SyncOperation] {
        difference.spotifyOperations + (session.appleSnapshot == nil ? [] : difference.appleMusicTasks.compactMap(\.operation))
    }

    func approve(_ ids: Set<String>) {
        guard !isApplying, let digest = library?.documentDigest else { return }
        let changes = readyDifferences.filter { ids.contains($0.id) }
        guard !changes.isEmpty else { return }
        let operations = changes.flatMap { operations(for: $0) }
        let tasks = changes.flatMap(\.appleMusicTasks).filter { session.appleSnapshot == nil || $0.operation == nil }
        let batch = LibraryApprovalBatch(sourceDigest: digest, differenceIDs: Set(changes.map(\.id)), unitIDs: Set(changes.map(\.unitID)), scope: session.configuration.scope, operations: operations, manualTasks: tasks)
        session.batches.append(batch); persist()
        statusText = "Confirmados \(changes.count) cambios concretos. Los resultados posteriores necesitarán otra confirmación."
        scheduleApplication()
    }

    func markManual(_ taskID: String, done: Bool) {
        if done { session.manualMarks.insert(taskID) } else { session.manualMarks.remove(taskID) }
        persist()
    }

    /// Choosing a side prepares a new proposal; it never approves it.
    func resolve(_ difference: LibraryDifference, prefer service: MusicService) {
        guard !isApplying, let library, let spotify else { return }
        var configuration = session.configuration
        configuration.mode = service == .appleMusic ? .appleMusicBase : .spotifyBase
        var replacement = LibraryComparison.compare(library: library, spotify: spotify, decisions: session.decisions,
            configuration: configuration, appleSnapshot: session.appleSnapshot).differences.filter { $0.unitID == difference.unitID }
        if difference.scope == .playlists, let proposal = playlistResolution(difference, prefer: service) { replacement = [proposal] }
        guard !replacement.isEmpty else { errorMessage = "La versión elegida ya está presente o requiere resolver sus equivalencias."; return }
        session.resolutions[difference.unitID] = .init(sourceDigest: library.documentDigest ?? "", spotifyFingerprint: spotify.stateFingerprint, differences: replacement)
        revokeQueued("Cambió la resolución de una diferencia.")
        Task { await publishReport(); persist() }
    }

    /// Called only by the dedicated, concrete confirmation dialog for one change.
    func approveRemoval(_ difference: LibraryDifference) {
        guard !isApplying, !hasApproval(difference.id), let library, let spotify,
              difference.category == .removal || session.resolutions[difference.unitID] != nil else { return }
        var operations = operations(for: difference)
        var tasks = difference.appleMusicTasks.filter { session.appleSnapshot == nil || $0.operation == nil }
        if operations.isEmpty && tasks.isEmpty {
            guard difference.category == .removal, let destination = difference.destination else { errorMessage = "Elegí la versión y resolvé las equivalencias antes de confirmar este cambio."; return }
            if destination == .appleMusic {
                let kind: OperationKind = difference.scope == .songs ? .removeTracks : difference.scope == .albums ? .removeAlbums : .removePlaylist
                tasks = [.init(id: "manual:" + difference.id, differenceID: difference.id, kind: kind, targetID: difference.destinationID,
                               title: difference.title, detail: difference.detail, tracks: difference.tracks, albums: difference.albums)]
            } else {
                switch difference.scope {
                case .songs:
                    guard let track = spotify.savedTracks.first(where: { $0.id == difference.destinationID || $0.playableID == difference.destinationID }) else { errorMessage = "La canción destino necesita una nueva comparación."; return }
                    operations = [.init(service: .spotify, kind: .removeTracks, title: difference.title, tracks: [track])]
                case .albums:
                    guard let source = difference.albums.first,
                          let album = spotify.savedAlbums.first(where: { $0.playableID == source.playableID }) ?? CatalogMatcher.album(source, candidates: spotify.savedAlbums, sourceService: .appleMusic).selected else {
                        errorMessage = "La edición del álbum destino requiere una elección explícita."; return
                    }
                    operations = [.init(service: .spotify, kind: .removeAlbums, title: difference.title, albums: [album])]
                case .playlists:
                    guard let id = difference.destinationID, let playlist = spotify.playlists.first(where: { $0.id == id }), playlist.editable else { errorMessage = "La playlist destino no está vinculada o no permite cambios."; return }
                    if difference.appleMusicTrackIDs == nil {
                        operations = [.init(service: .spotify, kind: .removePlaylist, targetID: id, title: difference.title)]
                    } else {
                        guard difference.tracks.allSatisfy({ $0.available && !$0.isLocal }) else { errorMessage = "Resolvé todas las canciones antes de reemplazar el contenido."; return }
                        operations = [.init(service: .spotify, kind: .replacePlaylistTracks, targetID: id, title: difference.title,
                                            tracks: difference.tracks, beforeTrackIDs: playlist.tracks.map(\.playableID))]
                    }
                }
            }
        }
        guard let digest = library.documentDigest else { return }
        var batch = LibraryApprovalBatch(sourceDigest: digest, differenceIDs: [difference.id], unitIDs: [difference.unitID],
            scope: session.configuration.scope, operations: operations, manualTasks: tasks)
        batch.separateReview = true
        session.batches.append(batch); persist(); scheduleApplication()
    }

    private func playlistResolution(_ difference: LibraryDifference, prefer service: MusicService) -> LibraryDifference? {
        guard let library, let spotify else { return nil }
        let pairs = session.configuration.playlistPairings.filter { link in
            let left = library.inventory?.playlists.first { $0.id == link.appleMusicID }
            let right = spotify.playlists.first { $0.id == link.spotifyID }
            return left?.trackIDs == difference.appleMusicTrackIDs && right?.tracks.map(\.playableID) == difference.spotifyTrackIDs
        }
        guard pairs.count == 1, let pair = pairs.first else { return nil }
        let applePlaylist = library.inventory?.playlists.first { $0.id == pair.appleMusicID }
        let spotifyPlaylist = spotify.playlists.first { $0.id == pair.spotifyID }
        var proposal = difference
        proposal.category = .removal // A separate content/metadata confirmation, outside bulk additions.
        proposal.detail = "Versión elegida: \(service.name). Reemplazar contenido conserva exactamente el orden y las repeticiones indicados. Requiere confirmación separada."
        proposal.spotifyOperations = []; proposal.appleMusicTasks = []
        if service == .appleMusic, applePlaylist == nil, let right = spotifyPlaylist,
           library.complete, library.inventory?.playlistsComplete == true, right.editable {
            proposal.destination = .spotify; proposal.destinationID = right.id; proposal.sourceID = pair.appleMusicID
            proposal.detail = "Elegiste conservar la ausencia de esta playlist en Música. Quitar de la biblioteca Spotify la playlist vinculada \(right.name) requiere esta confirmación separada."
            proposal.spotifyOperations = [.init(service: .spotify, kind: .removePlaylist, targetID: right.id, title: right.name)]
            return proposal
        }
        if service == .spotify, spotifyPlaylist == nil, let left = applePlaylist, spotify.coverage.playlists {
            proposal.destination = .appleMusic; proposal.destinationID = left.id; proposal.sourceID = pair.spotifyID
            proposal.detail = "Elegiste conservar la ausencia de esta playlist en Spotify. Revisá la baja manual de la playlist vinculada en Música."
            proposal.appleMusicTasks = [.init(id: "manual:" + proposal.id, differenceID: proposal.id, kind: .removePlaylist,
                targetID: left.id, title: left.name, detail: proposal.detail)]
            return proposal
        }
        guard let left = applePlaylist, let right = spotifyPlaylist, left.contentsComplete, right.contentsComplete else { return nil }
        if service == .appleMusic {
            guard right.editable else { return nil }
            let desired = left.trackIDs.compactMap { id in report.matches.first { $0.sourceService == .appleMusic && $0.source.id == id }?.selected }
            guard desired.count == left.trackIDs.count else { return nil }
            if left.name != right.name { proposal.spotifyOperations.append(.init(service: .spotify, kind: .renamePlaylist, targetID: right.id, title: left.name, playlistName: left.name)) }
            if desired.map(\.playableID) != right.tracks.map(\.playableID) {
                proposal.spotifyOperations.append(.init(service: .spotify, kind: .replacePlaylistTracks, targetID: right.id, title: left.name,
                                                       tracks: desired, beforeTrackIDs: right.tracks.map(\.playableID)))
            }
            proposal.destination = .spotify; proposal.sourceID = left.id; proposal.destinationID = right.id; proposal.tracks = desired
        } else {
            proposal.destination = .appleMusic; proposal.sourceID = right.id; proposal.destinationID = left.id
            proposal.appleMusicTasks = [.init(id: "manual:" + proposal.id, differenceID: proposal.id, kind: .replacePlaylistTracks,
                targetID: left.id, title: right.name, detail: "Igualar manualmente nombre y secuencia a Spotify, incluidas sus repeticiones.", tracks: right.tracks)]
        }
        return proposal
    }

    func establishBaseline() {
        guard !isWorking, let library, let spotify, spotify.complete, library.complete,
              outstanding.allSatisfy({ isIgnored($0) }),
              !session.batches.contains(where: { [.queued, .applying, .attention, .manual].contains($0.state) }) else {
            errorMessage = "Resolvé, omití explícitamente o verificá las diferencias antes de guardar la referencia."; return
        }
        session.baseline = .init(library: library, spotify: spotify, appleSnapshot: session.appleSnapshot)
        session.baselineScope = session.configuration.scope
        session.baselineIncludesUncertainSongs = session.configuration.includeUncertainXMLSongs; persist()
        statusText = "Referencia de comparación guardada para este alcance y estas fuentes."
    }

    func cancel() {
        revokeQueued("Cancelado. Revisá y confirmá los cambios pendientes otra vez."); persist()
        if isApplying { Task { await executor?.cancel() }; statusText = "Deteniendo nuevos envíos y verificando la petición en curso…" }
        else {
            analysisTask?.cancel(); libraryReadID = nil; libraryProgress = nil
            searches.values.forEach { $0.cancel() }; statusText = "Deteniendo el análisis; se conservan los resultados revisados."
        }
    }

    func reconcile(_ batchID: UUID) {
        guard !isWorking, !externalBusy(), let executor, let i = session.batches.firstIndex(where: { $0.id == batchID }), let runID = session.batches[i].runID else { return }
        isApplying = true
        applicationTask = Task {
            defer { isApplying = false }
            do {
                if try await store?.load(id: runID) == nil {
                    session.batches[i].state = .revoked
                    session.batches[i].message = "El lote se interrumpió antes de crear su journal. No hay envío registrado; podés analizar y confirmar otra vez."
                    persist(); return
                }
                let record = try await executor.reconcile(id: runID, providers: providers)
                session.batches[i].state = record.executions.contains(where: { $0.state == .unknown || $0.state == .applying }) ? .attention : .revoked
                session.batches[i].message = record.summary.message
                statusText = record.summary.message; persist(); onRun?()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func scheduleApplication() {
        guard !isWorking, !externalBusy(), let batch = session.batches.first(where: { $0.state == .queued }),
              let library, let spotify, let executor else { return }
        guard (batch.expectedSourceDigest ?? batch.sourceDigest) == library.documentDigest else { revokeQueued("La exportación cambió."); persist(); return }
        isApplying = true
        applicationTask = Task {
            defer { isApplying = false; scheduleApplication() }
            guard let i = session.batches.firstIndex(where: { $0.id == batch.id }) else { return }
            do {
                try await saveTask?.value
                if batch.operations.isEmpty {
                    session.batches[i].state = .manual; session.batches[i].message = "Tareas manuales confirmadas. Reimportá Música para verificar su presencia."
                    persist(); return
                }
                let runID = UUID()
                session.batches[i].state = .applying; session.batches[i].runID = runID
                persist(); try await saveTask?.value
                let record: RunRecord
                if let apple = session.appleSnapshot {
                    let plan = SyncPlan(mode: batch.separateReview ? .appleMusicBase : .merge, snapshots: [spotify, apple], operations: batch.operations)
                    record = try await executor.execute(plan: plan, selectedIDs: Set(batch.operations.map(\.id)), decisions: session.decisions, providers: providers, isDemo: session.isDemo, runID: runID, scopedApproval: true)
                } else {
                    guard let provider = providers[.spotify] else { throw SyncExecutionError.missingProvider }
                    let source = try SnapshotTransferSource(library: library, differenceIDs: Array(batch.differenceIDs), approvedAt: batch.approvedAt, allowsDestructive: batch.separateReview)
                    record = try await executor.executeSnapshotTransfer(source: source, destination: spotify, operations: batch.operations,
                                decisions: session.decisions, provider: provider, isDemo: session.isDemo, runID: runID)
                }
                session.batches[i].runID = record.id; session.batches[i].message = record.summary.message
                let verified = record.executions.allSatisfy { $0.state == .verified }
                session.batches[i].state = verified ? (batch.manualTasks.isEmpty ? .verified : .manual) : .attention
                if verified {
                    if let fresh = record.finalSnapshots.first(where: { $0.account.service == .spotify }) ?? record.checkpoints.first(where: { $0.account.service == .spotify }) { session.spotify = fresh }
                    if let fresh = record.finalSnapshots.first(where: { $0.account.service == .appleMusic }) {
                        session.appleSnapshot = fresh; session.library = Self.importedRepresentation(fresh)
                        for queued in session.batches.indices where session.batches[queued].state == .queued {
                            session.batches[queued].expectedSourceDigest = session.library?.documentDigest
                        }
                    }
                    for step in record.executions where step.state == .verified && step.operation.kind == .createPlaylist {
                        if let source = step.operation.sourcePlaylist, let id = step.receipt?.createdID, step.operation.service == .spotify {
                            session.configuration.playlistPairings.removeAll { $0.appleMusicID == source.playlistID }
                            session.configuration.playlistPairings.append(.init(spotifyID: id, appleMusicID: source.playlistID))
                        }
                    }
                    revision += 1; await publishReport()
                } else { revokeQueued("La ejecución anterior requiere revisión antes de enviar otro lote.") }
                statusText = record.summary.message; persist(); onRun?()
                onSnapshots?([session.spotify, session.appleSnapshot].compactMap { $0 })
            } catch {
                session.batches[i].state = .attention; session.batches[i].message = error.localizedDescription
                errorMessage = error.localizedDescription; revokeQueued("Revisá la ejecución anterior."); persist()
            }
        }
    }

    private func publishReport() async {
        guard let library, let spotify else { return }
        let decisions = session.decisions, configuration = session.configuration, apple = session.appleSnapshot
        let baseline = session.baselineScope == configuration.scope && session.baselineIncludesUncertainSongs == configuration.includeUncertainXMLSongs ? session.baseline : nil
        let expected = revision, token = generation
        var value = await Task.detached(priority: .userInitiated) {
            LibraryComparison.compare(library: library, spotify: spotify, decisions: decisions, configuration: configuration, baseline: baseline, appleSnapshot: apple)
        }.value
        guard revision == expected, generation == token else { return }
        for (unit, resolution) in session.resolutions where resolution.sourceDigest == library.documentDigest && resolution.spotifyFingerprint == spotify.stateFingerprint {
            value.differences.removeAll { $0.unitID == unit }; value.differences += resolution.differences
        }
        session.report = value
        for i in session.batches.indices where session.batches[i].state == .manual {
            let outstandingUnits = Set(value.differences.map(\.unitID))
            if library.complete, session.batches[i].sourceDigest != library.documentDigest,
               session.batches[i].scope == configuration.scope,
               session.batches[i].unitIDs.isDisjoint(with: outstandingUnits) {
                session.batches[i].state = .verified; session.batches[i].message = "Tareas verificadas en la nueva lectura de Música."
            }
        }
    }

    private func resolve(_ track: Track, service: MusicService, provider: any MusicProvider) async throws -> TrackMatch {
        let id = "\(service.rawValue):\(track.id)"
        var source = track; source.isLocal = false
        let local = service == .appleMusic ? (spotify?.allTracks ?? []) : (session.appleSnapshot?.allTracks ?? [])
        let previous = session.decisions.tracks.first { $0.id == id }
        if let previous, previous.manualSelection == true, CatalogMatcher.sameIdentityMetadata(previous.source, track), let chosen = previous.selected {
            guard let fresh = try await provider.catalogTrack(id: chosen.playableID), fresh.available, !fresh.isLocal,
                  CatalogMatcher.sameIdentityMetadata(chosen, fresh) else {
                var invalid = previous; invalid.selected = nil; invalid.decision = .pending; invalid.manualSelection = false
                invalid.reason = "La edición elegida dejó de estar disponible o cambió; elegí una equivalencia otra vez."
                revokeQueued("Cambió la disponibilidad de una edición elegida.")
                return invalid
            }
            var result = previous; result.source = track; result.selected = fresh; return result
        }
        var match = CatalogMatcher.track(source, candidates: local, sourceService: service)
        if match.selected == nil {
            let result = try await CatalogSearch.search(source: source, provider: provider)
            searchResults[id] = result
            match = CatalogSearch.match(source: source, sourceService: service, result: result)
        }
        match.source = track; match.rejectedCandidateIDs = previous?.rejectedCandidateIDs
        let rejected = Set(previous?.rejectedCandidateIDs ?? [])
        match.candidates.removeAll { rejected.contains($0.playableID) }
        if let selected = match.selected, rejected.contains(selected.playableID) { match.selected = nil; match.decision = .pending }
        return match
    }

    private func sourceTrack(matchID: String) -> (Track, MusicService)? {
        if let found = library?.tracks.first(where: { "appleMusic:\($0.id)" == matchID }) { return (found, .appleMusic) }
        if let found = spotify?.allTracks.first(where: { "spotify:\($0.id)" == matchID }) { return (found, .spotify) }
        return nil
    }
    private func relevantAppleTracks(_ library: ManualMusicLibrary) -> [Track] {
        let scope = session.configuration.scope
        if scope.songs || scope.albums { return library.tracks }
        let ids = Set((library.inventory?.playlists ?? []).filter { scope.playlists && (scope.appleMusicPlaylistIDs?.contains($0.id) ?? true) }.flatMap(\.trackIDs))
        return library.tracks.filter { ids.contains($0.id) }
    }
    private func relevantSpotifyTracks(_ snapshot: LibrarySnapshot) -> [Track] {
        let scope = session.configuration.scope
        if scope.songs || scope.albums { return snapshot.allTracks }
        return CatalogMatcher.unique(snapshot.playlists.filter { scope.playlists && (scope.spotifyPlaylistIDs?.contains($0.id) ?? true) }.flatMap(\.tracks))
    }
    private func revokeQueued(_ reason: String) {
        for i in session.batches.indices where session.batches[i].state == .queued { session.batches[i].state = .revoked; session.batches[i].message = reason }
        revision += 1
    }
    private func persist() {
        guard loaded, let store, let key = archive.activeKey else { return }
        archive.sessions[key] = session; let value = archive, previous = saveTask
        let task = Task { if let previous { _ = await previous.result }; try await store.saveDocument(value, key: "library-comparison-v1") }
        saveTask = task
        Task { do { try await task.value } catch { errorMessage = "No se pudo guardar la comparación. \(error.localizedDescription)" } }
    }
    private static func scopeKey(source: ManualMusicLibrary, spotify: LibrarySnapshot, demo: Bool) -> String {
        let fields = [demo ? "demo" : "live", source.id, spotify.account.id, spotify.account.storefront ?? ""]
        return SHA256.hash(data: Data(fields.map { "\($0.utf8.count):\($0)" }.joined().utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private static func signature(_ value: LibraryDifference) -> String {
        [value.id, value.detail] .joined(separator: "|")
    }
    static func importedRepresentation(_ snapshot: LibrarySnapshot) -> ManualMusicLibrary {
        let tracks = snapshot.allTracks
        let saved = Set(snapshot.savedTracks.map(\.id))
        let info = Dictionary(uniqueKeysWithValues: tracks.enumerated().map { ($0.element.id, XMLTrackInfo(referenceID: $0.offset + 1, playlistOnly: !saved.contains($0.element.id))) })
        let lists = snapshot.playlists.map { XMLMusicPlaylist(id: $0.id, name: $0.name, trackIDs: $0.tracks.map(\.id), contentsComplete: $0.contentsComplete, artworkURL: $0.artworkURL) }
        return ManualMusicLibrary(id: "apple-music-api:\(snapshot.account.id)", fileName: "Integración oficial de Apple Music", importedAt: snapshot.fetchedAt,
                                  exportedAt: snapshot.fetchedAt, tracks: tracks, warnings: snapshot.coverage.notes, complete: snapshot.complete,
                                  inventory: .init(playlists: lists, trackInfo: info, playlistsComplete: snapshot.coverage.playlists), documentDigest: snapshot.stateFingerprint)
    }
}
