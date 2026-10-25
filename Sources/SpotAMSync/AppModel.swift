import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
import SyncCore
import MusicProviders

enum AppPhase { case idle, connecting, analyzing, searching, review, syncing, finished }

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
    @Published private(set) var libraryProgress: LibraryReadProgress?
    private var libraryReadID: UUID?
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
    let manualChecklist: ManualChecklistModel
    let workspace = WorkspaceCoordinator()
    @Published var activeRequest: SyncRequest?
    @Published var activeJobID: UUID?
    @Published var selectedHistoryRecord: RunRecord?
    private var requestedHistoryID: UUID?
    @Published var navigationRequest: AppDestination?
    @Published var selectedPlaylistReference: PlaylistReference?
    @Published var editingProfileID: UUID?
    @Published var holdsAutomaticPreparation = false
    private var workspaceChanges: AnyCancellable?
    private var manualChanges: AnyCancellable?

    var isBusy: Bool { [.connecting, .analyzing, .searching, .syncing].contains(phase) || manualChecklist.isBusy }
    var displayedStatusText: String { manualChecklist.isBusy && phase == .idle ? manualChecklist.statusText : statusText }
    var canGenerateManualChecklist: Bool { accounts[.spotify] != nil && !isDemo && !isBusy && manualChecklist.library != nil }
    var canAnalyze: Bool { accounts.count == 2 && !isBusy }
    var canExecute: Bool { accounts.count == 2 && snapshots.count == 2 && snapshots.allSatisfy(\.complete) && !selectedOperations.isEmpty && !isBusy && workspace.validate(activeRequest) && (activeJobID == nil || workspace.state.jobs.first(where: { $0.id == activeJobID })?.state == .ready) }
    var selectedOperations: [SyncOperation] { plan?.executable.filter { selectedOperationIDs.contains($0.id) } ?? [] }
    private var providers: [MusicService: any MusicProvider] = [:]
    private var store: SyncStore?
    private var executor: SyncExecutor?
    private var workTask: Task<Void, Never>?
    private var approvalUpdateTask: Task<Void, Error>?
    private var decisionSaveTask: Task<Void, Never>?
    private var executionStartCancelled = false
    private var lastRecord: RunRecord?
    private var resumeRecord: RunRecord?
    private var capabilities: [MusicService: ProviderCapabilities] = [.spotify: .spotify, .appleMusic: .appleMusic]

    init(storageDirectory: URL? = nil, initialProviders: [MusicService: any MusicProvider] = [:], systemServices: Bool = true) {
        manualChecklist = ManualChecklistModel(storageDirectory: storageDirectory)
        manualChanges = manualChecklist.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        do {
            let base: URL
            if let storageDirectory {
                base = storageDirectory; spotifyClientID = ""
            } else if let override = ProcessInfo.processInfo.environment["SPOTAM_DATA_DIR"] {
                base = URL(fileURLWithPath: override, isDirectory: true)
                spotifyClientID = ""
            } else {
                base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("SpotAMSync", isDirectory: true)
            }
            let storage = try SyncStore(url: base.appendingPathComponent("library-sync.sqlite"))
            store = storage; executor = SyncExecutor(store: storage)
            workspaceChanges = workspace.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            workspace.start(store: storage, systemServices: systemServices) { [weak self] in self?.workspaceTick() }
            if !initialProviders.isEmpty {
                providers = initialProviders
                Task {
                    do { for (service, provider) in initialProviders { accounts[service] = try await provider.account() } }
                    catch { errorMessage = error.localizedDescription }
                }
            }
            refreshHistory()
        } catch { errorMessage = error.localizedDescription }
    }

    /// The manual workflow reads Spotify only. The XML is never treated as a
    /// live Apple authorization or sent to the synchronization executor.
    func generateManualChecklist() {
        guard canGenerateManualChecklist, let provider = providers[.spotify],
              let expected = accounts[.spotify] else { return }
        manualChecklist.generate(isDemo: false, fetchWithProgress: { observer in
            let snapshot = try await provider.fetchLibrary(progress: observer)
            try Task.checkCancellation()
            guard snapshot.account.service == .spotify,
                  snapshot.account.id == expected.id,
                  snapshot.account.connectionRevision == expected.connectionRevision else {
                throw SyncExecutionError.stale("La conexión de Spotify cambió mientras se leía la biblioteca. Volvé a generar la lista.")
            }
            return snapshot
        })
    }

    func connectSpotify() {
        guard !isBusy else { return }
        let clientID = spotifyClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty else { errorMessage = "Ingresá el Client ID público de tu app de Spotify."; return }
        saveSpotifyClientID(clientID)
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
        workspace.switchDemo(true)
        activeRequest = nil; activeJobID = nil
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

    func analyze(request: SyncRequest? = nil, jobID: UUID? = nil) {
        guard canAnalyze else { return }
        activeRequest = request; activeJobID = jobID
        if let request { mode = request.mode }
        if let jobID { workspace.setJob(jobID, state: .analyzing) }
        phase = .analyzing; errorMessage = nil; plan = nil; selectedOperationIDs = []
        progress = 0; logs = []; statusText = "Leyendo playlists, canciones y álbumes…"
        workTask = Task {
            do {
                var fresh: [LibrarySnapshot] = []
                for service in MusicService.allCases {
                    try Task.checkCancellation()
                    guard let provider = providers[service] else { throw SyncExecutionError.missingProvider }
                    statusText = "Analizando \(service.name)…"
                    fresh.append(try await readLibrary(provider))
                    try Task.checkCancellation()
                    capabilities[service] = await provider.capabilities()
                }
                if let request, !request.matches(accounts: fresh.map(\.account)) { throw SyncExecutionError.stale("La configuración corresponde a otras cuentas o región.") }
                snapshots = fresh
                await decisionSaveTask?.value
                if !isDemo, let stored = try await store?.loadDecisions(accountPair: accountPair(fresh)) { decisions = stored }
                // Compare both directions so changing the base also exposes the other side's missing music.
                let sources = matchingSources(fresh, request: request)
                let total = sources.reduce(0) { $0 + $1.allTracks.count + $1.savedAlbums.count }
                var processed = 0
                var trackMatches: [TrackMatch] = [], albumMatches: [AlbumMatch] = []
                for source in sources {
                    guard let destination = fresh.first(where: { $0.account.service == source.account.service.other }), let provider = providers[destination.account.service] else { throw SyncExecutionError.missingProvider }
                    for track in source.allTracks {
                        try Task.checkCancellation()
                        statusText = "Buscando coincidencias: \(track.title)"
                        let previous = decisions.tracks.first { $0.sourceService == source.account.service && $0.source.id == track.id }
                        let match = try await findMatch(track, sourceService: source.account.service, local: destination.allTracks, provider: provider, previous: previous)
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
                try Task.checkCancellation()
                if request != nil {
                    let trackIDs = Set(trackMatches.map(\.id)), albumIDs = Set(albumMatches.map(\.id))
                    decisions.tracks = decisions.tracks.filter { !trackIDs.contains($0.id) } + trackMatches
                    decisions.albums = decisions.albums.filter { !albumIDs.contains($0.id) } + albumMatches
                } else { decisions.tracks = trackMatches; decisions.albums = albumMatches }
                phase = .review; rebuildPlan(); persistDecisions()
                statusText = "Análisis listo. Revisá las coincidencias y los cambios antes de confirmar."
                workspaceTick()
            } catch is CancellationError {
                phase = .idle; statusText = "Análisis cancelado. No se modificó ninguna biblioteca."
                if let jobID { workspace.setJob(jobID, state: .paused, message: statusText) }
            } catch {
                phase = .idle; errorMessage = error.localizedDescription; statusText = "No se pudo completar el análisis."
                if let jobID { workspace.setJob(jobID, state: .attention, message: error.localizedDescription) }
            }
        }
    }

    func rebuildPlan() {
        guard !isBusy, snapshots.count == 2 else { return }
        revokePreviousApprovals()
        let newPlan = SyncPlanner.makePlan(snapshots: snapshots, mode: mode, decisions: decisions, capabilities: capabilities, request: activeRequest)
        plan = newPlan; selectedOperationIDs = Set(newPlan.executable.map(\.id))
        phase = .review; lastResult = nil; progress = 0
        if let activeJobID { workspace.ready(activeJobID, plan: newPlan, decisions: decisions) }
    }

    func executeApproved() {
        guard canExecute, let plan, let executor else { return }
        let approvedIDs = selectedOperationIDs, approvedDecisions = decisions, approvedProviders = providers, demo = isDemo, jobID = activeJobID
        executionStartCancelled = false
        phase = .syncing; errorMessage = nil; lastResult = nil; isReconciling = false; progress = 0; completedCount = 0; totalCount = approvedIDs.count; canResume = false
        let priorApprovalUpdate = approvalUpdateTask
        workTask = Task { [self] in
            do {
                try await priorApprovalUpdate?.value
                try await workspace.beginApplying(jobID: jobID, request: plan.request)
                guard !executionStartCancelled else {
                    phase = .finished; statusText = "Cancelado antes de iniciar la ejecución. No se enviaron cambios."
                    if let jobID { workspace.setJob(jobID, state: .paused, message: statusText) }
                    refreshHistory()
                    return
                }
                let result = try await executor.execute(plan: plan, selectedIDs: approvedIDs, decisions: approvedDecisions, providers: approvedProviders, isDemo: demo) { [weak self] update in
                    await self?.apply(update)
                }
                finish(result)
                workspace.finish(result, jobID: jobID)
            } catch {
                phase = .finished; errorMessage = error.localizedDescription; statusText = "La ejecución se detuvo. Revisá el historial antes de reintentar."
                if let jobID { workspace.setJob(jobID, state: .attention, message: error.localizedDescription) }
            }
            refreshHistory()
        }
    }

    private func readLibrary(_ provider: any MusicProvider) async throws -> LibrarySnapshot {
        try Task.checkCancellation()
        let id = UUID(); libraryReadID = id; libraryProgress = nil
        defer { if libraryReadID == id { libraryReadID = nil; libraryProgress = nil } }
        let snapshot = try await provider.fetchLibrary(progress: { [weak self] update in
            await self?.receiveLibraryProgress(update, id: id)
        })
        try Task.checkCancellation()
        return snapshot
    }

    private func receiveLibraryProgress(_ update: LibraryReadProgress, id: UUID) {
        guard libraryReadID == id, !Task.isCancelled else { return }
        libraryProgress = update; statusText = update.statusText
    }

    func cancel() {
        libraryReadID = nil; libraryProgress = nil
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
                try await workspace.recoverVerifiedTargets()
            } catch { errorMessage = error.localizedDescription; phase = .finished }
            isReconciling = false
            refreshHistory()
        }
    }

    func selectTrack(matchID: String, targetID: String?) {
        guard !isBusy, let i = decisions.tracks.firstIndex(where: { $0.id == matchID }) else { return }
        decisions.tracks[i].selected = decisions.tracks[i].candidates.first { $0.id == targetID }
        decisions.tracks[i].confidence = .review
        decisions.tracks[i].manualSelection = decisions.tracks[i].selected != nil
        decisions.tracks[i].decision = targetID == nil ? .pending : .manual
        decisions.tracks[i].reason = targetID == nil ? "Pendiente por decisión tuya." : "Equivalencia elegida manualmente."
        rebuildPlan(); persistDecisions(invalidateOtherDrafts: true)
    }

    func omitTrack(matchID: String) {
        guard !isBusy, let i = decisions.tracks.firstIndex(where: { $0.id == matchID }) else { return }
        decisions.tracks[i].selected = nil; decisions.tracks[i].manualSelection = false; decisions.tracks[i].decision = .omitted
        decisions.tracks[i].confidence = .review; decisions.tracks[i].reason = "Omitida por vos; no autoriza bajas."
        rebuildPlan(); persistDecisions(invalidateOtherDrafts: true)
    }

    func rejectTrack(matchID: String, candidateID: String) {
        guard !isBusy, let i = decisions.tracks.firstIndex(where: { $0.id == matchID }),
              let candidate = decisions.tracks[i].candidates.first(where: { $0.id == candidateID }) else { return }
        decisions.tracks[i].rejectedCandidateIDs = Array(Set((decisions.tracks[i].rejectedCandidateIDs ?? []) + [candidate.playableID])).sorted()
        decisions.tracks[i].candidates.removeAll { $0.playableID == candidate.playableID }
        if decisions.tracks[i].selected?.playableID == candidate.playableID { decisions.tracks[i].selected = nil }
        decisions.tracks[i].decision = decisions.tracks[i].selected == nil ? .pending : .manual
        decisions.tracks[i].confidence = .review
        rebuildPlan(); persistDecisions(invalidateOtherDrafts: true)
    }

    func searchTrack(matchID: String, query: TrackSearchQuery, restoreRejected: Bool = false) {
        guard !isBusy, query.valid, let original = decisions.tracks.first(where: { $0.id == matchID }),
              let provider = providers[original.sourceService.other] else { return }
        let context = accountPair(snapshots)
        phase = .searching; statusText = "Buscando alternativas para \(original.source.title)…"
        revokePreviousApprovals(); selectedOperationIDs = []
        workTask = Task {
            defer { phase = .review }
            do {
                let result = try await CatalogSearch.search(source: original.source, provider: provider, query: query)
                try Task.checkCancellation()
                guard context == accountPair(snapshots), let i = decisions.tracks.firstIndex(where: { $0.id == matchID && $0.source == original.source }) else { return }
                var previous = original
                if restoreRejected { previous.rejectedCandidateIDs = [] }
                var match = CatalogSearch.match(source: original.source, sourceService: original.sourceService, result: result, previous: previous)
                // An edited query proposes alternatives; choosing one is always explicit.
                if match.decision != .manual {
                    match.selected = nil; match.confidence = .review; match.decision = .pending
                    match.reason = "Alternativas disponibles para tu elección. La búsqueda no selecciona una versión por vos."
                }
                decisions.tracks[i] = match
                phase = .review; rebuildPlan(); persistDecisions(invalidateOtherDrafts: true)
                statusText = "Alternativas actualizadas. Elegí la grabación y edición que correspondan."
            } catch is CancellationError { statusText = "Búsqueda cancelada; se conservaron las decisiones anteriores." }
            catch { errorMessage = error.localizedDescription; statusText = "No se completó la búsqueda. Podés reintentar." }
        }
    }

    private func findMatch(_ source: Track, sourceService: MusicService, local: [Track], provider: any MusicProvider, previous: TrackMatch?) async throws -> TrackMatch {
        let localMatch = CatalogMatcher.track(source, candidates: local, sourceService: sourceService)
        var result = TrackSearchResult(candidates: localMatch.candidates)
        if (previous?.decision == .manual || previous?.manualSelection == true), let selected = previous?.selected,
           !local.contains(where: { CatalogMatcher.sameIdentityMetadata($0, selected) }) {
            do { if let fresh = try await provider.catalogTrack(id: selected.playableID) { result.candidates.append(fresh) } }
            catch is CancellationError { throw CancellationError() }
            catch { result.notes.append("La elección anterior necesita revalidación: \(error.localizedDescription)") }
        }
        if localMatch.selected == nil {
            do {
                let online = try await CatalogSearch.search(source: source, provider: provider)
                result.candidates = CatalogMatcher.ranked(source, candidates: result.candidates + online.candidates)
                result.coverage = online.coverage; result.notes += online.notes; result.stages = online.stages
            } catch is CancellationError { throw CancellationError() }
            catch { result.coverage = .failed; result.notes.append(error.localizedDescription) }
        }
        return CatalogSearch.match(source: source, sourceService: sourceService, result: result, previous: previous)
    }

    func searchManualTrack(itemID: String, query: TrackSearchQuery) {
        guard !isBusy else { return }
        if let provider = providers[.appleMusic] {
            manualChecklist.searchCandidates(itemID: itemID, query: query, catalogSearch: { @Sendable source, query in
                try await CatalogSearch.search(source: source, provider: provider, query: query)
            })
        } else { manualChecklist.searchCandidates(itemID: itemID, query: query) }
    }
    func selectAlbum(matchID: String, targetID: String?) {
        guard !isBusy, let i = decisions.albums.firstIndex(where: { $0.id == matchID }) else { return }
        decisions.albums[i].selected = decisions.albums[i].candidates.first { $0.id == targetID }
        decisions.albums[i].confidence = decisions.albums[i].selected == nil ? .review : .exact
        decisions.albums[i].manualSelection = decisions.albums[i].selected != nil
        decisions.albums[i].reason = "Selección manual."
        rebuildPlan(); persistDecisions(invalidateOtherDrafts: true)
    }
    func linkPlaylists(spotifyID: String, appleMusicID: String) {
        guard !isBusy else { return }
        decisions.playlists.removeAll { $0.spotifyID == spotifyID || $0.appleMusicID == appleMusicID }
        decisions.playlists.append(PlaylistLink(spotifyID: spotifyID, appleMusicID: appleMusicID))
        rebuildPlan(); persistDecisions(invalidateOtherDrafts: true)
    }
    func unlinkPlaylists(_ link: PlaylistLink) {
        guard !isBusy, decisions.playlists.contains(link) else { return }
        decisions.playlists.removeAll { $0 == link }
        rebuildPlan(); persistDecisions(invalidateOtherDrafts: true)
    }
    func protectPlaylist(service: MusicService, id: String, protected: Bool) {
        guard !isBusy else { return }
        if protected { decisions.protectedPlaylistIDs[service, default: []].insert(id) }
        else { decisions.protectedPlaylistIDs[service]?.remove(id) }
        rebuildPlan(); persistDecisions(invalidateOtherDrafts: true)
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
    private func invalidatePlan() { plan = nil; snapshots = []; selectedOperationIDs = []; decisions = MatchDecisions(); lastResult = nil; canResume = false; activeRequest = nil; activeJobID = nil }
    private func leaveDemoIfNeeded() {
        if isDemo { providers = [:]; accounts = [:]; isDemo = false; workspace.switchDemo(false); invalidatePlan() }
    }
    private func accountPair(_ inventory: [LibrarySnapshot]) -> String {
        inventory.sorted { $0.account.service.rawValue < $1.account.service.rawValue }.map {
            // Apple IDs identify the captured authorization grant, never an inferred Apple ID.
            "\($0.account.service.rawValue):\($0.account.id):\($0.account.storefront ?? "")"
        }.joined(separator: "|")
    }
    private func persistDecisions(invalidateOtherDrafts: Bool = false) {
        if invalidateOtherDrafts { workspace.invalidateDrafts(accountIDs: accounts.mapValues(\.id), except: activeJobID) }
        guard !isDemo, snapshots.count == 2, let store else { return }
        let value = decisions, key = accountPair(snapshots)
        let previous = decisionSaveTask
        decisionSaveTask = Task {
            await previous?.value
            do { try await store.saveDecisions(value, accountPair: key) }
            catch { errorMessage = error.localizedDescription }
        }
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

extension AppModel {
    func workspaceTick() {
        guard workspace.loaded else { return }
        if !workspace.state.preferences.spotifyClientID.isEmpty { spotifyClientID = workspace.state.preferences.spotifyClientID }
        guard !isBusy, !holdsAutomaticPreparation, accounts.count == 2 else { return }
        workspace.scheduleTick(accounts: Array(accounts.values))
        guard let job = workspace.state.jobs.first(where: { $0.state == .queued && $0.isDemo == isDemo && $0.request.matches(accounts: Array(accounts.values)) }) else { return }
        guard workspace.validate(job.request) else {
            workspace.setJob(job.id, state: .attention, message: "La configuración cambió. Prepará otra propuesta."); return
        }
        analyze(request: job.request, jobID: job.id)
    }

    func refreshLibraries() {
        guard canAnalyze else { return }
        revokePreviousApprovals(); invalidatePlan(); phase = .analyzing
        statusText = "Leyendo las bibliotecas para elegir el alcance…"
        workTask = Task {
            do {
                var fresh: [LibrarySnapshot] = []
                for service in MusicService.allCases {
                    try Task.checkCancellation()
                    guard let provider = providers[service], let expected = accounts[service] else { throw SyncExecutionError.missingProvider }
                    let snapshot = try await readLibrary(provider)
                    try Task.checkCancellation()
                    guard snapshot.account == expected else { throw SyncExecutionError.stale("Cambió la conexión durante la lectura.") }
                    fresh.append(snapshot); capabilities[service] = await provider.capabilities()
                }
                snapshots = fresh
                if !isDemo, let stored = try await store?.loadDecisions(accountPair: accountPair(fresh)) { decisions = stored }
                statusText = "Elegí las playlists y prepará una propuesta."
            } catch is CancellationError { statusText = "Lectura cancelada. Se conservan las bibliotecas anteriores." }
            catch { errorMessage = error.localizedDescription }
            phase = .idle
        }
    }

    func createSync(name: String, mode: SyncMode, playlists: [PlaylistReference], options: SyncOptions, schedule: ReviewSchedule) {
        guard !isBusy, workspace.loaded, accounts.count == 2, !playlists.isEmpty else { return }
        let frozenTargets = playlists.compactMap { ref -> PlaylistTarget? in
            guard let link = decisions.playlists.first(where: { ref.service == .spotify ? $0.spotifyID == ref.playlistID : $0.appleMusicID == ref.playlistID }) else { return nil }
            return PlaylistTarget(source: ref, targetID: ref.service == .spotify ? link.appleMusicID : link.spotifyID)
        }
        let request = SyncRequest(name: name.isEmpty ? "Mis playlists" : name, mode: mode, playlists: playlists, options: options, accounts: Array(accounts.values), playlistTargets: frozenTargets)
        let profile: SyncProfile
        if let editingProfileID, let old = workspace.state.profiles.first(where: { $0.id == editingProfileID }) {
            var revised = request; revised.profileID = old.id; revised.revision = old.request.revision
            if old.request.accountIDs == revised.accountIDs && old.request.storefronts == revised.storefronts {
                revised.copyTargets = old.request.copyTargets.filter { playlists.contains($0.source) }
            }
            changeProfile(old.id) { $0.request = revised; $0.schedule = schedule }
            profile = workspace.state.profiles.first { $0.id == old.id }!
        } else { profile = workspace.addProfile(request: request, schedule: schedule) }
        editingProfileID = nil
        _ = workspace.enqueue(profile.request)
        navigationRequest = .queue; workspaceTick()
    }

    func showPlaylist(_ playlist: Playlist, service: MusicService) {
        selectedPlaylistReference = PlaylistReference(service: service, playlistID: playlist.id)
        navigationRequest = .playlistDetails
    }

    func openJob(_ job: ReviewJob) {
        guard !isBusy, job.isDemo == isDemo, job.request.matches(accounts: Array(accounts.values)), workspace.validate(job.request) else {
            errorMessage = "Conectá las cuentas y la región de esta configuración antes de revisarla."; return
        }
        guard let preview = job.plan, let choices = job.decisions,
              preview.snapshots.allSatisfy({ accounts[$0.account.service]?.connectionRevision == $0.account.connectionRevision }) else {
            workspace.prepareAgain(job.id); navigationRequest = .queue; return
        }
        activeRequest = job.request; activeJobID = job.id; snapshots = preview.snapshots
        decisions = choices; mode = preview.mode; plan = preview; lastResult = nil
        selectedOperationIDs = Set(preview.executable.map(\.id)); phase = .review; navigationRequest = .review
    }

    func pauseJob(_ job: ReviewJob) {
        if activeJobID == job.id && isBusy { cancel() }
        else { workspace.setJob(job.id, state: .paused, message: "En pausa. Los cambios aplicados se conservan en el historial.") }
    }

    func changeProfile(_ id: UUID, update: (inout SyncProfile) -> Void) {
        guard !isBusy else { return }
        revokePreviousApprovals(); workspace.updateProfile(id: id, update: update)
        if activeRequest?.profileID == id { plan = nil; selectedOperationIDs = [] }
    }

    func loadHistoryRecord(id: UUID) {
        guard let store else { return }
        requestedHistoryID = id
        Task {
            do {
                let record = try await store.load(id: id)
                if requestedHistoryID == id { selectedHistoryRecord = record }
            }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func retryHistoricalRun(_ record: RunRecord) {
        guard !isBusy, record.isDemo == isDemo else { return }
        if record.executions.contains(where: { $0.state == .unknown || $0.state == .applying || (($0.state == .failed || $0.state == .pending) && $0.before != nil) }) {
            resumeRecord = record; resume()
        } else if let request = record.plan.request {
            let latest = request.profileID.flatMap { id in workspace.state.profiles.first { $0.id == id }?.request } ?? request
            if let id = workspace.enqueue(latest) { workspace.prepareAgain(id) }
            navigationRequest = .queue; workspaceTick()
        } else { mode = record.plan.mode; analyze(); navigationRequest = .review }
    }

    func prepareUndo(_ record: RunRecord) {
        guard canAnalyze, record.isDemo == isDemo, let store else { return }
        revokePreviousApprovals(); phase = .analyzing; plan = nil; activeRequest = nil; activeJobID = nil
        statusText = "Comprobando si los cambios pueden deshacerse…"
        workTask = Task {
            do {
                var current: [LibrarySnapshot] = []
                for service in MusicService.allCases {
                    try Task.checkCancellation()
                    guard let provider = providers[service] else { throw SyncExecutionError.missingProvider }
                    current.append(try await readLibrary(provider)); capabilities[service] = await provider.capabilities()
                }
                try Task.checkCancellation()
                guard try await store.unresolvedRuns(accountIDs: accounts.mapValues(\.id)).isEmpty else {
                    throw SyncExecutionError.unsafeResume("Hay resultados inciertos en el historial. Comprobá sus resultados primero.")
                }
                let currentDecisions = try await store.loadDecisions(accountPair: accountPair(current)) ?? decisions
                let inverse = UndoPlanner.makePlan(record: record, current: current, capabilities: capabilities, decisions: currentDecisions)
                snapshots = current; plan = inverse; decisions = currentDecisions; mode = inverse.mode
                selectedOperationIDs = Set(inverse.executable.map(\.id)); phase = .review; navigationRequest = .review
                statusText = "Revisá la propuesta inversa antes de confirmar."
            } catch { phase = .idle; errorMessage = error.localizedDescription }
        }
    }

    func exportHistoryCSV() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "SpotAMSync-historial.csv"; panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try HistoryCSV.encode(history).write(to: url, atomically: true, encoding: .utf8) }
        catch { errorMessage = error.localizedDescription }
    }

    func saveSpotifyClientID(_ value: String) {
        spotifyClientID = value.trimmingCharacters(in: .whitespacesAndNewlines)
        workspace.updatePreferences { $0.spotifyClientID = spotifyClientID }
    }

    func importElectronPreferences() {
        guard workspace.loaded, !isBusy else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let preferences = try LegacyPreferencesImporter.decode(Data(contentsOf: url), current: workspace.state.preferences)
            workspace.updatePreferences { $0 = preferences }
            statusText = "Preferencias importadas. Las conexiones y la programación necesitan configurarse con tus cuentas reales."
        } catch { errorMessage = error.localizedDescription }
    }

    func orderedCandidates(_ match: TrackMatch) -> [Track] {
        switch workspace.state.preferences.candidateOrder {
        case .metadata: return match.candidates
        case .duration:
            return match.candidates.enumerated().sorted {
                let left = abs(Double($0.element.durationMS) - Double(match.source.durationMS)), right = abs(Double($1.element.durationMS) - Double(match.source.durationMS))
                return left == right ? $0.offset < $1.offset : left < right
            }.map(\.element)
        case .studio:
            func live(_ track: Track) -> Bool {
                let text = CatalogMatcher.normalized(track.title + " " + track.albumTitle)
                return ["live", "en vivo", "directo"].contains { text.contains($0) }
            }
            guard !live(match.source) else { return match.candidates }
            return match.candidates.enumerated().sorted {
                let left = live($0.element), right = live($1.element)
                return left == right ? $0.offset < $1.offset : !left
            }.map(\.element)
        }
    }

    func disconnectAll() {
        guard !isBusy else { return }
        revokePreviousApprovals(); phase = .connecting
        let old = providers
        workTask = Task {
            do {
                try await approvalUpdateTask?.value
                for provider in old.values {
                    if let spotify = provider as? SpotifyProvider { try await spotify.disconnect() }
                    if let apple = provider as? AppleMusicProvider { try await apple.disconnect() }
                }
                providers = [:]; accounts = [:]; isDemo = false; workspace.switchDemo(false); invalidatePlan()
                statusText = "Cuentas desconectadas de esta app."
            } catch { errorMessage = error.localizedDescription }
            phase = .idle
        }
    }

    func clearSettledHistory() {
        guard !isBusy, let store else { return }
        Task {
            do {
                try await workspace.flush()
                let count = try await store.clearSettledHistory()
                statusText = "Se borraron \(count) registros resueltos. Los resultados inciertos se conservaron."
                selectedHistoryRecord = nil; refreshHistory()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func clearConfigurations() {
        guard !isBusy else { return }
        revokePreviousApprovals(); workspace.clearConfigurations()
        activeJobID = nil; activeRequest = nil; plan = nil; selectedOperationIDs = []
    }

    private func matchingSources(_ fresh: [LibrarySnapshot], request: SyncRequest?) -> [LibrarySnapshot] {
        guard let request else { return fresh }
        return fresh.map { original in
            var source = original
            source.playlists = original.playlists.filter { list in
                let ref = PlaylistReference(service: original.account.service, playlistID: list.id)
                if request.playlists.contains(ref) { return true }
                guard request.mode == .merge else { return false }
                return decisions.playlists.contains { link in
                    let other = original.account.service == .spotify ? PlaylistReference(service: .appleMusic, playlistID: link.appleMusicID) : PlaylistReference(service: .spotify, playlistID: link.spotifyID)
                    return (original.account.service == .spotify ? link.spotifyID : link.appleMusicID) == list.id && request.playlists.contains(other)
                }
            }
            if !request.includeSavedLibrary { source.savedTracks = []; source.savedAlbums = [] }
            return source
        }
    }
}
