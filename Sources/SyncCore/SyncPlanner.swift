import Foundation
import CryptoKit

public enum SyncPlanner {
    /// Plans exclusively from the supplied snapshots and decisions; no provider
    /// calls, clock reads, account changes, or mutation of the base library.
    public static func makePlan(snapshots: [LibrarySnapshot], mode: SyncMode, decisions: MatchDecisions,
                                capabilities: [MusicService: ProviderCapabilities]) -> SyncPlan {
        var builder = PlanBuilder(snapshots: snapshots, mode: mode, decisions: decisions, capabilities: capabilities)
        return builder.build()
    }
}

private struct PlaylistPairs {
    var spotifyToApple: [String: String] = [:]
    var reserved: [MusicService: Set<String>] = [.spotify: [], .appleMusic: []]
    var unambiguous = true

    func target(for id: String, from service: MusicService) -> String? {
        service == .spotify ? spotifyToApple[id] : spotifyToApple.first { $0.value == id }?.key
    }

    mutating func reserve(_ id: String, service: MusicService) { reserved[service, default: []].insert(id) }
    mutating func link(_ spotifyID: String, _ appleID: String) {
        spotifyToApple[spotifyID] = appleID
        reserve(spotifyID, service: .spotify); reserve(appleID, service: .appleMusic)
    }
}

private struct PlanBuilder {
    let snapshots: [LibrarySnapshot]
    let mode: SyncMode
    let decisions: MatchDecisions
    let capabilities: [MusicService: ProviderCapabilities]
    var libraries: [MusicService: LibrarySnapshot] = [:]
    var operations: [SyncOperation] = []
    var issues: [PlanIssue] = []
    var issueKeys = Set<String>()
    var trackCache: [String: TrackMatch] = [:]
    var albumCache: [String: AlbumMatch] = [:]
    var trackConflicts: [MusicService: Set<String>] = [:]
    var albumConflicts: [MusicService: Set<String>] = [:]

    mutating func build() -> SyncPlan {
        for service in MusicService.allCases {
            let found = snapshots.filter { $0.account.service == service }
            guard found.count == 1 else {
                issue("snapshot:\(service.rawValue)", "Biblioteca pendiente",
                      found.isEmpty ? "Falta la biblioteca de \(service.name)." : "Hay varias bibliotecas de \(service.name); no se puede elegir una cuenta implícitamente.", service)
                continue
            }
            let library = found[0]
            libraries[service] = library
            let rawTracks = library.savedTracks + library.playlists.flatMap(\.tracks) + library.savedAlbums.flatMap(\.tracks)
            trackConflicts[service] = conflictingTracks(rawTracks)
            albumConflicts[service] = conflictingAlbums(library.savedAlbums)
            if !library.coverage.complete {
                issue("coverage:\(service.rawValue)", "Inventario incompleto",
                      "Las colecciones incompletas no permiten bajas ni reemplazos dependientes. " + library.coverage.notes.joined(separator: " "), service)
            }
            for playlist in library.playlists where !playlist.contentsComplete {
                issue("contents:\(service.rawValue):\(playlist.id)", "Contenido de playlist pendiente",
                      "No se pudo leer todo el contenido de «\(playlist.name)». Se preserva el destino hasta completar la lectura.", service)
            }
        }
        guard libraries.count == MusicService.allCases.count else { return finish() }
        let pairs = playlistPairs()
        let directions: [MusicService] = mode.base.map { [$0] } ?? MusicService.allCases
        for service in directions {
            planLibrary(from: service)
            planPlaylists(from: service, pairs: pairs)
        }
        return finish()
    }

    mutating func issue(_ key: String, _ title: String, _ detail: String, _ service: MusicService? = nil) {
        guard issueKeys.insert(key).inserted else { return }
        issues.append(PlanIssue(id: stableID(key + title + detail), title: title, detail: detail, service: service))
    }

    func finish() -> SyncPlan {
        let date = snapshots.map(\.fetchedAt).max() ?? Date(timeIntervalSince1970: 0)
        var plan = SyncPlan(id: zeroID, createdAt: date, mode: mode, snapshots: snapshots, operations: operations, issues: issues)
        plan.id = stableID(encoded(plan))
        return plan
    }

