import SwiftUI
import SyncCore

struct LibrarySyncWizardView: View {
    @EnvironmentObject private var model: AppModel
    @ViewState private var step = 1
    @ViewState private var officialApple = false
    @ViewState private var awaitingSources = false
    @ViewState private var mode = SyncMode.appleMusicBase
    @ViewState private var songPolicy = LibrarySyncPolicy.prepare
    @ViewState private var albumPolicy = LibrarySyncPolicy.prepare
    @ViewState private var includeUncertain = false
    @ViewState private var appleSelection = Set<String>()
    @ViewState private var spotifySelection = Set<String>()
    @ViewState private var playlistQuery = ""
    @ViewState private var targets: [String: String] = [:]

    private var sync: LibrarySyncCoordinator { model.librarySync }
    private var applePlaylists: [XMLMusicPlaylist] { sync.library?.inventory?.playlists ?? [] }
    private var spotifyPlaylists: [Playlist] { sync.spotify?.playlists ?? [] }
    private var unknownSongs: Int {
        guard sync.session.appleSnapshot == nil, let library = sync.library else { return 0 }
        return library.tracks.filter { library.inventory?.trackInfo[$0.id]?.playlistOnly == nil }.count
    }
    private var canRead: Bool {
        sync.loaded && !model.isBusy && model.accounts[.spotify] != nil &&
            (officialApple || model.isDemo ? model.accounts[.appleMusic] != nil : model.manualChecklist.library != nil && !model.manualChecklist.isDemo)
    }
    private var stepTitle: String { ["Elegí las fuentes", "Definí la comparación", "Elegí las playlists"][step - 1] }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    PageHeading(eyebrow: "Nueva sincronización", title: stepTitle,
                                subtitle: "Paso \(step) de 3 · Cada lote de cambios necesita tu confirmación.")
                    stepIndicator
                    if model.isDemo { Notice(title: "Demostración", message: "Estás trabajando con bibliotecas ficticias.", symbol: "flask") }
                    if step == 1 { sourcesStep }
                    if step == 2 { policiesStep }
                    if step == 3 { playlistsStep }
                    LibraryAnalysisStatus(sync: sync)
                }.padding(28).frame(maxWidth: 1100, alignment: .leading).frame(maxWidth: .infinity)
            }
            wizardFooter
        }
        .onAppear { loadDraft(); if sync.library != nil && sync.spotify != nil { step = sync.session.configuration.scope.playlists ? 3 : 2 } }
        .onChange(of: sync.isAnalyzing) { _, busy in
            if awaitingSources && !busy {
                awaitingSources = false
                if sync.errorMessage == nil, sync.library != nil, sync.spotify != nil { loadDraft(); step = 2 }
            }
        }
    }

    private var stepIndicator: some View {
        HStack(spacing: 12) {
            ForEach(1...3, id: \.self) { index in
                HStack(spacing: 8) {
                    Text("\(index)").font(.caption.bold()).frame(width: 26, height: 26)
                        .foregroundStyle(step == index ? Color.black : Color.secondary)
                        .background(step == index ? SyncStyle.green : Color.white.opacity(0.07), in: Circle())
                    Text(["Fuentes", "Base y políticas", "Playlists"][index - 1]).font(.caption)
                    if index < 3 { Rectangle().fill(SyncStyle.border).frame(height: 1) }
                }
            }
        }.accessibilityElement(children: .combine)
    }

    private var sourcesStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            SurfaceCard {
                HStack(spacing: 14) {
                    ServiceMark(service: .spotify)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Spotify autorizado").font(.headline)
                        Text(model.accounts[.spotify]?.displayName ?? "Conectá Spotify para leer tu biblioteca.").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.accounts[.spotify] == nil { Button("Conectar") { model.navigationRequest = .connections } }
                    else { StatusPill(title: "Conectado", symbol: "checkmark", color: SyncStyle.spotify) }
                }
            }
            SurfaceCard {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 14) { ServiceMark(service: .appleMusic); Text("Biblioteca de Música").font(.headline) }
                    Picker("Fuente de Apple Music", selection: $officialApple) {
                        Text("Exportación XML de Música").tag(false)
                        Text("Integración oficial de Apple Music").tag(true)
                    }.pickerStyle(.radioGroup).disabled(model.isBusy)
                    if officialApple {
                        Text(model.accounts[.appleMusic]?.displayName ?? "Conectá Apple Music desde Conexiones para usar la integración oficial.")
                            .font(.callout).foregroundStyle(.secondary)
                        if model.accounts[.appleMusic] == nil { Button("Conectar Apple Music") { model.navigationRequest = .connections } }
                    } else {
                        Text("En Música: Archivo > Biblioteca > Exportar biblioteca…").font(.callout)
                        HStack {
                            Button(model.manualChecklist.library == nil ? "Importar XML de Música…" : "Elegir otro XML…") { model.manualChecklist.importXML() }
                                .disabled(model.isBusy || !model.manualChecklist.isHydrated || model.manualChecklist.isDemo)
                            if let library = model.manualChecklist.library {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(library.fileName).font(.callout.weight(.medium))
                                    Text("\(library.tracks.count) pistas exportadas · \(library.inventory?.playlists.count ?? 0) playlists")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        Text("El XML es una instantánea. Las acciones hacia Apple Music se completan manualmente y se verifican con una nueva exportación.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if let error = model.manualChecklist.errorMessage { Text(error).font(.callout).foregroundStyle(SyncStyle.coral) }
                    }
                }
            }
            Text("Leer las fuentes y analizar equivalencias sólo prepara una propuesta. Las futuras diferencias también necesitarán una nueva confirmación.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var policiesStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            SurfaceCard {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Primera sincronización o seguimiento").font(.headline)
                    ForEach(SyncMode.allCases) { value in
                        Button { mode = value } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: mode == value ? "largecircle.fill.circle" : "circle")
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(value == .merge ? (sync.session.baseline == nil ? "Ya deberían estar a la par" : "Seguimiento bidireccional") : value.title).font(.callout.weight(.semibold))
                                    Text(modeDescription(value)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer()
                                if value == .merge && sync.session.baseline == nil { StatusPill(title: "Verificación inicial") }
                            }.padding(12).background(mode == value ? Color.white.opacity(0.07) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(.plain).disabled(sync.isApplying)
                            .accessibilityAddTraits(mode == value ? .isSelected : [])
                    }
                }
            }
            policyCard(title: "Canciones", symbol: "music.note", selection: $songPolicy,
                       explanation: "Revisá las canciones guardadas por separado del contenido de las playlists.")
            if sync.session.appleSnapshot == nil, unknownSongs > 0 {
                SurfaceCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Incluir \(unknownSongs) pistas XML de membresía desconocida como canciones para guardar en Spotify", isOn: $includeUncertain)
                            .toggleStyle(.checkbox).disabled(songPolicy == .exclude || sync.isApplying)
                        Text("Esta selección expresa qué querés guardar en Spotify. La exportación no confirma que esas pistas estén guardadas individualmente en Apple Music. Las pistas marcadas Playlist Only quedan excluidas.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            policyCard(title: "Álbumes", symbol: "square.stack", selection: $albumPolicy,
                       explanation: sync.session.appleSnapshot == nil ? "En el XML se muestran agrupaciones por álbum. No autorizan guardar la edición completa." : "Las ediciones completas guardadas tienen su propia comparación.")
            Notice(title: "El análisis puede seguir mientras revisás", message: "Al continuar empezaremos por canciones y álbumes. Después podrás elegir playlists y revisar los resultados que vayan apareciendo.", symbol: "arrow.triangle.branch")
        }
    }

    private func policyCard(title: String, symbol: String, selection: Binding<LibrarySyncPolicy>, explanation: String) -> some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 10) {
                Label(title, systemImage: symbol).font(.headline)
                Picker("Política de \(title.lowercased())", selection: selection) {
                    ForEach(LibrarySyncPolicy.allCases, id: \.self) { Text($0.title).tag($0) }
                }.disabled(sync.isApplying)
                Text(explanation).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("Preparar y avisar requieren tu confirmación antes de aplicar cambios.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var playlistsStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            Notice(title: "Un nombre compartido es una sugerencia", message: "Elegí qué playlists comparar y confirmá cada vínculo con un destino existente. Las playlists excluidas siguen contando para clasificar canciones fuera de playlists.", symbol: "link")
            SearchField(text: $playlistQuery, prompt: "Buscar playlists en ambas fuentes")
            HStack {
                Button("Seleccionar todas las regulares") {
                    appleSelection = Set(applePlaylists.filter { $0.kind == .regular }.map(\.id)); spotifySelection = Set(spotifyPlaylists.map(\.id))
                }
                Button("Excluir todas") { appleSelection = []; spotifySelection = [] }
                Spacer()
                Text("\(appleSelection.count + spotifySelection.count) playlists seleccionadas").font(.caption).foregroundStyle(.secondary)
            }.disabled(sync.isApplying)
            SurfaceCard {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Apple Music\(sync.session.appleSnapshot == nil ? " · XML" : "")", systemImage: "music.note").font(.headline)
                    if applePlaylists.isEmpty { Text("No hay playlists observadas en esta fuente.").foregroundStyle(.secondary) }
                    ForEach(applePlaylists.filter { playlistQuery.isEmpty || $0.name.localizedCaseInsensitiveContains(playlistQuery) }, id: \.id) { playlist in
                        applePlaylistRow(playlist)
                    }
                }
            }
            SurfaceCard {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Spotify", systemImage: "waveform").font(.headline)
                    if spotifyPlaylists.isEmpty { Text("No hay playlists observadas en Spotify.").foregroundStyle(.secondary) }
                    ForEach(spotifyPlaylists.filter { playlistQuery.isEmpty || $0.name.localizedCaseInsensitiveContains(playlistQuery) }) { playlist in
                        HStack(spacing: 12) {
                            Toggle("Incluir \(playlist.name)", isOn: selection(playlist.id, in: $spotifySelection)).labelsHidden().toggleStyle(.checkbox)
                            ArtworkView(url: playlist.artworkURL, title: playlist.name, service: .spotify).frame(width: 44, height: 44)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(playlist.name).font(.callout.weight(.medium))
                                Text("\(playlist.tracks.count) apariciones\(playlist.contentsComplete ? "" : " · Lectura parcial")").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if !playlist.editable { StatusPill(title: "Sólo lectura") }
                        }.padding(.vertical, 6).disabled(sync.isApplying)
                    }
                }
            }
        }
    }

    private func applePlaylistRow(_ playlist: XMLMusicPlaylist) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Toggle("Incluir \(playlist.name)", isOn: selection(playlist.id, in: $appleSelection))
                    .labelsHidden().toggleStyle(.checkbox).disabled(playlist.kind != .regular || sync.isApplying)
                ArtworkView(url: playlist.artworkURL, title: playlist.name, service: .appleMusic).frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(playlist.name).font(.callout.weight(.medium))
                    Text("\(playlist.trackIDs.count) apariciones · \(playlist.kind.rawValue)\(playlist.contentsComplete ? "" : " · Lectura parcial")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if playlist.kind != .regular { StatusPill(title: "Revisión manual") }
            }
            if playlist.kind == .regular, appleSelection.contains(playlist.id) {
                HStack(spacing: 10) {
                    Picker("Destino en Spotify", selection: Binding(get: { targets[playlist.id] ?? "" }, set: { targets[playlist.id] = $0 })) {
                        Text("Sin vínculo confirmado").tag("")
                        ForEach(spotifyPlaylists) { Text($0.name + " · " + String($0.id.suffix(8))).tag($0.id) }
                    }
                    Button("Confirmar vínculo") {
                        guard let target = targets[playlist.id], !target.isEmpty else { return }
                        spotifySelection.insert(target); sync.link(appleID: playlist.id, spotifyID: target)
                    }.disabled((targets[playlist.id] ?? "").isEmpty || targetTaken(appleID: playlist.id) || sync.isApplying)
                    if sync.session.configuration.playlistPairings.contains(where: { $0.appleMusicID == playlist.id }) {
                        Button("Quitar vínculo") { targets[playlist.id] = ""; sync.link(appleID: playlist.id, spotifyID: nil) }.disabled(sync.isApplying)
                    }
                }
                if targetTaken(appleID: playlist.id) { Text("Ese destino ya está vinculado a otra playlist. Quitá primero el vínculo anterior.").font(.caption).foregroundStyle(SyncStyle.coral) }
                else if let linked = sync.session.configuration.playlistPairings.first(where: { $0.appleMusicID == playlist.id }) {
                    Label("Vínculo confirmado con \(spotifyPlaylists.first { $0.id == linked.spotifyID }?.name ?? linked.spotifyID)", systemImage: "checkmark.circle")
                        .font(.caption).foregroundStyle(.secondary)
                    PlaylistArtworkComparisonView(appleURL: playlist.artworkURL, spotifyURL: spotifyPlaylists.first { $0.id == linked.spotifyID }?.artworkURL, title: playlist.name)
                } else if let suggested = suggestedTarget(playlist) {
                    Text("Sugerencia por nombre: \(suggested.name). Elegila y confirmá el vínculo para comparar su contenido.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Divider()
        }
    }

    private var wizardFooter: some View {
        HStack(spacing: 14) {
            if step > 1 { Button("Atrás") { step -= 1 }.disabled(sync.isApplying) }
            Text(step == 3 ? "El orden y las repeticiones se conservan." : "Preparar requiere una confirmación posterior.").font(.caption).foregroundStyle(.secondary)
            Spacer()
            if step == 1 {
                Button(awaitingSources ? "Leyendo fuentes…" : "Leer fuentes y continuar") {
                    awaitingSources = true; model.readSyncSources(useOfficialApple: officialApple)
                }.buttonStyle(.borderedProminent).disabled(!canRead)
            } else if step == 2 {
                Button("Iniciar análisis y elegir playlists") {
                    sync.configure(mode: mode, songs: songPolicy, albums: albumPolicy, includeUncertainXMLSongs: includeUncertain)
                    step = 3
                }.buttonStyle(.borderedProminent).disabled(sync.isApplying || sync.library == nil || sync.spotify == nil)
            } else {
                Button("Comparar playlists y revisar") {
                    sync.selectPlaylists(apple: appleSelection, spotify: spotifySelection); model.navigationRequest = .syncReview
                }.buttonStyle(.borderedProminent).disabled(sync.isApplying)
            }
        }.controlSize(.large).padding(.horizontal, 28).padding(.vertical, 16).background(.ultraThinMaterial)
    }

    private func modeDescription(_ value: SyncMode) -> String {
        switch value {
        case .appleMusicBase: return "Prepará en Spotify las altas elegidas desde Música. El contenido exclusivo de destino se revisa por separado."
        case .spotifyBase: return sync.session.appleSnapshot == nil ? "Prepará las tareas para incorporar a Música lo elegido desde Spotify." : "Prepará en Apple Music las altas elegidas desde Spotify."
        case .merge: return sync.session.baseline == nil ? "Verificá las diferencias iniciales de ambos lados. Esta opción no afirma que estén iguales ni infiere bajas; podrás guardar una referencia después de resolver la comparación." : "Compará ambos lados con la referencia guardada. Los cambios incompatibles requieren tu elección."
        }
    }
    private func selection(_ id: String, in values: Binding<Set<String>>) -> Binding<Bool> {
        Binding(get: { values.wrappedValue.contains(id) }, set: { selected in
            if selected { values.wrappedValue.insert(id) } else { values.wrappedValue.remove(id) }
        })
    }
    private func targetTaken(appleID: String) -> Bool {
        guard let target = targets[appleID], !target.isEmpty else { return false }
        return sync.session.configuration.playlistPairings.contains { $0.spotifyID == target && $0.appleMusicID != appleID }
    }
    private func suggestedTarget(_ playlist: XMLMusicPlaylist) -> Playlist? {
        let name = CatalogMatcher.normalized(playlist.name)
        guard !name.isEmpty, applePlaylists.filter({ CatalogMatcher.normalized($0.name) == name }).count == 1 else { return nil }
        let matches = spotifyPlaylists.filter { CatalogMatcher.normalized($0.name) == name }
        return matches.count == 1 ? matches[0] : nil
    }
    private func loadDraft() {
        let configuration = sync.session.configuration
        officialApple = sync.session.appleSnapshot != nil || model.isDemo
        mode = configuration.mode; songPolicy = sync.session.songPolicy; albumPolicy = sync.session.albumPolicy
        includeUncertain = configuration.includeUncertainXMLSongs
        appleSelection = configuration.scope.appleMusicPlaylistIDs ?? Set(applePlaylists.filter { $0.kind == .regular }.map(\.id))
        spotifySelection = configuration.scope.spotifyPlaylistIDs ?? Set(spotifyPlaylists.map(\.id))
        targets = Dictionary(configuration.playlistPairings.map { ($0.appleMusicID, $0.spotifyID) }, uniquingKeysWith: { first, _ in first })
    }
}

