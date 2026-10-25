import Foundation
import CryptoKit

public enum LibraryComparisonKind: String, Codable, CaseIterable, Sendable { case songs, albums, playlists }
public enum LibraryDifferenceCategory: String, Codable, CaseIterable, Sendable { case addition, removal, conflict, review }

public struct LibraryComparisonScope: Codable, Equatable, Sendable {
    public var songs: Bool
    public var albums: Bool
    public var playlists: Bool
    /// nil selects all; an empty set selects none. Selection never changes inventory coverage or loose counts.
    public var appleMusicPlaylistIDs: Set<String>?
    public var spotifyPlaylistIDs: Set<String>?
    public init(songs: Bool = true, albums: Bool = true, playlists: Bool = true,
                appleMusicPlaylistIDs: Set<String>? = nil, spotifyPlaylistIDs: Set<String>? = nil) {
        self.songs = songs; self.albums = albums; self.playlists = playlists
        self.appleMusicPlaylistIDs = appleMusicPlaylistIDs; self.spotifyPlaylistIDs = spotifyPlaylistIDs
    }
}

public struct LibraryComparisonConfiguration: Codable, Equatable, Sendable {
    public var mode: SyncMode
    public var scope: LibraryComparisonScope
    /// The only authorization to compare/update an existing playlist pair. Names are suggestions only.
    public var playlistPairings: [PlaylistLink]
    /// Explicitly choose to save XML observations whose individual saved membership is unknown.
    public var includeUncertainXMLSongs: Bool
    public init(mode: SyncMode = .appleMusicBase, scope: LibraryComparisonScope = .init(), playlistPairings: [PlaylistLink] = [],
                includeUncertainXMLSongs: Bool = false) {
        self.mode = mode; self.scope = scope; self.playlistPairings = playlistPairings
        self.includeUncertainXMLSongs = includeUncertainXMLSongs
    }
}

/// Observations, not desired state. Persist only after the coordinator has reconciled any approved writes.
public struct LibraryComparisonBaseline: Codable, Equatable, Sendable {
    public var library: ManualMusicLibrary
    public var spotify: LibrarySnapshot
    public var appleSnapshot: LibrarySnapshot?
    public init(library: ManualMusicLibrary, spotify: LibrarySnapshot, appleSnapshot: LibrarySnapshot? = nil) {
        self.library = library; self.spotify = spotify; self.appleSnapshot = appleSnapshot
    }
}

public struct LibraryManualTask: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var differenceID: String
    public var kind: OperationKind
    public var targetID: String?
    public var title: String
    public var detail: String
    public var tracks: [Track]
    public var albums: [Album]
    /// Available only for an official Apple snapshot and verified Apple catalog IDs.
    public var operation: SyncOperation?
    public init(id: String, differenceID: String, kind: OperationKind, targetID: String? = nil,
                title: String, detail: String = "", tracks: [Track] = [], albums: [Album] = [], operation: SyncOperation? = nil) {
        self.id = id; self.differenceID = differenceID; self.kind = kind; self.targetID = targetID
        self.title = title; self.detail = detail; self.tracks = tracks; self.albums = albums
        self.operation = operation
    }
}

public struct LibraryDifference: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var unitID: String
    public var scope: LibraryComparisonKind
    public var category: LibraryDifferenceCategory
    public var destination: MusicService?
    public var sourceID: String?
    public var destinationID: String?
    public var title: String
    public var detail: String
    public var tracks: [Track]
    public var albums: [Album]
    /// Includes repetitions and order; empty differs from an absent playlist.
    public var appleMusicTrackIDs: [String]?
    public var spotifyTrackIDs: [String]?
    /// Finite, additive proposals associated with this approval item only.
    public var spotifyOperations: [SyncOperation]
    public var appleMusicTasks: [LibraryManualTask]
    public init(id: String, unitID: String, scope: LibraryComparisonKind, category: LibraryDifferenceCategory,
                destination: MusicService? = nil, sourceID: String? = nil, destinationID: String? = nil,
                title: String, detail: String = "", tracks: [Track] = [], albums: [Album] = [],
                appleMusicTrackIDs: [String]? = nil, spotifyTrackIDs: [String]? = nil,
                spotifyOperations: [SyncOperation] = [], appleMusicTasks: [LibraryManualTask] = []) {
        self.id = id; self.unitID = unitID; self.scope = scope; self.category = category
        self.destination = destination; self.sourceID = sourceID; self.destinationID = destinationID
        self.title = title; self.detail = detail; self.tracks = tracks; self.albums = albums
        self.appleMusicTrackIDs = appleMusicTrackIDs; self.spotifyTrackIDs = spotifyTrackIDs
        self.spotifyOperations = spotifyOperations; self.appleMusicTasks = appleMusicTasks
    }
}

public enum LibraryPlaylistPairingStatus: String, Codable, Sendable { case confirmed, suggested, ambiguous }
public struct LibraryPlaylistPairing: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var appleMusicID: String?
    public var spotifyID: String?
    public var status: LibraryPlaylistPairingStatus
    public var reason: String
    public init(id: String, appleMusicID: String? = nil, spotifyID: String? = nil,
                status: LibraryPlaylistPairingStatus, reason: String) {
        self.id = id; self.appleMusicID = appleMusicID; self.spotifyID = spotifyID; self.status = status; self.reason = reason
    }
}

public struct LibraryInventoryMetrics: Codable, Equatable, Sendable {
    public var songIdentities: Int
    public var savedSongMemberships: Int
    public var playlistOccurrences: Int
    public var playlists: Int
    public var completeSavedAlbums: Int
    public var albumGroups: Int
    /// nil means coverage cannot establish which songs are outside all playlists.
    public var looseSongIdentities: Int?
    public var songsComplete: Bool
    public var playlistsComplete: Bool
    public var savedSongsKnown: Bool
    public var uncertainSongMemberships: Int
    public var selectedUncertainSongs: Int
    public init(songIdentities: Int = 0, savedSongMemberships: Int = 0, playlistOccurrences: Int = 0,
                playlists: Int = 0, completeSavedAlbums: Int = 0, albumGroups: Int = 0,
                looseSongIdentities: Int? = nil, songsComplete: Bool = false, playlistsComplete: Bool = false,
                savedSongsKnown: Bool = false, uncertainSongMemberships: Int = 0, selectedUncertainSongs: Int = 0) {
        self.songIdentities = songIdentities; self.savedSongMemberships = savedSongMemberships
        self.playlistOccurrences = playlistOccurrences; self.playlists = playlists; self.completeSavedAlbums = completeSavedAlbums
        self.albumGroups = albumGroups; self.looseSongIdentities = looseSongIdentities
        self.songsComplete = songsComplete; self.playlistsComplete = playlistsComplete
        self.savedSongsKnown = savedSongsKnown; self.uncertainSongMemberships = uncertainSongMemberships
        self.selectedUncertainSongs = selectedUncertainSongs
    }
}

public struct LibraryComparisonMetrics: Codable, Equatable, Sendable {
    public var appleMusic: LibraryInventoryMetrics
    public var spotify: LibraryInventoryMetrics
    public var matchedSongIdentities: Int
    public var unresolvedSongIdentities: Int
    public init(appleMusic: LibraryInventoryMetrics = .init(), spotify: LibraryInventoryMetrics = .init(),
                matchedSongIdentities: Int = 0, unresolvedSongIdentities: Int = 0) {
        self.appleMusic = appleMusic; self.spotify = spotify; self.matchedSongIdentities = matchedSongIdentities
        self.unresolvedSongIdentities = unresolvedSongIdentities
    }
}

