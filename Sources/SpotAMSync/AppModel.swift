import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
import SyncCore
import MusicProviders

enum AppPhase { case idle, connecting, analyzing, review, syncing, finished }

@MainActor
final class AppModel: ObservableObject {
    @Published var spotifyClientID = UserDefaults.standard.string(forKey: "spotifyClientID") ?? ""
    @Published var accounts: [MusicService: ConnectedAccount] = [:]
    @Published var snapshots: [LibrarySnapshot] = []
    @Published var mode: SyncMode = .spotifyBase
    @Published var plan: SyncPlan?
    @Published var selectedOperationIDs: Set<UUID> = []
    @Published var decisions = MatchDecisions()
    @Published var phase: AppPhase = .idle
    @Published var statusText = "Conectá tus cuentas para comparar sus bibliotecas."
    @Published var progress: Double = 0
    @Published var completedCount = 0
    @Published var totalCount = 0
    @Published var logs: [String] = []
    @Published var errorMessage: String?
    @Published var isDemo = false
    @Published var history: [RunSummary] = []
    @Published var lastResult: RunSummary?
    @Published var canResume = false
    @Published var isReconciling = false
    let manualChecklist = ManualChecklistModel()
    private var manualChanges: AnyCancellable?

    var isBusy: Bool { [.connecting, .analyzing, .syncing].contains(phase) || manualChecklist.isBusy }
    var displayedStatusText: String { manualChecklist.isBusy && phase == .idle ? manualChecklist.statusText : statusText }
    var canGenerateManualChecklist: Bool { accounts[.spotify] != nil && !isDemo && !isBusy && manualChecklist.library != nil }
    var canAnalyze: Bool { accounts.count == 2 && !isBusy }
    var canExecute: Bool { accounts.count == 2 && snapshots.count == 2 && snapshots.allSatisfy(\.complete) && !selectedOperations.isEmpty && !isBusy }
    var selectedOperations: [SyncOperation] { plan?.executable.filter { selectedOperationIDs.contains($0.id) } ?? [] }
    private var providers: [MusicService: any MusicProvider] = [:]
    private var store: SyncStore?
    private var executor: SyncExecutor?
    private var workTask: Task<Void, Never>?
    private var approvalUpdateTask: Task<Void, Error>?
    private var executionStartCancelled = false
    private var lastRecord: RunRecord?
    private var resumeRecord: RunRecord?
    private var capabilities: [MusicService: ProviderCapabilities] = [.spotify: .spotify, .appleMusic: .appleMusic]

    init() {
        manualChanges = manualChecklist.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        do {
            let base: URL
            if let override = ProcessInfo.processInfo.environment["SPOTAM_DATA_DIR"] {
                base = URL(fileURLWithPath: override, isDirectory: true)
            } else {
                base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("SpotAMSync", isDirectory: true)
            }
            let storage = try SyncStore(url: base.appendingPathComponent("library-sync.sqlite"))
            store = storage; executor = SyncExecutor(store: storage)
            refreshHistory()
        } catch { errorMessage = error.localizedDescription }
    }

    /// The manual workflow reads Spotify only. The XML is never treated as a
    /// live Apple authorization or sent to the synchronization executor.
    func generateManualChecklist() {
        guard canGenerateManualChecklist, let provider = providers[.spotify],
              let expected = accounts[.spotify] else { return }
        manualChecklist.generate(isDemo: false) {
            let snapshot = try await provider.fetchLibrary()
            try Task.checkCancellation()
            guard snapshot.account.service == .spotify,
                  snapshot.account.id == expected.id,
                  snapshot.account.connectionRevision == expected.connectionRevision else {
                throw SyncExecutionError.stale("La conexión de Spotify cambió mientras se leía la biblioteca. Volvé a generar la lista.")
            }
            return snapshot
        }
    }

    func connectSpotify() {
        guard !isBusy else { return }
        let clientID = spotifyClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty else { errorMessage = "Ingresá el Client ID público de tu app de Spotify."; return }
        UserDefaults.standard.set(clientID, forKey: "spotifyClientID")
        leaveDemoIfNeeded()
        revokePreviousApprovals()
        let provider = SpotifyProvider(clientID: clientID)
        phase = .connecting; errorMessage = nil; statusText = "Esperando autorización de Spotify en el navegador…"
        workTask = Task {
            do {
                let account = try await provider.connect()
                providers[.spotify] = provider; accounts[.spotify] = account
                invalidatePlan(); statusText = "Spotify conectado: \(account.displayName)."
            } catch { errorMessage = error.localizedDescription; statusText = "La conexión de Spotify no se completó." }
            phase = .idle
            refreshHistory()
        }
    }