private struct LibraryAnalysisStatus: View {
    @ObservedObject var sync: LibrarySyncCoordinator
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let progress = sync.libraryProgress { LibraryReadProgressView(progress: progress) }
            if sync.isWorking {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(sync.statusText).font(.callout).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(sync.isApplying ? "Detener envíos" : "Detener análisis") { sync.cancel() }
                }
                if sync.isAnalyzing { ProgressView(value: sync.progress).accessibilityLabel("Análisis de equivalencias") }
            } else { Text(sync.statusText).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

enum LibraryChangeGroup: String, CaseIterable, Identifiable {
    case songs, albums, missingPlaylists, playlistContents, removals, conflicts
    var id: String { rawValue }
    var title: String {
        switch self {
        case .songs: return "Canciones"; case .albums: return "Álbumes"
        case .missingPlaylists: return "Playlists faltantes"; case .playlistContents: return "Contenido y vínculos de playlists"
        case .removals: return "Cambios con confirmación separada"; case .conflicts: return "Conflictos que requieren tu elección"
        }
    }
    static func of(_ difference: LibraryDifference) -> Self {
        if difference.category == .removal { return .removals }
        if difference.category == .conflict { return .conflicts }
        if difference.scope == .songs { return .songs }
        if difference.scope == .albums { return .albums }
        if difference.spotifyOperations.contains(where: { $0.kind == .createPlaylist }) ||
            difference.appleMusicTasks.contains(where: { $0.kind == .createPlaylist }) ||
            (difference.appleMusicTrackIDs == nil && difference.spotifyTrackIDs != nil) ||
            (difference.appleMusicTrackIDs != nil && difference.spotifyTrackIDs == nil) { return .missingPlaylists }
        return .playlistContents
    }
}

/// Captures the exact rows and operations shown by a confirmation, independently of later analysis results.
struct LibraryApprovalPreview: Identifiable {
    let id = UUID()
    let differences: [LibraryDifference]
    let operationsByID: [String: [SyncOperation]]
    var differenceIDs: Set<String> { Set(differences.map(\.id)) }
    var unitCount: Int { Set(differences.map(\.unitID)).count }
    var operations: [SyncOperation] { differences.flatMap { operationsByID[$0.id] ?? [] } }
    var manualTasks: [LibraryManualTask] {
        differences.flatMap(\.appleMusicTasks).filter { task in !operations.contains(where: { $0.id == task.operation?.id }) }
    }
    func stillMatches(_ available: [LibraryDifference], operations: [String: [SyncOperation]]) -> Bool {
        let byID = Dictionary(available.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return differences.allSatisfy { byID[$0.id] == $0 && operations[$0.id, default: []] == operationsByID[$0.id, default: []] }
    }
}

private enum LibraryReviewFilter: String, CaseIterable, Identifiable {
    case outstanding = "Pendientes", ready = "Altas listas", review = "Requieren decisión", deferred = "Diferidas", ignored = "Omitidas"
    var id: String { rawValue }
}

struct LibraryChangesView: View {
    @EnvironmentObject private var model: AppModel
    @ViewState private var selection = Set<String>()
    @ViewState private var filter = LibraryReviewFilter.outstanding
    @ViewState private var query = ""
    @ViewState private var approval: LibraryApprovalPreview?
    @ViewState private var removal: LibraryDifference?
    @ViewState private var candidate: LibraryMatchSelection?
    private var sync: LibrarySyncCoordinator { model.librarySync }
    private var readyIDs: Set<String> { Set(sync.readyDifferences.map(\.id)) }
    private var visible: [LibraryDifference] {
        sync.report.differences.filter { difference in
            let included: Bool
            switch filter {
            case .outstanding: included = !sync.isIgnored(difference)
            case .ready: included = readyIDs.contains(difference.id)
            case .review: included = !sync.isIgnored(difference) && difference.category != .addition
            case .deferred: included = !sync.isIgnored(difference) && sync.isDeferred(difference)
            case .ignored: included = sync.isIgnored(difference)
            }
            return included && (query.isEmpty || (difference.title + " " + difference.detail).localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    PageHeading(eyebrow: "Comparación de bibliotecas", title: "Elegí qué incorporar",
                                subtitle: "Los resultados aparecen por unidad de comparación. Confirmar un lote abarca sólo las diferencias que ves en ese lote.")
                    if sync.library == nil || sync.spotify == nil {
                        EmptyState(symbol: "square.stack", title: "Elegí las fuentes para comparar", message: "Leé Spotify y tu XML de Música o la integración oficial de Apple Music.")
                        Button("Abrir asistente") { model.navigationRequest = .newSync }.buttonStyle(.borderedProminent)
                    } else {
                        comparisonCounts
                        LibraryAnalysisStatus(sync: sync)
                        reviewControls
                        if visible.isEmpty {
                            EmptyState(symbol: "checkmark.circle", title: sync.isAnalyzing ? "El análisis sigue en curso" : "Sin diferencias en esta vista",
                                       message: sync.isAnalyzing ? "Podés seguir navegando. Los resultados nuevos aparecerán aquí y necesitarán su propia confirmación." : "Cambiá el filtro o actualizá las fuentes para revisar otra lectura.")
                        }
                        ForEach(LibraryChangeGroup.allCases) { group in
                            let differences = visible.filter { LibraryChangeGroup.of($0) == group }
                            if !differences.isEmpty { groupSection(group, differences: differences) }
                        }
                        referenceSection
                    }
                }.padding(28).frame(maxWidth: 1150, alignment: .leading).frame(maxWidth: .infinity)
            }
            if sync.library != nil { reviewFooter }
        }
        .onChange(of: readyIDs) { _, ids in selection.formIntersection(ids) }
        .sheet(item: $candidate) { selection in LibraryCandidateSheet(sync: sync, matchID: selection.id) }
        .confirmationDialog("Confirmar este lote de altas", isPresented: Binding(get: { approval != nil }, set: { if !$0 { approval = nil } }), titleVisibility: .visible) {
            if let preview = approval {
                Button("Confirmar \(preview.differences.count) diferencias concretas") { confirm(preview) }
                Button("Cancelar", role: .cancel) { approval = nil }
            }
        } message: {
            if let preview = approval {
                Text("\(preview.unitCount) unidades · \(preview.operations.count) operaciones · \(preview.manualTasks.count) tareas manuales.\n" +
                     preview.differences.prefix(5).map(\.title).joined(separator: "\n") +
                     (preview.differences.count > 5 ? "\nY \(preview.differences.count - 5) diferencias más de esta selección." : "") +
                     "\nLos resultados posteriores y las eliminaciones quedan fuera de esta confirmación.")
            }
        }
        .confirmationDialog("Confirmar cambio por separado", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }), titleVisibility: .visible) {
            if let difference = removal {
                Button("Confirmar sólo este cambio", role: LibrarySyncPresentation.requiresDestructiveConfirmation(difference, operations: sync.operations(for: difference)) ? .destructive : nil) {
                    guard sync.report.differences.contains(difference), !sync.isApplying else { removal = nil; return }
                    sync.approveRemoval(difference); removal = nil
                }
                Button("Cancelar", role: .cancel) { removal = nil }
            }
        } message: {
            if let difference = removal {
                Text("\(difference.title)\n" + LibrarySyncPresentation.separateChangeSummary(difference, operations: sync.operations(for: difference)) +
                     "\n\(difference.detail)\nDestino: \(difference.destination?.name ?? "requiere revisión"). Esta aprobación abarca sólo el cambio detallado.")
            }
        }
    }

    private var comparisonCounts: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { comparisonCountCards }
            VStack(spacing: 12) { comparisonCountCards }
        }
    }
    @ViewBuilder private var comparisonCountCards: some View {
        LibraryMetric(value: "\(Set(sync.outstanding.map(\.unitID)).count)", title: "Unidades por revisar")
        LibraryMetric(value: "\(sync.readyDifferences.count)", title: "Altas listas para confirmar")
        LibraryMetric(value: "\(sync.report.removals.count)", title: "Cambios con revisión separada")
        LibraryMetric(value: "\(sync.report.conflicts.count)", title: "Conflictos")
    }
    private var reviewControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Mostrar diferencias", selection: $filter) { ForEach(LibraryReviewFilter.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
            HStack {
                SearchField(text: $query, prompt: "Buscar diferencias")
                Button("Reanalizar") { sync.prepare() }.disabled(sync.isApplying || model.legacyBusy)
                if !sync.session.ignored.isEmpty { Button("Restaurar omitidas") { sync.restoreIgnored() }.disabled(sync.isApplying) }
                if sync.report.differences.contains(where: { sync.isDeferred($0) }) { Button("Reactivar diferidas") { sync.restoreDeferred() }.disabled(sync.isApplying) }
            }
            Text("Identidades de canción, canciones guardadas y apariciones en playlists son conteos distintos. Una coincidencia de catálogo no confirma membresía.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func groupSection(_ group: LibraryChangeGroup, differences: [LibraryDifference]) -> some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(group.title).font(.title3.weight(.semibold))
                Spacer()
                Text("\(Set(differences.map(\.unitID)).count) unidades · \(differences.count) diferencias").font(.caption).foregroundStyle(.secondary)
            }
            if group == .removals { Text("Los cambios de nombre, las secuencias y las eliminaciones tienen su propia confirmación. Quedan fuera de “Confirmar todas las altas”.").font(.caption).foregroundStyle(SyncStyle.coral) }
            ForEach(differences) { difference in
                LibraryDifferenceRow(sync: sync, difference: difference,
                                     selected: Binding(get: { selection.contains(difference.id) }, set: { value in
                                         if value { selection.insert(difference.id) } else { selection.remove(difference.id) }
                                     }),
                                     approve: { presentApproval([difference]) }, remove: { removal = difference },
                                     reviewMatch: { candidate = .init(id: $0) })
            }
        }
    }

    private var reviewFooter: some View {
        HStack(spacing: 12) {
            Text("\(selection.intersection(readyIDs).count) altas seleccionadas").font(.caption).foregroundStyle(.secondary)
            Button("Confirmar selección") { presentApproval(sync.readyDifferences.filter { selection.contains($0.id) }) }
                .disabled(selection.intersection(readyIDs).isEmpty || sync.isApplying || model.legacyBusy)
            Spacer()
            Button("Ver lotes") { model.navigationRequest = .syncActivity }
            Button("Confirmar todas las altas listas (\(sync.readyDifferences.count))") { presentApproval(sync.readyDifferences) }
                .buttonStyle(.borderedProminent).disabled(sync.readyDifferences.isEmpty || sync.isApplying || model.legacyBusy)
        }.padding(.horizontal, 28).padding(.vertical, 16).background(.ultraThinMaterial)
    }
    private var referenceSection: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Referencia para el seguimiento").font(.headline)
                Text("Una referencia guarda las observaciones de este alcance. El seguimiento prepara las nuevas diferencias para volver a confirmarlas.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    if sync.session.baseline != nil { StatusPill(title: "Referencia guardada", symbol: "checkmark.circle") }
                    Spacer()
                    Button("Guardar referencia de este alcance") { sync.establishBaseline() }.disabled(!LibrarySyncPresentation.canEstablishBaseline(sync.session, working: sync.isWorking))
                }
                if !LibrarySyncPresentation.canEstablishBaseline(sync.session, working: sync.isWorking) {
                    Text("Resolvé u omití explícitamente las diferencias y verificá los lotes y tareas antes de guardar la referencia.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
    private func presentApproval(_ differences: [LibraryDifference]) {
        let ready = differences.filter { readyIDs.contains($0.id) }
        guard !ready.isEmpty else { return }
        approval = .init(differences: ready, operationsByID: Dictionary(ready.map { ($0.id, sync.operations(for: $0)) }, uniquingKeysWith: { first, _ in first }))
    }
    private func confirm(_ preview: LibraryApprovalPreview) {
        let current = sync.readyDifferences
        let operations = Dictionary(current.map { ($0.id, sync.operations(for: $0)) }, uniquingKeysWith: { first, _ in first })
        guard !sync.isApplying, !model.legacyBusy, preview.stillMatches(current, operations: operations) else {
            approval = nil; sync.errorMessage = "La selección cambió durante la revisión. Revisá el lote actualizado y volvé a confirmarlo."; return
        }
        sync.approve(preview.differenceIDs); selection.subtract(preview.differenceIDs); approval = nil
    }
}

private struct LibraryDifferenceRow: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var sync: LibrarySyncCoordinator
    let difference: LibraryDifference
    @Binding var selected: Bool
    let approve: () -> Void
    let remove: () -> Void
    let reviewMatch: (String) -> Void
    private var ready: Bool { sync.readyDifferences.contains { $0.id == difference.id } }
    private var matches: [TrackMatch] {
        let ids = Set(difference.tracks.flatMap { [$0.id, $0.playableID] } + [difference.sourceID, difference.destinationID].compactMap { $0 })
        let preferred: MusicService
        if let destination = difference.destination { preferred = destination.other }
        else if sync.library?.tracks.contains(where: { $0.id == difference.sourceID }) == true { preferred = .appleMusic }
        else if sync.spotify?.allTracks.contains(where: { $0.id == difference.sourceID }) == true { preferred = .spotify }
        else { preferred = sync.session.configuration.mode == .spotifyBase ? .spotify : .appleMusic }
        return sync.report.matches.filter { $0.sourceService == preferred && (ids.contains($0.source.id) || $0.selected.map { ids.contains($0.playableID) || ids.contains($0.id) } == true) }
    }

    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    if ready { Toggle("Seleccionar \(difference.title)", isOn: $selected).labelsHidden().toggleStyle(.checkbox).disabled(sync.isApplying) }
                    artwork
                    VStack(alignment: .leading, spacing: 6) {
                        Text(difference.title).font(.headline).textSelection(.enabled)
                        Text(difference.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            StatusPill(title: LibrarySyncPresentation.categoryTitle(difference.category), color: difference.category == .addition ? SyncStyle.spotify : SyncStyle.coral)
                            if let destination = difference.destination { Text("Hacia \(destination.name)").font(.caption).foregroundStyle(.secondary) }
                            if sync.isIgnored(difference) { StatusPill(title: "Omitida") }
                            if sync.isDeferred(difference) { StatusPill(title: "Dejada pendiente por vos") }
                            if sync.hasApproval(difference.id) { StatusPill(title: "Incluida en un lote", symbol: "checkmark") }
                        }
                    }
                    Spacer(minLength: 0)
                }
                if difference.scope == .playlists, difference.appleMusicTrackIDs != nil || difference.spotifyTrackIDs != nil {
                    HStack {
                        Text("Música: \(difference.appleMusicTrackIDs.map { "\($0.count) apariciones" } ?? "playlist ausente")")
                        Text("·")
                        Text("Spotify: \(difference.spotifyTrackIDs.map { "\($0.count) apariciones" } ?? "playlist ausente")")
                    }.font(.caption).foregroundStyle(.secondary)
                }
                if difference.category == .removal {
                    Text(LibrarySyncPresentation.separateChangeSummary(difference, operations: sync.operations(for: difference)))
                        .font(.caption).foregroundStyle(SyncStyle.coral).fixedSize(horizontal: false, vertical: true)
                }
                if !matches.isEmpty {
                    DisclosureGroup("Equivalencias de canciones (\(matches.count))") {
                        ScrollView {
                            LazyVStack(spacing: 8) {
                                ForEach(matches) { match in
                                    HStack(spacing: 10) {
                                        ArtworkView(url: match.source.artworkURL, title: match.source.title, service: match.sourceService).frame(width: 38, height: 38)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(match.source.title).font(.callout)
                                            Text("\(match.source.artist) · \(match.source.albumTitle)").font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Text(LibrarySyncPresentation.matchTitle(match)).font(.caption).foregroundStyle(.secondary)
                                        Button("Buscar o elegir versión") { reviewMatch(match.id) }.disabled(sync.isApplying)
                                    }
                                }
                            }.padding(.top, 8)
                        }.frame(maxHeight: 250)
                    }.font(.callout)
                }
                if difference.scope == .albums {
                    DisclosureGroup("Buscar y elegir una edición de álbum") { AlbumDifferenceReviewView(difference: difference) }
                        .font(.callout)
                }
                if difference.scope == .playlists, let pair = confirmedPair {
                    DisclosureGroup("Comparar portadas de playlists") {
                        PlaylistArtworkComparisonView(appleURL: sync.library?.inventory?.playlists.first { $0.id == pair.appleMusicID }?.artworkURL,
                                                      spotifyURL: sync.spotify?.playlists.first { $0.id == pair.spotifyID }?.artworkURL,
                                                      title: difference.title)
                    }.font(.callout)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { actions }
                    VStack(alignment: .leading, spacing: 10) { actions }
                }
            }
        }
    }
    @ViewBuilder private var artwork: some View {
        if difference.scope == .playlists {
            ArtworkView(url: sync.library?.inventory?.playlists.first { $0.id == difference.sourceID }?.artworkURL ?? sync.spotify?.playlists.first { $0.id == difference.sourceID }?.artworkURL,
                        title: difference.title, service: difference.destination?.other ?? .appleMusic).frame(width: 54, height: 54)
        } else if let track = difference.tracks.first {
            ArtworkView(url: track.artworkURL, title: track.title, service: difference.destination ?? .appleMusic).frame(width: 54, height: 54)
        } else if let album = difference.albums.first {
            ArtworkView(url: album.artworkURL, title: album.title, service: difference.destination ?? .appleMusic).frame(width: 54, height: 54)
        } else {
            Image(systemName: difference.scope == .playlists ? "music.note.list" : "square.stack")
                .frame(width: 54, height: 54).background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        }
    }
    @ViewBuilder private var actions: some View {
        if ready { Button("Confirmar esta alta", action: approve).buttonStyle(.borderedProminent).disabled(sync.isApplying) }
        if difference.category == .removal, !sync.isIgnored(difference) {
            Button("Confirmar cambio por separado…", action: remove).disabled(sync.isWorking || sync.hasApproval(difference.id))
        }
        if needsPairing {
            Button("Elegir vínculo de playlists") { model.navigationRequest = .newSync }.disabled(sync.isApplying)
        } else if difference.category == .conflict || (difference.category == .review && difference.scope == .playlists) {
            Button("Preparar versión de Apple Music") { sync.resolve(difference, prefer: .appleMusic) }.disabled(sync.isApplying || sync.isIgnored(difference))
            Button("Preparar versión de Spotify") { sync.resolve(difference, prefer: .spotify) }.disabled(sync.isApplying || sync.isIgnored(difference))
        }
        if !sync.isIgnored(difference) && !sync.hasApproval(difference.id) {
            if !sync.isDeferred(difference) { Button("Dejar pendiente") { selected = false; sync.deferDifference(difference) }.disabled(sync.isApplying) }
            Button("Omitir este cambio") { sync.omit(difference) }.disabled(sync.isApplying)
        }
        if sync.isDeferred(difference) {
            Text("Fuera de Confirmar todas las altas. Usá Reactivar diferidas para volver a elegirla.").font(.caption).foregroundStyle(.secondary)
        }
        if difference.category == .review || difference.category == .conflict {
            Text("Queda pendiente hasta que elijas una opción. Preparar una versión necesita otra confirmación.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private var needsPairing: Bool {
        difference.scope == .playlists && difference.category == .review && difference.appleMusicTrackIDs == nil && difference.spotifyTrackIDs == nil &&
            !sync.session.configuration.playlistPairings.contains { link in
                (link.appleMusicID == difference.sourceID && link.spotifyID == difference.destinationID) ||
                (link.spotifyID == difference.sourceID && link.appleMusicID == difference.destinationID)
            }
    }
    private var confirmedPair: PlaylistLink? {
        sync.session.configuration.playlistPairings.first { link in
            (link.appleMusicID == difference.sourceID && link.spotifyID == difference.destinationID) ||
            (link.spotifyID == difference.sourceID && link.appleMusicID == difference.destinationID)
        }
    }
}

private struct LibraryMatchSelection: Identifiable { let id: String }

private struct LibraryCandidateSheet: View {
    @ObservedObject var sync: LibrarySyncCoordinator
    let matchID: String
    private var match: TrackMatch? { sync.session.decisions.tracks.first { $0.id == matchID } ?? sync.report.matches.first { $0.id == matchID } }
    var body: some View {
        if let match {
            let result = sync.searchResults[matchID]
            let rejected = Set(match.rejectedCandidateIDs ?? [])
            TrackCandidateReview(source: match.source, service: match.sourceService.other,
                                 candidates: CatalogMatcher.unique(match.candidates + (result?.candidates ?? [])).filter { !rejected.contains($0.playableID) },
                                 selected: match.selected,
                                 notes: (result?.notes ?? match.searchNotes ?? []) + [match.reason, "Elegir una referencia de catálogo no confirma que esté guardada ni que pertenezca a una playlist."],
                                 busy: sync.isApplying || sync.searchingIDs.contains(matchID),
                                 publicSearch: sync.session.appleSnapshot == nil && match.sourceService == .spotify,
                                 search: { sync.search(matchID: matchID, query: $0) },
                                 choose: { sync.choose(matchID: matchID, candidate: $0, decision: .manual) },
                                 reject: { sync.reject(matchID: matchID, candidate: $0) },
                                 pending: { sync.choose(matchID: matchID, candidate: nil, decision: .pending) },
                                 omit: { sync.choose(matchID: matchID, candidate: nil, decision: .omitted) },
                                 restore: { sync.restoreRejected(matchID: matchID) }, cancel: { sync.cancelSearch(matchID: matchID) })
        } else { EmptyState(symbol: "magnifyingglass", title: "La canción cambió", message: "Cerrá esta vista y elegí la equivalencia desde la comparación actual.").frame(width: 650, height: 350) }
    }
}

private struct LibraryMetric: View {
    let value: String
    let title: String
    var body: some View {
        SurfaceCard { VStack(alignment: .leading, spacing: 5) { Text(value).font(.title2.bold()); Text(title).font(.caption).foregroundStyle(.secondary) } }
    }
}

enum LibrarySyncPresentation {
    static func separateChangeSummary(_ difference: LibraryDifference, operations: [SyncOperation]) -> String {
        if !operations.isEmpty {
            return operations.map { operationSummary(kind: $0.kind, name: $0.playlistName ?? $0.title, trackCount: $0.tracks.count, albumCount: $0.albums.count) }.joined(separator: "\n")
        }
        if !difference.appleMusicTasks.isEmpty {
            return difference.appleMusicTasks.map { "Tarea manual · " + operationSummary(kind: $0.kind, name: $0.title, trackCount: $0.tracks.count, albumCount: $0.albums.count) }.joined(separator: "\n")
        }
        let kind: OperationKind = difference.scope == .songs ? .removeTracks : difference.scope == .albums ? .removeAlbums : difference.appleMusicTrackIDs == nil ? .removePlaylist : .replacePlaylistTracks
        return operationSummary(kind: kind, name: difference.title, trackCount: difference.tracks.count, albumCount: difference.albums.count)
    }
    static func requiresDestructiveConfirmation(_ difference: LibraryDifference, operations: [SyncOperation]) -> Bool {
        if !operations.isEmpty { return operations.contains { $0.kind.isDestructive } }
        return difference.appleMusicTasks.isEmpty || difference.appleMusicTasks.contains { $0.kind.isDestructive }
    }
    private static func operationSummary(kind: OperationKind, name: String, trackCount: Int, albumCount: Int) -> String {
        switch kind {
        case .renamePlaylist: return "\(kind.label) · Nuevo nombre: \(name)"
        case .replacePlaylistTracks: return "Igualar secuencia · \(name) · \(trackCount) apariciones, conservando su orden y repeticiones"
        case .removeTracks: return "\(kind.label) · \(trackCount) canciones guardadas"
        case .removeAlbums: return "\(kind.label) · \(albumCount) álbumes guardados"
        case .removePlaylist: return "\(kind.label) · \(name)"
        default: return "\(kind.label) · \(name) · \(trackCount) apariciones"
        }
    }
    static func categoryTitle(_ category: LibraryDifferenceCategory) -> String {
        switch category { case .addition: return "Alta"; case .removal: return "Confirmación separada"; case .conflict: return "Conflicto"; case .review: return "Por revisar" }
    }
    static func matchTitle(_ match: TrackMatch) -> String {
        if match.decision == .omitted { return "Omitida por vos" }
        if match.decision == .pending { return "Pendiente por vos" }
        if match.manualSelection == true { return "Elección manual" }
        if match.selected != nil { return "Equivalencia encontrada" }
        return "Requiere una versión"
    }
    static func canEstablishBaseline(_ session: LibrarySyncSession, working: Bool) -> Bool {
        !working && session.library?.complete == true && session.spotify?.complete == true &&
            session.report.differences.allSatisfy { session.ignored[$0.id] == [$0.id, $0.detail].joined(separator: "|") } &&
            !session.batches.contains { [.queued, .applying, .attention, .manual].contains($0.state) }
    }
}

private enum LibraryServiceSection: String, CaseIterable, Identifiable {
    case songs = "Canciones", albums = "Álbumes", playlists = "Playlists"
    var id: String { rawValue }
}
private enum LibrarySongFilter: String, CaseIterable, Identifiable {
    case observed = "Todas las pistas observadas", saved = "Guardadas conocidas", loose = "Fuera de playlists"
    var id: String { rawValue }
}

struct LibraryServiceView: View {
    let service: MusicService
    @EnvironmentObject private var model: AppModel
    @ViewState private var section = LibraryServiceSection.songs
    @ViewState private var songFilter = LibrarySongFilter.observed
    @ViewState private var onlyLooseAlbums = false
    @ViewState private var query = ""
    private var sync: LibrarySyncCoordinator { model.librarySync }
    private var snapshot: LibrarySnapshot? { service == .spotify ? sync.spotify : sync.session.appleSnapshot }
    private var xmlSource: Bool { service == .appleMusic && sync.session.appleSnapshot == nil }
    private var metrics: LibraryInventoryMetrics { service == .spotify ? sync.report.metrics.spotify : sync.report.metrics.appleMusic }
    private var tracks: [Track] { snapshot?.allTracks ?? (service == .appleMusic ? sync.library?.tracks ?? [] : []) }
    private var knownSaved: Set<String> {
        if let snapshot { return Set((snapshot.savedTracks + snapshot.savedAlbums.filter { !$0.isCompleteAlbum }.flatMap(\.tracks)).map(\.playableID)) }
        return Set((sync.library?.tracks ?? []).filter { sync.library?.inventory?.trackInfo[$0.id]?.playlistOnly == false }.map(\.id))
    }
    private var includedInPlaylists: Set<String> {
        if let snapshot { return Set(snapshot.playlists.flatMap(\.tracks).map(\.playableID)) }
        return Set((sync.library?.inventory?.playlists ?? []).flatMap(\.trackIDs))
    }
    private var visibleTracks: [Track] {
        tracks.filter { track in
            let matches = query.isEmpty || [track.title, track.artist, track.albumTitle].joined(separator: " ").localizedCaseInsensitiveContains(query)
            guard matches else { return false }
            switch songFilter {
            case .observed: return true
            case .saved: return knownSaved.contains(xmlSource ? track.id : track.playableID)
            case .loose: return metrics.looseSongIdentities != nil && knownSaved.contains(xmlSource ? track.id : track.playableID) && !includedInPlaylists.contains(xmlSource ? track.id : track.playableID)
            }
        }.sorted { [$0.artist, $0.title, $0.albumTitle, $0.id].lexicographicallyPrecedes([$1.artist, $1.title, $1.albumTitle, $1.id]) }
    }
    private var displayedAlbums: [Album] {
        if let snapshot { return snapshot.savedAlbums }
        let groups = Dictionary(grouping: tracks.filter { !$0.albumTitle.isEmpty }, by: { CatalogMatcher.normalized($0.artist) + "\u{0}" + CatalogMatcher.normalized($0.albumTitle) })
        return groups.map { key, songs in
            Album(id: "xml-group:" + key, title: songs[0].albumTitle, artist: songs[0].artist, tracks: songs, isCompleteAlbum: false)
        }.sorted { [$0.artist, $0.title, $0.id].lexicographicallyPrecedes([$1.artist, $1.title, $1.id]) }
    }
    private var visibleAlbums: [Album] {
        let outside = Set((snapshot?.libraryMembership.albums ?? []).filter { !$0.classifiesSavedTracksOnly && $0.membership == .outsidePlaylists }.map { $0.album.id })
        return displayedAlbums.filter {
            (query.isEmpty || ($0.title + " " + $0.artist).localizedCaseInsensitiveContains(query)) &&
                (!onlyLooseAlbums || (!xmlSource && snapshot?.libraryMembership.outsideCompleteAlbumCount != nil && outside.contains($0.id)))
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeading(eyebrow: "Bibliotecas", title: service.name,
                            subtitle: xmlSource ? "Instantánea exportada de Música · \(sync.library?.fileName ?? "XML pendiente")" : "Inventario de la última lectura autorizada.")
                if sync.library == nil || sync.spotify == nil {
                    EmptyState(symbol: "square.stack", title: "Cargá las fuentes", message: "El asistente leerá Spotify y la fuente de Apple Music que elijas.")
                    Button("Abrir asistente") { model.navigationRequest = .newSync }.buttonStyle(.borderedProminent)
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) { metricCards }
                        VStack(spacing: 12) { metricCards }
                    }
                    if !metrics.songsComplete || !metrics.playlistsComplete {
                        Notice(title: "Cobertura e incertidumbre", message: coverageDescription, symbol: "info.circle", color: SyncStyle.coral)
                    }
                    HStack {
                        Picker("Contenido", selection: $section) { ForEach(LibraryServiceSection.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                        Button("Revisar diferencias") { model.navigationRequest = .syncReview }
                    }
                    SearchField(text: $query, prompt: "Buscar en \(service.name)")
                    if section == .songs { songContent }
                    if section == .albums { albumContent }
                    if section == .playlists { playlistContent }
                    LibraryAnalysisStatus(sync: sync)
                }
            }.padding(28).frame(maxWidth: 1100, alignment: .leading).frame(maxWidth: .infinity)
        }
    }
    @ViewBuilder private var metricCards: some View {
        LibraryMetric(value: "\(metrics.songIdentities)", title: "Identidades de canción")
        LibraryMetric(value: "\(metrics.savedSongMemberships)", title: metrics.savedSongsKnown ? "Membresías guardadas" : "Membresías guardadas conocidas")
        LibraryMetric(value: "\(metrics.playlistOccurrences)", title: "Apariciones en playlists")
        LibraryMetric(value: metrics.looseSongIdentities.map(String.init) ?? "Sin determinar", title: "Guardadas fuera de playlists")
    }
    private var coverageDescription: String {
        if xmlSource && !metrics.savedSongsKnown {
            return "\(metrics.uncertainSongMemberships) pistas del XML tienen membresía guardada desconocida. \(metrics.selectedUncertainSongs) fueron elegidas explícitamente para guardar en Spotify. El conteo de canciones fuera de playlists requiere membresía y cobertura completas."
        }
        return "La lectura es parcial. Sólo se muestran observaciones recibidas; no se confirma ausencia ni un total de canciones fuera de playlists."
    }
    private var songContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Membresía de canción", selection: $songFilter) { ForEach(LibrarySongFilter.allCases) { Text($0.rawValue).tag($0) } }
            Text("\(visibleTracks.count) filas observadas en esta vista. Las repeticiones de playlists se cuentan en cada playlist, sin multiplicar las identidades de canción.").font(.caption).foregroundStyle(.secondary)
            if songFilter == .loose && metrics.looseSongIdentities == nil {
                Notice(title: "Clasificación pendiente", message: "La cobertura o la membresía guardada desconocida no permiten afirmar qué canciones están fuera de todas las playlists.")
            }
            LazyVStack(spacing: 8) {
                ForEach(visibleTracks) { track in
                    HStack(spacing: 12) {
                        ArtworkView(url: track.artworkURL, title: track.title, service: service).frame(width: 46, height: 46)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(track.title).font(.callout.weight(.medium))
                            Text("\(track.artist) · \(track.albumTitle)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(membershipLabel(track)).font(.caption).foregroundStyle(.secondary)
                        if let url = MusicLinks.url(track, service: service) { Link("Abrir", destination: url).font(.caption) }
                    }.padding(12).background(SyncStyle.surface, in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }
    private var albumContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(xmlSource ? "Agrupaciones por álbum del XML. Sus pistas no acreditan una edición completa guardada." : "Álbumes guardados, con las ediciones completas separadas de los grupos parciales.")
                .font(.callout).foregroundStyle(.secondary)
            if !xmlSource {
                Toggle("Sólo álbumes completos fuera de playlists", isOn: $onlyLooseAlbums).toggleStyle(.checkbox)
                Text("\(metrics.completeSavedAlbums) álbumes completos guardados · \(snapshot?.libraryMembership.outsideCompleteAlbumCount.map(String.init) ?? "Sin determinar") fuera de playlists")
                    .font(.caption).foregroundStyle(.secondary)
                if onlyLooseAlbums && snapshot?.libraryMembership.outsideCompleteAlbumCount == nil {
                    Notice(title: "Clasificación de álbumes pendiente", message: "La cobertura no permite afirmar cuáles están fuera de todas las playlists.")
                }
            }
            ForEach(visibleAlbums) { album in
                SurfaceCard {
                    HStack(spacing: 14) {
                        ArtworkView(url: album.artworkURL ?? album.tracks.first?.artworkURL, title: album.title, service: service).frame(width: 55, height: 55)
                        VStack(alignment: .leading, spacing: 5) { Text(album.title).font(.headline); Text(album.artist).font(.callout).foregroundStyle(.secondary) }
                        Spacer()
                        StatusPill(title: album.isCompleteAlbum ? "Álbum completo guardado" : "Agrupación de \(album.tracks.count) pistas")
                    }
                }
            }
        }
    }
    @ViewBuilder private var playlistContent: some View {
        if let snapshot {
            ForEach(snapshot.playlists.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }) { playlist in
                playlistCard(id: playlist.id, name: playlist.name, artwork: playlist.artworkURL, count: playlist.tracks.count, complete: playlist.contentsComplete)
            }
        } else {
            ForEach((sync.library?.inventory?.playlists ?? []).filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }, id: \.id) { playlist in
                playlistCard(id: playlist.id, name: playlist.name, artwork: playlist.artworkURL, count: playlist.trackIDs.count, complete: playlist.contentsComplete)
            }
        }
    }
    private func playlistCard(id: String, name: String, artwork: String?, count: Int, complete: Bool) -> some View {
        let included = (service == .spotify ? sync.session.configuration.scope.spotifyPlaylistIDs : sync.session.configuration.scope.appleMusicPlaylistIDs)?.contains(id) ?? true
        return SurfaceCard {
            HStack(spacing: 14) {
                ArtworkView(url: artwork, title: name, service: service).frame(width: 55, height: 55)
                VStack(alignment: .leading, spacing: 5) {
                    Text(name).font(.headline)
                    Text("\(count) apariciones\(complete ? "" : " · Contenido parcial")").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                StatusPill(title: included && sync.session.configuration.scope.playlists ? "Incluida en comparación" : "Fuera del alcance elegido")
            }
        }
    }
    private func membershipLabel(_ track: Track) -> String {
        let id = xmlSource ? track.id : track.playableID
        if knownSaved.contains(id) { return includedInPlaylists.contains(id) ? "Guardada · En playlist" : "Guardada conocida" }
        if xmlSource, sync.library?.inventory?.trackInfo[track.id]?.playlistOnly == nil { return "Guardada: desconocido" }
        return "Pista observada · Sin membresía guardada"
    }
}

