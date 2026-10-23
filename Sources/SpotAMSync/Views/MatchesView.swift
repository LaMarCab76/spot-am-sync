import SwiftUI
import SyncCore

private enum MatchFilter: String, CaseIterable, Identifiable {
    case pending = "Por revisar", unavailable = "Sin coincidencia", resolved = "Con selección", all = "Todas"
    var id: String { rawValue }
    func includes(confidence: MatchConfidence, selected: Bool) -> Bool {
        switch self {
        case .pending: return !selected
        case .unavailable: return confidence == .unavailable && !selected
        case .resolved: return selected
        case .all: return true
        }
    }
}

struct MatchesView: View {
    @EnvironmentObject private var model: AppModel
    @ViewState private var showAlbums = false
    @ViewState private var search = ""
    @ViewState private var filter: MatchFilter = .pending

    private var tracks: [TrackMatch] {
        model.decisions.tracks.filter {
            filter.includes(confidence: $0.confidence, selected: $0.selected != nil)
                && (search.isEmpty || "\($0.source.title) \($0.source.artist) \($0.source.albumTitle)".localizedCaseInsensitiveContains(search))
        }
    }
    private var albums: [AlbumMatch] {
        model.decisions.albums.filter {
            filter.includes(confidence: $0.confidence, selected: $0.selected != nil)
                && (search.isEmpty || "\($0.source.title) \($0.source.artist)".localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeading(eyebrow: "La versión correcta importa", title: "Encontrá su equivalente", subtitle: "Compará artista, álbum y duración antes de elegir. Lo que quede sin resolver no se selecciona por vos.")
                HStack(spacing: 14) {
                    Picker("Contenido", selection: $showAlbums) {
                        Text("Canciones · \(model.decisions.tracks.count)").tag(false)
                        Text("Álbumes · \(model.decisions.albums.count)").tag(true)
                    }.pickerStyle(.segmented)
                    SearchField(text: $search, prompt: showAlbums ? "Buscar álbum o artista" : "Buscar canción o artista").frame(maxWidth: 290)
                }
                HStack {
                    Picker("Mostrar", selection: $filter) {
                        ForEach(MatchFilter.allCases) { option in Text(option.rawValue).tag(option) }
                    }.frame(width: 250)
                    Spacer()
                    Text("\(showAlbums ? albums.count : tracks.count) resultados").font(.caption).foregroundStyle(.secondary)
                }
                Notice(title: "Cada decisión actualiza la vista previa", message: "Cuando termines, volvé a Revisar cambios y comprobá la selección antes de confirmar.", symbol: "checklist", color: SyncStyle.green)
                if model.decisions.tracks.isEmpty && model.decisions.albums.isEmpty {
                    EmptyState(symbol: "arrow.triangle.branch", title: "Las coincidencias aparecen después del análisis", message: "Analizá las dos bibliotecas para comparar canciones y álbumes entre servicios.")
                } else if showAlbums ? albums.isEmpty : tracks.isEmpty {
                    EmptyState(symbol: "checkmark.magnifyingglass", title: "Sin coincidencias en esta vista", message: filter == .pending ? "No quedan elementos por revisar con estos filtros. Elegí Todas para ver las coincidencias seleccionadas." : "Probá otro filtro o una búsqueda diferente.")
                } else {
                    LazyVStack(spacing: 14) {
                        if showAlbums {
                            ForEach(albums) { match in AlbumMatchCard(match: match) }
                        } else {
                            ForEach(tracks) { match in TrackMatchCard(match: match) }
                        }
                    }
                }
            }.padding(28)
        }
    }
}

