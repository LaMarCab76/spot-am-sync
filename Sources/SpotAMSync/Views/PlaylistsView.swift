import SwiftUI
import SyncCore

struct PlaylistsView: View {
    @EnvironmentObject private var model: AppModel
    @ViewState private var spotifyID = ""
    @ViewState private var appleID = ""
    @ViewState private var search = ""
    @ViewState private var showProtectedOnly = false
    @ViewState private var serviceFilter = "all"
    @ViewState private var notice: String?

    private func playlists(_ service: MusicService) -> [Playlist] {
        model.snapshots.first { $0.account.service == service }?.playlists ?? []
    }

    private var existingLink: PlaylistLink? {
        model.decisions.playlists.first { $0.spotifyID == spotifyID || $0.appleMusicID == appleID }
    }

    private var canLink: Bool {
        !spotifyID.isEmpty && !appleID.isEmpty && !model.isBusy
            && playlists(.spotify).contains { $0.id == spotifyID }
            && playlists(.appleMusic).contains { $0.id == appleID }
            && !model.decisions.playlists.contains { $0.spotifyID == spotifyID && $0.appleMusicID == appleID }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeading(eyebrow: "Dales el mismo lugar", title: "Vinculá y protegé playlists", subtitle: "Indicá cuáles se corresponden entre servicios, incluso si tienen nombres diferentes. Revisá los cambios después de cada decisión.")
                if model.snapshots.isEmpty {
                    EmptyState(symbol: "music.note.list", title: "Todavía no hay playlists para revisar", message: "El análisis de las bibliotecas carga las playlists disponibles para vincular y proteger.")
                } else {
                    linkingCard
                    if let notice { Notice(title: "Vínculo solicitado", message: notice, symbol: "link", color: SyncStyle.green) }
                    if !model.decisions.playlists.isEmpty { linkedPlaylists }
                    Notice(title: "Conservá las playlists que elegís", message: "La protección bloquea los cambios sobre esa playlist en el servicio elegido. Podés desactivarla y revisar la nueva vista previa.", symbol: "lock.shield", color: SyncStyle.green)
                    HStack(spacing: 13) {
                        SearchField(text: $search, prompt: "Buscar playlist")
                        Picker("Servicio", selection: $serviceFilter) {
                            Text("Ambos").tag("all")
                            ForEach(MusicService.allCases) { service in Text(service.name).tag(service.rawValue) }
                        }.frame(width: 205)
                        Toggle("Sólo protegidas", isOn: $showProtectedOnly).toggleStyle(.checkbox)
                    }
                    ForEach(MusicService.allCases) { service in
                        if serviceFilter == "all" || serviceFilter == service.rawValue {
                            playlistSection(service)
                        }
                    }
                }
            }.padding(28)
        }
    }

    private var linkingCard: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 15) {
                Label("Vincular manualmente", systemImage: "link").font(.headline)
                Text("Elegí una playlist de cada servicio. El vínculo se usa en la vista previa; no cambia el contenido por sí solo.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack(alignment: .bottom, spacing: 13) {
                    playlistPicker(.spotify, selection: $spotifyID)
                    Image(systemName: "link").foregroundStyle(.secondary).padding(.bottom, 6)
                    playlistPicker(.appleMusic, selection: $appleID)
                    Button("Vincular") {
                        model.linkPlaylists(spotifyID: spotifyID, appleMusicID: appleID)
                        notice = "Comprobá el vínculo en la lista y volvé a revisar los cambios propuestos."
                    }.buttonStyle(.borderedProminent).disabled(!canLink)
                }
                if existingLink != nil && canLink {
                    Label("Una de estas playlists ya tiene un vínculo. Revisá la pareja actual antes de cambiarla.", systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(SyncStyle.coral)
                }
            }
        }.disabled(model.isBusy)
    }

    private func playlistPicker(_ service: MusicService, selection: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(service.name).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            Picker(service.name, selection: selection) {
                Text("Elegí una playlist").tag("")
                ForEach(playlists(service)) { playlist in Text("\(playlist.name) · \(playlist.tracks.count) canciones").tag(playlist.id) }
            }.labelsHidden().frame(maxWidth: .infinity)
        }
    }

    private var linkedPlaylists: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 13) {
                HStack { Label("Playlists vinculadas", systemImage: "link").font(.headline); Spacer(); Text("\(model.decisions.playlists.count)").foregroundStyle(.secondary).monospacedDigit() }
                ForEach(Array(model.decisions.playlists.enumerated()), id: \.offset) { _, link in
                    HStack(spacing: 12) {
                        ServiceMark(service: .spotify, size: 23)
                        Text(playlists(.spotify).first { $0.id == link.spotifyID }?.name ?? "Playlist no disponible")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "link").foregroundStyle(.secondary)
                        ServiceMark(service: .appleMusic, size: 23)
                        Text(playlists(.appleMusic).first { $0.id == link.appleMusicID }?.name ?? "Playlist no disponible")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if !playlists(.spotify).contains(where: { $0.id == link.spotifyID }) || !playlists(.appleMusic).contains(where: { $0.id == link.appleMusicID }) {
                            StatusPill(title: "Vínculo pendiente", color: SyncStyle.coral)
                        }
                        Button("Desvincular") {
                            model.unlinkPlaylists(link)
                            notice = "Vínculo quitado. Revisá la nueva propuesta antes de aplicar cambios."
                        }.disabled(model.isBusy)
                            .help("Quita la correspondencia guardada y recalcula la vista previa. No modifica playlists en los servicios.")
                    }.font(.callout).padding(.vertical, 3)
                }
            }
        }
    }

    private func playlistSection(_ service: MusicService) -> some View {
        let rows = playlists(service).filter { playlist in
            (search.isEmpty || playlist.name.localizedCaseInsensitiveContains(search))
                && (!showProtectedOnly || model.decisions.protectedPlaylistIDs[service, default: []].contains(playlist.id))
        }
        return VStack(alignment: .leading, spacing: 12) {
            HStack { Text(service.name).font(.headline); Text("\(rows.count) playlists").font(.caption).foregroundStyle(.secondary); Spacer() }
            if rows.isEmpty {
                Text("No hay playlists para mostrar con estos filtros.").font(.callout).foregroundStyle(.secondary).padding(.vertical, 16)
            }
            LazyVStack(spacing: 8) {
                ForEach(rows) { playlist in
                    HStack(alignment: .center, spacing: 12) {
                        Image(systemName: "music.note.list").font(.system(size: 18)).foregroundStyle(service == .spotify ? SyncStyle.green : SyncStyle.coral)
                            .frame(width: 32)
                        VStack(alignment: .leading, spacing: 5) {
                            Button(playlist.name) { model.showPlaylist(playlist, service: service) }.buttonStyle(.plain).font(.callout.weight(.semibold))
                            Text("\(playlist.tracks.count) canciones · \(ownership(playlist.ownership))").font(.caption).foregroundStyle(.secondary)
                            if !playlist.contentsComplete {
                                Label("Contenido incompleto", systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(SyncStyle.coral)
                            }
                            if !playlist.editable { Text("Sin permiso de edición").font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Toggle(isOn: Binding(get: { model.decisions.protectedPlaylistIDs[service, default: []].contains(playlist.id) }, set: { value in
                            model.protectPlaylist(service: service, id: playlist.id, protected: value)
                        })) { Label("Proteger", systemImage: "lock.shield") }
                        .toggleStyle(.switch).controlSize(.small).fixedSize().disabled(model.isBusy)
                        .accessibilityLabel("Proteger \(playlist.name) en \(service.name)")
                    }.padding(14).background(SyncStyle.surface, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(SyncStyle.border))
                }
            }
        }
    }

    private func ownership(_ ownership: PlaylistOwnership) -> String {
        switch ownership {
        case .owned: return "Propia"
        case .collaborative: return "Colaborativa"
        case .followed: return "Seguida"
        case .system: return "Del servicio"
        case .unknown: return "Propiedad sin confirmar"
        }
    }
}
