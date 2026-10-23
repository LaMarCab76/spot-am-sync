import Foundation
import CoreFoundation

public enum MusicXMLImportError: Error, LocalizedError, Sendable {
    case invalidXML, duplicateKeys, invalidLibraryIdentity, missingTracks

    public var errorDescription: String? {
        switch self {
        case .invalidXML: return "El archivo no es una exportación XML plist válida de Música. Volvé a exportar la biblioteca."
        case .duplicateKeys: return "El XML contiene claves duplicadas y no se puede interpretar sin perder información."
        case .invalidLibraryIdentity: return "El XML no contiene un Library Persistent ID válido de 16 dígitos hexadecimales."
        case .missingTracks: return "El XML no contiene el diccionario Tracks requerido; no se interpretará como una biblioteca vacía."
        }
    }
}

public enum MusicXMLImporter {
    public static func parse(_ data: Data, fileName: String, importedAt: Date = Date()) throws -> ManualMusicLibrary {
        let object: Any
        var format = PropertyListSerialization.PropertyListFormat.xml
        do { object = try PropertyListSerialization.propertyList(from: data, options: [], format: &format) }
        catch { throw MusicXMLImportError.invalidXML }
        guard format == .xml, let root = object as? [String: Any] else { throw MusicXMLImportError.invalidXML }
        let validator = MusicXMLKeyValidator()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = validator
        guard parser.parse() else { throw MusicXMLImportError.invalidXML }
        guard !validator.hasDuplicateKeys else { throw MusicXMLImportError.duplicateKeys }
        guard let libraryPersistentID = persistentID(root["Library Persistent ID"]) else {
            throw MusicXMLImportError.invalidLibraryIdentity
        }
        guard let entries = root["Tracks"] as? [String: Any] else { throw MusicXMLImportError.missingTracks }
        let libraryID = "apple-music-xml:\(libraryPersistentID)"
        var issues = ImportIssues()
        var tracks: [Track] = []
        var knownTrackIDs = Set<Int>()
        var seenPersistentIDs = Set<String>()

        for key in entries.keys.sorted() {
            guard let number = Int(key), number > 0, String(number) == key,
                  let entry = entries[key] as? [String: Any], integer(entry["Track ID"]) == number else {
                issues.add("Entradas de Tracks con estructura o identidad inválida")
                continue
            }
            // References to known non-music entries remain valid after filtering.
            knownTrackIDs.insert(number)
            for field in ["Podcast", "Movie", "TV Show", "Audiobook", "Playlist Only"] {
                if entry[field] != nil && boolean(entry[field]) == nil {
                    issues.add("Indicadores de tipo de contenido inválidos")
                }
            }
            if isKnownNonMusic(entry) { continue }
            var identity = "entry:\(key)"
            if let rawID = entry["Persistent ID"] {
                if let trackID = persistentID(rawID) {
                    identity = "persistent:\(trackID):entry:\(key)"
                    if !seenPersistentIDs.insert(trackID).inserted {
                        issues.add("Identidades persistentes de canción duplicadas")
                    }
                } else {
                    issues.add("Identidades persistentes de canción inválidas")
                }
            }
            let title = text(entry["Name"]) ?? ""
            let artist = text(entry["Artist"]) ?? ""
            let album = text(entry["Album"]) ?? ""
            if CatalogMatcher.normalized(title).isEmpty || CatalogMatcher.normalized(artist).isEmpty {
                issues.add("Canciones sin título o artista utilizable")
            }
            if entry["Album"] != nil && !(entry["Album"] is String) {
                issues.add("Metadatos de álbum inválidos")
            }
            let duration = integer(entry["Total Time"])
            if entry["Total Time"] != nil && (duration == nil || duration! < 0) {
                issues.add("Duraciones inválidas")
            }
            let explicit = explicitEvidence(entry, issues: &issues)
            let trackType = text(entry["Track Type"])
            if entry["Track Type"] != nil && !["File", "Remote", "URL"].contains(trackType ?? "") {
                issues.add("Tipos de almacenamiento de canción desconocidos")
            }
            // Remote and Playlist Only entries are music observations, not local-file placeholders.
            let local = trackType == "File" || (trackType == nil && text(entry["Location"])?.hasPrefix("file:") == true)
            tracks.append(Track(id: "\(libraryID):track:\(identity)", title: title, artist: artist, albumTitle: album,
                                durationMS: max(0, duration ?? 0), explicit: explicit, isLocal: local))
            // XML row numbers, Persistent IDs, Store IDs and URLs never become catalog IDs or ISRCs.
        }

        if let rawPlaylists = root["Playlists"] {
            if let playlists = rawPlaylists as? [Any] {
                for rawPlaylist in playlists {
                    guard let playlist = rawPlaylist as? [String: Any] else {
                        issues.add("Playlists con estructura inválida"); continue
                    }
                    guard let rawItems = playlist["Playlist Items"] else { continue } // Empty playlists/folders are valid.
                    guard let items = rawItems as? [Any] else {
                        issues.add("Listas de referencias de playlist inválidas"); continue
                    }
                    for rawItem in items {
                        guard let item = rawItem as? [String: Any], let reference = integer(item["Track ID"]),
                              knownTrackIDs.contains(reference) else {
                            issues.add("Referencias de playlist inválidas o ausentes en Tracks"); continue
                        }
                    }
                }
            } else { issues.add("Playlists con estructura inválida") }
        }
        let exportedAt = root["Date"] as? Date
        if root["Date"] != nil && exportedAt == nil { issues.add("Fecha de exportación inválida") }
        let warnings = [ManualChecklistNotice.snapshot, ManualChecklistNotice.coverage, ManualChecklistNotice.albums] +
            issues.counts.keys.sorted().map { "\($0): \(issues.counts[$0]!). La cobertura del XML es parcial." }
        return ManualMusicLibrary(id: libraryID, fileName: fileName, importedAt: importedAt, exportedAt: exportedAt,
                                  tracks: tracks, warnings: warnings, complete: issues.counts.isEmpty)
    }