public struct LibraryComparisonReport: Codable, Equatable, Sendable {
    public var differences: [LibraryDifference]
    public var matches: [TrackMatch]
    public var playlistPairings: [LibraryPlaylistPairing]
    public var metrics: LibraryComparisonMetrics
    public var warnings: [String]
    public init(differences: [LibraryDifference] = [], matches: [TrackMatch] = [], playlistPairings: [LibraryPlaylistPairing] = [],
                metrics: LibraryComparisonMetrics = .init(), warnings: [String] = []) {
        self.differences = differences; self.matches = matches; self.playlistPairings = playlistPairings
        self.metrics = metrics; self.warnings = warnings
    }
    public var additions: [LibraryDifference] { differences.filter { $0.category == .addition } }
    public var removals: [LibraryDifference] { differences.filter { $0.category == .removal } }
    public var conflicts: [LibraryDifference] { differences.filter { $0.category == .conflict } }
    public var reviews: [LibraryDifference] { differences.filter { $0.category == .review } }
    public var spotifyAdditions: [SyncOperation] { additions.flatMap(\.spotifyOperations) }
    public var appleMusicTasks: [LibraryManualTask] { additions.flatMap(\.appleMusicTasks) }
    public var operationsByDifferenceID: [String: [SyncOperation]] {
        Dictionary(uniqueKeysWithValues: additions.filter { !$0.spotifyOperations.isEmpty }.map { ($0.id, $0.spotifyOperations) })
    }
    public var differencesByUnitID: [String: [LibraryDifference]] { Dictionary(grouping: differences, by: \.unitID) }
}

/// Pure comparison. It performs no provider reads, writes, persistence or implicit future synchronization.
public enum LibraryComparison {
    public static func compare(library: ManualMusicLibrary, spotify: LibrarySnapshot, decisions: MatchDecisions = .init(),
                               configuration: LibraryComparisonConfiguration = .init(), baseline: LibraryComparisonBaseline? = nil,
                               appleSnapshot: LibrarySnapshot? = nil) -> LibraryComparisonReport {
        var engine = ComparisonEngine(library: library, spotify: spotify, decisions: decisions,
                                      configuration: configuration, baseline: baseline, appleSnapshot: appleSnapshot)
        return engine.compare()
    }
}

private struct ComparisonInventory {
    var tracks: [Track]
    var saved: [Track]
    var knownSaved: [Track]
    var uncertainSaved: [Track]
    var albums: [Album]
    var playlists: [XMLMusicPlaylist]
    var trackInfo: [String: XMLTrackInfo]
    var persistentIDCounts: [String: Int]
    var nativeAliases: [String: String]
    var byID: [String: Track]
    var songsComplete: Bool
    var albumsComplete: Bool
    var playlistsComplete: Bool

    init(library: ManualMusicLibrary, official: LibrarySnapshot?, includeUncertain: Bool = false) {
        if let official {
            tracks = official.allTracks
            saved = official.savedTracks + official.savedAlbums.filter { !$0.isCompleteAlbum }.flatMap(\.tracks)
            knownSaved = official.savedTracks + official.savedAlbums.filter { !$0.isCompleteAlbum }.flatMap(\.tracks)
            uncertainSaved = []
            albums = official.savedAlbums.filter(\.isCompleteAlbum)
            playlists = official.playlists.map {
                XMLMusicPlaylist(id: $0.id, name: $0.name, trackIDs: $0.tracks.map(\.id),
                                 kind: $0.ownership == .system ? .system : .regular,
                                 contentsComplete: $0.contentsComplete, artworkURL: $0.artworkURL)
            }
            trackInfo = [:]; songsComplete = official.coverage.tracks && official.coverage.albums
            albumsComplete = official.coverage.albums; playlistsComplete = official.coverage.playlists
        } else {
            let info = library.inventory?.trackInfo ?? [:]
            tracks = library.tracks; trackInfo = info
            knownSaved = library.tracks.filter { info[$0.id]?.playlistOnly == false }
            uncertainSaved = library.tracks.filter { info[$0.id]?.playlistOnly == nil }
            saved = library.tracks.filter { info[$0.id]?.playlistOnly == false || (includeUncertain && info[$0.id]?.playlistOnly == nil) }
            albums = []; playlists = library.inventory?.playlists ?? []
            songsComplete = library.complete && library.tracks.allSatisfy { info[$0.id]?.playlistOnly != nil }; albumsComplete = false
            playlistsComplete = library.inventory?.playlistsComplete == true
        }
        persistentIDCounts = trackInfo.values.reduce(into: [:]) { counts, info in
            if let persistent = info.persistentID { counts[persistent, default: 0] += 1 }
        }
        byID = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        nativeAliases = official.map { snapshot in
            ComparisonIdentity.aliases(snapshot.savedTracks + snapshot.playlists.flatMap(\.tracks) + snapshot.savedAlbums.flatMap(\.tracks))
        } ?? [:]
    }

    func stableID(_ track: Track) -> String {
        if let persistent = trackInfo[track.id]?.persistentID, !persistent.isEmpty,
           persistentIDCounts[persistent] == 1 { return "persistent:" + persistent }
        return nativeAliases[track.playableID] ?? nativeAliases[track.id] ?? track.id
    }
}

private struct ComparisonEngine {
    let library: ManualMusicLibrary
    let spotify: LibrarySnapshot
    let decisions: MatchDecisions
    let configuration: LibraryComparisonConfiguration
    let baseline: LibraryComparisonBaseline?
    let appleSnapshot: LibrarySnapshot?
    var report = LibraryComparisonReport()
    var apple: ComparisonInventory
    var oldApple: ComparisonInventory?
    var mapped: [String: Track] = [:]
    var oldMapped: [String: Track] = [:]
    var spotifyAliases: [String: String] = [:]
    var spotifyIndex: ComparisonTrackIndex
    var appleIndex: ComparisonTrackIndex
    var namespace: String
    var decisionsBySource: [MusicService: [String: [TrackMatch]]]
    var appleBySpotifyIdentity: [String: [Track]] = [:]
    var emittedDifferenceIDs: Set<String> = []

    init(library: ManualMusicLibrary, spotify: LibrarySnapshot, decisions: MatchDecisions,
         configuration: LibraryComparisonConfiguration, baseline: LibraryComparisonBaseline?, appleSnapshot: LibrarySnapshot?) {
        self.library = library; self.spotify = spotify; self.decisions = decisions; self.configuration = configuration
        self.baseline = baseline; self.appleSnapshot = appleSnapshot
        decisionsBySource = Dictionary(grouping: decisions.tracks, by: \.sourceService).mapValues { Dictionary(grouping: $0, by: { $0.source.id }) }
        let inventory = ComparisonInventory(library: library, official: appleSnapshot, includeUncertain: configuration.includeUncertainXMLSongs)
        apple = inventory
        oldApple = baseline.map { ComparisonInventory(library: $0.library, official: $0.appleSnapshot, includeUncertain: configuration.includeUncertainXMLSongs) }
        let candidates = spotify.allTracks + (baseline?.spotify.allTracks ?? [])
        spotifyIndex = ComparisonTrackIndex(candidates)
        appleIndex = ComparisonTrackIndex(inventory.tracks)
        namespace = ComparisonIdentity.digest([library.id, spotify.account.id, appleSnapshot?.account.id ?? "xml"])
    }