    mutating func append(_ proposed: SyncOperation, playlist: Playlist? = nil) {
        var operation = proposed
        var reasons = operation.blockedReason.map { [$0] } ?? []
        if let capability = capabilities[operation.service] {
            if !capability.supported.contains(operation.kind) {
                reasons.append("\(operation.service.name) no admite esta operación con la API disponible.")
            }
        } else {
            reasons.append("Falta verificar las capacidades de \(operation.service.name).")
        }
        if let playlist {
            if decisions.protectedPlaylistIDs[operation.service, default: []].contains(playlist.id) {
                reasons.append("La playlist está protegida por una decisión explícita.")
            }
            // Apple's canEdit is an explicit editing capability, but not proof of ownership.
            // It permits the documented append operation only; never infer deletion rights.
            let appleAppend = operation.service == .appleMusic && operation.kind == .addPlaylistTracks && playlist.ownership == .unknown && playlist.contentsComplete
            if !playlist.editable || (![PlaylistOwnership.owned, .collaborative].contains(playlist.ownership) && !appleAppend) {
                reasons.append("La playlist no es editable o es seguida, del sistema o de propiedad desconocida.")
            }
            if operation.kind == .removePlaylist && playlist.ownership != .owned {
                reasons.append("Sólo se pueden quitar playlists de propiedad exclusiva.")
            }
        }
        operation.blockedReason = reasons.isEmpty ? nil : reasons.joined(separator: " ")
        operation.id = zeroID
        operation.id = stableID(encoded(operation))
        operations.append(operation)
    }

    mutating func track(_ source: Track, from service: MusicService) -> Track? {
        let key = "\(service.rawValue):\(source.id)"
        if let cached = trackCache[key] { return cached.selected }
        let destination = libraries[service.other]!
        let supplied = decisions.tracks.filter { $0.sourceService == service && $0.source.id == source.id }
        var result: TrackMatch
        if trackConflicts[service, default: []].contains(source.id) || trackConflicts[service, default: []].contains(source.playableID) {
            result = TrackMatch(sourceService: service, source: source, reason: "El inventario contiene metadatos contradictorios para la misma canción.")
        } else if let first = supplied.first {
            if supplied.allSatisfy({ $0 == first }), first.source == source {
                result = first
            } else {
                result = TrackMatch(sourceService: service, source: source, reason: "Las decisiones están en conflicto o corresponden a otros metadatos de origen.")
            }
        } else {
            let reverse = decisions.tracks.filter {
                $0.sourceService == service.other && $0.selected?.playableID == source.playableID && $0.confidence != .unavailable
            }
            if !reverse.isEmpty {
                let targets = Set(reverse.map { $0.source.playableID })
                let compatible = reverse.allSatisfy {
                    sameTrackMetadata($0.selected!, source) && sameTrackMetadata($0.source, reverse[0].source)
                }
                result = TrackMatch(sourceService: service, source: source, selected: targets.count == 1 && compatible ? reverse[0].source : nil,
                                    reason: "Vínculo inverso de una decisión explícita; los vínculos múltiples requieren revisión.")
            } else {
                result = CatalogMatcher.track(source, candidates: destination.allTracks, sourceService: service)
            }
        }
        if let selected = result.selected {
            if !selected.available || selected.isLocal || selected.playableID.isEmpty || result.confidence == .unavailable ||
                trackConflicts[service.other, default: []].contains(selected.id) || trackConflicts[service.other, default: []].contains(selected.playableID) {
                result.selected = nil
                result.reason = "La selección de destino no está disponible o su identidad es ambigua."
            }
        }
        trackCache[key] = result
        if result.selected == nil {
            issue("track:\(key)", "Canción sin coincidencia confirmada", "«\(source.title)» — \(source.artist). \(result.reason)", service)
        }
        return result.selected
    }