    func connectAppleMusic() {
        guard !isBusy else { return }
        leaveDemoIfNeeded()
        revokePreviousApprovals()
        let provider = AppleMusicProvider()
        phase = .connecting; errorMessage = nil; statusText = "Solicitando acceso a Apple Music…"
        workTask = Task {
            do {
                let account = try await provider.connect()
                providers[.appleMusic] = provider; accounts[.appleMusic] = account
                invalidatePlan(); statusText = "Apple Music conectado."
            } catch { errorMessage = error.localizedDescription; statusText = "Apple Music necesita completar su configuración." }
            phase = .idle
            refreshHistory()
        }
    }

    func disconnect(_ service: MusicService) {
        guard !isBusy else { return }
        let provider = providers[service]
        revokePreviousApprovals()
        phase = .connecting; statusText = "Desconectando \(service.name)…"
        workTask = Task {
            do {
                if let spotify = provider as? SpotifyProvider { try await spotify.disconnect() }
                if let apple = provider as? AppleMusicProvider { try await apple.disconnect() }
            } catch { errorMessage = error.localizedDescription }
            providers[service] = nil; accounts[service] = nil; invalidatePlan()
            phase = .idle; statusText = "\(service.name) desconectado de esta app."
            refreshHistory()
        }
    }

    func loadDemo() {
        guard !isBusy else { return }
        isDemo = true; errorMessage = nil; lastRecord = nil; lastResult = nil; canResume = false
        decisions = DemoFixtures.decisions(); snapshots = DemoFixtures.snapshots()
        let demoSession = UUID().uuidString
        for index in snapshots.indices {
            snapshots[index].account.id = "demo:\(demoSession):\(snapshots[index].account.service.rawValue)"
            snapshots[index].account.connectionRevision = demoSession
        }
        providers = [:]; accounts = [:]
        for snapshot in snapshots {
            let tracks = decisions.tracks.filter { $0.sourceService.other == snapshot.account.service }.compactMap(\.selected)
            let albums = decisions.albums.filter { $0.sourceService.other == snapshot.account.service }.compactMap(\.selected)
            providers[snapshot.account.service] = DemoMusicProvider(snapshot: snapshot, catalogTracks: tracks, catalogAlbums: albums)
            accounts[snapshot.account.service] = snapshot.account
        }
        logs = []; rebuildPlan(); statusText = "Demostración con bibliotecas ficticias. Ninguna cuenta real se modificará."
    }