    mutating func compare() -> LibraryComparisonReport {
        report.warnings = library.warnings + spotify.coverage.notes
        if appleSnapshot == nil {
            report.warnings += ["El XML prueba presencia sólo en esta exportación; no consulta la nube de Apple Music.",
                                "Los grupos de álbum del XML no prueban que un álbum completo esté guardado."]
        }
        guard spotify.account.service == .spotify, appleSnapshot == nil || appleSnapshot?.account.service == .appleMusic else {
            emit(unit: "configuration", scope: .songs, category: .conflict, title: "Los servicios de las cuentas no coinciden")
            return report
        }
        if let baseline, baseline.library.id != library.id || baseline.spotify.account.id != spotify.account.id ||
            baseline.spotify.account.service != .spotify || baseline.appleSnapshot?.account.id != appleSnapshot?.account.id ||
            baseline.appleSnapshot?.account.service != appleSnapshot?.account.service {
            emit(unit: "baseline", scope: .songs, category: .conflict, title: "El seguimiento pertenece a otra biblioteca o cuenta")
            return report
        }
        buildAliases()
        for track in apple.tracks.sorted(by: { $0.id < $1.id }) {
            let match = resolve(track, inventory: apple)
            report.matches.append(match)
            if let selected = match.selected { mapped[track.id] = selected }
        }
        appleBySpotifyIdentity = Dictionary(grouping: apple.tracks.filter { mapped[$0.id] != nil }, by: { spotifyToken(mapped[$0.id]!) })
        if let oldApple {
            let currentByStable = Dictionary(apple.tracks.compactMap { track in
                mapped[track.id].map { (apple.stableID(track), $0) }
            }, uniquingKeysWith: { first, _ in first })
            for track in oldApple.tracks {
                oldMapped[track.id] = currentByStable[oldApple.stableID(track)] ?? resolve(track, inventory: oldApple).selected
            }
        }
        for source in spotify.allTracks.sorted(by: { $0.id < $1.id }) {
            report.matches.append(reverseMatch(source))
        }
        report.metrics = .init(appleMusic: metrics(apple), spotify: spotifyMetrics(),
                               matchedSongIdentities: Set(apple.tracks.filter { mapped[$0.id] != nil }.map { token($0, inventory: apple) }).count,
                               unresolvedSongIdentities: Set(apple.tracks.filter { mapped[$0.id] == nil }.map { apple.stableID($0) }).count)
        if configuration.scope.songs { compareSongs() }
        if configuration.scope.albums { compareAlbums() }
        if configuration.scope.playlists { comparePlaylists() }
        report.differences.sort { ($0.scope.rawValue, $0.unitID, $0.id) < ($1.scope.rawValue, $1.unitID, $1.id) }
        report.warnings = Array(Set(report.warnings)).sorted()
        return report
    }

    mutating func buildAliases() {
        // Account-local aliases only. ISRC, album and title are never identity keys.
        let observations = spotify.allTracks + (baseline?.spotify.allTracks ?? []) + decisions.tracks.filter { $0.sourceService == .appleMusic }.flatMap { $0.candidates + [$0.selected].compactMap { $0 } } + decisions.tracks.filter { $0.sourceService == .spotify }.map(\.source)
        spotifyAliases = ComparisonIdentity.aliases(observations)
    }

    func spotifyToken(_ track: Track) -> String { "spotify:" + (spotifyAliases[track.playableID] ?? spotifyAliases[track.id] ?? track.playableID) }
    func token(_ track: Track, inventory: ComparisonInventory, historical: Bool = false) -> String {
        if let target = (historical ? oldMapped : mapped)[track.id] { return spotifyToken(target) }
        return "appleMusic:" + inventory.stableID(track)
    }

    func resolve(_ source: Track, inventory: ComparisonInventory) -> TrackMatch {
        let supplied = decisionsBySource[.appleMusic]?[source.id] ?? []
        if !supplied.isEmpty {
            guard supplied.count == 1, let previous = supplied.first,
                  CatalogMatcher.sameIdentityMetadata(previous.source, source) else {
                return TrackMatch(sourceService: .appleMusic, source: source, reason: "La decisión es contradictoria o corresponde a otros metadatos.")
            }
            var result = previous; result.selected = nil
            guard previous.decision != .pending, previous.decision != .omitted, let selected = previous.selected,
                  selected.available, !selected.isLocal, !selected.playableID.isEmpty,
                  !(previous.rejectedCandidateIDs ?? []).contains(selected.playableID),
                  previous.decision == .manual || previous.manualSelection == true ||
                    (previous.confidence == .exact && (previous.searchCoverage == nil || previous.searchCoverage == .complete)) else { return result }
            if !previous.candidates.isEmpty {
                let candidates = CatalogMatcher.unique(previous.candidates).filter { $0.playableID == selected.playableID }
                guard candidates.count == 1, let candidate = candidates.first,
                      CatalogMatcher.sameIdentityMetadata(candidate, selected) else { return result }
            }
            result.selected = selected; return result
        }
        let reverse = decisions.tracks.filter {
            $0.sourceService == .spotify && $0.selected.map { selected in
                selected.id == source.id || (appleSnapshot != nil && inventory.stableID(selected) == inventory.stableID(source))
            } == true &&
            ($0.decision == .manual || $0.manualSelection == true || ($0.confidence == .exact && ($0.searchCoverage == nil || $0.searchCoverage == .complete))) &&
            $0.decision != .pending && $0.decision != .omitted
        }
        if !reverse.isEmpty {
            let targets = CatalogMatcher.unique(reverse.filter { $0.selected.map { selected in
                var sameID = selected; sameID.id = source.id; sameID.catalogID = source.catalogID
                return CatalogMatcher.sameIdentityMetadata(sameID, source)
            } == true }.map(\.source))
            var result = TrackMatch(sourceService: .appleMusic, source: source, candidates: targets,
                                    selected: targets.count == 1 ? targets[0] : nil,
                                    confidence: .review, reason: "Equivalencia suministrada para una canción observada en el XML.")
            result.manualSelection = true; result.decision = targets.count == 1 ? .manual : .pending
            return result
        }
        // XML isLocal means storage on disk, not that an equivalent cannot exist in Spotify.
        var searchable = source; searchable.isLocal = false
        var result = CatalogMatcher.track(searchable, candidates: spotifyIndex.candidates(for: searchable), sourceService: .appleMusic)
        result.source = source
        return result
    }

    func metrics(_ inventory: ComparisonInventory) -> LibraryInventoryMetrics {
        let identities = Set(inventory.tracks.map { inventory.stableID($0) })
        let saved = Set(inventory.knownSaved.map { inventory.stableID($0) })
        let byID = inventory.byID
        let included = Set(inventory.playlists.flatMap(\.trackIDs).compactMap { byID[$0] }.map { inventory.stableID($0) })
        let complete = inventory.playlistsComplete && inventory.playlists.allSatisfy(\.contentsComplete)
        return .init(songIdentities: identities.count, savedSongMemberships: saved.count,
                     playlistOccurrences: inventory.playlists.reduce(0) { $0 + $1.trackIDs.count }, playlists: inventory.playlists.count,
                     completeSavedAlbums: inventory.albums.count, albumGroups: albumGroups(inventory.tracks).count,
                     looseSongIdentities: complete && inventory.songsComplete ? saved.subtracting(included).count : nil,
                     songsComplete: inventory.songsComplete, playlistsComplete: complete,
                     savedSongsKnown: inventory.uncertainSaved.isEmpty,
                     uncertainSongMemberships: Set(inventory.uncertainSaved.map { inventory.stableID($0) }).count,
                     selectedUncertainSongs: configuration.includeUncertainXMLSongs && appleSnapshot == nil ? inventory.uncertainSaved.count : 0)
    }

