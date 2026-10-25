import AppKit
import SwiftUI
import UniformTypeIdentifiers
import SyncCore
import MusicProviders

/// A deliberate local-file read. No library discovery, Music launch or Apple Events.
struct LocalArtworkSelection: View {
    let track: Track
    let receive: (ArtworkImage) -> Void
    @ViewState private var busy = false
    @ViewState private var message = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button(busy ? "Leyendo portada local…" : "Leer portada de un archivo local…") {
                Task { await read() }
            }.disabled(busy)
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }
    @MainActor private func read() async {
        busy = true; defer { busy = false }
        let xmlPanel = NSOpenPanel(); xmlPanel.title = "Elegí el XML de esta canción"
        xmlPanel.message = "La lectura verifica la identidad de la canción. No se consultan bases privadas ni se controla Música."
        xmlPanel.allowedContentTypes = [.xml]; xmlPanel.canChooseFiles = true; xmlPanel.canChooseDirectories = false
        guard await response(xmlPanel) == .OK, let xmlURL = xmlPanel.url else { return }
        let folderPanel = NSOpenPanel(); folderPanel.title = "Autorizar lectura de portadas incrustadas"
        folderPanel.message = "Elegí la carpeta que contiene el archivo de audio referenciado por el XML. La autorización se usa sólo para esta lectura."
        folderPanel.canChooseFiles = false; folderPanel.canChooseDirectories = true
        guard await response(folderPanel) == .OK, let folder = folderPanel.url else { return }
        let xmlAccess = xmlURL.startAccessingSecurityScopedResource(), folderAccess = folder.startAccessingSecurityScopedResource()
        defer { if xmlAccess { xmlURL.stopAccessingSecurityScopedResource() }; if folderAccess { folder.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: xmlURL)
            let result = await MusicArtworkReader().read(for: track, xmlData: data, consent: .enabled, allowedMediaRoots: [folder])
            message = result.detail
            if let image = result.image { receive(image) }
        } catch { message = "No se pudo leer la portada: \(error.localizedDescription)" }
    }
    @MainActor private func response(_ panel: NSOpenPanel) async -> NSApplication.ModalResponse {
        await withCheckedContinuation { continuation in panel.begin { continuation.resume(returning: $0) } }
    }
}

struct PlaylistArtworkComparisonView: View {
    let appleURL: String?
    let spotifyURL: String?
    let title: String
    @ViewState private var comparison = ArtworkComparison.unavailable("Falta una de las portadas originales.")
    @ViewState private var comparing = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                VStack { ArtworkView(url: appleURL, title: title, service: .appleMusic).frame(width: 66, height: 66); Text("Apple Music").font(.caption) }
                VStack { ArtworkView(url: spotifyURL, title: title, service: .spotify).frame(width: 66, height: 66); Text("Spotify").font(.caption) }
            }
            Label(comparing ? "Comparando portadas…" : comparison.state.label, systemImage: "photo.on.rectangle")
                .font(.caption).foregroundStyle(.secondary).help(comparison.detail)
            if appleURL == nil { Text("La fuente de Apple Music no aporta una portada original para esta playlist.").font(.caption).foregroundStyle(.secondary) }
        }
        .task(id: (appleURL ?? "") + "|" + (spotifyURL ?? "")) {
            guard appleURL != nil, spotifyURL != nil else { return }
            comparing = true
            let value = await ArtworkComparison.compare(sourceURL: appleURL, sourceOrigin: .appleMusicLibrary,
                candidateURL: spotifyURL, candidateOrigin: .spotifyCatalog)
            guard !Task.isCancelled else { return }; comparison = value; comparing = false
        }
    }
}