    func analyze() {
        guard canAnalyze else { return }
        phase = .analyzing; errorMessage = nil; plan = nil; selectedOperationIDs = []
        progress = 0; logs = []; statusText = "Leyendo playlists, canciones y álbumes…"
        workTask = Task {
            do {
                var fresh: [LibrarySnapshot] = []
                for service in MusicService.allCases {
                    try Task.checkCancellation()
                    guard let provider = providers[service] else { throw SyncExecutionError.missingProvider }
                    statusText = "Analizando \(service.name)…"
                    fresh.append(try await provider.fetchLibrary())
                    capabilities[service] = await provider.capabilities()
                }
                snapshots = fresh
                if !isDemo, let stored = try await store?.loadDecisions(accountPair: accountPair(fresh)) { decisions = stored }
                // Compare both directions so changing the base also exposes the other side's missing music.
                let sources = fresh
                let total = sources.reduce(0) { $0 + $1.allTracks.count + $1.savedAlbums.count }
                var processed = 0
                var trackMatches: [TrackMatch] = [], albumMatches: [AlbumMatch] = []
                for source in sources {
                    guard let destination = fresh.first(where: { $0.account.service == source.account.service.other }), let provider = providers[destination.account.service] else { throw SyncExecutionError.missingProvider }
                    for track in source.allTracks {
                        try Task.checkCancellation()
                        statusText = "Buscando coincidencias: \(track.title)"
                        var candidates = destination.allTracks
                        var match = CatalogMatcher.track(track, candidates: candidates, sourceService: source.account.service)
                        let previous = decisions.tracks.first { $0.sourceService == source.account.service && $0.source.id == track.id }
                        if match.confidence != .exact {
                            let search: CatalogSearchResult<Track>
                            do { search = try await provider.searchTracks(matching: track) }
                            catch is CancellationError { throw CancellationError() }
                            catch {
                                search = .init(coverage: .failed, notes: [error.localizedDescription])
                            }
                            candidates += search.candidates
                            logs += search.notes.map { "\(track.title): \($0)" }
                            match = CatalogMatcher.track(track, candidates: uniqueTracks(candidates), sourceService: source.account.service, coverage: search.coverage)
                            if !search.notes.isEmpty { match.reason += " " + Array(Set(search.notes)).sorted().joined(separator: " ") }
                        }
                        let rememberedCandidates = previous?.selected.map { selected in uniqueTracks(candidates).filter { $0.playableID == selected.playableID } } ?? []
                        if previous?.manualSelection == true, previous?.source == track, let selected = previous?.selected,
                           rememberedCandidates.count == 1, let found = rememberedCandidates.first, CatalogMatcher.unique([found, selected]).count == 1, found.available {
                            match.selected = found; match.confidence = .exact; match.manualSelection = true
                            match.reason = "Correspondencia elegida manualmente para estas cuentas. " + match.reason
                        }
                        trackMatches.append(match); processed += 1
                        progress = total == 0 ? 1 : Double(processed) / Double(total)
                    }
                    for album in source.savedAlbums {
                        try Task.checkCancellation()
                        statusText = "Comparando álbum: \(album.title)"
                        var candidates = destination.savedAlbums
                        var match = CatalogMatcher.album(album, candidates: candidates, sourceService: source.account.service)
                        if match.confidence != .exact {
                            let search: CatalogSearchResult<Album>
                            do { search = try await provider.searchAlbums(matching: album) }
                            catch is CancellationError { throw CancellationError() }
                            catch { search = .init(coverage: .failed, notes: [error.localizedDescription]) }
                            candidates = CatalogMatcher.uniqueAlbums(candidates + search.candidates)
                            logs += search.notes.map { "\(album.title): \($0)" }
                            match = CatalogMatcher.album(album, candidates: candidates, sourceService: source.account.service, coverage: search.coverage)
                            if !search.notes.isEmpty { match.reason += " " + Array(Set(search.notes)).sorted().joined(separator: " ") }
                        }
                        let previous = decisions.albums.first { $0.sourceService == source.account.service && $0.source.id == album.id }
                        let rememberedCandidates = previous?.selected.map { selected in CatalogMatcher.uniqueAlbums(candidates).filter { $0.playableID == selected.playableID } } ?? []
                        if previous?.manualSelection == true, previous?.source == album, let selected = previous?.selected,
                           rememberedCandidates.count == 1, let found = rememberedCandidates.first, CatalogMatcher.uniqueAlbums([found, selected]).count == 1, found.available {
                            match.selected = found; match.confidence = .exact; match.manualSelection = true
                            match.reason = "Correspondencia elegida manualmente para estas cuentas. " + match.reason
                        }
                        albumMatches.append(match); processed += 1
                        progress = total == 0 ? 1 : Double(processed) / Double(total)
                    }
                }
                decisions.tracks = trackMatches; decisions.albums = albumMatches
                phase = .review; rebuildPlan(); persistDecisions()
                statusText = "Análisis listo. Revisá las coincidencias y los cambios antes de confirmar."
            } catch is CancellationError {
                phase = .idle; statusText = "Análisis cancelado. No se modificó ninguna biblioteca."
            } catch {
                phase = .idle; errorMessage = error.localizedDescription; statusText = "No se pudo completar el análisis."
            }
        }
    }

    func rebuildPlan() {
        guard !isBusy, snapshots.count == 2 else { return }
        revokePreviousApprovals()
        let newPlan = SyncPlanner.makePlan(snapshots: snapshots, mode: mode, decisions: decisions, capabilities: capabilities)
        plan = newPlan; selectedOperationIDs = Set(newPlan.executable.map(\.id))
        phase = .review; lastResult = nil; progress = 0
    }