    mutating func album(_ source: Album, from service: MusicService) -> Album? {
        let key = "\(service.rawValue):\(source.id)"
        if let cached = albumCache[key] { return cached.selected }
        let supplied = decisions.albums.filter { $0.sourceService == service && $0.source.id == source.id }
        var result: AlbumMatch
        if albumConflicts[service, default: []].contains(source.id) || albumConflicts[service, default: []].contains(source.playableID) {
            result = AlbumMatch(sourceService: service, source: source, reason: "El inventario contiene álbumes contradictorios con la misma identidad.")
        } else if let first = supplied.first {
            result = supplied.allSatisfy({ $0 == first }) && first.source == source ? first
                : AlbumMatch(sourceService: service, source: source, reason: "Las decisiones de álbum están en conflicto o desactualizadas.")
        } else {
            let reverse = decisions.albums.filter {
                $0.sourceService == service.other && $0.selected?.playableID == source.playableID && $0.confidence != .unavailable
            }
            if !reverse.isEmpty {
                let compatible = reverse.allSatisfy {
                    sameAlbumMetadata($0.selected!, source) && sameAlbumMetadata($0.source, reverse[0].source)
                }
                result = AlbumMatch(sourceService: service, source: source,
                                    selected: Set(reverse.map { $0.source.playableID }).count == 1 && compatible ? reverse[0].source : nil,
                                    reason: "Vínculo inverso de una decisión de álbum; requiere una identidad única.")
            } else {
                result = CatalogMatcher.album(source, candidates: libraries[service.other]!.savedAlbums, sourceService: service)
            }
        }
        if let selected = result.selected {
            if !source.isCompleteAlbum || !selected.isCompleteAlbum || !selected.available || selected.playableID.isEmpty ||
                result.confidence == .unavailable || albumConflicts[service.other, default: []].contains(selected.id) ||
                albumConflicts[service.other, default: []].contains(selected.playableID) {
                result.selected = nil
                result.reason = "La selección no representa un álbum completo disponible y de identidad única."
            }
        }
        albumCache[key] = result
        if result.selected == nil {
            issue("album:\(key)", "Álbum sin coincidencia confirmada", "«\(source.title)». \(result.reason)", service)
        }
        return result.selected
    }

    mutating func mapped(_ playlist: Playlist, from service: MusicService) -> [Track] {
        playlist.tracks.compactMap { track($0, from: service) }
    }

    mutating func planLibrary(from service: MusicService) {
        let source = libraries[service]!, destination = libraries[service.other]!
        let partialAlbums = source.savedAlbums.filter { !$0.isCompleteAlbum }
        for partial in partialAlbums {
            issue("partial:\(service.rawValue):\(partial.id)", "Álbum guardado parcialmente",
                  "«\(partial.title)»: sólo se trasladan las canciones presentes; nunca se guarda el álbum completo.", service)
        }
        let sourceTracks = source.savedTracks + partialAlbums.flatMap(\.tracks)
        let desiredTracks = uniqueTracks(sourceTracks.compactMap { track($0, from: service) })
        let desiredTrackIDs = Set(desiredTracks.map(\.playableID))
        let existingTrackIDs = Set(destination.savedTracks.map(\.playableID))
        let additions = desiredTracks.filter { !existingTrackIDs.contains($0.playableID) }
        if !additions.isEmpty {
            append(SyncOperation(service: service.other, kind: .saveTracks, title: "Guardar \(additions.count) canciones", tracks: additions))
        }
        let fullAlbums = source.savedAlbums.filter(\.isCompleteAlbum)
        let desiredAlbums = uniqueAlbums(fullAlbums.compactMap { album($0, from: service) })
        let desiredAlbumIDs = Set(desiredAlbums.map(\.playableID))
        let existingAlbumIDs = Set(destination.savedAlbums.filter(\.isCompleteAlbum).map(\.playableID))
        let albumAdditions = desiredAlbums.filter { !existingAlbumIDs.contains($0.playableID) }
        if !albumAdditions.isEmpty {
            append(SyncOperation(service: service.other, kind: .saveAlbums, title: "Guardar \(albumAdditions.count) álbumes", albums: albumAdditions))
        }
        guard mode != .merge else { return }
        let removals = uniqueTracks(destination.savedTracks.filter { !desiredTrackIDs.contains($0.playableID) })
        if !removals.isEmpty {
            var reasons: [String] = []
            if !source.coverage.tracks || !destination.coverage.tracks || !source.coverage.albums {
                reasons.append("El inventario de canciones o de álbumes de origen está incompleto.")
            }
            if sourceTracks.contains(where: { trackCache["\(service.rawValue):\($0.id)"]?.selected == nil }) ||
                !trackConflicts[service.other, default: []].isEmpty || partialAlbums.contains(where: { $0.tracks.isEmpty }) {
                reasons.append("Hay identidades de canciones sin resolver; podrían corresponder a canciones del destino.")
            }
            append(SyncOperation(service: service.other, kind: .removeTracks, title: "Quitar \(removals.count) canciones", tracks: removals,
                                 blockedReason: reasons.isEmpty ? nil : reasons.joined(separator: " ")))
        }
        let albumRemovals = uniqueAlbums(destination.savedAlbums.filter { !desiredAlbumIDs.contains($0.playableID) })
        if !albumRemovals.isEmpty {
            var reasons: [String] = []
            if !source.coverage.albums || !destination.coverage.albums { reasons.append("El inventario de álbumes está incompleto.") }
            if !partialAlbums.isEmpty || fullAlbums.contains(where: { albumCache["\(service.rawValue):\($0.id)"]?.selected == nil }) ||
                albumRemovals.contains(where: { !$0.isCompleteAlbum }) || !albumConflicts[service.other, default: []].isEmpty {
                reasons.append("Hay álbumes parciales o identidades sin resolver; se preservan los álbumes de destino.")
            }
            append(SyncOperation(service: service.other, kind: .removeAlbums, title: "Quitar \(albumRemovals.count) álbumes", albums: albumRemovals,
                                 blockedReason: reasons.isEmpty ? nil : reasons.joined(separator: " ")))
        }
    }

