import Foundation

/// Local, conservative matching. An identifier is evidence, never a unique key
/// across editions. A caller can present review candidates for a manual choice.
public enum CatalogMatcher {
    public static func track(_ source: Track, candidates: [Track], sourceService: MusicService) -> TrackMatch {
        guard source.available, !source.isLocal, !source.playableID.isEmpty else {
            return TrackMatch(sourceService: sourceService, source: source, confidence: .unavailable,
                              reason: "La canción de origen es local o no está disponible en el catálogo.")
        }
        let plausible = ranked(source, candidates: candidates.filter {
            $0.available && !$0.isLocal && !$0.playableID.isEmpty &&
            (sameCode(source.isrc, $0.isrc) ||
             (similar(source.title, $0.title) && similar(source.artist, $0.artist)))
        })
        let exact = plausible.filter { candidate in
            guard sameText(source.title, candidate.title), sameText(source.artist, candidate.artist),
                  durationAgrees(source.durationMS, candidate.durationMS),
                  source.explicit != nil, candidate.explicit != nil, source.explicit == candidate.explicit,
                  sameText(source.albumTitle, candidate.albumTitle),
                  editions(source.title + " " + source.albumTitle) == editions(candidate.title + " " + candidate.albumTitle)
            else { return false }
            // A contradictory identifier or album edition must be reviewed even
            // when title/artist happen to be identical.
            if let left = code(source.isrc), let right = code(candidate.isrc), left != right { return false }
            if !normalized(source.albumTitle).isEmpty, !normalized(candidate.albumTitle).isEmpty,
               !sameText(source.albumTitle, candidate.albumTitle) { return false }
            return sameCode(source.isrc, candidate.isrc) || sameText(source.albumTitle, candidate.albumTitle)
        }
        let selected = exact.count == 1 && unambiguousIdentity(exact[0], in: plausible) ? exact[0] : nil
        return TrackMatch(sourceService: sourceService, source: source, candidates: plausible, selected: selected,
                          confidence: selected != nil ? .exact : (plausible.isEmpty ? .unavailable : .review),
                          reason: selected != nil ? "Identidad, edición, duración y metadatos compatibles; un único candidato."
                              : (plausible.isEmpty ? "No hay candidatos disponibles en el catálogo consultado."
                                 : "Revisá la edición, la duración, el contenido explícito o los candidatos con el mismo ISRC."))
    }

    public static func album(_ source: Album, candidates: [Album], sourceService: MusicService) -> AlbumMatch {
        guard source.available, !source.playableID.isEmpty else {
            return AlbumMatch(sourceService: sourceService, source: source, confidence: .unavailable,
                              reason: "El álbum de origen no está disponible.")
        }
        var seen = Set<Album>()
        let plausible = candidates.filter {
            $0.available && !$0.playableID.isEmpty && seen.insert($0).inserted &&
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
        let selected = exact.count == 1 && plausible.filter({ $0.playableID == exact[0].playableID }).count == 1 ? exact[0] : nil
        return AlbumMatch(sourceService: sourceService, source: source, candidates: plausible, selected: selected,
                          confidence: selected != nil ? .exact : (plausible.isEmpty ? .unavailable : .review),
                          reason: !source.isCompleteAlbum ? "El origen contiene canciones sueltas del álbum; no se debe guardar la edición completa."
                              : (selected != nil ? "Un único álbum completo con edición y contenido compatibles."
                                 : "El título no alcanza para identificar la edición del álbum; hace falta revisar el catálogo."))
    }

    public static func normalized(_ value: String) -> String {
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

    private static func unique(_ candidates: [Track]) -> [Track] {
        var result: [Track] = []
        for candidate in candidates where !result.contains(where: { sameIdentityMetadata($0, candidate) }) { result.append(candidate) }
        return result
    }

    private static func unambiguousIdentity(_ candidate: Track, in candidates: [Track]) -> Bool {
        candidates.filter { $0.playableID == candidate.playableID }.count == 1
    }

    /// Broader discovery is deliberately separate from the exact-match predicate.
    public static func similar(_ left: String, _ right: String) -> Bool {
        let ignored: Set<String> = ["feat", "featuring", "ft", "with"]
        let lhs = Set(normalized(left).split(separator: " ").map(String.init)).subtracting(ignored)
        let rhs = Set(normalized(right).split(separator: " ").map(String.init)).subtracting(ignored)
        guard !lhs.isEmpty, !rhs.isEmpty else { return false }
        return Double(lhs.intersection(rhs).count) / Double(max(lhs.count, rhs.count)) >= 0.6
    }

    public static func ranked(_ source: Track, candidates: [Track]) -> [Track] {
        func score(_ value: Track) -> Int {
            (sameCode(source.isrc, value.isrc) ? 100 : 0) +
            (sameText(source.title, value.title) ? 35 : similar(source.title, value.title) ? 15 : 0) +
            (sameText(source.artist, value.artist) ? 30 : similar(source.artist, value.artist) ? 12 : 0) +
            (sameText(source.albumTitle, value.albumTitle) ? 25 : 0) +
            (durationAgrees(source.durationMS, value.durationMS) ? 10 : 0)
        }
        return unique(candidates).sorted {
            let left = score($0), right = score($1)
            if left != right { return left > right }
            return [$0.artist, $0.albumTitle, $0.title, $0.playableID, $0.id, String($0.durationMS)]
                .lexicographicallyPrecedes([$1.artist, $1.albumTitle, $1.title, $1.playableID, $1.id, String($1.durationMS)])
        }
    }

    public static func comparison(_ source: Track, _ candidate: Track) -> String {
        var details: [String] = []
        if sameCode(source.isrc, candidate.isrc) { details.append("Mismo ISRC") }
        if !sameText(source.albumTitle, candidate.albumTitle) { details.append("Otro álbum o edición: elegí si corresponde") }
        if !sameText(source.artist, candidate.artist) { details.append("Créditos de artista diferentes") }
        if !sameText(source.title, candidate.title) { details.append("Título o versión diferente") }
        if source.explicit == nil || candidate.explicit == nil { details.append("Contenido explícito sin confirmar") }
        else if source.explicit != candidate.explicit { details.append("Contenido explícito diferente") }
        if !durationAgrees(source.durationMS, candidate.durationMS) { details.append("Duración diferente o desconocida") }
        return details.isEmpty ? "Metadatos compatibles" : details.joined(separator: " · ")
    }

    public static func sameIdentityMetadata(_ lhs: Track, _ rhs: Track) -> Bool {
        lhs.playableID == rhs.playableID && lhs.title == rhs.title && lhs.artist == rhs.artist &&
        lhs.albumTitle == rhs.albumTitle && lhs.durationMS == rhs.durationMS && lhs.isrc == rhs.isrc &&
        lhs.explicit == rhs.explicit && lhs.available == rhs.available && lhs.isLocal == rhs.isLocal
    }
}
