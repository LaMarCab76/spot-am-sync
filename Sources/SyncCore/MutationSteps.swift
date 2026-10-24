import Foundation

public struct MutationLimits: Sendable {
    public let libraryItems: Int
    public let playlistItems: Int
    public init(libraryItems: Int, playlistItems: Int) {
        self.libraryItems = max(1, libraryItems); self.playlistItems = max(1, playlistItems)
    }
}

/// Expand approved operations before persisting the journal. Library items retain
/// individual verification while the executor coalesces them into one HTTP request.
/// Playlist writes have one journal entry per request, including the empty creation.
enum MutationSteps {
    static func prepare(_ operation: SyncOperation, limits: MutationLimits?) -> [OperationExecution] {
        guard let limits else {
            // Keep playlist request boundaries in demos and custom providers too.
            if [.createPlaylist, .replacePlaylistTracks, .addPlaylistTracks].contains(operation.kind) {
                return prepare(operation, limits: .init(libraryItems: 40, playlistItems: 100))
            }
            return [OperationExecution(operation: operation)]
        }
        var parts: [SyncOperation] = []
        switch operation.kind {
        case .saveTracks, .removeTracks:
            parts = operation.tracks.map { track in
                var part = operation; part.tracks = [track]; return part
            }
        case .saveAlbums, .removeAlbums:
            parts = operation.albums.map { album in
                var part = operation; part.albums = [album]; return part
            }
        case .createPlaylist, .replacePlaylistTracks, .addPlaylistTracks:
            var previous = operation.beforeTrackIDs
            var remaining = operation.tracks
            if operation.kind == .createPlaylist {
                var creation = operation; creation.tracks = []; parts.append(creation); previous = []
            } else if operation.kind == .replacePlaylistTracks {
                var replacement = operation; replacement.tracks = Array(remaining.prefix(limits.playlistItems))
                parts.append(replacement); previous = replacement.tracks.map(\.playableID)
                remaining = Array(remaining.dropFirst(limits.playlistItems))
            }
            while !remaining.isEmpty {
                var append = operation
                append.kind = .addPlaylistTracks
                append.tracks = Array(remaining.prefix(limits.playlistItems))
                append.beforeTrackIDs = previous
                parts.append(append)
                previous = previous.map { $0 + append.tracks.map(\.playableID) }
                remaining = Array(remaining.dropFirst(limits.playlistItems))
            }
        default: parts = [operation]
        }
        if parts.isEmpty { parts = [operation] }
        for i in parts.indices { parts[i].id = i == 0 ? operation.id : UUID() }
        return parts.enumerated().map { index, part in
            var execution = OperationExecution(operation: part, parentOperationID: operation.id,
                               creationDependencyID: operation.kind == .createPlaylist && index > 0 ? parts[0].id : nil)
            execution.createdByOperationID = execution.creationDependencyID
            return execution
        }
    }
}
