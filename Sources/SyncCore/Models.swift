import Foundation
import CryptoKit

public enum MusicService: String, Codable, CaseIterable, Sendable, Identifiable {
    case spotify, appleMusic
    public var id: String { rawValue }
    public var name: String { self == .spotify ? "Spotify" : "Apple Music" }
    public var other: MusicService { self == .spotify ? .appleMusic : .spotify }
}

public struct ConnectedAccount: Codable, Equatable, Sendable {
    public var id: String
    public var service: MusicService
    public var displayName: String
    public var storefront: String?
    public var connectionRevision: String
    public init(id: String, service: MusicService, displayName: String, storefront: String? = nil, connectionRevision: String = UUID().uuidString) {
        self.id = id; self.service = service; self.displayName = displayName
        self.storefront = storefront; self.connectionRevision = connectionRevision
    }
}

public struct Track: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var catalogID: String?
    public var title: String
    public var artist: String
    public var albumTitle: String
    public var durationMS: Int
    public var isrc: String?
    public var explicit: Bool?
    public var available: Bool
    public var isLocal: Bool
    public var url: String?
    public var artistNames: [String]?
    public var albumID: String?
    public var releaseDate: String?
    public var discNumber: Int?
    public var trackNumber: Int?
    public var artworkURL: String?
    public init(id: String, catalogID: String? = nil, title: String, artist: String, albumTitle: String = "", durationMS: Int = 0, isrc: String? = nil, explicit: Bool? = nil, available: Bool = true, isLocal: Bool = false) {
        self.id = id; self.catalogID = catalogID; self.title = title; self.artist = artist
        self.albumTitle = albumTitle; self.durationMS = durationMS; self.isrc = isrc
        self.explicit = explicit; self.available = available; self.isLocal = isLocal
    }
    public var playableID: String { catalogID ?? id }
}

public struct Album: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var catalogID: String?
    public var title: String
    public var artist: String
    public var upc: String?
    public var tracks: [Track]
    public var isCompleteAlbum: Bool
    public var available: Bool
    public var artworkURL: String?
    public init(id: String, catalogID: String? = nil, title: String, artist: String, upc: String? = nil, tracks: [Track] = [], isCompleteAlbum: Bool = true, available: Bool = true) {
        self.id = id; self.catalogID = catalogID; self.title = title; self.artist = artist
        self.upc = upc; self.tracks = tracks; self.isCompleteAlbum = isCompleteAlbum; self.available = available
    }
    public var playableID: String { catalogID ?? id }
}

public enum PlaylistOwnership: String, Codable, Sendable { case owned, collaborative, followed, system, unknown }

public struct Playlist: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var description: String
    public var tracks: [Track]
    public var editable: Bool
    public var ownership: PlaylistOwnership
    public var contentsComplete: Bool
    public var version: String?
    public var artworkURL: String?
    public init(id: String, name: String, description: String = "", tracks: [Track] = [], editable: Bool = true, ownership: PlaylistOwnership = .owned, contentsComplete: Bool = true, version: String? = nil) {
        self.id = id; self.name = name; self.description = description; self.tracks = tracks
        self.editable = editable; self.ownership = ownership; self.contentsComplete = contentsComplete; self.version = version
    }
}

public struct InventoryCoverage: Codable, Equatable, Sendable {
    public var playlists: Bool
    public var tracks: Bool
    public var albums: Bool
    public var notes: [String]
    public init(playlists: Bool = true, tracks: Bool = true, albums: Bool = true, notes: [String] = []) {
        self.playlists = playlists; self.tracks = tracks; self.albums = albums; self.notes = notes
    }
    public var complete: Bool { playlists && tracks && albums }
}

