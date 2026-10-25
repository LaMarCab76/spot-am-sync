import SwiftUI
import SyncCore

enum AppDestination: String, CaseIterable, Identifiable {
    case overview, newSync, manual, review, matches, playlists, playlistDetails, library, queue, activity, history, connections, settings
    case spotifyLibrary, appleMusicLibrary, syncReview, syncActivity, legacySync
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: return "Inicio"; case .newSync: return "Nueva sincronización"
        case .manual: return "Agregar a Apple Music"; case .review: return "Revisar cambios"
        case .matches: return "Coincidencias"; case .playlists: return "Playlists"; case .playlistDetails: return "Playlist"
        case .library: return "Bibliotecas"; case .queue: return "Cola y programación"; case .activity: return "Actividad"
        case .history: return "Historial"; case .connections: return "Conectar cuentas"; case .settings: return "Ajustes"
        case .spotifyLibrary: return "Spotify"; case .appleMusicLibrary: return "Apple Music"
        case .syncReview: return "Cambios por revisar"; case .syncActivity: return "En curso y lotes"; case .legacySync: return "Configuraciones guardadas"
        }
    }
    var symbol: String {
        switch self {
        case .overview: return "house"; case .newSync: return "plus.circle"; case .manual: return "checklist"
        case .review: return "checklist"; case .matches: return "arrow.triangle.branch"
        case .playlists, .playlistDetails: return "music.note.list"; case .library: return "square.stack"
        case .queue: return "calendar.badge.clock"; case .activity: return "waveform.path"
        case .history: return "clock.arrow.circlepath"; case .connections: return "link"; case .settings: return "gearshape"
        case .spotifyLibrary, .appleMusicLibrary: return "square.stack"
        case .syncReview: return "checklist"; case .syncActivity: return "arrow.triangle.2.circlepath"; case .legacySync: return "slider.horizontal.3"
        }
    }
}

