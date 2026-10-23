import Foundation
import CryptoKit

/// Coverage concerns the imported document, never the live Apple Music account.
public struct ManualMusicLibrary: Codable, Sendable {
    public var id: String
    public var fileName: String
    public var importedAt: Date
    public var exportedAt: Date?
    public var tracks: [Track]
    public var warnings: [String]
    public var complete: Bool

    public init(id: String, fileName: String, importedAt: Date = Date(), exportedAt: Date? = nil,
                tracks: [Track], warnings: [String] = [], complete: Bool = true) {
        self.id = id; self.fileName = fileName; self.importedAt = importedAt; self.exportedAt = exportedAt
        self.tracks = tracks; self.warnings = warnings; self.complete = complete
    }
}

public enum ManualTrackEvidence: String, Codable, Sendable { case missing, review, present }

public struct ManualChecklistItem: Codable, Sendable, Identifiable {
    public var id: String
    public var track: Track
    public var evidence: ManualTrackEvidence
    public var candidates: [Track]
    public var reason: String
    public var locations: [String]

    public init(id: String, track: Track, evidence: ManualTrackEvidence, candidates: [Track],
                reason: String, locations: [String]) {
        self.id = id; self.track = track; self.evidence = evidence; self.candidates = candidates
        self.reason = reason; self.locations = locations
    }
}

public struct ManualChecklist: Codable, Sendable {
    public var sourceAccountID: String
    public var sourceAccountName: String
    public var libraryID: String
    public var fileName: String
    public var sourceFetchedAt: Date
    public var importedAt: Date
    public var exportedAt: Date?
    public var generatedAt: Date
    public var items: [ManualChecklistItem]
    public var warnings: [String]
    public var isDemo: Bool

    public init(sourceAccountID: String, sourceAccountName: String, libraryID: String, fileName: String,
                sourceFetchedAt: Date, importedAt: Date, exportedAt: Date?, generatedAt: Date = Date(),
                items: [ManualChecklistItem], warnings: [String], isDemo: Bool = false) {
        self.sourceAccountID = sourceAccountID; self.sourceAccountName = sourceAccountName
        self.libraryID = libraryID; self.fileName = fileName; self.sourceFetchedAt = sourceFetchedAt
        self.importedAt = importedAt; self.exportedAt = exportedAt; self.generatedAt = generatedAt
        self.items = items; self.warnings = warnings; self.isDemo = isDemo
    }

    /// File renames, reconnections and refresh dates do not move manual progress to another scope.
    public var scopeID: String {
        "manual-checklist:v1:" + (isDemo ? "demo:" : "live:") +
            ManualChecklistIdentity.digest(["spotify", sourceAccountID, libraryID])
    }
}

public struct ManualChecklistState: Codable, Sendable {
    public var library: ManualMusicLibrary?
    public var report: ManualChecklist?
    public var markedIDsByScope: [String: Set<String>]

    public init(library: ManualMusicLibrary? = nil, report: ManualChecklist? = nil,
                markedIDsByScope: [String: Set<String>] = [:]) {
        self.library = library; self.report = report; self.markedIDsByScope = markedIDsByScope
    }
}

enum ManualChecklistNotice {
    static let snapshot = "La exportación XML es una instantánea (snapshot), no una consulta de Apple Music en la nube en tiempo real."
    static let coverage = "La cobertura completa describe sólo el XML importado; no garantiza que incluya toda la biblioteca en la nube."
    static let albums = "Los metadatos de álbum de una canción no prueban que el álbum completo esté guardado."
}

public enum ManualChecklistPlanner {
    public static func make(source: LibrarySnapshot, library: ManualMusicLibrary, isDemo: Bool = false) -> ManualChecklist {
        var warnings = library.warnings + [ManualChecklistNotice.snapshot, ManualChecklistNotice.coverage, ManualChecklistNotice.albums]
        var items: [ManualChecklistItem] = []
        if source.account.service != .spotify {
            warnings.append("El checklist manual requiere una biblioteca de origen Spotify; no se comparó este origen.")
        } else {
            if !source.complete {
                warnings.append("La lectura de Spotify es parcial: la lista sólo incluye las canciones recibidas.")
            }
            warnings.append(contentsOf: source.coverage.notes)
            if !library.complete {
                warnings.append("El XML tiene cobertura parcial: las canciones sin coincidencia requieren revisión, no se confirman como faltantes.")
            }
            let index = ManualTrackIndex(library.tracks)
            var occurrences: [String: Set<Track>] = [:]
            var locations: [String: Set<String>] = [:]
            func include(_ track: Track, at location: String) {
                occurrences[track.id, default: []].insert(track)
                locations[track.id, default: []].insert(location)
            }
            for track in source.savedTracks { include(track, at: "Canciones guardadas") }
            for playlist in source.playlists {
                for track in playlist.tracks { include(track, at: "Playlist: \(playlist.name)") }
            }
            for album in source.savedAlbums {
                for track in album.tracks { include(track, at: "Álbum guardado: \(album.title) — \(album.artist)") }
            }
            // The same union as allTracks, while retaining conflicting observations of a Spotify ID.
            for versions in occurrences.values {
                let ordered = versions.sorted { ManualChecklistIdentity.fields($0).lexicographicallyPrecedes(ManualChecklistIdentity.fields($1)) }
                guard let track = ordered.first else { continue }
                let candidates = index.candidates(for: track)
                let evidence: ManualTrackEvidence
                let reason: String
                if ordered.count > 1 {
                    evidence = .review
                    reason = "Spotify informó metadatos distintos para la misma canción; revisá la edición."
                } else if !track.available || track.isLocal || !validSourceID(track.id) {
                    evidence = .review
                    reason = "La canción de Spotify es local, no está disponible o no tiene una identidad verificable."
                } else if !hasRequiredMetadata(track) {
                    evidence = .review
                    reason = "Faltan metadatos de origen, duración o evidencia de contenido explícito para comparar la edición."
                } else if candidates.count > 1 {
                    evidence = .review
                    reason = "Hay varios candidatos en el XML; revisá qué grabación y edición corresponden."
                } else if let candidate = candidates.first {
                    if compatible(track, candidate) {
                        evidence = .present
                        reason = "Un único candidato del XML coincide en título, artista, álbum, duración y contenido explícito."
                    } else {
                        evidence = .review
                        reason = "El candidato del XML tiene metadatos desconocidos o una edición, duración o contenido explícito diferente."
                    }
                } else if !library.complete {
                    evidence = .review
                    reason = "No se encontró un candidato, pero el XML es parcial y no permite confirmar la ausencia."
                } else {
                    evidence = .missing
                    reason = "No se encontró un candidato en esta instantánea XML; verificá Apple Music antes de agregarlo manualmente."
                }
                let rowID = "manual-track:v1:" + ManualChecklistIdentity.digest(
                    ["spotify", source.account.id] + ordered.flatMap(ManualChecklistIdentity.fields))
                items.append(ManualChecklistItem(id: rowID, track: track, evidence: evidence, candidates: candidates,
                                                reason: reason, locations: locations[track.id, default: []].sorted()))
            }
        }
        items.sort { ManualTrackIndex.order($0.track, $1.track) }
        return ManualChecklist(sourceAccountID: source.account.id, sourceAccountName: source.account.displayName,
                               libraryID: library.id, fileName: library.fileName, sourceFetchedAt: source.fetchedAt,
                               importedAt: library.importedAt, exportedAt: library.exportedAt, items: items,
                               warnings: Array(Set(warnings)).sorted(), isDemo: isDemo)
    }