    private static func persistentID(_ value: Any?) -> String? {
        guard let value = value as? String, value.utf8.count == 16,
              value.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
              value != "0000000000000000" else { return nil }
        return value.uppercased()
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              !["f", "d"].contains(String(cString: value.objCType)) else { return nil }
        return Int(value.stringValue)
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return value.boolValue
    }

    private static func text(_ value: Any?) -> String? {
        (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func explicitEvidence(_ entry: [String: Any], issues: inout ImportIssues) -> Bool? {
        let explicit = boolean(entry["Explicit"]), clean = boolean(entry["Clean"])
        if (entry["Explicit"] != nil && explicit == nil) || (entry["Clean"] != nil && clean == nil) {
            issues.add("Indicadores Explicit o Clean inválidos"); return nil
        }
        if explicit == true && clean == true {
            issues.add("Indicadores Explicit y Clean contradictorios"); return nil
        }
        if clean == true { return false }
        // Clean=false alone does not prove explicit content; no field means unknown.
        return explicit
    }

    private static func isKnownNonMusic(_ entry: [String: Any]) -> Bool {
        if ["Podcast", "Movie", "TV Show", "Audiobook"].contains(where: { boolean(entry[$0]) == true }) { return true }
        let nonMusic: Set<String> = ["podcast", "podcasts", "movie", "movies", "tv show", "tv shows", "audiobook", "audiobooks", "home video"]
        return ["Media Kind", "Video Kind", "Kind"].contains { field in
            guard let value = text(entry[field]) else { return false }
            return nonMusic.contains(value.lowercased())
        }
    }
}

private struct ImportIssues {
    var counts: [String: Int] = [:]
    mutating func add(_ message: String) { counts[message, default: 0] += 1 }
}

/// PropertyListSerialization otherwise silently keeps only the last value for a duplicate key.
private final class MusicXMLKeyValidator: NSObject, XMLParserDelegate {
    var hasDuplicateKeys = false
    private var dictionaries: [Set<String>] = []
    private var currentKey: String?

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        if elementName == "dict" { dictionaries.append([]) }
        if elementName == "key" { currentKey = "" }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if currentKey != nil { currentKey! += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "key", let key = currentKey, !dictionaries.isEmpty {
            if !dictionaries[dictionaries.count - 1].insert(key).inserted { hasDuplicateKeys = true }
            currentKey = nil
        }
        if elementName == "dict", !dictionaries.isEmpty { dictionaries.removeLast() }
    }
}
