import Foundation

/// Local, conservative matching. An identifier is evidence, never a unique key
/// across editions. A caller can present review candidates for a manual choice.
public enum CatalogMatcher {
    public static func track(_ source: Track, candidates: [Track], sourceService: MusicService, coverage: CatalogSearchCoverage? = nil) -> TrackMatch {
        guard source.available, !source.isLocal, !source.playableID.isEmpty else {
            return TrackMatch(sourceService: sourceService, source: source, confidence: .unavailable,
                              reason: "La canción de origen es local o no está disponible en el catálogo.")
        }
        let plausible = unique(candidates.filter {
            $0.available && !$0.isLocal && !$0.playableID.isEmpty &&
            (sameCode(source.isrc, $0.isrc) ||
             (sameText(source.title, $0.title) && sameText(source.artist, $0.artist)))
        })
        let exact = plausible.filter { candidate in
            guard sameText(source.title, candidate.title), sameText(source.artist, candidate.artist),
                  durationAgrees(source.durationMS, candidate.durationMS),
                  source.explicit == candidate.explicit,
                  editions(source.title + " " + source.albumTitle) == editions(candidate.title + " " + candidate.albumTitle)
            else { return false }
            // A contradictory identifier or album edition must be reviewed even
            // when title/artist happen to be identical.
            if let left = code(source.isrc), let right = code(candidate.isrc), left != right { return false }
            if !normalized(source.albumTitle).isEmpty, !normalized(candidate.albumTitle).isEmpty,
               !sameText(source.albumTitle, candidate.albumTitle) { return false }
            return sameCode(source.isrc, candidate.isrc) || sameText(source.albumTitle, candidate.albumTitle)
        }
        let complete = coverage == nil || coverage == .complete
        let selected = complete && exact.count == 1 && unambiguousIdentity(exact[0], in: plausible) ? exact[0] : nil
        var result = TrackMatch(sourceService: sourceService, source: source, candidates: plausible, selected: selected,
                          confidence: selected != nil ? .exact : (plausible.isEmpty ? .unavailable : .review),
                          reason: selected != nil ? "Identidad, edición, duración y metadatos compatibles; un único candidato."
                              : (plausible.isEmpty ? "No hay candidatos disponibles en el catálogo consultado."
                                 : "Revisá la edición, la duración, el contenido explícito o los candidatos con el mismo ISRC."))
        result.searchCoverage = coverage
        if !complete { result.confidence = .review; result.reason = "La búsqueda no terminó; no se puede confirmar ausencia ni una coincidencia única." }
        return result
    }

    public static func album(_ source: Album, candidates: [Album], sourceService: MusicService, coverage: CatalogSearchCoverage? = nil) -> AlbumMatch {
        guard source.available, !source.playableID.isEmpty else {
            return AlbumMatch(sourceService: sourceService, source: source, confidence: .unavailable,
                              reason: "El álbum de origen no está disponible.")
        }
        let plausible = uniqueAlbums(candidates).filter {
            $0.available && !$0.playableID.isEmpty &&
            (sameCode(source.upc, $0.upc) || (sameText(source.title, $0.title) && sameText(source.artist, $0.artist)))
        }
        let exact = plausible.filter { candidate in
            guard source.isCompleteAlbum, candidate.isCompleteAlbum,
                  sameText(source.title, candidate.title), sameText(source.artist, candidate.artist) else { return false }
            if let left = code(source.upc), let right = code(candidate.upc), left != right { return false }
            if !source.tracks.isEmpty, !candidate.tracks.isEmpty {
                guard source.tracks.count == candidate.tracks.count else { return false }
                return zip(source.tracks, candidate.tracks).allSatisfy { left, right in
                    track(left, candidates: [right], sourceService: sourceService).selected != nil
                }
            }
            // A title alone is never sufficient to identify an album.
            return sameCode(source.upc, candidate.upc) && source.tracks.isEmpty && candidate.tracks.isEmpty
        }
        let complete = coverage == nil || coverage == .complete
        let selected = complete && exact.count == 1 && plausible.filter({ $0.playableID == exact[0].playableID }).count == 1 ? exact[0] : nil
        var result = AlbumMatch(sourceService: sourceService, source: source, candidates: plausible, selected: selected,
                          confidence: selected != nil ? .exact : (plausible.isEmpty ? .unavailable : .review),
                          reason: !source.isCompleteAlbum ? "El origen contiene canciones sueltas del álbum; no se debe guardar la edición completa."
                              : (selected != nil ? "Un único álbum completo con edición y contenido compatibles."
                                 : "El título no alcanza para identificar la edición del álbum; hace falta revisar el catálogo."))
        result.searchCoverage = coverage
        if !complete { result.confidence = .review; result.reason = "La búsqueda de álbumes no terminó; las ediciones pendientes requieren revisión." }
        return result
    }

    static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func sameText(_ left: String, _ right: String) -> Bool {
        let value = normalized(left)
        return !value.isEmpty && value == normalized(right)
    }

    private static func code(_ value: String?) -> String? {
        guard let value else { return nil }
        let result = normalized(value).replacingOccurrences(of: " ", with: "")
        return result.isEmpty ? nil : result
    }

    private static func sameCode(_ left: String?, _ right: String?) -> Bool {
        guard let left = code(left), let right = code(right) else { return false }
        return left == right
    }

    private static func durationAgrees(_ left: Int, _ right: Int) -> Bool {
        guard left > 0, right > 0 else { return false }
        return abs(Double(left) - Double(right)) <= min(3_000, max(1_000, Double(min(left, right)) * 0.01))
    }

    private static func editions(_ value: String) -> Set<String> {
        let markers: Set<String> = ["live", "vivo", "directo", "remaster", "remastered", "remasterizado", "deluxe",
                                    "expanded", "anniversary", "acoustic", "acustico", "remix", "radio", "edit", "mono", "stereo",
                                    "explicit", "clean", "instrumental", "karaoke", "demo", "version"]
        return Set(normalized(value).split(separator: " ").map(String.init)).intersection(markers)
    }

    public static func unique(_ candidates: [Track]) -> [Track] {
        var seen = Set<Track>()
        return candidates.filter { seen.insert(canonical($0)).inserted }
    }

    private static func canonical(_ track: Track) -> Track {
        var value = track; value.id = track.playableID; value.catalogID = track.playableID; return value
    }

    public static func uniqueAlbums(_ candidates: [Album]) -> [Album] {
        var seen = Set<Album>()
        return candidates.filter { album in
            var value = album; value.id = album.playableID; value.catalogID = album.playableID
            value.tracks = album.tracks.map(canonical)
            return seen.insert(value).inserted
        }
    }

    private static func unambiguousIdentity(_ candidate: Track, in candidates: [Track]) -> Bool {
        candidates.filter { $0.playableID == candidate.playableID }.count == 1
    }
}