    func executeApproved() {
        guard canExecute, let plan, let executor else { return }
        let approvedIDs = selectedOperationIDs, approvedDecisions = decisions, approvedProviders = providers, demo = isDemo
        executionStartCancelled = false
        phase = .syncing; errorMessage = nil; lastResult = nil; isReconciling = false; progress = 0; completedCount = 0; totalCount = approvedIDs.count; canResume = false
        let priorApprovalUpdate = approvalUpdateTask
        workTask = Task { [self] in
            do {
                try await priorApprovalUpdate?.value
                guard !executionStartCancelled else {
                    phase = .finished; statusText = "Cancelado antes de iniciar la ejecución. No se enviaron cambios."
                    refreshHistory()
                    return
                }
                let result = try await executor.execute(plan: plan, selectedIDs: approvedIDs, decisions: approvedDecisions, providers: approvedProviders, isDemo: demo) { [weak self] update in
                    await self?.apply(update)
                }
                finish(result)
            } catch { phase = .finished; errorMessage = error.localizedDescription; statusText = "La ejecución se detuvo. Revisá el historial antes de reintentar." }
            refreshHistory()
        }
    }

    func cancel() {
        if phase == .syncing {
            executionStartCancelled = true
            statusText = "Deteniendo nuevas operaciones y comprobando la petición en curso…"
            if isReconciling { workTask?.cancel() }
            else { Task { await executor?.cancel() } }
        } else if manualChecklist.isBusy { manualChecklist.cancel() }
        else { workTask?.cancel() }
    }

    func resume() {
        guard !isBusy, let record = resumeRecord, record.isDemo == isDemo, let executor, accounts.count == 2 else { return }
        phase = .syncing; errorMessage = nil; lastResult = nil; isReconciling = true
        let activeProviders = providers
        let priorApprovalUpdate = approvalUpdateTask
        workTask = Task { [self] in
            do {
                try await priorApprovalUpdate?.value
                // Recovery gathers evidence only. Continuing requires a fresh preview and approval.
                let result = try await executor.reconcile(id: record.id, providers: activeProviders) { [weak self] update in await self?.apply(update) }
                finish(result)
            } catch { errorMessage = error.localizedDescription; phase = .finished }
            isReconciling = false
            refreshHistory()
        }
    }

    func selectTrack(matchID: String, targetID: String?) {
        guard !isBusy, let i = decisions.tracks.firstIndex(where: { $0.id == matchID }) else { return }
        decisions.tracks[i].selected = decisions.tracks[i].candidates.first { $0.id == targetID }
        decisions.tracks[i].confidence = decisions.tracks[i].selected == nil ? .review : .exact
        decisions.tracks[i].manualSelection = decisions.tracks[i].selected != nil
        decisions.tracks[i].reason = "Selección manual."
        rebuildPlan(); persistDecisions()
    }
    func selectAlbum(matchID: String, targetID: String?) {
        guard !isBusy, let i = decisions.albums.firstIndex(where: { $0.id == matchID }) else { return }
        decisions.albums[i].selected = decisions.albums[i].candidates.first { $0.id == targetID }
        decisions.albums[i].confidence = decisions.albums[i].selected == nil ? .review : .exact
        decisions.albums[i].manualSelection = decisions.albums[i].selected != nil
        decisions.albums[i].reason = "Selección manual."
        rebuildPlan(); persistDecisions()
    }
    func linkPlaylists(spotifyID: String, appleMusicID: String) {
        guard !isBusy else { return }
        decisions.playlists.removeAll { $0.spotifyID == spotifyID || $0.appleMusicID == appleMusicID }
        decisions.playlists.append(PlaylistLink(spotifyID: spotifyID, appleMusicID: appleMusicID))
        rebuildPlan(); persistDecisions()
    }
    func unlinkPlaylists(_ link: PlaylistLink) {
        guard !isBusy, decisions.playlists.contains(link) else { return }
        decisions.playlists.removeAll { $0 == link }
        rebuildPlan(); persistDecisions()
    }
    func protectPlaylist(service: MusicService, id: String, protected: Bool) {
        guard !isBusy else { return }
        if protected { decisions.protectedPlaylistIDs[service, default: []].insert(id) }
        else { decisions.protectedPlaylistIDs[service]?.remove(id) }
        rebuildPlan(); persistDecisions()
    }

