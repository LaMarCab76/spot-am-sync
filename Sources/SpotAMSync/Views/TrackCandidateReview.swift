import SwiftUI
import SyncCore

struct TrackCandidateReview: View {
    let source: Track
    let service: MusicService
    let candidates: [Track]
    let selected: Track?
    let notes: [String]
    let busy: Bool
    var publicSearch = false
    let search: (TrackSearchQuery) -> Void
    let choose: (Track) -> Void
    let reject: (Track) -> Void
    let pending: () -> Void
    let omit: () -> Void
    let restore: () -> Void
    let cancel: () -> Void
    @Environment(\.dismiss) private var dismiss
    @ViewState private var title = ""
    @ViewState private var artist = ""
    @ViewState private var album = ""
    @ViewState private var country = Locale.current.region?.identifier ?? "US"
    @ViewState private var selectedAlbum = ""
    @ViewState private var selectedArtist = ""

    private var visible: [Track] {
        candidates.filter { (selectedAlbum.isEmpty || $0.albumTitle == selectedAlbum) && (selectedArtist.isEmpty || $0.artist == selectedArtist) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Elegí el equivalente").font(.title2.bold())
                Spacer()
                Button("Cerrar") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("\(source.title) — \(source.artist) · \(source.albumTitle)").textSelection(.enabled)
            Text("Las opciones de otro álbum o edición requieren tu elección. Elegir no envía cambios a ninguna plataforma.")
                .font(.callout).foregroundStyle(.secondary)
            searchFields
            if busy { HStack { ProgressView().controlSize(.small); Text("Procesando…").font(.caption); Button("Cancelar búsqueda", action: cancel) } }
            if !notes.isEmpty {
                Text(notes.joined(separator: "\n")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .frame(maxHeight: 90, alignment: .top).accessibilityLabel(notes.joined(separator: ". "))
            }
            HStack {
                Picker("Artista", selection: $selectedArtist) {
                    Text("Todos").tag("")
                    ForEach(Array(Set(candidates.map(\.artist))).filter { !$0.isEmpty }.sorted(), id: \.self) { Text($0).tag($0) }
                }
                Picker("Álbum", selection: $selectedAlbum) {
                    Text("Todos").tag("")
                    ForEach(Array(Set(candidates.map(\.albumTitle))).filter { !$0.isEmpty }.sorted(), id: \.self) { Text($0).tag($0) }
                }
            }
            ScrollView {
                LazyVStack(spacing: 10) {
                    if visible.isEmpty {
                        Text("No hay opciones en esta vista. Buscá por artista, álbum y canción, o ampliá los términos.")
                            .foregroundStyle(.secondary).padding()
                    }
                    ForEach(Array(visible.enumerated()), id: \.offset) { _, candidate in
                        CandidateReviewRow(source: source, candidate: candidate, service: service,
                                           selected: selected?.id == candidate.id, busy: busy,
                                           choose: { choose(candidate) }, reject: { reject(candidate) })
                    }
                }
            }
            HStack {
                Text("\(visible.count) opciones").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Restaurar descartadas", action: restore)
                Button("Dejar pendiente", action: pending)
                Button("Omitir canción", action: omit)
            }.disabled(busy)
        }
        .padding(24).frame(minWidth: 720, idealWidth: 850, minHeight: 650, idealHeight: 760)
        .onAppear { title = source.title; artist = source.artist; album = source.albumTitle }
        .onChange(of: candidates) { _, _ in selectedAlbum = ""; selectedArtist = "" }
    }

    private var searchFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Artista", text: $artist)
                TextField("Álbum", text: $album)
                TextField("Canción", text: $title)
            }.textFieldStyle(.roundedBorder)
            HStack {
                if publicSearch {
                    Text("País del catálogo público").font(.caption)
                    TextField("AR", text: $country).textFieldStyle(.roundedBorder).frame(width: 55)
                }
                Button("Buscar opciones") { submit() }.buttonStyle(.borderedProminent).disabled(title.isEmpty && artist.isEmpty && album.isEmpty)
                Button("Ver canciones del álbum") { submit(withoutTitle: true) }.disabled(album.trimmingCharacters(in: .whitespaces).isEmpty)
                Spacer()
                if let url = MusicLinks.searchURL(source, service: service) { Link("Abrir búsqueda en \(service.name)", destination: url) }
            }
        }.disabled(busy)
    }
    private func submit(withoutTitle: Bool = false) {
        var query = TrackSearchQuery(title: withoutTitle ? "" : title, artist: artist, album: album)
        query.country = country.uppercased()
        search(query)
    }
}

private struct CandidateReviewRow: View {
    let source: Track
    let candidate: Track
    let service: MusicService
    let selected: Bool
    let busy: Bool
    let choose: () -> Void
    let reject: () -> Void
    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(candidate.title).font(.headline)
                    Spacer()
                    if selected { StatusPill(title: "Seleccionada", color: SyncStyle.green) }
                    if candidate.id.hasPrefix("itunes:") { StatusPill(title: "Referencia iTunes") }
                }
                Text("\(candidate.artist) · \(candidate.albumTitle)").font(.callout)
                Text("\(duration(candidate.durationMS)) · \(candidate.explicit.map { $0 ? "Explícita" : "Sin contenido explícito" } ?? "Contenido explícito desconocido")")
                    .font(.caption).foregroundStyle(.secondary)
                Text(CatalogMatcher.comparison(source, candidate)).font(.caption).foregroundStyle(SyncStyle.coral)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(selected ? "Elegida" : "Elegir esta versión", action: choose).disabled(busy || !candidate.available)
                    Button("Descartar", action: reject).disabled(busy)
                    Spacer()
                    if let url = MusicLinks.url(candidate, service: service) { Link("Abrir en \(service.name)", destination: url) }
                }
            }
        }
    }
    private func duration(_ value: Int) -> String {
        value > 0 ? "\(value / 60000):\(String(format: "%02d", value / 1000 % 60))" : "Duración desconocida"
    }
}

enum MusicLinks {
    static func url(_ track: Track, service: MusicService) -> URL? {
        if let value = track.url, let url = URL(string: value), url.scheme == "https", url.user == nil, url.password == nil,
           ["music.apple.com", "itunes.apple.com", "open.spotify.com"].contains(url.host ?? "") { return url }
        return searchURL(track, service: service)
    }
    static func searchURL(_ track: Track, service: MusicService) -> URL? {
        var url = URLComponents(); url.scheme = "https"
        let term = [track.title, track.artist, track.albumTitle].filter { !$0.isEmpty }.joined(separator: " ")
        if service == .appleMusic {
            url.host = "music.apple.com"; url.path = "/search"; url.queryItems = [.init(name: "term", value: term)]
        } else { url.host = "open.spotify.com"; url.path = "/search/" + term }
        return url.url
    }
}
