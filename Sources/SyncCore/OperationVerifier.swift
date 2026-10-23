import Foundation

public enum OperationVerifier {
    /// Verify provider state, never an HTTP success code. Catalogue IDs are distinct from library IDs.
    public static func receipt(for operation: SyncOperation, before: LibrarySnapshot, after: LibrarySnapshot, receipt: MutationReceipt? = nil) -> MutationReceipt? {
        guard before.complete, after.complete,
              before.account.service == operation.service,
              before.account.id == after.account.id,
              before.account.connectionRevision == after.account.connectionRevision,
              after.account.service == operation.service else { return nil }
        let tracks = operation.tracks.map(\.playableID)
        let albums = operation.albums.map(\.playableID)
        switch operation.kind {
        case .saveTracks:
            guard after.coverage.tracks, Set(tracks).isSubset(of: Set(after.savedTracks.map(\.playableID))) else { return nil }
        case .removeTracks:
            guard after.coverage.tracks, Set(tracks).isDisjoint(with: Set(after.savedTracks.map(\.playableID))) else { return nil }
        case .saveAlbums:
            // A library album can exist with only a subset of its tracks saved.
            // Its identifier alone does not prove that the requested whole album arrived.
            guard after.coverage.albums, Set(albums).isSubset(of: Set(after.savedAlbums.filter(\.isCompleteAlbum).map(\.playableID))) else { return nil }
        case .removeAlbums:
            guard after.coverage.albums, Set(albums).isDisjoint(with: Set(after.savedAlbums.map(\.playableID))) else { return nil }
        case .removePlaylist:
            guard let id = operation.targetID, after.coverage.playlists, !after.playlists.contains(where: { $0.id == id }) else { return nil }
        case .createPlaylist:
            guard after.coverage.playlists else { return nil }
            let previousIDs = Set(before.playlists.map(\.id))
            let candidates = after.playlists.filter { playlist in
                let isNew = !previousIDs.contains(playlist.id) && (receipt?.createdID.map { $0 == playlist.id } ?? true)
                return isNew && playlist.contentsComplete && playlist.name == operation.playlistName &&
                    (operation.playlistDescription.map { playlist.description == $0 } ?? true) && playlist.tracks.map(\.playableID) == tracks
            }
            guard candidates.count == 1 else { return nil }
            return MutationReceipt(createdID: candidates[0].id, message: "Playlist y contenido verificados mediante lectura.")
        case .renamePlaylist:
            guard let p = after.playlists.first(where: { $0.id == operation.targetID }),
                  let old = before.playlists.first(where: { $0.id == operation.targetID }),
                  p.contentsComplete, p.tracks.map(\.playableID) == old.tracks.map(\.playableID),
                  operation.playlistName.map({ p.name == $0 }) ?? true,
                  operation.playlistDescription.map({ p.description == $0 }) ?? true else { return nil }
        case .replacePlaylistTracks:
            guard let p = after.playlists.first(where: { $0.id == operation.targetID }),
                  let old = before.playlists.first(where: { $0.id == operation.targetID }),
                  p.name == old.name, p.description == old.description,
                  p.contentsComplete, p.tracks.map(\.playableID) == tracks else { return nil }
        case .addPlaylistTracks:
            guard let old = before.playlists.first(where: { $0.id == operation.targetID }),
                  let p = after.playlists.first(where: { $0.id == operation.targetID }),
                  old.contentsComplete, p.contentsComplete,
                  p.name == old.name, p.description == old.description,
                  p.tracks.map(\.playableID) == old.tracks.map(\.playableID) + tracks else { return nil }
        }
        return receipt ?? MutationReceipt(message: "Cambio verificado mediante lectura.")
    }

    /// Detect external changes and library side effects outside the approved operations.
    /// A successful operation must not silently become approval for a different inventory.
    public static func unrelatedStateUnchanged(operations: [SyncOperation], before: LibrarySnapshot, after: LibrarySnapshot) -> Bool {
        guard before.complete, after.complete, before.account.id == after.account.id,
              before.account.service == after.account.service,
              before.account.connectionRevision == after.account.connectionRevision else { return false }
        if before.stateFingerprint == after.stateFingerprint { return true }
        var lhs = before, rhs = after
        for op in operations {
            switch op.kind {
            case .saveTracks, .removeTracks:
                let ids = Set(op.tracks.map(\.playableID))
                lhs.savedTracks.removeAll { ids.contains($0.playableID) }
                rhs.savedTracks.removeAll { ids.contains($0.playableID) }
            case .saveAlbums, .removeAlbums:
                let ids = Set(op.albums.map(\.playableID))
                lhs.savedAlbums.removeAll { ids.contains($0.playableID) }
                rhs.savedAlbums.removeAll { ids.contains($0.playableID) }
            case .createPlaylist:
                let oldIDs = Set(before.playlists.map(\.id))
                let created = after.playlists.filter { !oldIDs.contains($0.id) && $0.name == op.playlistName && $0.tracks.map(\.playableID) == op.tracks.map(\.playableID) }
                guard created.count == 1 else { return false }
                rhs.playlists.removeAll { $0.id == created[0].id }
            case .removePlaylist, .renamePlaylist, .replacePlaylistTracks, .addPlaylistTracks:
                lhs.playlists.removeAll { $0.id == op.targetID }
                rhs.playlists.removeAll { $0.id == op.targetID }
            }
        }
        return lhs.stateFingerprint == rhs.stateFingerprint
    }

    public static func targetUnchanged(_ operation: SyncOperation, before: LibrarySnapshot, after: LibrarySnapshot) -> Bool {
        guard before.complete, after.complete, before.account.id == after.account.id,
              before.account.service == after.account.service,
              before.account.connectionRevision == after.account.connectionRevision else { return false }
        switch operation.kind {
        case .saveTracks, .removeTracks:
            let ids = Set(operation.tracks.map(\.playableID))
            return Set(before.savedTracks.filter { ids.contains($0.playableID) }) == Set(after.savedTracks.filter { ids.contains($0.playableID) })
        case .saveAlbums, .removeAlbums:
            let ids = Set(operation.albums.map(\.playableID))
            return Set(before.savedAlbums.filter { ids.contains($0.playableID) }) == Set(after.savedAlbums.filter { ids.contains($0.playableID) })
        case .createPlaylist:
            return Set(before.playlists.map(\.id)) == Set(after.playlists.map(\.id))
        default:
            return before.playlists.first { $0.id == operation.targetID } == after.playlists.first { $0.id == operation.targetID }
        }
    }

    static func isIdempotentLibraryWrite(_ operation: SyncOperation) -> Bool {
        [.saveTracks, .removeTracks, .saveAlbums, .removeAlbums].contains(operation.kind)
    }
}
