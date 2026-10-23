import Foundation

/// Membership in this account's playlists, based only on identifiers from its snapshot.
public enum PlaylistMembership: Equatable, Sendable {
    case inPlaylist
    case outsidePlaylists
    case unknown
}

public struct SavedTrackMembership: Equatable, Sendable {
    public let track: Track
    public let membership: PlaylistMembership
}

public struct SavedAlbumMembership: Equatable, Sendable {
    public let album: Album
    /// For a partial album this describes only its supplied saved tracks.
    public let membership: PlaylistMembership
    public var classifiesSavedTracksOnly: Bool { !album.isCompleteAlbum }
}

public struct LibraryMembership: Equatable, Sendable {
    /// Includes individually saved tracks and the saved tracks of partial albums, deduplicated by ID aliases.
    public let tracks: [SavedTrackMembership]
    public let albums: [SavedAlbumMembership]
    public let playlistsComplete: Bool
    public let savedTracksComplete: Bool
    public let savedAlbumsComplete: Bool

    /// An incomplete read has no exact outside count: unseen playlists can reduce it,
    /// while unseen saved content can increase it. It must never be displayed as "N+".
    public var outsideTrackCount: Int? {
        guard playlistsComplete, savedTracksComplete, !tracks.contains(where: { $0.membership == .unknown }) else { return nil }
        return tracks.filter { $0.membership == .outsidePlaylists }.count
    }

    /// Partial albums contribute their saved tracks, never a complete album.
    public var outsideCompleteAlbumCount: Int? {
        guard playlistsComplete, savedAlbumsComplete else { return nil }
        let completeAlbums = albums.filter { !$0.classifiesSavedTracksOnly }
        guard !completeAlbums.contains(where: { $0.membership == .unknown }) else { return nil }
        return completeAlbums.filter { $0.membership == .outsidePlaylists }.count
    }
}

extension LibrarySnapshot {
    public var libraryMembership: LibraryMembership {
        let playlistTracks = playlists.flatMap(\.tracks)
        // Do not use allTracks: its ID-only deduplication can discard an alias observed elsewhere.
        let identities = LibraryTrackIdentities(tracks: savedTracks + playlistTracks + savedAlbums.flatMap(\.tracks))
        let included = Set(playlistTracks.compactMap { identities.component(for: $0) })
        let playlistsComplete = coverage.playlists && playlists.allSatisfy(\.contentsComplete) &&
            playlistTracks.allSatisfy { identities.component(for: $0) != nil }

        func membership(of track: Track) -> PlaylistMembership {
            guard let identity = identities.component(for: track) else { return .unknown }
            if included.contains(identity) { return .inPlaylist }
            return playlistsComplete ? .outsidePlaylists : .unknown
        }

        var seen = Set<Int>()
        let individuallySaved = savedTracks + savedAlbums.filter { !$0.isCompleteAlbum }.flatMap(\.tracks)
        let tracks = individuallySaved.compactMap { track -> SavedTrackMembership? in
            if let identity = identities.component(for: track), !seen.insert(identity).inserted { return nil }
            return SavedTrackMembership(track: track, membership: membership(of: track))
        }
        let albums = savedAlbums.map { album in
            let tracks = album.tracks.map { membership(of: $0) }
            let status: PlaylistMembership
            if tracks.contains(.inPlaylist) {
                // Any observed track in a playlist rules out an entirely loose album,
                // even if the album or playlist read is incomplete.
                status = .inPlaylist
            } else if !tracks.isEmpty && tracks.allSatisfy({ $0 == .outsidePlaylists }) {
                status = .outsidePlaylists
            } else {
                status = .unknown
            }
            return SavedAlbumMembership(album: album, membership: status)
        }
        return LibraryMembership(tracks: tracks, albums: albums, playlistsComplete: playlistsComplete,
                                 savedTracksComplete: coverage.tracks && coverage.albums, savedAlbumsComplete: coverage.albums)
    }
}

/// Alias components are rebuilt for a single snapshot, so IDs never cross accounts or services.
/// Album IDs, names, ISRCs and other metadata are deliberately not song identity evidence here.
private struct LibraryTrackIdentities {
    private var components: [String: Int] = [:]

    init(tracks: [Track]) {
        var neighbors: [String: Set<String>] = [:]
        for track in tracks {
            let ids = Self.identifiers(for: track)
            for id in ids { neighbors[id, default: []].formUnion(ids) }
        }
        var nextComponent = 0
        for id in neighbors.keys where components[id] == nil {
            var pending = [id]
            components[id] = nextComponent
            while let current = pending.popLast() {
                for neighbor in neighbors[current, default: []] where components[neighbor] == nil {
                    components[neighbor] = nextComponent
                    pending.append(neighbor)
                }
            }
            nextComponent += 1
        }
    }

    func component(for track: Track) -> Int? {
        Self.identifiers(for: track).compactMap { components[$0] }.first
    }

    private static func identifiers(for track: Track) -> [String] {
        [track.id, track.catalogID].compactMap { value in
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !value.hasPrefix("unknown:") else { return nil }
            return value
        }
    }
}