    func spotifyMetrics() -> LibraryInventoryMetrics {
        let saved = spotify.savedTracks + spotify.savedAlbums.filter { !$0.isCompleteAlbum }.flatMap(\.tracks)
        let memberships = Set(saved.map(spotifyToken))
        let included = Set(spotify.playlists.flatMap(\.tracks).map(spotifyToken))
        let complete = spotify.coverage.playlists && spotify.playlists.allSatisfy(\.contentsComplete)
        return .init(songIdentities: Set(spotify.allTracks.map(spotifyToken)).count, savedSongMemberships: memberships.count,
                     playlistOccurrences: spotify.playlists.reduce(0) { $0 + $1.tracks.count }, playlists: spotify.playlists.count,
                     completeSavedAlbums: spotify.savedAlbums.filter(\.isCompleteAlbum).count,
                     albumGroups: albumGroups(spotify.allTracks).count,
                     looseSongIdentities: complete && spotify.coverage.tracks && spotify.coverage.albums ? memberships.subtracting(included).count : nil,
                     songsComplete: spotify.coverage.tracks && spotify.coverage.albums, playlistsComplete: complete,
                     savedSongsKnown: true)
    }

    func albumGroups(_ tracks: [Track]) -> [String: [Track]] {
        Dictionary(grouping: tracks.filter { !CatalogMatcher.normalized($0.albumTitle).isEmpty }, by: {
            ComparisonIdentity.digest([CatalogMatcher.normalized($0.artist), CatalogMatcher.normalized($0.albumTitle)])
        })
    }

    /// No date, presentation artwork, UUID or filename participates in stable review identity.
    @discardableResult mutating func emit(unit: String, scope: LibraryComparisonKind, category: LibraryDifferenceCategory,
                                         destination: MusicService? = nil, sourceID: String? = nil, targetID: String? = nil,
                                         title: String, detail: String = "", tracks: [Track] = [], albums: [Album] = [],
                                         appleIDs: [String]? = nil, spotifyIDs: [String]? = nil,
                                         operationKind: OperationKind? = nil, playlistName: String? = nil,
                                         beforeIDs: [String]? = nil, playlistDescription: String? = nil) -> String {
        let unitID = "comparison-unit:v1:" + ComparisonIdentity.digest([namespace, scope.rawValue, unit])
        let id = "comparison-difference:v1:" + ComparisonIdentity.digest([unitID, category.rawValue, destination?.rawValue ?? "", sourceID ?? "", targetID ?? "", title] +
            [appleIDs.map { ComparisonIdentity.digest($0) } ?? "absent", spotifyIDs.map { ComparisonIdentity.digest($0) } ?? "absent"] +
            tracks.map { $0.playableID } + albums.map { $0.playableID })
        var difference = LibraryDifference(id: id, unitID: unitID, scope: scope, category: category, destination: destination,
                                           sourceID: sourceID, destinationID: targetID, title: title, detail: detail,
                                           tracks: tracks, albums: albums, appleMusicTrackIDs: appleIDs, spotifyTrackIDs: spotifyIDs)
        if category == .addition, let destination, let operationKind, !operationKind.isDestructive {
            if destination == .spotify {
                var operation = SyncOperation(id: ComparisonIdentity.uuid(id), service: .spotify, kind: operationKind,
                                              targetID: targetID, title: title, detail: detail, playlistName: playlistName,
                                              playlistDescription: playlistDescription, tracks: tracks, albums: albums, beforeTrackIDs: beforeIDs)
                if scope == .playlists, let sourceID { operation.sourcePlaylist = .init(service: .appleMusic, playlistID: sourceID) }
                difference.spotifyOperations = [operation]
            } else {
                let resolved = tracks.compactMap(appleDestinationTrack)
                var operation: SyncOperation?
                if appleSnapshot != nil, resolved.count == tracks.count, albums.allSatisfy({ !$0.playableID.isEmpty }) {
                    operation = SyncOperation(id: ComparisonIdentity.uuid(id), service: .appleMusic, kind: operationKind,
                                              targetID: targetID, title: title, detail: detail, playlistName: playlistName,
                                              playlistDescription: playlistDescription, tracks: resolved, albums: albums, beforeTrackIDs: beforeIDs)
                    if scope == .playlists, let sourceID { operation?.sourcePlaylist = .init(service: .spotify, playlistID: sourceID) }
                }
                difference.appleMusicTasks = [.init(id: "manual:" + id, differenceID: id, kind: operationKind,
                                                    targetID: targetID, title: title, detail: detail, tracks: resolved.count == tracks.count ? resolved : tracks,
                                                    albums: albums, operation: operation)]
            }
        }
        if emittedDifferenceIDs.insert(id).inserted { report.differences.append(difference) }
        return id
    }

    func appleDestinationTrack(_ source: Track) -> Track? {
        let identity = spotifyToken(source)
        let present = appleBySpotifyIdentity[identity, default: []].filter { $0.available && !$0.isLocal }
        if let selected = present.sorted(by: { $0.id < $1.id }).first { return selected }
        let choices = decisions.tracks.filter { $0.sourceService == .spotify && CatalogMatcher.sameIdentityMetadata($0.source, source) }
        guard choices.count == 1, let choice = choices.first, choice.decision != .pending, choice.decision != .omitted,
              choice.decision == .manual || choice.manualSelection == true ||
                (choice.confidence == .exact && (choice.searchCoverage == nil || choice.searchCoverage == .complete)),
              let selected = choice.selected, selected.available, !selected.isLocal, !selected.playableID.isEmpty,
              !(choice.rejectedCandidateIDs ?? []).contains(selected.playableID) else { return nil }
        if !choice.candidates.isEmpty {
            let versions = CatalogMatcher.unique(choice.candidates).filter { $0.playableID == selected.playableID }
            guard versions.count == 1, CatalogMatcher.sameIdentityMetadata(versions[0], selected) else { return nil }
        }
        return selected
    }

    func reverseMatch(_ source: Track) -> TrackMatch {
        let duplicates = decisionsBySource[.spotify]?[source.id] ?? []
        if let previous = duplicates.first {
            guard duplicates.count == 1, CatalogMatcher.sameIdentityMetadata(previous.source, source) else {
                return TrackMatch(sourceService: .spotify, source: source, reason: "Decisión contradictoria o anterior a estos metadatos.")
            }
            var result = previous
            if previous.decision == .pending || previous.decision == .omitted { result.selected = nil; return result }
            // A catalog selection remains a catalog selection; membership uses only observed XML/official IDs.
            if let selected = appleDestinationTrack(source) { result.selected = selected; return result }
            result.selected = nil; return result
        }
        let observed = appleBySpotifyIdentity[spotifyToken(source), default: []].sorted { $0.id < $1.id }
        if let selected = observed.first {
            return TrackMatch(sourceService: .spotify, source: source, candidates: observed, selected: selected,
                              confidence: .exact, reason: "Equivalencia con una canción observada en la biblioteca de Apple.")
        }
        let candidates = appleIndex.candidates(for: source).map { track -> Track in var candidate = track; candidate.isLocal = false; return candidate }
        var result = CatalogMatcher.track(source, candidates: candidates, sourceService: .spotify)
        // Do not independently create a contradictory reverse identity from a many-to-one candidate set.
        result.selected = nil
        result.candidates = result.candidates.compactMap { candidate in apple.byID[candidate.id] }
        return result
    }