public struct LibrarySnapshot: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var account: ConnectedAccount
    public var fetchedAt: Date
    public var playlists: [Playlist]
    public var savedTracks: [Track]
    public var savedAlbums: [Album]
    public var coverage: InventoryCoverage
    public init(id: UUID = UUID(), account: ConnectedAccount, fetchedAt: Date = Date(), playlists: [Playlist] = [], savedTracks: [Track] = [], savedAlbums: [Album] = [], coverage: InventoryCoverage = .init()) {
        self.id = id; self.account = account; self.fetchedAt = fetchedAt; self.playlists = playlists
        self.savedTracks = savedTracks; self.savedAlbums = savedAlbums; self.coverage = coverage
    }
    public var complete: Bool { coverage.complete && playlists.allSatisfy(\.contentsComplete) }
    public var allTracks: [Track] {
        var seen = Set<String>()
        return (savedTracks + playlists.flatMap(\.tracks) + savedAlbums.flatMap(\.tracks)).filter { seen.insert($0.id).inserted }
    }
    public var looseTracks: [Track] {
        let included = Set(playlists.flatMap(\.tracks).map(\.playableID))
        return savedTracks.filter { !included.contains($0.playableID) }
    }
    public var stateFingerprint: String {
        var stable = self
        stable.id = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        stable.fetchedAt = Date(timeIntervalSince1970: 0)
        stable.playlists.sort { $0.id < $1.id }
        // Artwork is presentation metadata and may rotate independently of music.
        for index in stable.playlists.indices { stable.playlists[index].artworkURL = nil }
        stable.savedTracks.sort { $0.id < $1.id }
        stable.savedAlbums.sort { $0.id < $1.id }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: (try? encoder.encode(stable)) ?? Data()).map { String(format: "%02x", $0) }.joined()
    }
}

public enum SyncMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case merge, spotifyBase, appleMusicBase
    public var id: String { rawValue }
    public var title: String {
        switch self { case .merge: return "Fusionar sin eliminar"; case .spotifyBase: return "Spotify como base"; case .appleMusicBase: return "Apple Music como base" }
    }
    public var base: MusicService? {
        switch self { case .merge: return nil; case .spotifyBase: return .spotify; case .appleMusicBase: return .appleMusic }
    }
}

public enum OperationKind: String, Codable, CaseIterable, Sendable {
    case createPlaylist, removePlaylist, renamePlaylist, replacePlaylistTracks, addPlaylistTracks
    case saveTracks, removeTracks, saveAlbums, removeAlbums
    public var isDestructive: Bool { [.removePlaylist, .replacePlaylistTracks, .removeTracks, .removeAlbums].contains(self) }
    public var label: String {
        switch self {
        case .createPlaylist: return "Crear playlist"
        case .removePlaylist: return "Quitar playlist de la biblioteca"
        case .renamePlaylist: return "Actualizar playlist"
        case .replacePlaylistTracks: return "Igualar canciones y orden"
        case .addPlaylistTracks: return "Agregar a playlist"
        case .saveTracks: return "Guardar canción"
        case .removeTracks: return "Quitar canción de la biblioteca"
        case .saveAlbums: return "Guardar álbum"
        case .removeAlbums: return "Quitar álbum de la biblioteca"
        }
    }
}

public struct ProviderCapabilities: Codable, Equatable, Sendable {
    public var supported: Set<OperationKind>
    public var notes: [String]
    public init(supported: Set<OperationKind>, notes: [String] = []) { self.supported = supported; self.notes = notes }
    public static let spotify = ProviderCapabilities(supported: Set(OperationKind.allCases))
    public static let appleMusic = ProviderCapabilities(supported: [.createPlaylist, .addPlaylistTracks, .saveTracks, .saveAlbums], notes: ["Apple Music no documenta bajas ni reordenamiento general mediante su API pública."])
}

public struct SyncOperation: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var service: MusicService
    public var kind: OperationKind
    public var targetID: String?
    public var title: String
    public var detail: String
    public var playlistName: String?
    public var playlistDescription: String?
    public var tracks: [Track]
    public var albums: [Album]
    public var beforeTrackIDs: [String]?
    public var blockedReason: String?
    public var sourcePlaylist: PlaylistReference?
    public init(id: UUID = UUID(), service: MusicService, kind: OperationKind, targetID: String? = nil, title: String, detail: String = "", playlistName: String? = nil, playlistDescription: String? = nil, tracks: [Track] = [], albums: [Album] = [], beforeTrackIDs: [String]? = nil, blockedReason: String? = nil) {
        self.id = id; self.service = service; self.kind = kind; self.targetID = targetID; self.title = title
        self.detail = detail; self.playlistName = playlistName; self.playlistDescription = playlistDescription
        self.tracks = tracks; self.albums = albums; self.beforeTrackIDs = beforeTrackIDs; self.blockedReason = blockedReason
    }
}

public enum MatchConfidence: String, Codable, Sendable { case exact, review, unavailable }
public struct TrackMatch: Codable, Equatable, Sendable, Identifiable {
    public var sourceService: MusicService
    public var source: Track
    public var candidates: [Track]
    public var selected: Track?
    public var confidence: MatchConfidence
    public var reason: String
    public var decision: TrackDecision?
    public var searchCoverage: SearchCoverage?
    public var searchNotes: [String]?
    public var searchStages: [SearchStage]?
    public var rejectedCandidateIDs: [String]?
    public var id: String { "\(sourceService.rawValue):\(source.id)" }
    public init(sourceService: MusicService, source: Track, candidates: [Track] = [], selected: Track? = nil, confidence: MatchConfidence = .review, reason: String = "") {
        self.sourceService = sourceService; self.source = source; self.candidates = candidates
        self.selected = selected; self.confidence = confidence; self.reason = reason
    }
}

