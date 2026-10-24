import SwiftUI
import SyncCore

struct PlaylistDetailView: View {
    @EnvironmentObject private var model: AppModel
    @ViewState private var filter = "all"
    @ViewState private var search = ""
    @ViewState private var reviewing: TrackMatch?
    private var reference: PlaylistReference? { model.selectedPlaylistReference }
    private var playlist: Playlist? {
        guard let reference else { return nil }
        return model.snapshots.first { $0.account.service == reference.service }?.playlists.first { $0.id == reference.playlistID }
    }
    private func match(_ track: Track) -> TrackMatch? {
        model.decisions.tracks.first { $0.sourceService == reference?.service && $0.source.id == track.id }
    }
    private func state(_ track: Track) -> String {
        guard let match = match(track) else { return "Sin analizar" }
        if match.decision == .omitted { return "Omitida" }
        return match.selected == nil ? "Por revisar" : "Equivalencia confirmada"
    }
    var body: some View {
        if let playlist, let reference {
            ScrollView {
                VStack(alignment: .leading, spacing: 25) {
                    HStack(alignment: .bottom, spacing: 26) {
                        ArtworkView(url: playlist.artworkURL, title: playlist.name, service: reference.service).frame(width: 190, height: 190)
                        VStack(alignment: .leading, spacing: 13) {
                            Text(reference.service.name.uppercased()).font(.caption.weight(.semibold)).tracking(1.5).foregroundStyle(.secondary)
                            Text(playlist.name).font(.system(size: 38, weight: .semibold)).tracking(-1)
                            if !playlist.description.isEmpty { Text(playlist.description).font(.callout).foregroundStyle(.secondary) }
                            Text("\(playlist.tracks.count) canciones · \(duration(playlist.tracks.reduce(0) { $0 + $1.durationMS }))\(playlist.contentsComplete ? "" : " · Lectura parcial")")
                                .font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    HStack(spacing: 14) {
                        Button("Preparar esta playlist", systemImage: "arrow.triangle.2.circlepath") {
                            let mode: SyncMode = reference.service == .spotify ? .spotifyBase : .appleMusicBase
                            model.createSync(name: playlist.name, mode: mode, playlists: [reference], options: model.workspace.state.preferences.options, schedule: ReviewSchedule())
                        }.buttonStyle(.borderedProminent).controlSize(.large).disabled(!model.canAnalyze)
                        Toggle("Proteger", isOn: Binding(get: { model.decisions.protectedPlaylistIDs[reference.service, default: []].contains(playlist.id) }, set: {
                            model.protectPlaylist(service: reference.service, id: playlist.id, protected: $0)
                        })).toggleStyle(.switch).fixedSize().disabled(model.isBusy)
                        Spacer()
                    }
                    Divider()
                    HStack(spacing: 14) {
                        Picker("Estado", selection: $filter) {
                            Text("Todas").tag("all"); Text("Por revisar").tag("Por revisar"); Text("Con equivalencia").tag("Equivalencia confirmada"); Text("Omitidas").tag("Omitida")
                        }.pickerStyle(.segmented)
                        SearchField(text: $search, prompt: "Canción, artista o álbum").frame(maxWidth: 300)
                    }
                    Text("Una equivalencia elegida no confirma que la canción esté agregada en destino. La ejecución verifica sus resultados por separado.")
                        .font(.caption).foregroundStyle(.secondary)
                    LazyVStack(spacing: 0) {
                        ForEach(Array(playlist.tracks.enumerated()), id: \.offset) { index, track in
                            if (filter == "all" || state(track) == filter) && (search.isEmpty || "\(track.title) \(track.artist) \(track.albumTitle)".localizedCaseInsensitiveContains(search)) {
                                HStack(spacing: 13) {
                                    Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 25, alignment: .trailing)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(track.title).font(.callout.weight(.medium))
                                        Text("\(track.artist) · \(track.albumTitle)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                    Text(duration(track.durationMS)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    Button { reviewing = match(track) } label: {
                                        Text(state(track)).font(.caption).foregroundStyle(state(track) == "Por revisar" ? SyncStyle.coral : SyncStyle.green)
                                    }.buttonStyle(.plain).disabled(match(track) == nil || model.isBusy).frame(width: 155, alignment: .trailing)
                                }.padding(.vertical, 13)
                                Divider().opacity(0.5)
                            }
                        }
                    }
                }.padding(32)
            }
            .sheet(item: $reviewing) { captured in
                let current = model.decisions.tracks.first { $0.id == captured.id } ?? captured
                TrackCandidateReview(source: current.source, service: current.sourceService.other, candidates: model.orderedCandidates(current), selected: current.selected,
                    notes: (current.searchNotes ?? []) + [current.reason], busy: model.isBusy,
                    search: { model.searchTrack(matchID: current.id, query: $0) }, choose: { model.selectTrack(matchID: current.id, targetID: $0.id) },
                    reject: { model.rejectTrack(matchID: current.id, candidateID: $0.id) }, pending: { model.selectTrack(matchID: current.id, targetID: nil) },
                    omit: { model.omitTrack(matchID: current.id) }, restore: { model.searchTrack(matchID: current.id, query: TrackSearchQuery(current.source), restoreRejected: true) }, cancel: { model.cancel() })
            }
            .onChange(of: reviewing?.id) { _, value in model.holdsAutomaticPreparation = value != nil }
            .onDisappear { model.holdsAutomaticPreparation = false }
        } else {
            EmptyState(symbol: "music.note.list", title: "Esta playlist ya no está en el inventario", message: "Volvé a Playlists y actualizá las bibliotecas para comprobar su estado.")
        }
    }
    private func duration(_ milliseconds: Int) -> String { "\(milliseconds / 60_000):\(String(format: "%02d", milliseconds / 1000 % 60))" }
}