    /// Returns the side receiving a change. Missing observations require complete coverage on that side.
    func change(applePresent: Bool, spotifyPresent: Bool, oldApplePresent: Bool?, oldSpotifyPresent: Bool?,
                appleComplete: Bool, spotifyComplete: Bool, oldAppleComplete: Bool, oldSpotifyComplete: Bool)
        -> (LibraryDifferenceCategory, MusicService?, String)? {
        if applePresent == spotifyPresent { return nil }
        if !applePresent && !appleComplete || !spotifyPresent && !spotifyComplete {
            return (.review, nil, "La cobertura parcial no permite confirmar ausencia ni inferir altas o bajas.")
        }
        if baseline != nil {
            guard let oldApplePresent, let oldSpotifyPresent,
                  oldApplePresent || oldAppleComplete, oldSpotifyPresent || oldSpotifyComplete else {
                return (.review, nil, "El baseline es parcial para esta unidad; no establece el cambio de membresía.")
            }
            let appleChanged = oldApplePresent != applePresent
            let spotifyChanged = oldSpotifyPresent != spotifyPresent
            if appleChanged && spotifyChanged {
                return (.conflict, nil, "Ambos lados cambiaron de forma diferente desde el baseline; elegí cómo resolverlo.")
            }
            if appleChanged { return (applePresent ? .addition : .removal, .spotify, "Cambio observado en Apple desde el baseline.") }
            if spotifyChanged { return (spotifyPresent ? .addition : .removal, .appleMusic, "Cambio observado en Spotify desde el baseline.") }
            return (.review, nil, "La diferencia ya existía en el baseline y sigue pendiente; no representa una nueva escritura.")
        }
        if configuration.mode == .merge { return (.addition, applePresent ? .spotify : .appleMusic, "Fusionar las altas observadas, con confirmación.") }
        if configuration.mode == .appleMusicBase && applePresent { return (.addition, .spotify, "Apple Music es la base elegida para la primera sincronización.") }
        if configuration.mode == .spotifyBase && spotifyPresent { return (.addition, .appleMusic, "Spotify es la base elegida para la primera sincronización.") }
        return (.review, nil, "Contenido exclusivo del destino. La primera sincronización no autoriza inferir bajas.")
    }

    mutating func compareSongs() {
        if !apple.uncertainSaved.isEmpty, !configuration.includeUncertainXMLSongs {
            emit(unit: "xml-uncertain-saved-membership", scope: .songs, category: .review,
                 title: "\(apple.uncertainSaved.count) canciones del XML con membresía guardada desconocida",
                 detail: "El XML no indica si estas canciones están guardadas individualmente. Podés elegir explícitamente incluirlas como canciones para guardar en Spotify.",
                 tracks: apple.uncertainSaved.sorted { $0.id < $1.id })
        }
        let appleSaved = Dictionary(apple.saved.map { (token($0, inventory: apple), $0) }, uniquingKeysWith: { first, _ in first })
        let spotifySaved = Dictionary((spotify.savedTracks + spotify.savedAlbums.filter { !$0.isCompleteAlbum }.flatMap(\.tracks)).map { (spotifyToken($0), $0) }, uniquingKeysWith: { first, _ in first })
        let oldAppleSaved = oldApple.map { inventory in
            Dictionary(inventory.saved.map { (token($0, inventory: inventory, historical: true), $0) }, uniquingKeysWith: { first, _ in first })
        } ?? [:]
        let oldSpotifySaved = Dictionary(((baseline?.spotify.savedTracks ?? []) + (baseline?.spotify.savedAlbums.filter { !$0.isCompleteAlbum }.flatMap(\.tracks) ?? [])).map { (spotifyToken($0), $0) }, uniquingKeysWith: { first, _ in first })
        for identity in Set(appleSaved.keys).union(spotifySaved.keys).union(oldAppleSaved.keys).union(oldSpotifySaved.keys).sorted() {
            guard let outcome = change(applePresent: appleSaved[identity] != nil, spotifyPresent: spotifySaved[identity] != nil,
                                       oldApplePresent: oldAppleSaved[identity] != nil, oldSpotifyPresent: oldSpotifySaved[identity] != nil,
                                       appleComplete: apple.songsComplete, spotifyComplete: spotify.coverage.tracks && spotify.coverage.albums,
                                       oldAppleComplete: oldApple?.songsComplete == true,
                                       oldSpotifyComplete: baseline?.spotify.coverage.tracks == true && baseline?.spotify.coverage.albums == true) else { continue }
            let source = appleSaved[identity] ?? spotifySaved[identity] ?? oldAppleSaved[identity] ?? oldSpotifySaved[identity]
            guard let source else { continue }
            var category = outcome.0; var detail = outcome.2
            var targetTracks = [source]
            if category == .addition, outcome.1 == .spotify {
                if let selected = mapped[source.id] { targetTracks = [selected] }
                else { category = .review; detail = "Buscá o elegí una equivalencia de catálogo de Spotify antes de preparar el alta." }
            }
            if category == .addition, outcome.1 == .appleMusic,
               let match = report.matches.first(where: { $0.sourceService == .spotify && $0.source.id == source.id }),
               match.decision == .pending || match.decision == .omitted || (match.selected == nil && !match.candidates.isEmpty) {
                category = .review; detail = "Hay una equivalencia pendiente, omitida o ambigua; no prueba una canción faltante."
            }
            if category == .addition, outcome.1 == .appleMusic, appleSnapshot != nil, appleDestinationTrack(source) == nil {
                category = .review; detail = "Elegí una equivalencia del catálogo de Apple antes de preparar el alta oficial."
            }
            if category == .addition, !source.available || (outcome.1 == .appleMusic && source.isLocal) {
                category = .review; detail = "El origen es local en Spotify o no está disponible; verificá una equivalencia antes de preparar el alta."
            }
            if category == .addition, outcome.1 == .spotify, targetTracks.contains(where: { !$0.available || $0.isLocal || $0.playableID.isEmpty }) {
                category = .review; detail = "La canción de destino no está disponible para guardar."
            }
            if category == .removal, (oldApple?.tracks.contains { oldMapped[$0.id] == nil } == true || apple.tracks.contains { mapped[$0.id] == nil }) {
                category = .review; detail = "Hay identidades sin resolver; no se puede proponer una baja de posibles equivalentes."
            }
            if category == .removal, !apple.uncertainSaved.isEmpty || oldApple?.uncertainSaved.isEmpty == false {
                category = .review; detail = "La membresía guardada de canciones XML es desconocida; la selección para altas no autoriza inferir bajas."
            }
            emit(unit: identity, scope: .songs, category: category, destination: outcome.1,
                 sourceID: source.id, targetID: outcome.1 == .spotify ? spotifySaved[identity]?.id : appleSaved[identity]?.id,
                 title: source.title, detail: detail, tracks: targetTracks,
                 operationKind: category == .addition ? .saveTracks : nil)
        }
    }