private struct MatchCardHeader: View {
    let title: String
    let artist: String
    let service: MusicService
    let reason: String
    let selected: Bool
    let confidence: MatchConfidence
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline).textSelection(.enabled)
                    Text(artist).font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                StatusPill(title: selected ? "Seleccionada" : confidence == .unavailable ? "Sin equivalente" : "Por revisar",
                           symbol: selected ? "checkmark.circle" : "questionmark.circle", color: selected ? SyncStyle.green : SyncStyle.coral)
            }
            HStack(spacing: 5) {
                Text(service.name)
                Image(systemName: "arrow.right")
                Text(service.other.name)
            }.font(.caption).foregroundStyle(.secondary)
            if !reason.isEmpty { Text(reason).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

private struct TrackMatchCard: View {
    @EnvironmentObject private var model: AppModel
    let match: TrackMatch
    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 13) {
                MatchCardHeader(title: match.source.title, artist: match.source.artist, service: match.sourceService, reason: match.reason, selected: match.selected != nil, confidence: match.confidence)
                TrackMetadata(track: match.source)
                Divider()
                if match.candidates.isEmpty {
                    Label("No se encontraron candidatos para elegir.", systemImage: "magnifyingglass").font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("Elegí la canción en \(match.sourceService.other.name)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(Array(match.candidates.enumerated()), id: \.offset) { _, candidate in
                        Button { model.selectTrack(matchID: match.id, targetID: candidate.id) } label: {
                            HStack(alignment: .top, spacing: 11) {
                                Image(systemName: match.selected?.id == candidate.id ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(match.selected?.id == candidate.id ? SyncStyle.green : .secondary).padding(.top, 3)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(candidate.title).font(.callout.weight(.medium)).foregroundStyle(.primary)
                                    Text(candidate.artist).font(.caption).foregroundStyle(.secondary)
                                    TrackMetadata(track: candidate)
                                }
                                Spacer(minLength: 0)
                                if !candidate.available || candidate.isLocal {
                                    StatusPill(title: candidate.isLocal ? "Archivo local" : "No disponible", color: .secondary)
                                }
                            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                .background(match.selected?.id == candidate.id ? SyncStyle.green.opacity(0.07) : Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 9))
                        }.buttonStyle(.plain).disabled(model.isBusy || !candidate.available || candidate.isLocal)
                            .accessibilityLabel("Elegir \(candidate.title), \(candidate.artist), \(candidate.albumTitle)")
                            .accessibilityAddTraits(match.selected?.id == candidate.id ? .isSelected : [])
                    }
                }
                HStack {
                    Text(match.selected == nil ? "Sin selección: esta equivalencia queda pendiente." : "Equivalencia seleccionada para la vista previa.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if match.selected != nil {
                        Button("Dejar sin seleccionar") { model.selectTrack(matchID: match.id, targetID: nil) }
                            .controlSize(.small).disabled(model.isBusy)
                    }
                }
            }
        }
    }
}

private struct TrackMetadata: View {
    let track: Track
    var body: some View {
        HStack(spacing: 8) {
            if !track.albumTitle.isEmpty { Label(track.albumTitle, systemImage: "square.stack").lineLimit(2) }
            if track.durationMS > 0 { Text("\(track.durationMS / 60_000):\(String(format: "%02d", track.durationMS / 1000 % 60))").monospacedDigit() }
            if let explicit = track.explicit {
                Text(explicit ? "Explícita" : "Sin contenido explícito").font(.system(size: 9, weight: .medium))
            }
        }.font(.caption).foregroundStyle(.secondary)
    }
}

private struct AlbumMatchCard: View {
    @EnvironmentObject private var model: AppModel
    let match: AlbumMatch
    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 13) {
                MatchCardHeader(title: match.source.title, artist: match.source.artist, service: match.sourceService, reason: match.reason, selected: match.selected != nil, confidence: match.confidence)
                Text("\(match.source.tracks.count) canciones\(match.source.isCompleteAlbum ? "" : " · Álbum incompleto")").font(.caption).foregroundStyle(.secondary)
                Divider()
                if match.candidates.isEmpty {
                    Label("No se encontraron álbumes candidatos.", systemImage: "magnifyingglass").font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("Elegí el álbum en \(match.sourceService.other.name)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(Array(match.candidates.enumerated()), id: \.offset) { _, candidate in
                        Button { model.selectAlbum(matchID: match.id, targetID: candidate.id) } label: {
                            HStack(alignment: .top, spacing: 11) {
                                Image(systemName: match.selected?.id == candidate.id ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(match.selected?.id == candidate.id ? SyncStyle.green : .secondary).padding(.top, 3)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(candidate.title).font(.callout.weight(.medium)).foregroundStyle(.primary)
                                    Text(candidate.artist).font(.caption).foregroundStyle(.secondary)
                                    Text("\(candidate.tracks.count) canciones\(candidate.isCompleteAlbum ? "" : " · Álbum incompleto")").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                if !candidate.available || !candidate.isCompleteAlbum {
                                    StatusPill(title: !candidate.available ? "No disponible" : "Incompleto", color: .secondary)
                                }
                            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                .background(match.selected?.id == candidate.id ? SyncStyle.green.opacity(0.07) : Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 9))
                        }.buttonStyle(.plain).disabled(model.isBusy || !candidate.available || !candidate.isCompleteAlbum)
                            .accessibilityLabel("Elegir álbum \(candidate.title), \(candidate.artist), \(candidate.tracks.count) canciones")
                            .accessibilityAddTraits(match.selected?.id == candidate.id ? .isSelected : [])
                    }
                }
                HStack {
                    Text(match.selected == nil ? "Sin selección: esta equivalencia queda pendiente." : "Equivalencia seleccionada para la vista previa.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if match.selected != nil {
                        Button("Dejar sin seleccionar") { model.selectAlbum(matchID: match.id, targetID: nil) }
                            .controlSize(.small).disabled(model.isBusy)
                    }
                }
            }
        }
    }
}
