import Foundation

/// Every execution represents at most one mutating HTTP request in the official adapters.
/// IDs and dependencies are persisted before dispatch; the approved plan remains unchanged.
enum MutationBatches {
    static func executions(_ operations: [SyncOperation]) -> [OperationExecution] {
        operations.flatMap { operation in
            var result: [OperationExecution] = []
            func add(_ op: SyncOperation, createdBy: UUID? = nil) {
                var step = OperationExecution(operation: op)
                step.parentOperationID = operation.id; step.createdByOperationID = createdBy
                result.append(step)
            }
            func trackChunks(_ tracks: [Track], size: Int) -> [[Track]] {
                stride(from: 0, to: tracks.count, by: size).map { Array(tracks[$0..<min($0 + size, tracks.count)]) }
            }
            switch operation.kind {
            case .saveTracks, .removeTracks, .addPlaylistTracks:
                let size = operation.kind == .addPlaylistTracks ? 100 : operation.service == .spotify ? 40 : 100
                for (index, batch) in trackChunks(operation.tracks, size: size).enumerated() {
                    var part = operation; if index > 0 { part.id = UUID() }; part.tracks = batch
                    add(part)
                }
            case .saveAlbums, .removeAlbums:
                let size = operation.service == .spotify ? 40 : 100
                for start in stride(from: 0, to: operation.albums.count, by: size) {
                    var part = operation; if start > 0 { part.id = UUID() }
                    part.albums = Array(operation.albums[start..<min(start + size, operation.albums.count)])
                    add(part)
                }
            case .createPlaylist:
                var create = operation; create.tracks = []; add(create)
                for batch in trackChunks(operation.tracks, size: 100) {
                    var append = operation; append.id = UUID(); append.kind = .addPlaylistTracks
                    append.tracks = batch; append.targetID = nil
                    add(append, createdBy: create.id)
                }
            case .replacePlaylistTracks:
                var replace = operation; replace.tracks = Array(operation.tracks.prefix(100)); add(replace)
                for batch in trackChunks(Array(operation.tracks.dropFirst(100)), size: 100) {
                    var append = operation; append.id = UUID(); append.kind = .addPlaylistTracks; append.tracks = batch
                    add(append)
                }
            default: add(operation)
            }
            return result
        }
    }
}
