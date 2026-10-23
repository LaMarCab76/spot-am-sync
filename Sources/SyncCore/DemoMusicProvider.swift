import Foundation

/// An isolated, in-memory provider. It never contacts a music service or shares credentials.
public actor DemoMusicProvider: MusicProvider {
    public nonisolated let service: MusicService
    private var snapshot: LibrarySnapshot
    private let catalogTracks: [Track]
    private let catalogAlbums: [Album]
    public init(snapshot: LibrarySnapshot, catalogTracks: [Track] = [], catalogAlbums: [Album] = []) {
        self.service = snapshot.account.service; self.snapshot = snapshot
        self.catalogTracks = catalogTracks + snapshot.allTracks
        self.catalogAlbums = catalogAlbums + snapshot.savedAlbums
    }
    public func account() async throws -> ConnectedAccount { snapshot.account }
    public func capabilities() async -> ProviderCapabilities { service == .spotify ? .spotify : .appleMusic }
    public func fetchLibrary() async throws -> LibrarySnapshot {
        var copy = snapshot; copy.id = UUID(); copy.fetchedAt = Date(); return copy
    }
    public func searchTracks(matching track: Track) async throws -> [Track] {
        var seen = Set<String>()
        return catalogTracks.filter {
            (($0.isrc != nil && $0.isrc == track.isrc) || $0.title.localizedCaseInsensitiveContains(track.title)) && seen.insert($0.id).inserted
        }
    }
    public func searchAlbums(matching album: Album) async throws -> [Album] {
        var seen = Set<String>()
        return catalogAlbums.filter {
            (($0.upc != nil && $0.upc == album.upc) || $0.title.localizedCaseInsensitiveContains(album.title)) && seen.insert($0.id).inserted
        }
    }
    public func perform(_ operation: SyncOperation) async throws -> MutationReceipt {
        guard operation.service == service, (await capabilities()).supported.contains(operation.kind) else { throw ProviderError.unsupported("Operación no disponible en este servicio.") }
        // Let the user observe progress and cancellation in the explicitly marked demo.
        try await Task.sleep(nanoseconds: 750_000_000)
        switch operation.kind {
        case .createPlaylist:
            let id = "demo-created-" + UUID().uuidString
            snapshot.playlists.append(Playlist(id: id, name: operation.playlistName ?? operation.title, description: operation.playlistDescription ?? "", tracks: operation.tracks))
            return MutationReceipt(createdID: id)
        case .removePlaylist:
            snapshot.playlists.removeAll { $0.id == operation.targetID }
        case .renamePlaylist, .replacePlaylistTracks, .addPlaylistTracks:
            guard let index = snapshot.playlists.firstIndex(where: { $0.id == operation.targetID }) else { throw ProviderError.invalidResponse("No se encontró la playlist.") }
            if let expected = operation.beforeTrackIDs, expected != snapshot.playlists[index].tracks.map(\.playableID) { throw SyncExecutionError.stale("La playlist cambió.") }
            switch operation.kind {
            case .renamePlaylist:
                if let name = operation.playlistName { snapshot.playlists[index].name = name }
                if let description = operation.playlistDescription { snapshot.playlists[index].description = description }
            case .replacePlaylistTracks: snapshot.playlists[index].tracks = operation.tracks
            case .addPlaylistTracks: snapshot.playlists[index].tracks.append(contentsOf: operation.tracks)
            default: break
            }
            snapshot.playlists[index].version = UUID().uuidString
        case .saveTracks:
            for track in operation.tracks where !snapshot.savedTracks.contains(where: { $0.playableID == track.playableID }) { snapshot.savedTracks.append(track) }
        case .removeTracks:
            let ids = Set(operation.tracks.map(\.playableID)); snapshot.savedTracks.removeAll { ids.contains($0.playableID) }
        case .saveAlbums:
            for album in operation.albums where !snapshot.savedAlbums.contains(where: { $0.playableID == album.playableID }) { snapshot.savedAlbums.append(album) }
        case .removeAlbums:
            let ids = Set(operation.albums.map(\.playableID)); snapshot.savedAlbums.removeAll { ids.contains($0.playableID) }
        }
        return MutationReceipt()
    }
}
