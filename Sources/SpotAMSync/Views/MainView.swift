import SwiftUI
import SyncCore

enum AppDestination: String, CaseIterable, Identifiable {
    case overview, review, matches, playlists, activity, history, connections
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: return "Resumen"
        case .review: return "Revisar cambios"
        case .matches: return "Coincidencias"
        case .playlists: return "Playlists"
        case .activity: return "Actividad"
        case .history: return "Historial"
        case .connections: return "Conexiones"
        }
    }
    var symbol: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .review: return "checklist"
        case .matches: return "arrow.triangle.branch"
        case .playlists: return "music.note.list"
        case .activity: return "waveform.path"
        case .history: return "clock.arrow.circlepath"
        case .connections: return "link"
        }
    }
}

struct MainView: View {
    @EnvironmentObject private var model: AppModel
    @ViewState private var destination: AppDestination? = .overview
    @ViewState private var visibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $visibility) {
            sidebar.navigationSplitViewColumnWidth(min: 205, ideal: 220, max: 260)
        } detail: {
            VStack(spacing: 0) {
                if model.isDemo { demoBanner }
                Group {
                    switch destination ?? .overview {
                    case .overview: OverviewView(navigate: navigate)
                    case .review: ReviewView(navigate: navigate)
                    case .matches: MatchesView()
                    case .playlists: PlaylistsView()
                    case .activity: ActivityView()
                    case .history: HistoryView()
                    case .connections: ConnectionsView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                statusBar
            }
            .background(SyncStyle.background)
            .navigationTitle((destination ?? .overview).title)
        }
        .tint(SyncStyle.green)
        .frame(minWidth: 950, minHeight: 650)
        .alert("No se pudo completar la acción", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("Entendido", role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .onReceive(model.$phase) { phase in
            switch phase {
            case .syncing, .finished: destination = .activity
            case .analyzing: destination = .overview
            case .review: if destination == .overview { destination = .review }
            case .connecting: destination = .connections
            case .idle: break
            }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(SyncStyle.green)
                    .frame(width: 44, height: 44)
                    .background(SyncStyle.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 3) {
                    Text("SpotAM Sync").font(.system(size: 16, weight: .bold, design: .rounded))
                    Text("Tu música, en sintonía").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }.padding(.horizontal, 16).padding(.top, 23).padding(.bottom, 21)

            List(selection: $destination) {
                Section("Bibliotecas") {
                    navigationRow(.overview)
                    navigationRow(.review)
                    navigationRow(.matches)
                    navigationRow(.playlists)
                }
                Section("Seguimiento") {
                    navigationRow(.activity)
                    navigationRow(.history)
                }
                Section("Configuración") { navigationRow(.connections) }
            }
            .listStyle(.sidebar)
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 13) {
                ForEach(MusicService.allCases) { service in
                    HStack(spacing: 9) {
                        ServiceMark(service: service, size: 25)
                        Text(service.name).font(.system(size: 11, weight: .medium))
                        Spacer()
                        Image(systemName: model.accounts[service] != nil ? (model.isDemo ? "flask" : "checkmark.circle.fill") : "circle.dotted")
                            .foregroundStyle(model.accounts[service] != nil ? SyncStyle.green : .secondary)
                            .help(model.isDemo ? "Cuenta de ejemplo" : model.accounts[service] != nil ? "Conectado" : "Sin conectar")
                            .accessibilityLabel(model.isDemo ? "Ejemplo" : model.accounts[service] != nil ? "Conectado" : "Sin conectar")
                    }
                }
                Divider()
                Label("Vos elegís qué cambia", systemImage: "hand.raised")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }.padding(18)
        }
    }

    private func navigationRow(_ item: AppDestination) -> some View {
        HStack {
            Label(item.title, systemImage: item.symbol)
            Spacer(minLength: 4)
            if item == .review, let plan = model.plan, !plan.operations.isEmpty {
                Text("\(plan.operations.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if item == .matches, unresolvedCount > 0 {
                Text("\(unresolvedCount)").font(.caption.monospacedDigit()).foregroundStyle(SyncStyle.coral)
            }
        }.padding(.vertical, 3).tag(item)
    }

    private var unresolvedCount: Int {
        model.decisions.tracks.filter { $0.selected == nil }.count
            + model.decisions.albums.filter { $0.selected == nil }.count
    }

    private var demoBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "flask.fill")
            Text("MODO DEMOSTRACIÓN").fontWeight(.bold)
            Text("Datos de ejemplo · No representan tus bibliotecas ni cambios reales.")
            Spacer(minLength: 0)
        }
        .font(.system(size: 11)).foregroundStyle(SyncStyle.coral)
        .padding(.horizontal, 24).padding(.vertical, 10)
        .background(SyncStyle.coral.opacity(0.09))
    }

    private var statusBar: some View {
        HStack(spacing: 7) {
            if model.isBusy { ProgressView().controlSize(.mini) }
            else { Image(systemName: "music.note").foregroundStyle(SyncStyle.green) }
            Text(model.statusText.isEmpty ? "Listo para conectar tus bibliotecas" : model.statusText)
                .lineLimit(1).help(model.statusText)
            Spacer(minLength: 8)
            Text(model.isDemo ? "Demostración" : "Spotify + Apple Music").foregroundStyle(.tertiary)
        }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.vertical, 9)
    }

    private func navigate(_ value: AppDestination) { destination = value }
}
