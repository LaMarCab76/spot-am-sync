import SwiftUI
import SyncCore
import MusicProviders

struct TrackCandidateReview: View {
    let source: Track
    let service: MusicService
    let candidates: [Track]
    let selected: Track?
    let notes: [String]
    let busy: Bool
    var publicSearch = false
    /// Optional bytes read through MusicArtworkReader after a separate local opt-in.
    var sourceArtwork: ArtworkImage? = nil
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
    @ViewState private var localArtwork: ArtworkImage?
    @ViewState private var referenceArtwork: ArtworkImage?
    private var displayedArtwork: ArtworkImage? { localArtwork ?? sourceArtwork ?? referenceArtwork }

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
            HStack(alignment: .top, spacing: 14) {
                ArtworkView(url: source.artworkURL, title: source.title, service: service.other)
                    .overlay {
                        if let sourceArtwork = displayedArtwork, let image = NSImage(data: sourceArtwork.data) {
                            Image(nsImage: image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }.frame(width: 82, height: 82)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Origen · \(service.other.name)").font(.caption).foregroundStyle(.secondary)
                    Text("\(source.title) — \(source.artist) · \(source.albumTitle)").textSelection(.enabled)
                    if displayedArtwork?.origin == .spotifyReference {
                        Text("Referencia de Spotify; no confirma la portada de Música").font(.caption).foregroundStyle(.secondary)
                    } else if displayedArtwork?.origin == .localMusicFile {
                        Text("Portada incrustada del archivo local vinculado al XML").font(.caption).foregroundStyle(.secondary)
                    } else if source.artworkURL == nil {
                        Text("Portada de origen no disponible").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Text("Las opciones de otro álbum o edición requieren tu elección. Elegir no envía cambios a ninguna plataforma.")
                .font(.callout).foregroundStyle(.secondary)
            searchFields
            if source.id.hasPrefix("apple-music-xml:") {
                LocalArtworkSelection(track: source) { localArtwork = $0 }
            }
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
                                           sourceArtwork: displayedArtwork,
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
        .task(id: selected?.playableID) {
            referenceArtwork = nil
            if source.artworkURL == nil, source.id.hasPrefix("apple-music-xml:"), service == .spotify, let selected {
                referenceArtwork = await ArtworkComparison.load(url: selected.artworkURL, origin: .spotifyReference)
            }
        }
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
    let sourceArtwork: ArtworkImage?
    let selected: Bool
    let busy: Bool
    let choose: () -> Void
    let reject: () -> Void
    @ViewState private var artworkComparison = ArtworkComparison.unavailable("Falta una portada para comparar.")
    @ViewState private var comparingArtwork = false
    private var comparisonKey: ArtworkReviewKey {
        .init(sourceURL: source.artworkURL, candidateURL: candidate.artworkURL,
              sourceData: sourceArtwork?.data, origin: sourceArtwork?.origin)
    }
    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 14) {
                    ArtworkView(url: candidate.artworkURL, title: candidate.title, service: service).frame(width: 76, height: 76)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(candidate.id.hasPrefix("itunes:") ? "Candidato · catálogo público iTunes" : "Candidato · \(service.name)")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(candidate.title).font(.headline)
                        Text("\(candidate.artist) · \(candidate.albumTitle)").font(.callout)
                    }
                    Spacer()
                    if selected { StatusPill(title: "Seleccionada", color: SyncStyle.green) }
                    if candidate.id.hasPrefix("itunes:") { StatusPill(title: "Referencia iTunes") }
                }
                Text("\(duration(candidate.durationMS)) · \(candidate.explicit.map { $0 ? "Explícita" : "Sin contenido explícito" } ?? "Contenido explícito desconocido")")
                    .font(.caption).foregroundStyle(.secondary)
                Text(CatalogMatcher.comparison(source, candidate)).font(.caption).foregroundStyle(SyncStyle.coral)
                    .fixedSize(horizontal: false, vertical: true)
                Label(comparingArtwork ? "Comparando portadas…" : artworkComparison.state.label,
                      systemImage: artworkComparison.state == .equal ? "photo.badge.checkmark" : "photo.on.rectangle")
                    .font(.caption).foregroundStyle(.secondary)
                    .help(artworkComparison.detail)
                    .accessibilityLabel(comparingArtwork ? "Comparando portadas" : artworkComparison.state.label + ". " + artworkComparison.detail)
                HStack {
                    Button(selected ? "Elegida" : "Elegir esta versión", action: choose).disabled(busy || !candidate.available)
                    Button("Descartar", action: reject).disabled(busy)
                    Spacer()
                    if let url = MusicLinks.url(candidate, service: service) { Link("Abrir en \(service.name)", destination: url) }
                }
            }
        }
        .task(id: comparisonKey) {
            comparingArtwork = true
            let origin: ArtworkOrigin = service == .spotify ? .spotifyCatalog : .appleMusicCatalog
            let candidateOrigin: ArtworkOrigin = candidate.id.hasPrefix("itunes:") ? .itunesCatalog : origin
            let result: ArtworkComparison
            if sourceArtwork?.origin == .spotifyReference {
                result = .unavailable("La portada de Spotify es sólo una referencia; no prueba la portada de Música.")
            } else if let sourceArtwork {
                let other = await ArtworkComparison.load(url: candidate.artworkURL, origin: candidateOrigin)
                result = ArtworkComparison.compare(sourceArtwork, other)
            } else if source.artworkURL != nil && candidate.artworkURL != nil {
                result = await ArtworkComparison.compare(sourceURL: source.artworkURL,
                    sourceOrigin: service.other == .spotify ? .spotifyCatalog : .appleMusicCatalog,
                    candidateURL: candidate.artworkURL, candidateOrigin: candidateOrigin)
            } else {
                result = .unavailable("Falta una portada de origen o del candidato. Una URL diferente nunca prueba una diferencia visual.")
            }
            guard !Task.isCancelled else { return }
            artworkComparison = result; comparingArtwork = false
        }
    }
    private func duration(_ value: Int) -> String {
        value > 0 ? "\(value / 60000):\(String(format: "%02d", value / 1000 % 60))" : "Duración desconocida"
    }
}

private struct ArtworkReviewKey: Hashable {
    let sourceURL: String?
    let candidateURL: String?
    let sourceData: Data?
    let origin: ArtworkOrigin?
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
