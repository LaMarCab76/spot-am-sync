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

    var body: some View {
        LibraryProgressPanel(presentation: .init(read: progress)) { EmptyView() }
    }
}

/// Presentation only: these values never become inventory or authorize a write.
struct LibraryProgressPresentation: Equatable {
    var title: String
    var detail: String
    var countText: String = ""
    var fraction: Double?
    var isWorking = false
    var waitingUntil: Date?
    var playlists: [LibraryReadProgress.PlaylistStatus] = []

    init(title: String, detail: String, fraction: Double? = nil, isWorking: Bool = false) {
        self.title = title; self.detail = detail
        self.fraction = fraction.map { min(1, max(0, $0)) }; self.isWorking = isWorking
    }

    init(read: LibraryReadProgress) {
        title = read.stageTitle
        detail = read.itemName ?? "Actualizando el estado de la biblioteca…"
        if let received = read.itemReceived {
            detail += " · \(received)" + (read.itemTotal.map { " de \($0) canciones" } ?? " canciones")
        }
        countText = read.countText
        // A known empty collection is different from an unknown total.
        fraction = read.total.map { $0 > 0 ? min(1, max(0, Double(read.received) / Double($0))) : 1 }
        isWorking = true; waitingUntil = read.waitingUntil; playlists = read.playlists
    }

    var accessibilityProgress: String {
        if !countText.isEmpty { return countText }
        return fraction.map { "\(Int($0 * 100)) %" } ?? "En curso"
    }
}

/// All stages use the same rows. Only an explicit user action opens the detail list.
struct LibraryProgressPanel<Actions: View>: View {
    let presentation: LibraryProgressPresentation
    @ViewBuilder var actions: () -> Actions
    @ViewState private var showsPlaylists = false
    @ScaledMetric(relativeTo: .callout) private var textRowHeight = 20
    @ScaledMetric(relativeTo: .caption) private var controlsHeight = 26
    @ScaledMetric(relativeTo: .caption) private var detailsWidth = 108

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text(presentation.title).font(.callout.weight(.semibold))
                    .lineLimit(1).help(presentation.title)
                Spacer(minLength: 0)
                Text(presentation.countText).font(.caption.monospacedDigit()).lineLimit(1)
                    .help(presentation.countText)
            }.frame(height: textRowHeight)
            Text(presentation.detail).font(.callout).lineLimit(1, reservesSpace: true)
                .truncationMode(.tail).help(presentation.detail)
                .frame(maxWidth: .infinity, alignment: .leading).frame(height: textRowHeight)
            ProgressView(value: presentation.isWorking ? presentation.fraction : (presentation.fraction ?? 0))
                .progressViewStyle(.linear).frame(height: 8)
                .opacity(presentation.isWorking || presentation.fraction != nil ? 1 : 0)
                .accessibilityLabel(presentation.title).accessibilityValue(presentation.accessibilityProgress)
                .accessibilityHidden(!presentation.isWorking && presentation.fraction == nil)
            HStack(spacing: 12) {
                waitStatus.frame(maxWidth: .infinity, alignment: .leading)
                Button { showsPlaylists = true } label: {
                    Text("Playlists (\(presentation.playlists.count))").monospacedDigit().lineLimit(1)
                        .frame(width: detailsWidth)
                }
                    .disabled(presentation.playlists.isEmpty)
                    .opacity(presentation.playlists.isEmpty ? 0 : 1)
                    .accessibilityHidden(presentation.playlists.isEmpty)
                    .popover(isPresented: $showsPlaylists, arrowEdge: .top) {
                        LibraryReadPlaylistDetails(playlists: presentation.playlists)
                    }
                actions()
            }.controlSize(.small).frame(height: controlsHeight)
        }
        .padding(14).background(SyncStyle.green.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("library-progress-panel")
        .onChange(of: presentation.playlists.isEmpty) { _, empty in
            if empty { showsPlaylists = false }
        }
    }

    @ViewBuilder private var waitStatus: some View {
        if let until = presentation.waitingUntil {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let text = until > context.date ? "Reintento en \(Int(ceil(until.timeIntervalSince(context.date)))) s" : "Esperando la respuesta del servicio…"
                Text(text).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .lineLimit(1).help(text)
            }
        } else {
            Text(" ").font(.caption).accessibilityHidden(true)
        }
    }
}

struct LibraryReadPlaylistDetails: View {
    let playlists: [LibraryReadProgress.PlaylistStatus]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Playlists encontradas: \(playlists.count)").font(.headline.monospacedDigit())
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(playlists) { playlist in
                        HStack(spacing: 12) {
                            Text(playlist.name).lineLimit(1).help(playlist.name)
                            Spacer(minLength: 8)
                            Text(playlistStatus(playlist)).monospacedDigit().foregroundStyle(.secondary).fixedSize()
                        }.font(.callout).accessibilityElement(children: .combine)
                    }
                }.padding(.vertical, 4)
            }.frame(height: 280)
        }.padding(18).frame(width: 520)
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
