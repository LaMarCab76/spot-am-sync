import Foundation
import AVFoundation
import SyncCore

public enum LocalMusicArtworkConsent: Sendable { case disabled, enabled }
public enum LocalMusicArtworkState: String, Sendable { case disabled, unavailable, available }

public struct LocalMusicArtworkResult: Sendable {
    public let state: LocalMusicArtworkState
    public let image: ArtworkImage?
    public let detail: String
    public let trackPersistentID: String?
}

/// Reads embedded artwork only from an explicitly allowed local media folder.
/// No Music.app launch, Apple Events, MusicKit, ITLibrary initialization, TCC
/// request, library discovery, private cache/database access or file writes.
///
/// ITLibrary itself requires Music permission. Instead, the original, validated
/// XML binds Library Persistent ID + a unique Track Persistent ID to Location;
/// AVFoundation reads that file. XML import alone is NOT consent to read media.
/// The caller must obtain a separate opt-in and user-selected media roots, and
/// keep any security-scoped folder access open for the duration of `read`.
///
/// Limit: streaming songs, missing/duplicate PIDs, moved files, and custom covers
/// stored only in Music's database/cache are unavailable. A file's embedded
/// picture is evidence from that file, not a claim about the current cloud or
/// the cover currently displayed by Music. Spotify fallback stays a reference.
/// SDK contracts:
/// https://developer.apple.com/documentation/avfoundation/retrieving-media-metadata
/// https://developer.apple.com/documentation/ituneslibrary/itlibrary
public struct MusicArtworkReader: Sendable {
    public typealias EmbeddedArtworkLoader = @Sendable (URL) async throws -> Data?
    private let embeddedArtwork: EmbeddedArtworkLoader

    public init(embeddedArtwork: EmbeddedArtworkLoader? = nil) {
        self.embeddedArtwork = embeddedArtwork ?? { url in try await Self.readEmbeddedArtwork(url) }
    }

    public func read(for track: Track, xmlData: Data,
                     consent: LocalMusicArtworkConsent = .disabled,
                     allowedMediaRoots: [URL] = []) async -> LocalMusicArtworkResult {
        guard consent == .enabled else {
            return .init(state: .disabled, image: nil, detail: "La lectura local de portadas requiere que la actives expresamente.", trackPersistentID: nil)
        }
        func unavailable(_ detail: String, pid: String? = nil) -> LocalMusicArtworkResult {
            .init(state: .unavailable, image: nil, detail: detail, trackPersistentID: pid)
        }
        guard !Task.isCancelled else { return unavailable("Lectura cancelada.") }
        // parse rejects duplicate dictionary keys before any file is considered.
        guard let library = try? MusicXMLImporter.parse(xmlData, fileName: "Artwork.xml"),
              let imported = library.tracks.first(where: { $0.id == track.id }),
              CatalogMatcher.sameIdentityMetadata(imported, track),
              let root = (try? PropertyListSerialization.propertyList(from: xmlData, options: [], format: nil)) as? [String: Any],
              let entries = root["Tracks"] as? [String: Any] else {
            return unavailable("La canción no está vinculada inequívocamente a este XML.")
        }
        let prefix = library.id + ":track:persistent:"
        guard track.id.hasPrefix(prefix) else { return unavailable("El XML no aporta un PID de canción único y estable.") }
        let suffix = String(track.id.dropFirst(prefix.count))
        let pid = String(suffix.prefix(16))
        guard pid.count == 16, pid.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) }),
              suffix.count == 16 || suffix.dropFirst(16).hasPrefix(":entry:") else {
            return unavailable("La identidad persistente de la canción es inválida.")
        }
        let matching = entries.values.compactMap { $0 as? [String: Any] }.filter {
            ($0["Persistent ID"] as? String)?.uppercased() == pid
        }
        guard matching.count == 1, let location = matching[0]["Location"] as? String,
              let url = URL(string: location), url.isFileURL, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, [nil, "", "localhost"].contains(url.host) else {
            return unavailable("El PID está ausente, duplicado o no tiene un archivo local asociado.", pid: pid)
        }
        let file = url.standardizedFileURL.resolvingSymlinksInPath()
        let allowed = allowedMediaRoots.contains { root in
            guard root.isFileURL, [nil, "", "localhost"].contains(root.host) else { return false }
            let folder = root.standardizedFileURL.resolvingSymlinksInPath().path
            // Never interpret an accidental filesystem root as blanket access.
            return folder != "/" && file.path.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
        }
        guard allowed else { return unavailable("El archivo queda fuera de las carpetas que elegiste para leer portadas.", pid: pid) }
        guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey]), values.isRegularFile == true else {
            return unavailable("El archivo local ya no está disponible.", pid: pid)
        }
        do {
            guard let data = try await embeddedArtwork(file), !Task.isCancelled else {
                return unavailable("El archivo no ofrece una portada incrustada legible.", pid: pid)
            }
            let image = ArtworkImage(data: data, origin: .localMusicFile)
            guard ArtworkComparison.compare(image, image).state == .equal else {
                return unavailable("La portada incrustada no es una imagen válida o excede el límite.", pid: pid)
            }
            return .init(state: .available, image: image,
                         detail: "Portada incrustada del archivo local vinculado al PID del XML; no confirma la portada de la nube ni la caché de Música.",
                         trackPersistentID: pid)
        } catch { return unavailable("No se pudo leer la portada incrustada del archivo local.", pid: pid) }
    }

    private static func readEmbeddedArtwork(_ url: URL) async throws -> Data? {
        guard url.isFileURL, [nil, "", "localhost"].contains(url.host) else { return nil }
        try Task.checkCancellation()
        let asset = AVURLAsset(url: url)
        let metadata = try await asset.load(.commonMetadata)
        let pictures = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierArtwork)
        // Multiple embedded images have no unambiguous front-cover selection.
        guard pictures.count == 1 else { return nil }
        return try await pictures[0].load(.dataValue)
    }
}
