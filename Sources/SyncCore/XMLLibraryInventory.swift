import Foundation

/// Structure observed in one XML export; completeness never describes the live cloud account.
public struct XMLLibraryInventory: Codable, Equatable, Sendable {
    public var playlists: [XMLMusicPlaylist]
    /// Keyed by the imported Track.id, not by the export-local numeric reference.
    public var trackInfo: [String: XMLTrackInfo]
    public var playlistsComplete: Bool

    public init(playlists: [XMLMusicPlaylist] = [], trackInfo: [String: XMLTrackInfo] = [:],
                playlistsComplete: Bool = true) {
        self.playlists = playlists
        self.trackInfo = trackInfo
        self.playlistsComplete = playlistsComplete
    }
}

public enum XMLPlaylistKind: String, Codable, Equatable, Sendable {
    case regular, folder, smart, system, unknown
}

public struct XMLMusicPlaylist: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    /// Export order is significant, including repeated references to the same song.
    public var trackIDs: [String]
    public var kind: XMLPlaylistKind
    public var parentID: String?
    public var contentsComplete: Bool
    public var artworkURL: String?

    public init(id: String, name: String, trackIDs: [String] = [], kind: XMLPlaylistKind = .regular,
                parentID: String? = nil, contentsComplete: Bool = true, artworkURL: String? = nil) {
        self.id = id
        self.name = name
        self.trackIDs = trackIDs
        self.kind = kind
        self.parentID = parentID
        self.contentsComplete = contentsComplete
        self.artworkURL = artworkURL
    }
}

public struct XMLTrackInfo: Codable, Equatable, Sendable {
    public var persistentID: String?
    public var referenceID: Int
    /// A playlist observation does not establish membership in saved songs or a complete album.
    public var playlistOnly: Bool?

    public init(persistentID: String? = nil, referenceID: Int, playlistOnly: Bool? = nil) {
        self.persistentID = persistentID
        self.referenceID = referenceID
        self.playlistOnly = playlistOnly
    }
}