    mutating func compareAlbums() {
        if appleSnapshot == nil {
            for (group, tracks) in albumGroups(apple.saved).sorted(by: { $0.key < $1.key }) {
                guard let first = tracks.first else { continue }
                let album = Album(id: "xml-album-group:" + group, title: first.albumTitle, artist: first.artist,
                                  tracks: tracks.sorted { $0.id < $1.id }, isCompleteAlbum: false)
                emit(unit: "xml-group:" + group, scope: .albums, category: .review, title: album.title,
                     detail: "Agrupación de canciones del XML. No prueba un álbum completo guardado ni permite guardar toda una edición.", albums: [album])
            }
            for album in spotify.savedAlbums.filter(\.isCompleteAlbum).sorted(by: { $0.id < $1.id }) {
                emit(unit: "spotify-album:" + album.playableID, scope: .albums, category: .review, title: album.title,
                     detail: "Álbum completo guardado en Spotify. El XML no acredita membresía de álbum completo en Apple Music.", albums: [album])
            }
            return
        }
        let current = albumIdentities(apple.albums)
        let historical = albumIdentities(oldApple?.albums ?? [])
        let currentSpotify = Dictionary(spotify.savedAlbums.filter(\.isCompleteAlbum).map { ("spotify-album:" + $0.playableID, $0) }, uniquingKeysWith: { first, _ in first })
        let oldSpotify = Dictionary((baseline?.spotify.savedAlbums.filter(\.isCompleteAlbum) ?? []).map { ("spotify-album:" + $0.playableID, $0) }, uniquingKeysWith: { first, _ in first })
        for identity in Set(current.keys).union(historical.keys).union(currentSpotify.keys).union(oldSpotify.keys).sorted() {
            guard let outcome = change(applePresent: current[identity] != nil, spotifyPresent: currentSpotify[identity] != nil,
                                       oldApplePresent: historical[identity] != nil, oldSpotifyPresent: oldSpotify[identity] != nil,
                                       appleComplete: apple.albumsComplete, spotifyComplete: spotify.coverage.albums,
                                       oldAppleComplete: oldApple?.albumsComplete == true, oldSpotifyComplete: baseline?.spotify.coverage.albums == true),
                  let source = current[identity] ?? currentSpotify[identity] ?? historical[identity] ?? oldSpotify[identity] else { continue }
            var category = outcome.0; var selected: Album?
            if category == .addition {
                let sourceService: MusicService = outcome.1 == .spotify ? .appleMusic : .spotify
                let supplied = decisions.albums.filter { $0.sourceService == sourceService && $0.source == source }
                if supplied.count == 1, let match = supplied.first,
                   match.manualSelection == true || (match.confidence == .exact && (match.searchCoverage == nil || match.searchCoverage == .complete)),
                   let choice = match.selected, choice.available, choice.isCompleteAlbum, !choice.playableID.isEmpty {
                    selected = choice
                } else { category = .review }
            }
            emit(unit: identity, scope: .albums, category: category, destination: outcome.1, sourceID: source.id,
                 title: source.title, detail: category == .review ? "Revisá la edición completa y su equivalencia antes de preparar un alta o una baja." : outcome.2,
                 albums: [selected ?? source], operationKind: category == .addition ? .saveAlbums : nil)
        }
    }

    func albumIdentities(_ albums: [Album]) -> [String: Album] {
        var result: [String: Album] = [:]
        for album in albums {
            let supplied = decisions.albums.filter { $0.sourceService == .appleMusic && $0.source == album }
            var selected: Album?
            if supplied.count == 1, let match = supplied.first,
               match.manualSelection == true || (match.confidence == .exact && (match.searchCoverage == nil || match.searchCoverage == .complete)) { selected = match.selected }
            if selected == nil { selected = CatalogMatcher.album(album, candidates: spotify.savedAlbums.filter(\.isCompleteAlbum), sourceService: .appleMusic).selected }
            let reverse = decisions.albums.filter { $0.sourceService == .spotify && $0.selected == album && ($0.manualSelection == true || $0.confidence == .exact) }
            if selected == nil, reverse.count == 1 { selected = reverse[0].source }
            result[selected.map { "spotify-album:" + $0.playableID } ?? "apple-album:" + album.playableID] = album
        }
        return result
    }