    func refreshHistory() {
        Task {
            do {
                let recent = try await store?.recent(limit: 500) ?? []
                let unresolved = try await store?.unresolvedRuns(accountIDs: accounts.mapValues(\.id)) ?? []
                var seen = Set<UUID>()
                let records = (recent + unresolved).filter { seen.insert($0.id).inserted }.sorted { $0.summary.startedAt > $1.summary.startedAt }
                history = records.map { record in
                    var summary = record.summary
                    if summary.status == .running { summary.status = .interrupted }
                    if record.isDemo { summary.message = summary.message.hasPrefix("Demostración:") ? summary.message : "Demostración: " + summary.message }
                    return summary
                }
                let eligible = records.filter { record in
                    record.isDemo == isDemo && record.summary.status != .completed && record.executions.contains(where: { $0.state != .verified }) &&
                    record.plan.snapshots.allSatisfy { accounts[$0.account.service]?.id == $0.account.id }
                }
                resumeRecord = eligible.first { $0.executions.contains { $0.state == .unknown || $0.state == .applying } } ?? eligible.first
                canResume = resumeRecord != nil && accounts.count == 2 && !isBusy
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func exportReport() {
        if let lastRecord { saveJSON(lastRecord, filename: "SpotAMSync-resultado.json") }
        else if let plan { saveJSON(plan, filename: "SpotAMSync-plan.json") }
    }
    func exportBackup() {
        let inventory = lastRecord?.plan.snapshots ?? snapshots
        guard !inventory.isEmpty else { return }
        saveJSON(inventory, filename: "SpotAMSync-respaldo.json")
    }

    func exportHistoricalRun(id: UUID, backupOnly: Bool) {
        guard !isBusy, let store else { return }
        Task {
            do {
                guard let record = try await store.load(id: id) else {
                    errorMessage = "No se encontró el registro de esta ejecución."
                    return
                }
                if backupOnly { saveJSON(record.plan.snapshots, filename: "SpotAMSync-respaldo-\(id.uuidString).json") }
                else { saveJSON(record, filename: "SpotAMSync-registro-\(id.uuidString).json") }
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func finish(_ record: RunRecord) {
        lastRecord = record; lastResult = record.summary; phase = .finished
        completedCount = record.summary.verifiedCount; totalCount = record.summary.totalCount
        progress = totalCount == 0 ? 0 : Double(completedCount) / Double(totalCount)
        statusText = record.summary.message; logs = record.summary.logs; decisions = record.decisions
        if !record.finalSnapshots.isEmpty { snapshots = record.finalSnapshots }
        else { snapshots = record.checkpoints }
        persistDecisions()
    }
    private func apply(_ update: SyncProgress) {
        completedCount = update.completed; totalCount = update.total
        progress = update.total == 0 ? 0 : Double(update.completed) / Double(update.total)
        statusText = update.message; logs = update.logs
    }
    private func invalidatePlan() { plan = nil; snapshots = []; selectedOperationIDs = []; decisions = MatchDecisions(); lastResult = nil; canResume = false }
    private func leaveDemoIfNeeded() {
        if isDemo { providers = [:]; accounts = [:]; isDemo = false; invalidatePlan() }
    }
    private func accountPair(_ inventory: [LibrarySnapshot]) -> String {
        inventory.sorted { $0.account.service.rawValue < $1.account.service.rawValue }.map {
            // Apple IDs identify the captured authorization grant, never an inferred Apple ID.
            "\($0.account.service.rawValue):\($0.account.id):\($0.account.storefront ?? "")"
        }.joined(separator: "|")
    }
    private func persistDecisions() {
        guard !isDemo, snapshots.count == 2, let store else { return }
        let value = decisions, key = accountPair(snapshots)
        Task { do { try await store.saveDecisions(value, accountPair: key) } catch { errorMessage = error.localizedDescription } }
    }
    private func uniqueTracks(_ tracks: [Track]) -> [Track] {
        CatalogMatcher.unique(tracks)
    }
    private func revokePreviousApprovals() {
        guard let store, !accounts.isEmpty else { return }
        let ids = accounts.mapValues(\.id), previous = approvalUpdateTask
        approvalUpdateTask = Task {
            try await previous?.value
            try await store.revokeApprovals(accountIDs: ids)
        }
    }
    private func saveJSON<T: Encodable>(_ value: T, filename: String) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = filename; panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(value).write(to: url, options: .atomic)
        } catch { errorMessage = error.localizedDescription }
    }
}