    mutating func playlistPairs() -> PlaylistPairs {
        let spotify = libraries[.spotify]!, apple = libraries[.appleMusic]!
        let spIDs = Dictionary(grouping: spotify.playlists, by: \.id), amIDs = Dictionary(grouping: apple.playlists, by: \.id)
        var pairs = PlaylistPairs()
        for service in MusicService.allCases {
            let lists = libraries[service]!.playlists
            let groups = Dictionary(grouping: lists, by: \.id)
            for id in groups.keys.sorted() where id.isEmpty || groups[id]!.count != 1 {
                pairs.reserve(id, service: service); pairs.unambiguous = false
                issue("playlist-id:\(service.rawValue):\(id)", "Identidad de playlist ambigua", "Hay playlists sin ID o con el mismo ID en el inventario.", service)
            }
        }
        // Reserve even broken or stale links so neither endpoint can be treated
        // as absent and accidentally created or removed.
        for link in decisions.playlists {
            pairs.reserve(link.spotifyID, service: .spotify); pairs.reserve(link.appleMusicID, service: .appleMusic)
            let spTargets = Set(decisions.playlists.filter { $0.spotifyID == link.spotifyID }.map(\.appleMusicID))
            let amTargets = Set(decisions.playlists.filter { $0.appleMusicID == link.appleMusicID }.map(\.spotifyID))
            if spTargets.count == 1, amTargets.count == 1, !link.spotifyID.isEmpty, !link.appleMusicID.isEmpty,
               spIDs[link.spotifyID]?.count == 1, amIDs[link.appleMusicID]?.count == 1 {
                pairs.link(link.spotifyID, link.appleMusicID)
            } else {
                pairs.unambiguous = false
                issue("link:\(link.spotifyID):\(link.appleMusicID)", "Vínculo manual pendiente",
                      "El vínculo de playlists no es uno a uno o falta uno de sus extremos. Se preservan ambos IDs.")
            }
        }
        let spNames = Dictionary(grouping: spotify.playlists, by: { CatalogMatcher.normalized($0.name) })
        let amNames = Dictionary(grouping: apple.playlists, by: { CatalogMatcher.normalized($0.name) })
        for service in MusicService.allCases {
            let names = service == .spotify ? spNames : amNames
            for name in names.keys.sorted() where name.isEmpty || names[name]!.count > 1 {
                let unlinked = names[name]!.filter { pairs.target(for: $0.id, from: service) == nil }
                if !unlinked.isEmpty {
                    pairs.unambiguous = false
                    for list in unlinked { pairs.reserve(list.id, service: service) }
                    issue("duplicate-name:\(service.rawValue):\(name)", "Playlists que necesitan un vínculo manual",
                          "El nombre «\(names[name]![0].name)» está vacío o se repite; no identifica una playlist única.", service)
                }
            }
        }
        for list in spotify.playlists where !pairs.reserved[.spotify, default: []].contains(list.id) {
            let name = CatalogMatcher.normalized(list.name)
            guard let possible = amNames[name], !possible.isEmpty else { continue }
            let targets = possible.filter { !pairs.reserved[.appleMusic, default: []].contains($0.id) }
            let translated = mapped(list, from: .spotify)
            if spNames[name]?.count == 1, possible.count == 1, targets.count == 1,
               spotify.coverage.playlists, apple.coverage.playlists,
               list.contentsComplete, targets[0].contentsComplete, !list.tracks.isEmpty,
               translated.count == list.tracks.count, translated.map(\.playableID) == targets[0].tracks.map(\.playableID) {
                pairs.link(list.id, targets[0].id)
            } else {
                pairs.reserve(list.id, service: .spotify)
                for target in targets { pairs.reserve(target.id, service: .appleMusic) }
                pairs.unambiguous = false
                issue("same-name:\(list.id)", "Confirmá el vínculo entre playlists",
                      "«\(list.name)» existe en ambos servicios, pero el nombre no prueba identidad: el contenido difiere o está incompleto. No se duplica ni se elimina ninguna posible pareja.")
            }
        }
        // A duplicate name or a broken explicit link may have reserved only one
        // side above. Protect every remaining same-name counterpart in either
        // direction, including when Apple Music is the base.
        for name in Set(spNames.keys).intersection(amNames.keys).sorted() {
            let unlinkedSpotify = spNames[name]!.filter { pairs.target(for: $0.id, from: .spotify) == nil }
            let unlinkedApple = amNames[name]!.filter { pairs.target(for: $0.id, from: .appleMusic) == nil }
            if !unlinkedSpotify.isEmpty || !unlinkedApple.isEmpty {
                for list in unlinkedSpotify { pairs.reserve(list.id, service: .spotify) }
                for list in unlinkedApple { pairs.reserve(list.id, service: .appleMusic) }
                pairs.unambiguous = false
                issue("unlinked-name:\(name)", "Nombre de playlist sin identidad confirmada",
                      "Las playlists llamadas «\((spNames[name] ?? amNames[name])![0].name)» necesitan vínculos manuales para evitar duplicados.")
            }
        }
        // The same occurrences with a different name or order are a potential
        // renamed pair, not proof that either playlist is an extra to delete.
        let unmatchedSpotify = spotify.playlists.filter { !pairs.reserved[.spotify, default: []].contains($0.id) && !$0.tracks.isEmpty }
        let unmatchedApple = apple.playlists.filter { !pairs.reserved[.appleMusic, default: []].contains($0.id) }
        for list in unmatchedSpotify {
            let translated = mapped(list, from: .spotify)
            guard translated.count == list.tracks.count else { continue }
            let counts = occurrenceCounts(translated)
            let possible = unmatchedApple.filter { occurrenceCounts($0.tracks) == counts }
            if !possible.isEmpty {
                pairs.reserve(list.id, service: .spotify)
                for target in possible { pairs.reserve(target.id, service: .appleMusic) }
                pairs.unambiguous = false
                issue("renamed-pair:\(list.id)", "Posible playlist renombrada",
                      "«\(list.name)» tiene las mismas canciones y repeticiones que una playlist con otro nombre, posiblemente en otro orden. Elegí un vínculo manual antes de crear o quitar playlists.")
            }
        }
        return pairs
    }