    mutating func comparePlaylists() {
        let appleLists = Dictionary(apple.playlists.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let spotifyLists = Dictionary(spotify.playlists.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let confirmed = Dictionary(configuration.playlistPairings.map { (ComparisonIdentity.digest([$0.appleMusicID, $0.spotifyID]), $0) }, uniquingKeysWith: { first, _ in first }).values.sorted { ($0.appleMusicID, $0.spotifyID) < ($1.appleMusicID, $1.spotifyID) }
        let appleLinks = Dictionary(grouping: confirmed, by: \.appleMusicID)
        let spotifyLinks = Dictionary(grouping: confirmed, by: \.spotifyID)
        var consideredApple = Set<String>(), consideredSpotify = Set<String>()
        for link in confirmed {
            consideredApple.insert(link.appleMusicID); consideredSpotify.insert(link.spotifyID)
            guard selectedApple(link.appleMusicID), selectedSpotify(link.spotifyID) else { continue }
            let pairID = ComparisonIdentity.digest([link.appleMusicID, link.spotifyID])
            if appleLinks[link.appleMusicID, default: []].count != 1 || spotifyLinks[link.spotifyID, default: []].count != 1 {
                report.playlistPairings.append(.init(id: pairID, appleMusicID: link.appleMusicID, spotifyID: link.spotifyID,
                                                    status: .ambiguous, reason: "Un mismo destino u origen figura en varios vínculos confirmados."))
                emit(unit: "playlist-pair:" + pairID, scope: .playlists, category: .conflict,
                     title: "Vínculos de playlist contradictorios", detail: "Elegí un vínculo uno a uno antes de preparar cambios.")
                continue
            }
            report.playlistPairings.append(.init(id: pairID, appleMusicID: link.appleMusicID, spotifyID: link.spotifyID,
                                                status: .confirmed, reason: "Vínculo confirmado en la configuración de esta comparación."))
            comparePlaylist(appleLists[link.appleMusicID], spotifyLists[link.spotifyID], appleID: link.appleMusicID, spotifyID: link.spotifyID)
        }
        // A remembered link is a suggestion until explicitly confirmed in configuration.
        for link in decisions.playlists.sorted(by: { ($0.appleMusicID, $0.spotifyID) < ($1.appleMusicID, $1.spotifyID) }) {
            guard !consideredApple.contains(link.appleMusicID), !consideredSpotify.contains(link.spotifyID),
                  selectedApple(link.appleMusicID), selectedSpotify(link.spotifyID),
                  appleLists[link.appleMusicID] != nil, spotifyLists[link.spotifyID] != nil else { continue }
            consideredApple.insert(link.appleMusicID); consideredSpotify.insert(link.spotifyID)
            suggestPair(appleID: link.appleMusicID, spotifyID: link.spotifyID,
                        reason: "Hay un vínculo recordado; confirmalo para habilitar esta pareja.")
        }
        let allAppleNames = Dictionary(grouping: apple.playlists.filter { $0.kind == .regular }, by: { CatalogMatcher.normalized($0.name) })
        let allSpotifyNames = Dictionary(grouping: spotify.playlists, by: { CatalogMatcher.normalized($0.name) })
        for list in apple.playlists.sorted(by: { $0.id < $1.id }) where !consideredApple.contains(list.id) && selectedApple(list.id) {
            consideredApple.insert(list.id)
            guard list.kind == .regular else {
                emit(unit: "apple-playlist:" + list.id, scope: .playlists, category: .review, sourceID: list.id,
                     title: list.name, detail: "Carpetas, playlists inteligentes, del sistema o de tipo desconocido requieren revisión manual.")
                continue
            }
            let name = CatalogMatcher.normalized(list.name)
            let candidates = allSpotifyNames[name, default: []]
            if !candidates.isEmpty {
                if !name.isEmpty, candidates.count == 1, allAppleNames[name, default: []].count == 1,
                   let target = candidates.first, !consideredSpotify.contains(target.id), selectedSpotify(target.id) {
                    consideredSpotify.insert(target.id)
                    suggestPair(appleID: list.id, spotifyID: target.id, reason: "Nombre único en ambos inventarios. Confirmá el vínculo antes de actualizar.")
                } else {
                    for candidate in candidates { consideredSpotify.insert(candidate.id) }
                    report.playlistPairings.append(.init(id: "ambiguous:" + list.id, appleMusicID: list.id, status: .ambiguous,
                                                        reason: "El nombre no identifica una única pareja dentro del alcance elegido."))
                    emit(unit: "apple-playlist:" + list.id, scope: .playlists, category: .review, sourceID: list.id,
                         title: list.name, detail: "Hay playlists con nombres duplicados, ya vinculadas o fuera del alcance. Elegí el vínculo manualmente.")
                }
            } else if allAppleNames[name, default: []].count > 1 || name.isEmpty {
                report.playlistPairings.append(.init(id: "ambiguous:" + list.id, appleMusicID: list.id, status: .ambiguous,
                                                    reason: "El nombre del origen es duplicado o vacío."))
                emit(unit: "apple-playlist:" + list.id, scope: .playlists, category: .review, sourceID: list.id,
                     title: list.name, detail: "Confirmá manualmente la identidad de esta playlist antes de crear un destino.")
            } else { comparePlaylist(list, nil, appleID: list.id, spotifyID: nil) }
        }
        for list in spotify.playlists.sorted(by: { $0.id < $1.id }) where !consideredSpotify.contains(list.id) && selectedSpotify(list.id) {
            let name = CatalogMatcher.normalized(list.name)
            if !allAppleNames[name, default: []].isEmpty || allSpotifyNames[name, default: []].count > 1 || name.isEmpty {
                report.playlistPairings.append(.init(id: "ambiguous-spotify:" + list.id, spotifyID: list.id, status: .ambiguous,
                                                    reason: "Hay un posible equivalente sin vínculo confirmado o un nombre duplicado."))
                emit(unit: "spotify-playlist:" + list.id, scope: .playlists, category: .review, sourceID: list.id,
                     title: list.name, detail: "Elegí la pareja manualmente antes de preparar cambios en esta playlist.")
            } else { comparePlaylist(nil, list, appleID: nil, spotifyID: list.id) }
        }
        if library.inventory == nil, appleSnapshot == nil {
            emit(unit: "xml-playlist-coverage", scope: .playlists, category: .review,
                 title: "El XML importado no conserva inventario de playlists", detail: "Volvé a importar el XML para comparar playlists; no se interpretó como un inventario vacío.")
        }
    }

    func selectedApple(_ id: String) -> Bool { configuration.scope.appleMusicPlaylistIDs?.contains(id) ?? true }
    func selectedSpotify(_ id: String) -> Bool { configuration.scope.spotifyPlaylistIDs?.contains(id) ?? true }

    mutating func suggestPair(appleID: String, spotifyID: String, reason: String) {
        let id = ComparisonIdentity.digest([appleID, spotifyID])
        report.playlistPairings.append(.init(id: id, appleMusicID: appleID, spotifyID: spotifyID, status: .suggested, reason: reason))
        emit(unit: "playlist-pair:" + id, scope: .playlists, category: .review, sourceID: appleID, targetID: spotifyID,
             title: "Confirmar vínculo de playlists", detail: reason)
    }

    func appleSequence(_ list: XMLMusicPlaylist, inventory: ComparisonInventory, historical: Bool = false) -> [String]? {
        let lookup = inventory.byID
        let sequence = list.trackIDs.compactMap { id -> String? in
            guard let track = lookup[id], (historical ? oldMapped : mapped)[id] != nil else { return nil }
            return token(track, inventory: inventory, historical: historical)
        }
        return sequence.count == list.trackIDs.count ? sequence : nil
    }

    mutating func comparePlaylist(_ left: XMLMusicPlaylist?, _ right: Playlist?, appleID: String?, spotifyID: String?) {
        guard left != nil || right != nil else { return }
        let unit = "playlist:" + ComparisonIdentity.digest([appleID ?? "absent", spotifyID ?? "absent"])
        let title = left?.name ?? right?.name ?? "Playlist"
        let oldLeft = oldApple?.playlists.first { $0.id == appleID }
        let oldRight = baseline?.spotify.playlists.first { $0.id == spotifyID }
        let appleIDs = left?.trackIDs
        let spotifyIDs = right?.tracks.map(\.playableID)
        if left.map({ $0.kind != .regular || !$0.contentsComplete }) == true || right?.contentsComplete == false ||
            (left == nil && !apple.playlistsComplete) || (right == nil && !spotify.coverage.playlists) {
            emit(unit: unit, scope: .playlists, category: .review, title: title,
                 detail: "Lectura de playlist incompleta o tipo no regular: no se infiere contenido faltante, ausencia ni eliminación.", appleIDs: appleIDs, spotifyIDs: spotifyIDs)
            return
        }
        if let id = appleID, decisions.protectedPlaylistIDs[.appleMusic]?.contains(id) == true {
            emit(unit: unit, scope: .playlists, category: .review, title: title, detail: "La playlist de Apple está protegida en esta comparación.")
            return
        }
        if let id = spotifyID, decisions.protectedPlaylistIDs[.spotify]?.contains(id) == true {
            emit(unit: unit, scope: .playlists, category: .review, title: title, detail: "La playlist de Spotify está protegida en esta comparación.")
            return
        }
        if left == nil || right == nil {
            guard var outcome = change(applePresent: left != nil, spotifyPresent: right != nil,
                                       oldApplePresent: oldLeft != nil, oldSpotifyPresent: oldRight != nil,
                                       appleComplete: apple.playlistsComplete, spotifyComplete: spotify.coverage.playlists,
                                       oldAppleComplete: oldApple?.playlistsComplete == true,
                                       oldSpotifyComplete: baseline?.spotify.coverage.playlists == true) else { return }
            // A deleted playlist conflicting with edits on the other side requires a choice.
            if baseline != nil, oldLeft != nil, oldRight != nil {
                let leftEdited = left.map { list in list.name != oldLeft?.name || appleSequence(list, inventory: apple) != oldLeft.flatMap { old in oldApple.flatMap { appleSequence(old, inventory: $0, historical: true) } } } ?? false
                let rightEdited = right.map { $0.name != oldRight?.name || $0.tracks.map(spotifyToken) != oldRight?.tracks.map(spotifyToken) } ?? false
                if leftEdited || rightEdited { outcome = (.conflict, nil, "Una playlist fue eliminada de un lado y modificada del otro desde el baseline.") }
            }
            var tracks = right?.tracks ?? []
            if outcome.0 == .addition, outcome.1 == .spotify, let left {
                tracks = left.trackIDs.compactMap { mapped[$0] }
                if tracks.count != left.trackIDs.count { outcome = (.review, nil, "Faltan equivalencias para conservar todas las canciones, su orden y sus repeticiones.") }
            }
            if outcome.0 == .addition, outcome.1 == .appleMusic, appleSnapshot != nil,
               tracks.compactMap(appleDestinationTrack).count != tracks.count {
                outcome = (.review, nil, "Faltan equivalencias del catálogo Apple para crear la playlist completa.")
            }
            emit(unit: unit, scope: .playlists, category: outcome.0, destination: outcome.1,
                 sourceID: outcome.1 == .spotify ? appleID : spotifyID,
                 targetID: outcome.1 == .spotify ? spotifyID : appleID,
                 title: title, detail: outcome.2, tracks: tracks, appleIDs: appleIDs, spotifyIDs: spotifyIDs,
                 operationKind: outcome.0 == .addition ? .createPlaylist : nil, playlistName: title,
                 playlistDescription: outcome.1 == .appleMusic ? right?.description : nil)
            return
        }
        guard let left, let right else { return }
        guard let leftSequence = appleSequence(left, inventory: apple) else {
            emit(unit: unit, scope: .playlists, category: .review, title: title,
                 detail: "Resolvé todas las equivalencias de esta playlist; ninguna aparición se omitirá silenciosamente.", appleIDs: appleIDs, spotifyIDs: spotifyIDs)
            return
        }
        let rightSequence = right.tracks.map(spotifyToken)
        if leftSequence == rightSequence && left.name == right.name { return }
        var destination: MusicService?
        var reason = ""
        if baseline != nil {
            guard let oldLeft, let oldRight, let oldApple, oldLeft.contentsComplete, oldRight.contentsComplete,
                  let oldLeftSequence = appleSequence(oldLeft, inventory: oldApple, historical: true) else {
                emit(unit: unit, scope: .playlists, category: .review, title: title,
                     detail: "El baseline no establece el contenido completo de ambas playlists.", appleIDs: appleIDs, spotifyIDs: spotifyIDs)
                return
            }
            let leftChanged = oldLeftSequence != leftSequence || oldLeft.name != left.name
            let rightChanged = oldRight.tracks.map(spotifyToken) != rightSequence || oldRight.name != right.name
            if leftChanged && rightChanged {
                emit(unit: unit, scope: .playlists, category: .conflict, title: title,
                     detail: "Ambas playlists cambiaron de forma distinta desde el baseline; consultá cómo resolver nombre, orden y repeticiones.", appleIDs: appleIDs, spotifyIDs: spotifyIDs)
                return
            }
            if !leftChanged && !rightChanged {
                emit(unit: unit, scope: .playlists, category: .review, title: title,
                     detail: "La diferencia de playlists ya existía en el baseline y sigue pendiente.", appleIDs: appleIDs, spotifyIDs: spotifyIDs)
                return
            }
            destination = leftChanged ? .spotify : .appleMusic
            reason = "Cambio unilateral desde el baseline."
        } else if configuration.mode == .merge {
            emit(unit: unit, scope: .playlists, category: .conflict, title: title,
                 detail: "Sin baseline no se puede elegir entre dos secuencias distintas. Elegí qué versión conservar.", appleIDs: appleIDs, spotifyIDs: spotifyIDs)
            return
        } else { destination = configuration.mode == .appleMusicBase ? .spotify : .appleMusic }
        let desired = destination == .spotify ? leftSequence : rightSequence
        let existing = destination == .spotify ? rightSequence : leftSequence
        let desiredName = destination == .spotify ? left.name : right.name
        let existingName = destination == .spotify ? right.name : left.name
        if desiredName != existingName {
            emit(unit: unit, scope: .playlists, category: .review, destination: destination,
                 sourceID: destination == .spotify ? left.id : right.id, targetID: destination == .spotify ? right.id : left.id,
                 title: title + " · nombre", detail: "Los nombres difieren; la confirmación de altas no autoriza renombrar. " + reason)
        }
        guard desired != existing else { return }
        if desired.starts(with: existing) {
            let suffixCount = desired.count - existing.count
            let tracks = destination == .spotify ? left.trackIDs.suffix(suffixCount).compactMap { mapped[$0] } : Array(right.tracks.suffix(suffixCount))
            var category: LibraryDifferenceCategory = .addition
            var detail = "Agregar \(suffixCount) apariciones al final conserva el orden y todas las repeticiones. " + reason
            if destination == .spotify && !right.editable {
                category = .review; detail = "La playlist de Spotify no permite modificaciones para esta cuenta."
            }
            if destination == .appleMusic && appleSnapshot != nil && tracks.compactMap(appleDestinationTrack).count != tracks.count {
                category = .review; detail = "Faltan equivalencias Apple para añadir todas las apariciones de forma segura."
            }
            emit(unit: unit, scope: .playlists, category: category, destination: destination,
                 sourceID: destination == .spotify ? left.id : right.id, targetID: destination == .spotify ? right.id : left.id,
                 title: title, detail: detail, tracks: tracks, appleIDs: appleIDs, spotifyIDs: spotifyIDs,
                 operationKind: category == .addition ? .addPlaylistTracks : nil, beforeIDs: destination == .spotify ? right.tracks.map(\.playableID) : left.trackIDs.compactMap { apple.byID[$0]?.playableID })
        } else {
            let isRemoval = ComparisonIdentity.isSubsequence(desired, of: existing)
            let category: LibraryDifferenceCategory = baseline != nil && isRemoval ? .removal : .review
            emit(unit: unit, scope: .playlists, category: category, destination: destination,
                 sourceID: destination == .spotify ? left.id : right.id, targetID: destination == .spotify ? right.id : left.id,
                 title: title, detail: isRemoval ? "La secuencia requiere quitar apariciones. Revisá la eliminación por separado. " + reason
                    : "Igualar esta secuencia requiere insertar o reordenar apariciones; agregar al final alteraría el orden. Revisalo por separado. " + reason,
                 tracks: destination == .spotify ? left.trackIDs.compactMap { mapped[$0] } : right.tracks,
                 appleIDs: appleIDs, spotifyIDs: spotifyIDs)
        }
    }
}

private enum ComparisonIdentity {
    static func aliases(_ tracks: [Track]) -> [String: String] {
        var neighbors: [String: Set<String>] = [:]
        for track in tracks {
            let ids = [track.id, track.catalogID].compactMap { $0 }.filter { !$0.isEmpty }
            for id in ids { neighbors[id, default: []].formUnion(ids) }
        }
        var aliases: [String: String] = [:]
        for id in neighbors.keys.sorted() where aliases[id] == nil {
            var pending = [id]; var component = Set<String>()
            while let next = pending.popLast() {
                guard component.insert(next).inserted else { continue }
                pending.append(contentsOf: neighbors[next, default: []].subtracting(component))
            }
            let canonical = component.sorted().first ?? id
            for alias in component { aliases[alias] = canonical }
        }
        return aliases
    }
    static func isSubsequence(_ desired: [String], of existing: [String]) -> Bool {
        var index = 0
        for item in existing where index < desired.count {
            if desired[index] == item { index += 1 }
        }
        return index == desired.count
    }
    static func digest(_ parts: [String]) -> String {
        SHA256.hash(data: Data(parts.map { "\($0.utf8.count):\($0)" }.joined().utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func uuid(_ key: String) -> UUID {
        let value = Array(SHA256.hash(data: Data(key.utf8)).prefix(16))
        return UUID(uuid: (value[0], value[1], value[2], value[3], value[4], value[5], value[6], value[7],
                           value[8], value[9], value[10], value[11], value[12], value[13], value[14], value[15]))
    }
}

/// Exact metadata and identifiers narrow local matching; near matches remain review candidates.
private struct ComparisonTrackIndex {
    var exact: [String: [Track]] = [:]
    var byISRC: [String: [Track]] = [:]
    var byWord: [String: [Track]] = [:]
    var byPlayableID: [String: [Track]] = [:]
    init(_ tracks: [Track]) {
        var seen = Set<Track>()
        for track in tracks where seen.insert(track).inserted {
            exact[Self.key(track), default: []].append(track)
            if let code = Self.code(track.isrc) { byISRC[code, default: []].append(track) }
            for word in Set(CatalogMatcher.normalized(track.title).split(separator: " ").map(String.init)) {
                byWord[word, default: []].append(track)
            }
            byPlayableID[track.playableID, default: []].append(track)
        }
    }
    func candidates(for source: Track) -> [Track] {
        var result = Set(exact[Self.key(source), default: []])
        if let code = Self.code(source.isrc) { result.formUnion(byISRC[code, default: []]) }
        if result.isEmpty {
            let words = CatalogMatcher.normalized(source.title).split(separator: " ").map(String.init)
            let broad = Set(words.flatMap { byWord[$0, default: []] })
            result.formUnion(broad.filter { CatalogMatcher.similar(source.title, $0.title) && CatalogMatcher.similar(source.artist, $0.artist) })
        }
        for id in Set(result.map(\.playableID)) { result.formUnion(byPlayableID[id, default: []]) }
        return result.sorted { [$0.id, $0.playableID, $0.title, $0.artist, $0.albumTitle, String($0.durationMS)]
            .lexicographicallyPrecedes([$1.id, $1.playableID, $1.title, $1.artist, $1.albumTitle, String($1.durationMS)]) }
    }
    static func key(_ track: Track) -> String { ComparisonIdentity.digest([CatalogMatcher.normalized(track.title), CatalogMatcher.normalized(track.artist)]) }
    static func code(_ value: String?) -> String? {
        guard let value else { return nil }
        let code = CatalogMatcher.normalized(value).replacingOccurrences(of: " ", with: "")
        return code.isEmpty ? nil : code
    }
}