struct LibrarySyncActivityView: View {
    @EnvironmentObject private var model: AppModel
    private var sync: LibrarySyncCoordinator { model.librarySync }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeading(eyebrow: "Actividad de sincronización", title: "En curso y lotes confirmados",
                            subtitle: "Cada lote conserva los cambios concretos que confirmaste. Los nuevos resultados esperan otra decisión.")
                LibraryAnalysisStatus(sync: sync)
                HStack {
                    Button("Volver a revisar") { model.navigationRequest = .syncReview }
                    Button("Actualizar fuentes") { model.readSyncSources(useOfficialApple: sync.session.appleSnapshot != nil) }
                        .disabled(model.isBusy || sync.library == nil)
                    if sync.session.appleSnapshot == nil {
                        Button("Reimportar XML para verificar…") { model.manualChecklist.importXML() }
                            .disabled(model.isBusy || !model.manualChecklist.isHydrated || model.manualChecklist.isDemo)
                    }
                }
                if sync.session.batches.isEmpty {
                    EmptyState(symbol: "checklist", title: "Todavía no hay lotes confirmados", message: "Las equivalencias y el análisis preparan propuestas. Confirmá las altas elegidas desde Cambios por revisar.")
                }
                ForEach(sync.session.batches.reversed()) { batch in batchCard(batch) }
            }.padding(28).frame(maxWidth: 1100, alignment: .leading).frame(maxWidth: .infinity)
        }
    }
    private func batchCard(_ batch: LibraryApprovalBatch) -> some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Lote de \(batch.unitIDs.count) unidades · \(batch.differenceIDs.count) diferencias").font(.headline)
                        Text(batch.approvedAt, format: .dateTime.day().month().hour().minute()).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    StatusPill(title: batchTitle(batch.state), symbol: batch.state == .verified ? "checkmark.circle" : nil,
                               color: batch.state == .attention ? SyncStyle.coral : .secondary)
                }
                Text(batch.message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !batch.operations.isEmpty {
                    DisclosureGroup("Operaciones confirmadas (\(batch.operations.count))") {
                        VStack(alignment: .leading, spacing: 9) {
                            ForEach(batch.operations) { operation in
                                HStack {
                                    Label(operation.title, systemImage: operation.kind.symbol)
                                    Spacer()
                                    Text("\(operation.service.name) · \(operation.kind.label)").foregroundStyle(.secondary)
                                }.font(.caption)
                            }
                        }.padding(.top, 8)
                    }
                }
                if !batch.manualTasks.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Tareas para completar en Apple Music").font(.callout.weight(.semibold))
                        Text("Marcar una tarea expresa que la realizaste. La presencia se verifica con una nueva lectura o exportación de Música.")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(batch.manualTasks) { task in
                            HStack(alignment: .top, spacing: 12) {
                                Toggle("Marqué como realizada: \(task.title)", isOn: Binding(get: { sync.session.manualMarks.contains(task.id) }, set: { sync.markManual(task.id, done: $0) }))
                                    .toggleStyle(.checkbox).disabled(sync.isApplying || batch.state == .verified)
                                Spacer()
                                StatusPill(title: batch.state == .verified ? "Verificada por lectura" : sync.session.manualMarks.contains(task.id) ? "Marcada por vos" : "Pendiente manual")
                                if let track = task.tracks.first, let url = MusicLinks.searchURL(track, service: .appleMusic) { Link("Buscar en Apple Music", destination: url) }
                            }
                        }
                    }
                }
                if batch.state == .attention {
                    HStack {
                        Text("Comprobá el resultado antes de confirmar otro envío.").font(.caption).foregroundStyle(SyncStyle.coral)
                        Spacer()
                        if batch.runID != nil { Button("Comprobar por lectura") { sync.reconcile(batch.id) }.disabled(sync.isWorking || model.legacyBusy) }
                        Button("Ver historial") { model.navigationRequest = .history }
                    }
                }
            }
        }
    }
    private func batchTitle(_ state: LibraryApprovalState) -> String {
        switch state {
        case .queued: return "Confirmado · En espera"; case .applying: return "Aplicando"
        case .verified: return "Verificado"; case .manual: return "Esperando verificación manual"
        case .attention: return "Requiere comprobación"; case .revoked: return "Requiere nueva confirmación"
        }
    }
}