    mutating func planPlaylists(from service: MusicService, pairs: PlaylistPairs) {
        let source = libraries[service]!, destination = libraries[service.other]!
        for list in source.playlists {
            if let targetID = pairs.target(for: list.id, from: service), let target = destination.playlists.first(where: { $0.id == targetID }) {
                planLinked(list, target: target, from: service)
            } else if !pairs.reserved[service, default: []].contains(list.id) {
                let translated = mapped(list, from: service)
                let complete = translated.count == list.tracks.count && list.contentsComplete
                if !complete {
                    issue("partial-create:\(service.rawValue):\(list.id)", "Playlist con canciones pendientes",
                          "«\(list.name)» sólo puede incluir las canciones confirmadas; las demás quedan pendientes.", service.other)
                }
                guard !translated.isEmpty || (list.tracks.isEmpty && list.contentsComplete) else { continue }
                append(SyncOperation(service: service.other, kind: .createPlaylist, title: "Crear «\(list.name)»",
                                     playlistName: list.name, playlistDescription: list.description, tracks: translated,
                                     blockedReason: destination.coverage.playlists ? nil : "No se conoce todo el inventario de destino; la playlist podría existir."))
            }
        }
        guard mode != .merge else { return }
        let sourceMatchesComplete = source.playlists.allSatisfy { list in
            list.contentsComplete && list.tracks.allSatisfy { track($0, from: service) != nil }
        }
        let identityComplete = pairs.unambiguous && source.coverage.playlists && destination.coverage.playlists &&
            sourceMatchesComplete && destination.playlists.allSatisfy(\.contentsComplete)
        for extra in destination.playlists where !pairs.reserved[service.other, default: []].contains(extra.id) {
            // Unsupported or protected extras still prevent a complete mirror. Keep
            // the difference visible; append applies permission and capability blocks.
            append(SyncOperation(service: service.other, kind: .removePlaylist, targetID: extra.id,
                                 title: "Quitar «\(extra.name)»", beforeTrackIDs: extra.tracks.map(\.playableID),
                                 blockedReason: identityComplete ? nil : "La identidad o el inventario de las playlists está incompleto; no se puede probar que esta playlist sobre."), playlist: extra)
        }
    }