    private static func validSourceID(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !value.hasPrefix("unknown:")
    }

    private static func hasRequiredMetadata(_ track: Track) -> Bool {
        [track.title, track.artist, track.albumTitle].allSatisfy { !CatalogMatcher.normalized($0).isEmpty } &&
            track.durationMS > 0 && track.explicit != nil
    }

    private static func compatible(_ source: Track, _ candidate: Track) -> Bool {
        // A file in the XML is presence evidence too; isLocal describes storage, not membership.
        guard candidate.available, hasRequiredMetadata(candidate), source.explicit == candidate.explicit,
              CatalogMatcher.normalized(source.title) == CatalogMatcher.normalized(candidate.title),
              CatalogMatcher.normalized(source.artist) == CatalogMatcher.normalized(candidate.artist),
              CatalogMatcher.normalized(source.albumTitle) == CatalogMatcher.normalized(candidate.albumTitle)
        else { return false }
        if let left = ManualTrackIndex.code(source.isrc), let right = ManualTrackIndex.code(candidate.isrc), left != right { return false }
        let tolerance = min(3_000.0, max(1_000.0, Double(min(source.durationMS, candidate.durationMS)) * 0.01))
        return abs(Double(source.durationMS) - Double(candidate.durationMS)) <= tolerance
    }
}

private struct ManualTrackIndex {
    private struct MetadataKey: Hashable { var title: String; var artist: String }
    private var byMetadata: [MetadataKey: [Track]] = [:]
    private var byISRC: [String: [Track]] = [:]

    init(_ tracks: [Track]) {
        for track in Set(tracks) {
            if let key = Self.key(track) { byMetadata[key, default: []].append(track) }
            if let isrc = Self.code(track.isrc) { byISRC[isrc, default: []].append(track) }
        }
    }

    func candidates(for track: Track) -> [Track] {
        var result = Set<Track>()
        if let key = Self.key(track) { result.formUnion(byMetadata[key, default: []]) }
        if let isrc = Self.code(track.isrc) { result.formUnion(byISRC[isrc, default: []]) }
        return result.sorted(by: Self.order)
    }

    private static func key(_ track: Track) -> MetadataKey? {
        let title = CatalogMatcher.normalized(track.title), artist = CatalogMatcher.normalized(track.artist)
        guard !title.isEmpty, !artist.isEmpty else { return nil }
        return MetadataKey(title: title, artist: artist)
    }

    static func code(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = CatalogMatcher.normalized(value).replacingOccurrences(of: " ", with: "")
        return normalized.isEmpty ? nil : normalized
    }

    static func order(_ left: Track, _ right: Track) -> Bool {
        let lhs = [left.artist, left.title, left.albumTitle].map(CatalogMatcher.normalized) + ManualChecklistIdentity.fields(left)
        let rhs = [right.artist, right.title, right.albumTitle].map(CatalogMatcher.normalized) + ManualChecklistIdentity.fields(right)
        return lhs.lexicographicallyPrecedes(rhs)
    }
}

private enum ManualChecklistIdentity {
    static func fields(_ track: Track) -> [String] {
        [track.id, optional(track.catalogID), track.title, track.artist, track.albumTitle,
         String(track.durationMS), optional(track.isrc), track.explicit.map { $0 ? "true" : "false" } ?? "unknown",
         track.available ? "available" : "unavailable", track.isLocal ? "local" : "catalog"]
    }

    private static func optional(_ value: String?) -> String { value.map { "value:" + $0 } ?? "nil" }

    static func digest(_ fields: [String]) -> String {
        // Length framing prevents delimiters embedded in account IDs or metadata from colliding.
        let framed = fields.map { "\($0.utf8.count):\($0)" }.joined()
        return SHA256.hash(data: Data(framed.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