struct MainView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    var registerReopen: (OpenWindowAction) -> Void = { _ in }
    @ViewState private var destination: AppDestination? = .overview
    @ViewState private var visibility: NavigationSplitViewVisibility = .all
    @ViewState private var backStack: [AppDestination] = []
    @ViewState private var forwardStack: [AppDestination] = []
    @ViewState private var previous: AppDestination = .overview
    @ViewState private var movingHistory = false

    var body: some View {
        NavigationSplitView(columnVisibility: $visibility) {
            sidebar.navigationSplitViewColumnWidth(min: 215, ideal: 235, max: 280)
        } detail: {
            VStack(spacing: 0) {
                if model.isDemo {
                    HStack(spacing: 8) {
                        Image(systemName: "flask"); Text("Demostración").fontWeight(.semibold)
                        Text("Bibliotecas de ejemplo · Ningún cambio en cuentas reales")
                        Spacer()
                    }.font(.caption).foregroundStyle(SyncStyle.coral).padding(.horizontal, 28).padding(.vertical, 9)
                        .background(SyncStyle.coral.opacity(0.08))
                }
                if let progress = model.libraryProgress ?? model.librarySync.libraryProgress {
                    LibraryReadProgressView(progress: progress).padding(.horizontal, 28).padding(.top, 12)
                }
                if destination != .syncReview, !model.librarySync.readyDifferences.isEmpty {
                    HStack(spacing: 10) {
                        Label("\(model.librarySync.readyDifferences.count) altas listas para revisar", systemImage: "checklist")
                        Spacer()
                        Button("Revisar ahora") { navigate(.syncReview) }
                    }.font(.callout).padding(.horizontal, 28).padding(.vertical, 10).background(SyncStyle.green.opacity(0.08))
                }
                content.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(SyncStyle.background)
            .safeAreaInset(edge: .bottom, spacing: 0) { syncBar.padding(.horizontal, 22).padding(.bottom, 14).padding(.top, 8) }
            .navigationTitle((destination ?? .overview).title)
            .toolbar {
                ToolbarItemGroup(placement: .navigation) {
                    Button { goBack() } label: { Image(systemName: "chevron.left") }.disabled(backStack.isEmpty).help("Atrás")
                    Button { goForward() } label: { Image(systemName: "chevron.right") }.disabled(forwardStack.isEmpty).help("Adelante")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { model.editingProfileID = nil; navigate(.newSync) } label: { Label("Nueva sincronización", systemImage: "plus") }
                        .keyboardShortcut("n", modifiers: .command).disabled(model.isBusy)
                }
            }
        }
        .tint(SyncStyle.green).preferredColorScheme(.dark)
        .frame(minWidth: 1050, minHeight: 720)
        .onAppear { registerReopen(openWindow) }
        .alert("No se pudo completar la acción", isPresented: Binding(get: { model.errorMessage != nil || model.workspace.errorMessage != nil || model.librarySync.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil; model.workspace.errorMessage = nil; model.librarySync.errorMessage = nil } })) {
            Button("Entendido", role: .cancel) { model.errorMessage = nil; model.workspace.errorMessage = nil; model.librarySync.errorMessage = nil }
        } message: { Text(model.errorMessage ?? model.workspace.errorMessage ?? model.librarySync.errorMessage ?? "") }
        .onChange(of: destination) { _, new in
            guard let new, new != previous else { return }
            if !movingHistory { backStack.append(previous); forwardStack = [] }
            previous = new; movingHistory = false
        }
        .onReceive(model.$navigationRequest) { value in
            if let value { navigate(value); model.navigationRequest = nil }
        }
        .onReceive(model.$phase) { phase in
            switch phase {
            case .connecting: navigate(.connections)
            default: break
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch destination ?? .overview {
        case .overview: HomeView(navigate: navigate)
        case .newSync:
            if model.editingProfileID != nil { NewSyncView() } else { LibrarySyncWizardView() }
        case .legacySync: NewSyncView()
        case .spotifyLibrary: LibraryServiceView(service: .spotify)
        case .appleMusicLibrary: LibraryServiceView(service: .appleMusic)
        case .syncReview: LibraryChangesView()
        case .syncActivity: LibrarySyncActivityView()
        case .manual: ManualChecklistView(manual: model.manualChecklist)
        case .review: ReviewView(navigate: navigate)
        case .matches: MatchesView()
        case .playlists: PlaylistsView()
        case .playlistDetails: PlaylistDetailView()
        case .library: OverviewView(navigate: navigate)
        case .queue: QueueView()
        case .activity: ActivityView()
        case .history: HistoryView()
        case .connections: ConnectionsView()
        case .settings: AppSettingsView()
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 21, weight: .medium))
                Text("Spot·AM").font(.system(size: 22, weight: .semibold)).tracking(-0.7)
                Spacer()
            }.padding(.horizontal, 22).padding(.top, 25).padding(.bottom, 24)
            List(selection: $destination) {
                Section { row(.overview) }
                Section("Bibliotecas") { row(.spotifyLibrary); row(.appleMusicLibrary) }
                Section("Sincronización") { row(.newSync); row(.syncReview) }
                Section("Actividad") { row(.syncActivity); row(.queue); row(.history) }
                Section("Herramientas") { row(.manual); row(.review); row(.matches) }
                Section("Ajustes") { row(.connections); row(.settings) }
            }.listStyle(.sidebar).scrollContentBackground(.hidden)
            VStack(spacing: 12) {
                ForEach(MusicService.allCases) { service in
                    HStack(spacing: 9) {
                        ServiceMark(service: service, size: 24)
                        Text(service.name).font(.caption)
                        Spacer()
                        Circle().fill(model.accounts[service] == nil ? Color.gray : SyncStyle.green).frame(width: 5, height: 5)
                    }.accessibilityElement(children: .combine)
                }
                Text(model.isDemo ? "Cuentas de demostración" : "Tus cambios, con tu confirmación")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }.padding(20)
        }.background(Color(white: 0.025))
    }

    private func row(_ value: AppDestination) -> some View {
        HStack {
            Label(value.title, systemImage: value.symbol)
            Spacer(minLength: 3)
            if value == .queue {
                let count = model.workspace.state.jobs.filter { $0.state == .ready }.count
                if count > 0 { Text("\(count)").font(.caption.monospacedDigit()).foregroundStyle(SyncStyle.coral) }
            }
            if value == .syncReview, !model.librarySync.readyDifferences.isEmpty {
                Text("\(model.librarySync.readyDifferences.count)").font(.caption.monospacedDigit()).foregroundStyle(SyncStyle.green)
            }
        }.padding(.vertical, 5).tag(value)
    }

    private var syncBar: some View {
        HStack(spacing: 13) {
            if model.isBusy { ProgressView().controlSize(.small) }
            else { Image(systemName: "arrow.triangle.2.circlepath").font(.title3) }
            VStack(alignment: .leading, spacing: 4) {
                Text(model.isBusy ? "En curso" : "Todo a tu ritmo").font(.caption.weight(.semibold))
                Text(model.librarySync.library != nil ? model.librarySync.statusText : model.displayedStatusText).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(model.displayedStatusText)
            }
            Spacer(minLength: 10)
            if model.isBusy { Button("Detener") { model.cancel() } }
            else if model.canResume { Button("Comprobar pendientes") { model.resume() } }
            else { Button("Ver cambios") { navigate(.syncReview) }.buttonStyle(.plain).font(.caption.weight(.medium)) }
        }.padding(.horizontal, 18).padding(.vertical, 13)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.15)))
            .shadow(color: .black.opacity(0.3), radius: 15, y: 5)
    }

    private func navigate(_ value: AppDestination) { destination = value }
    private func goBack() {
        guard let target = backStack.popLast() else { return }
        forwardStack.append(destination ?? .overview); movingHistory = true; destination = target
    }
    private func goForward() {
        guard let target = forwardStack.popLast() else { return }
        backStack.append(destination ?? .overview); movingHistory = true; destination = target
    }
}