public struct AlbumMatch: Codable, Equatable, Sendable, Identifiable {
    public var sourceService: MusicService
    public var source: Album
    public var candidates: [Album]
    public var selected: Album?
    public var confidence: MatchConfidence
    public var reason: String
    public var id: String { "\(sourceService.rawValue):\(source.id)" }
    public init(sourceService: MusicService, source: Album, candidates: [Album] = [], selected: Album? = nil, confidence: MatchConfidence = .review, reason: String = "") {
        self.sourceService = sourceService; self.source = source; self.candidates = candidates
        self.selected = selected; self.confidence = confidence; self.reason = reason
    }
}

public struct PlaylistLink: Codable, Equatable, Sendable {
    public var spotifyID: String
    public var appleMusicID: String
    public init(spotifyID: String, appleMusicID: String) { self.spotifyID = spotifyID; self.appleMusicID = appleMusicID }
}

public struct MatchDecisions: Codable, Equatable, Sendable {
    public var tracks: [TrackMatch]
    public var albums: [AlbumMatch]
    public var playlists: [PlaylistLink]
    public var protectedPlaylistIDs: [MusicService: Set<String>]
    public init(tracks: [TrackMatch] = [], albums: [AlbumMatch] = [], playlists: [PlaylistLink] = [], protectedPlaylistIDs: [MusicService: Set<String>] = [:]) {
        self.tracks = tracks; self.albums = albums; self.playlists = playlists; self.protectedPlaylistIDs = protectedPlaylistIDs
    }
}

public struct PlanIssue: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    public var detail: String
    public var service: MusicService?
    public init(id: UUID = UUID(), title: String, detail: String, service: MusicService? = nil) { self.id = id; self.title = title; self.detail = detail; self.service = service }
}

public struct SyncPlan: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var createdAt: Date
    public var mode: SyncMode
    public var snapshots: [LibrarySnapshot]
    public var operations: [SyncOperation]
    public var issues: [PlanIssue]
    public var request: SyncRequest?
    public var undoOfRunID: UUID?
    public init(id: UUID = UUID(), createdAt: Date = Date(), mode: SyncMode, snapshots: [LibrarySnapshot], operations: [SyncOperation], issues: [PlanIssue] = [], request: SyncRequest? = nil) {
        self.id = id; self.createdAt = createdAt; self.mode = mode; self.snapshots = snapshots; self.operations = operations; self.issues = issues
        self.request = request
    }
    public var executable: [SyncOperation] { operations.filter { $0.blockedReason == nil } }
}

public struct MutationReceipt: Codable, Equatable, Sendable {
    public var createdID: String?
    public var message: String
    public init(createdID: String? = nil, message: String = "") { self.createdID = createdID; self.message = message }
}

public enum ProviderError: Error, LocalizedError, Sendable {
    case notConnected, unauthorized, forbidden(String), rateLimited(seconds: Int), quotaExceeded
    case unsupported(String), invalidResponse(String), network(String), uncertainWrite(String)
    public var errorDescription: String? {
        switch self {
        case .notConnected: return "Conectá la cuenta para continuar."
        case .unauthorized: return "La autorización venció. Volvé a conectar la cuenta."
        case .forbidden(let s), .unsupported(let s), .invalidResponse(let s), .network(let s), .uncertainWrite(let s): return s
        case .rateLimited(let seconds): return "El servicio pidió esperar \(seconds) segundos."
        case .quotaExceeded: return "Se agotó la cuota del servicio. Reanudá más tarde."
        }
    }
}

public protocol MusicProvider: Sendable {
    var service: MusicService { get }
    func account() async throws -> ConnectedAccount
    func capabilities() async -> ProviderCapabilities
    func fetchLibrary() async throws -> LibrarySnapshot
    func searchTracks(matching track: Track) async throws -> [Track]
    func searchCatalog(_ query: TrackSearchQuery) async throws -> TrackSearchResult
    func catalogTrack(id: String) async throws -> Track?
    func searchAlbums(matching album: Album) async throws -> [Album]
    func perform(_ operation: SyncOperation) async throws -> MutationReceipt
}