    mutating func planLinked(_ source: Playlist, target: Playlist, from service: MusicService) {
        // A deterministic metadata authority prevents two-way merge from swapping
        // conflicting names/descriptions on every run. Track merge remains symmetric.
        if (mode != .merge || service == .spotify), (source.name != target.name || source.description != target.description) {
            append(SyncOperation(service: service.other, kind: .renamePlaylist, targetID: target.id,
                                 title: "Actualizar «\(target.name)»", playlistName: source.name, playlistDescription: source.description), playlist: target)
        }
        let translated = mapped(source, from: service)
        let desiredIDs = translated.map(\.playableID), currentIDs = target.tracks.map(\.playableID)
        let allMapped = translated.count == source.tracks.count
        let additions = missingOccurrences(translated, existing: target.tracks)
        if mode == .merge {
            if !additions.isEmpty {
                append(SyncOperation(service: service.other, kind: .addPlaylistTracks, targetID: target.id,
                                     title: "Agregar \(additions.count) canciones a «\(target.name)»", tracks: additions, beforeTrackIDs: currentIDs,
                                     blockedReason: target.contentsComplete ? nil : "Falta leer el contenido de destino para conservar la multiplicidad."), playlist: target)
            }
            return
        }
        guard !allMapped || desiredIDs != currentIDs else { return }
        var reasons: [String] = []
        if !allMapped { reasons.append("Faltan coincidencias de origen; reemplazar eliminaría contenido potencialmente válido.") }
        if !source.contentsComplete || !target.contentsComplete || !libraries[service]!.coverage.playlists || !libraries[service.other]!.coverage.playlists {
            reasons.append("Falta completar el inventario o el contenido de las playlists.")
        }
        if target.tracks.contains(where: { trackConflicts[service.other, default: []].contains($0.id) || trackConflicts[service.other, default: []].contains($0.playableID) }) {
            reasons.append("Hay identidades contradictorias en el contenido de destino.")
        }
        if reasons.isEmpty, desiredIDs.starts(with: currentIDs) {
            let suffix = Array(translated.dropFirst(currentIDs.count))
            if !suffix.isEmpty {
                append(SyncOperation(service: service.other, kind: .addPlaylistTracks, targetID: target.id,
                                     title: "Completar «\(target.name)»", tracks: suffix, beforeTrackIDs: currentIDs), playlist: target)
            }
            return
        }
        append(SyncOperation(service: service.other, kind: .replacePlaylistTracks, targetID: target.id,
                             title: "Igualar «\(target.name)»", tracks: translated, beforeTrackIDs: currentIDs,
                             blockedReason: reasons.isEmpty ? nil : reasons.joined(separator: " ")), playlist: target)
        if operations.last?.blockedReason != nil, !additions.isEmpty, target.contentsComplete {
            issue("partial-add:\(service.rawValue):\(source.id)", "Reemplazo pendiente",
                  "Se pueden agregar las ocurrencias confirmadas de «\(source.name)», pero el orden y las bajas siguen pendientes.", service.other)
            append(SyncOperation(service: service.other, kind: .addPlaylistTracks, targetID: target.id,
                                 title: "Agregar canciones confirmadas a «\(target.name)»", tracks: additions, beforeTrackIDs: currentIDs), playlist: target)
        }
    }
}

