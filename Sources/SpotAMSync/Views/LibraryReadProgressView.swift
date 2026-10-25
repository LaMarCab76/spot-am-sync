import SwiftUI
import SyncCore

extension LibraryReadProgress {
    var stageTitle: String {
        switch stage {
        case .savedTracks: return "Tus me gusta"
        case .savedAlbums: return "Álbumes guardados"
        case .playlistList: return "Listando playlists"
        case .playlistTracks: return "Contenido de playlists"
        }
    }
    var countText: String { total.map { "\(received) de \($0)" } ?? "\(received) recibidos" }
    var statusText: String {
        var text = "\(stageTitle): \(countText)"
        if let itemName { text += " · \(itemName)" }
        if let itemReceived { text += " · \(itemReceived)" + (itemTotal.map { " de \($0) canciones" } ?? " canciones") }
        if waitingUntil != nil { text += " · Esperando al servicio…" }
        return text
    }
}

struct LibraryReadProgressView: View {
    let progress: LibraryReadProgress
    @ViewState private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(progress.statusText).font(.callout).fixedSize(horizontal: false, vertical: true)
            if let total = progress.total, total > 0 {
                ProgressView(value: Double(min(progress.received, total)), total: Double(total))
                    .accessibilityLabel(progress.stageTitle).accessibilityValue(progress.countText)
            } else { ProgressView().controlSize(.small) }
            if let until = progress.waitingUntil {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(until > context.date ? "Reintento en \(Int(ceil(until.timeIntervalSince(context.date)))) s" : "Esperando la respuesta del servicio…")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if !progress.playlists.isEmpty {
                DisclosureGroup("Playlists encontradas: \(progress.playlists.count)", isExpanded: $expanded) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 7) {
                            ForEach(progress.playlists) { playlist in
                                HStack {
                                    Text(playlist.name).lineLimit(1)
                                    Spacer()
                                    Text(playlistStatus(playlist)).foregroundStyle(.secondary)
                                }.font(.caption).accessibilityElement(children: .combine)
                            }
                        }.padding(.vertical, 4)
                    }.frame(maxHeight: 120)
                }.font(.caption)
            }
        }.padding(14).background(SyncStyle.green.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    private func playlistStatus(_ playlist: LibraryReadProgress.PlaylistStatus) -> String {
        switch playlist.state {
        case .pending: return "Pendiente"
        case .reading: return "Leyendo: \(playlist.received)" + (playlist.total.map { " de \($0)" } ?? "")
        case .complete: return "Completa · \(playlist.received) canciones"
        case .partial: return "Lectura parcial · \(playlist.received) canciones"
        }
    }
}
