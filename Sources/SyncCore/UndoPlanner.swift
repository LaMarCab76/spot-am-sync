import Foundation

/// Undo is another reviewed plan, never a flag on a history entry. A full-state
/// comparison prevents undoing somebody else's later edits or ambiguous writes.
public enum UndoPlanner {
    public static func makePlan(record: RunRecord, current: [LibrarySnapshot], capabilities: [MusicService: ProviderCapabilities], decisions: MatchDecisions? = nil) -> SyncPlan {
        var result = SyncPlan(mode: record.plan.mode, snapshots: current, operations: [])
        result.undoOfRunID = record.id
        func issue(_ text: String) -> PlanIssue { PlanIssue(title: "No se puede deshacer este cambio", detail: text) }
        guard !record.executions.contains(where: { $0.state == .unknown || $0.state == .applying || (($0.state == .failed || $0.state == .pending) && $0.before != nil) }) else {
            result.issues = [issue("Hay escrituras inciertas. Comprobá primero los resultados pendientes.")]; return result
        }
        let expected = record.finalSnapshots.isEmpty ? record.checkpoints : record.finalSnapshots
        guard current.count == 2, expected.count == 2, current.allSatisfy(\.complete), expected.allSatisfy(\.complete),
              expected.allSatisfy({ old in
                  guard let fresh = current.first(where: { $0.account.service == old.account.service }),
                        fresh.account.id == old.account.id, fresh.account.storefront == old.account.storefront else { return false }
                  var rebound = old; rebound.account.connectionRevision = fresh.account.connectionRevision
                  return rebound.stateFingerprint == fresh.stateFingerprint
              }) else {
            result.issues = [issue("Las cuentas o bibliotecas cambiaron desde la ejecución. Se conserva el contenido actual.")]; return result
        }
        var handled = Set<String>()
        let createdIDs = Set(record.executions.filter { $0.state == .verified && $0.operation.kind == .createPlaylist }
            .compactMap { step in step.receipt?.createdID.map { "\(step.operation.service.rawValue):\($0)" } })
        func blocked(_ operation: SyncOperation) -> SyncOperation {
            var op = operation
            if capabilities[op.service]?.supported.contains(op.kind) != true {
                op.blockedReason = "\(op.service.name) no permite esta operación inversa mediante la integración disponible."
            }
            if let target = op.targetID, let playlist = current.first(where: { $0.account.service == op.service })?.playlists.first(where: { $0.id == target }) {
                let protection = decisions ?? record.decisions
                if protection.protectedPlaylistIDs[op.service, default: []].contains(target) {
                    op.blockedReason = "La playlist está protegida por una decisión explícita."
                } else if !playlist.editable || ![PlaylistOwnership.owned, .collaborative].contains(playlist.ownership) || (op.kind == .removePlaylist && playlist.ownership != .owned) {
                    op.blockedReason = "La playlist no permite esta operación inversa con los permisos actuales."
                }
            }
            return op
        }
        for step in record.executions.reversed() where step.state == .verified {
            let op = step.operation
            guard let before = record.plan.snapshots.first(where: { $0.account.service == op.service }),
                  let after = current.first(where: { $0.account.service == op.service }) else { continue }
            let target = op.targetID ?? step.receipt?.createdID ?? ""
            let group: String
            switch op.kind {
            case .createPlaylist, .addPlaylistTracks, .replacePlaylistTracks, .removePlaylist, .renamePlaylist: group = "playlist:\(target)"
            case .saveTracks, .removeTracks: group = "tracks"
            case .saveAlbums, .removeAlbums: group = "albums"
            }
            let key = "\(op.service.rawValue):\(group)"
            guard handled.insert(key).inserted else { continue }
            if createdIDs.contains("\(op.service.rawValue):\(target)") {
                guard let playlist = after.playlists.first(where: { $0.id == target }) else { continue }
                result.operations.append(blocked(SyncOperation(service: op.service, kind: .removePlaylist, targetID: target,
                    title: "Deshacer creación de «\(playlist.name)»", beforeTrackIDs: playlist.tracks.map(\.playableID))))
                continue
            }
            switch op.kind {
            case .createPlaylist: break
            case .removePlaylist:
                result.issues.append(issue("Una playlist quitada no puede recuperar automáticamente su ID, enlaces y seguidores originales."))
            case .addPlaylistTracks, .replacePlaylistTracks, .renamePlaylist:
                guard let old = before.playlists.first(where: { $0.id == target }), let fresh = after.playlists.first(where: { $0.id == target }) else {
                    result.issues.append(issue("Falta la identidad de la playlist original.")); continue
                }
                if old.name != fresh.name || old.description != fresh.description {
                    result.operations.append(blocked(SyncOperation(service: op.service, kind: .renamePlaylist, targetID: target,
                        title: "Restaurar nombre de «\(old.name)»", playlistName: old.name, playlistDescription: old.description)))
                }
                if old.tracks.map(\.playableID) != fresh.tracks.map(\.playableID) {
                    result.operations.append(blocked(SyncOperation(service: op.service, kind: .replacePlaylistTracks, targetID: target,
                        title: "Restaurar canciones de «\(old.name)»", tracks: old.tracks, beforeTrackIDs: fresh.tracks.map(\.playableID))))
                }
            case .saveTracks, .removeTracks:
                let old = Set(before.savedTracks.map(\.playableID)), now = Set(after.savedTracks.map(\.playableID))
                for (kind, tracks) in [(OperationKind.removeTracks, after.savedTracks.filter { !old.contains($0.playableID) }),
                                       (.saveTracks, before.savedTracks.filter { !now.contains($0.playableID) })] where !tracks.isEmpty {
                    result.operations.append(blocked(SyncOperation(service: op.service, kind: kind, title: "Deshacer cambios en canciones guardadas", tracks: tracks)))
                }
            case .saveAlbums, .removeAlbums:
                let old = Set(before.savedAlbums.map(\.playableID)), now = Set(after.savedAlbums.map(\.playableID))
                for (kind, albums) in [(OperationKind.removeAlbums, after.savedAlbums.filter { !old.contains($0.playableID) }),
                                       (.saveAlbums, before.savedAlbums.filter { !now.contains($0.playableID) })] where !albums.isEmpty {
                    result.operations.append(blocked(SyncOperation(service: op.service, kind: kind, title: "Deshacer cambios en álbumes guardados", albums: albums)))
                }
            }
        }
        return result
    }
}