private let zeroID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

private func stableID(_ text: String) -> UUID {
    let bytes = Array(SHA256.hash(data: Data(text.utf8)).prefix(16))
    return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                       bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
}

private func encoded<T: Encodable>(_ value: T) -> String {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    // All model values are JSON encodable. A deterministic fallback also keeps
    // the planner pure if a caller supplies an invalid date.
    return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? String(describing: T.self)
}

private func missingOccurrences(_ desired: [Track], existing: [Track]) -> [Track] {
    var remaining = occurrenceCounts(existing)
    return desired.filter { track in
        if remaining[track.playableID, default: 0] > 0 {
            remaining[track.playableID, default: 0] -= 1
            return false
        }
        return true
    }
}

private func occurrenceCounts(_ tracks: [Track]) -> [String: Int] {
    Dictionary(grouping: tracks, by: \.playableID).mapValues(\.count)
}

private func uniqueTracks(_ tracks: [Track]) -> [Track] {
    var seen = Set<String>()
    return tracks.filter { seen.insert($0.playableID).inserted }
}

private func uniqueAlbums(_ albums: [Album]) -> [Album] {
    var seen = Set<String>()
    return albums.filter { seen.insert($0.playableID).inserted }
}

private func sameTrackMetadata(_ left: Track, _ right: Track) -> Bool {
    var left = left, right = right
    left.id = ""; right.id = ""; left.catalogID = nil; right.catalogID = nil
    return left == right
}

private func sameAlbumMetadata(_ left: Album, _ right: Album) -> Bool {
    var left = left, right = right
    left.id = ""; right.id = ""; left.catalogID = nil; right.catalogID = nil
    return left.title == right.title && left.artist == right.artist && left.upc == right.upc &&
        left.isCompleteAlbum == right.isCompleteAlbum && left.available == right.available &&
        left.tracks.count == right.tracks.count && zip(left.tracks, right.tracks).allSatisfy { sameTrackMetadata($0, $1) }
}

private func conflictingTracks(_ tracks: [Track]) -> Set<String> {
    var result = Set<String>()
    for key in [\Track.id, \Track.playableID] {
        for (id, group) in Dictionary(grouping: tracks, by: { $0[keyPath: key] }) {
            if id.isEmpty || !group.allSatisfy({ sameTrackMetadata(group[0], $0) }) { result.insert(id) }
        }
    }
    return result
}

private func conflictingAlbums(_ albums: [Album]) -> Set<String> {
    var result = Set<String>()
    for key in [\Album.id, \Album.playableID] {
        for (id, group) in Dictionary(grouping: albums, by: { $0[keyPath: key] }) {
            if id.isEmpty || !group.allSatisfy({ sameAlbumMetadata(group[0], $0) }) { result.insert(id) }
        }
    }
    return result
}
