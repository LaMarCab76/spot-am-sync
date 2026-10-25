import Foundation
import Darwin

private final class RunLease {
    private var descriptor: Int32
    init(url: URL) throws {
        descriptor = Darwin.open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw SyncExecutionError.persistence("No se pudo abrir el bloqueo de ejecución.") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor); descriptor = -1; throw SyncExecutionError.busy
        }
    }
    func release() {
        if descriptor >= 0 { flock(descriptor, LOCK_UN); Darwin.close(descriptor); descriptor = -1 }
    }
    deinit { release() }
}

public actor SyncExecutor {
    private let store: SyncStore
    private var active = false
    private var cancelled = false
    private let verificationDelays: [UInt64]
    public init(store: SyncStore, verificationDelays: [UInt64] = [0, 1_000_000_000, 2_000_000_000]) {
        self.store = store; self.verificationDelays = verificationDelays.isEmpty ? [0] : verificationDelays
    }
    public func cancel() { cancelled = true }

    /// Transfer a reviewed local export to Spotify. Only Spotify is re-read;
    /// the local document is immutable evidence, never a fabricated cloud read.
    public func executeSnapshotTransfer(source: SnapshotTransferSource, destination: LibrarySnapshot,
                                        operations: [SyncOperation], decisions: MatchDecisions,
                                        provider: any MusicProvider, isDemo: Bool = false, runID: UUID? = nil,
                                        progress: @escaping @Sendable (SyncProgress) async -> Void = { _ in }) async throws -> RunRecord {
        guard !active, !operations.isEmpty, destination.account.service == .spotify,
              provider.service == .spotify, destination.complete,
              Set(operations.map(\.id)).count == operations.count,
              operations.allSatisfy({ $0.service == .spotify && $0.blockedReason == nil &&
                  ([.createPlaylist, .addPlaylistTracks, .saveTracks, .saveAlbums].contains($0.kind) || source.allowsDestructive == true) &&
                  $0.tracks.allSatisfy({ $0.available && !$0.isLocal && !$0.playableID.isEmpty }) }) else {
            throw SyncExecutionError.invalidSelection
        }
        let plan = SyncPlan(mode: .appleMusicBase, snapshots: [destination], operations: operations)
        let steps = operations.flatMap { MutationSteps.prepare($0, limits: provider.mutationLimits) }
        var record = RunRecord(summary: RunSummary(id: runID ?? UUID(), totalCount: steps.count, message: "Verificando el lote aprobado desde XML…"),
                               plan: plan, decisions: decisions, executions: steps, checkpoints: [destination], isDemo: isDemo)
        record.snapshotSource = source
        return try await run(record, providers: [.spotify: provider], resuming: false, progress: progress)
    }

    public func execute(plan: SyncPlan, selectedIDs: Set<UUID>, decisions: MatchDecisions, providers: [MusicService: any MusicProvider], isDemo: Bool = false, runID: UUID? = nil, scopedApproval: Bool = false, progress: @escaping @Sendable (SyncProgress) async -> Void = { _ in }) async throws -> RunRecord {
        guard !active else { throw SyncExecutionError.busy }
        guard !selectedIDs.isEmpty, selectedIDs.isSubset(of: Set(plan.executable.map(\.id))) else { throw SyncExecutionError.invalidSelection }
        let selected = plan.operations.filter { selectedIDs.contains($0.id) }
        guard plan.snapshots.count == 2, Set(plan.snapshots.map { $0.account.service }).count == 2,
              !selected.contains(where: { plan.mode.base == $0.service }),
              plan.mode != .merge || plan.undoOfRunID != nil || !selected.contains(where: { $0.kind.isDestructive }) else { throw SyncExecutionError.invalidSelection }
        // Sorting ensures additive changes precede destructive operations, while keeping playlist operations stable.
        let ordered = plan.operations.enumerated().filter { selectedIDs.contains($0.element.id) }.sorted {
            let lhs = $0.element.kind.isDestructive ? 1 : 0, rhs = $1.element.kind.isDestructive ? 1 : 0
            return lhs == rhs ? $0.offset < $1.offset : lhs < rhs
        }.map(\.element)
        let steps = ordered.flatMap { MutationSteps.prepare($0, limits: providers[$0.service]?.mutationLimits) }
        let summary = RunSummary(id: runID ?? UUID(), totalCount: steps.count, message: "Verificando el estado aprobado…")
        var approvedPlan = plan
        if scopedApproval { approvedPlan.operations = ordered }
        var record = RunRecord(summary: summary, plan: approvedPlan, decisions: decisions, executions: steps, checkpoints: plan.snapshots, isDemo: isDemo)
        record.scopedApproval = scopedApproval
        return try await run(record, providers: providers, resuming: false, progress: progress)
    }

    public func resume(id: UUID, providers: [MusicService: any MusicProvider], progress: @escaping @Sendable (SyncProgress) async -> Void = { _ in }) async throws -> RunRecord {
        guard !active else { throw SyncExecutionError.busy }
        guard let record = try await store.load(id: id), record.summary.status != .completed else { throw SyncExecutionError.invalidSelection }
        guard record.snapshotSource == nil, record.scopedApproval != true else {
            throw SyncExecutionError.unsafeResume("Las transferencias XML interrumpidas sólo se comprueban mediante lectura. Prepará y confirmá lo pendiente otra vez.")
        }
        return try await run(record, providers: providers, resuming: true, progress: progress)
    }

    /// Recover journal evidence without sending mutations or carrying approval across a restart.
    /// Only a matching stable account ID permits comparison across connection revisions.
    public func reconcile(id: UUID, providers: [MusicService: any MusicProvider], progress: @escaping @Sendable (SyncProgress) async -> Void = { _ in }) async throws -> RunRecord {
        guard !active else { throw SyncExecutionError.busy }
        let lease = try RunLease(url: store.url.appendingPathExtension("sync.lock"))
        active = true
        defer { active = false; lease.release() }
        guard var record = try await store.load(id: id) else { throw SyncExecutionError.invalidSelection }
        record.approvalRevoked = true
        record.remainingPlan = nil
        markInterruptedWritesUnknown(&record)
        try await store.save(record) // Revoke even if a later read or account check fails.
        do {
            try requireCompleteBackup(record)
            await emit(record, "Reconciliando mediante lectura; la aprobación anterior quedó revocada…", progress)
            let current = try await fetchAll(record.plan.snapshots, providers: providers, allowConnectionRebind: true)
            record.finalSnapshots = current
            try reconcileInterrupted(&record, current: current, allowRetry: false, allowConnectionRebind: true)
            record.summary.status = .partial
            record.summary.message = record.executions.contains(where: { $0.state == .unknown })
                ? "Persisten resultados inciertos. No se enviaron escrituras; reconciliá nuevamente cuando el servicio refleje los cambios."
                : "Resultados reconciliados mediante lectura. Se requiere un nuevo análisis y confirmación para aplicar cambios pendientes."
        } catch {
            record.summary.status = .failed
            record.summary.message = error.localizedDescription
            record.summary.logs.append(error.localizedDescription)
        }
        record.summary.verifiedCount = record.executions.filter { $0.state == .verified }.count
        if record.isDemo { record.summary.message = "Demostración: " + record.summary.message }
        try await store.save(record)
        await emit(record, record.summary.message, progress)
        return record
    }

    private func run(_ original: RunRecord, providers: [MusicService: any MusicProvider], resuming: Bool, progress: @escaping @Sendable (SyncProgress) async -> Void) async throws -> RunRecord {
        guard !active else { throw SyncExecutionError.busy }
        let lease = try RunLease(url: store.url.appendingPathExtension("sync.lock"))
        active = true; cancelled = false
        defer { active = false; lease.release() }
        var record = original
        // resume's initial lookup precedes the lease and may have crossed another actor call.
        if resuming {
            guard let saved = try await store.load(id: record.id), saved.summary.status != .completed else { throw SyncExecutionError.invalidSelection }
            record = saved
            markInterruptedWritesUnknown(&record)
        } else if try await store.load(id: record.id) != nil {
            throw SyncExecutionError.invalidSelection
        }
        var unexpectedChanges = false
        do {
            record.summary.status = .running
            record.remainingPlan = nil
            try requireCompleteBackup(record)
            if resuming && record.executions.contains(where: { $0.parentOperationID == nil && providers[$0.operation.service]?.mutationLimits != nil }) {
                throw SyncExecutionError.unsafeResume("Este registro es anterior al journal por petición. Comprobá sus pendientes mediante lectura y confirmá un nuevo análisis.")
            }
            // Publish the approval before provider awaits so a policy change during the very
            // first inventory read can revoke it too.
            if !resuming { try await store.save(record) }
            try await requireApproval(&record)
            let accountIDs = Dictionary(uniqueKeysWithValues: record.plan.snapshots.map { ($0.account.service, $0.account.id) })
            let unresolved = try await store.unresolvedRuns(accountIDs: accountIDs, excluding: record.id)
            guard unresolved.isEmpty else {
                throw SyncExecutionError.unsafeResume("La ejecución \(unresolved[0].id.uuidString) tiene escrituras inciertas para estas cuentas. Reconciliá ese historial antes de iniciar nuevas escrituras.")
            }
            var current = try await fetchAll(record.plan.snapshots, providers: providers)
            if resuming {
                try reconcileInterrupted(&record, current: current, allowRetry: true, allowConnectionRebind: false)
            }
            try validate(current, against: record.checkpoints)
            try await store.save(record) // Durable backup and approval before the first mutation.
            await emit(record, "Respaldo guardado. Bibliotecas verificadas.", progress)

            while let index = record.executions.firstIndex(where: { $0.state == .pending }) {
                if cancellationRequested { break }
                if record.executions.contains(where: { $0.state == .unknown || $0.state == .failed || $0.state == .rejected }) { break }
                current = try await fetchAll(record.plan.snapshots, providers: providers)
                try validate(current, against: record.checkpoints)
                if cancellationRequested { break }

                if let dependency = record.executions[index].creationDependencyID ?? record.executions[index].createdByOperationID {
                    guard let creation = record.executions.first(where: { $0.id == dependency }), creation.state == .verified,
                          let target = creation.receipt?.createdID else {
                        throw SyncExecutionError.unsafeResume("Falta verificar la playlist creada antes de agregarle canciones.")
                    }
                    record.executions[index].operation.targetID = target
                }
                let operation = record.executions[index].operation
                guard let provider = providers[operation.service], let before = current.first(where: { $0.account.service == operation.service }) else { throw SyncExecutionError.missingProvider }
                let capabilities = await provider.capabilities()
                guard capabilities.supported.contains(operation.kind), operation.blockedReason == nil else {
                    throw ProviderError.unsupported("La capacidad para \(operation.kind.label.lowercased()) ya no está disponible.")
                }
                // Library writes are coalesced to reduce readback cost without losing per-operation journaling.
                let indices = batchIndices(starting: index, in: record, limit: provider.mutationLimits?.libraryItems ?? 40)
                let unsent = indices.map { record.executions[$0] }
                for i in indices {
                    record.executions[i].state = .applying
                    // Keep the original evidence when retrying an idempotent library write.
                    if record.executions[i].before == nil { record.executions[i].before = before }
                }
                record.summary.logs.append("\(operation.service.name): \(operation.kind.label) · \(indices.count == 1 ? operation.title : "\(indices.count) cambios")")
                do {
                    try await store.save(record)
                    await emit(record, operation.kind.label + " en " + operation.service.name, progress)
                    try await requireApproval(&record)
                } catch {
                    for (i, previous) in zip(indices, unsent) { record.executions[i] = previous }
                    throw error
                }

                var combined = operation
                if indices.count > 1 {
                    combined.tracks = indices.flatMap { record.executions[$0].operation.tracks }
                    combined.albums = indices.flatMap { record.executions[$0].operation.albums }
                }
                var receipt: MutationReceipt?
                var mutationError: Error?
                // No await between this check and dispatch: progress/store calls can cancel us.
                if cancellationRequested {
                    for (i, previous) in zip(indices, unsent) { record.executions[i] = previous }
                    try await store.save(record)
                    break
                }
                do { receipt = try await provider.perform(combined) }
                catch { mutationError = error }
                for (position, i) in indices.enumerated() {
                    if let receipt { record.executions[i].receipt = receipt }
                    if let mutationError { rememberError(mutationError.localizedDescription, at: i, record: &record) }
                    // A rejected retry cannot erase uncertainty from an earlier send.
                    if (mutationError as? ProviderError)?.definitelyNotApplied == true, unsent[position].before == nil {
                        record.executions[i].state = .rejected
                    }
                }
                try await store.save(record)

                // Writes may be eventually consistent. A cancellation still completes this reconciliation.
                var after: LibrarySnapshot?
                var readError: Error?
                for delay in verificationDelays {
                    if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
                    do {
                        let readback = try await provider.fetchLibrary()
                        after = readback
                        if indices.allSatisfy({ OperationVerifier.receipt(for: record.executions[$0].operation, before: before, after: readback, receipt: receipt) != nil }) { break }
                    } catch { readError = error; break }
                }
                for i in indices {
                    if record.executions[i].state == .rejected { continue }
                    let op = record.executions[i].operation
                    if let after, let verified = OperationVerifier.receipt(for: op, before: before, after: after, receipt: record.executions[i].receipt) {
                        record.executions[i].state = .verified
                        record.executions[i].receipt = verified
                        if let createdID = verified.createdID, op.kind == .createPlaylist {
                            rememberCreatedPlaylist(operation: op, createdID: createdID, record: &record)
                        }
                    } else {
                        // Never assume that an errored write was not applied.
                        record.executions[i].state = .unknown
                        rememberError((readError ?? mutationError)?.localizedDescription ?? "El servicio todavía no refleja el resultado esperado.", at: i, record: &record)
                    }
                }
                if let after {
                    let operations = indices.map { record.executions[$0].operation }
                    let targetsExpected = indices.allSatisfy {
                        record.executions[$0].state == .verified || OperationVerifier.targetUnchanged(record.executions[$0].operation, before: before, after: after)
                    }
                    if targetsExpected && OperationVerifier.unrelatedStateUnchanged(operations: operations, before: before, after: after) {
                        record.checkpoints.removeAll { $0.account.service == after.account.service }
                        record.checkpoints.append(after)
                    } else {
                        unexpectedChanges = true
                        record.summary.logs.append("Se detectaron otros cambios o efectos sobre la biblioteca. Se requiere un nuevo análisis antes de continuar.")
                    }
                }
                record.summary.verifiedCount = record.executions.filter { $0.state == .verified }.count
                try await store.save(record)
                await emit(record, "\(record.summary.verifiedCount) de \(record.summary.totalCount) cambios verificados", progress)
                if unexpectedChanges || record.executions.contains(where: { $0.state == .unknown || $0.state == .rejected }) { break }
            }

            if cancellationRequested {
                markInterruptedWritesUnknown(&record)
                record.summary.status = .cancelled
                record.summary.message = "Cancelado. Los cambios ya aplicados se conservaron y quedaron registrados."
            } else if unexpectedChanges {
                record.summary.status = .partial
                record.summary.message = "El servicio refleja cambios adicionales al plan. Se detuvo la ejecución para que puedas revisar un nuevo análisis."
            } else if record.executions.contains(where: { $0.state == .rejected }) {
                record.summary.status = .partial
                record.summary.message = "El servicio rechazó un lote sin aplicarlo. Los lotes verificados se conservan. Corregí el permiso o la disponibilidad y confirmá un nuevo análisis para lo pendiente."
            } else if record.executions.contains(where: { $0.state == .unknown || $0.state == .failed }) {
                record.summary.status = .partial
                record.summary.message = "Hay cambios cuyo resultado requiere reconciliación. No se repetirán automáticamente."
            } else {
                await emit(record, "Comprobando el resultado final…", progress)
                let final = try await fetchAll(record.plan.snapshots, providers: providers)
                try validate(final, against: record.checkpoints)
                record.finalSnapshots = final
                var capabilities: [MusicService: ProviderCapabilities] = [:]
                for (service, provider) in providers { capabilities[service] = await provider.capabilities() }
                var request = record.plan.request
                if request?.options.existingPlaylist == .copy {
                    for step in record.executions where step.state == .verified && step.operation.kind == .createPlaylist {
                        if let source = step.operation.sourcePlaylist, let id = step.receipt?.createdID {
                            request?.copyTargets.removeAll { $0.source == source }
                            request?.copyTargets.append(PlaylistTarget(source: source, targetID: id))
                        }
                    }
                }
                let remaining: SyncPlan
                if record.snapshotSource != nil || record.scopedApproval == true || record.plan.undoOfRunID != nil {
                    let verifiedParents = Set(record.executions.filter { $0.state == .verified }.map { $0.parentOperationID ?? $0.operation.id })
                    remaining = SyncPlan(mode: record.plan.mode, snapshots: final,
                        operations: record.plan.operations.filter { !verifiedParents.contains($0.id) }, issues: record.plan.issues)
                } else {
                    remaining = SyncPlanner.makePlan(snapshots: final, mode: record.plan.mode, decisions: record.decisions, capabilities: capabilities, request: request)
                }
                record.remainingPlan = remaining
                if remaining.operations.isEmpty && remaining.issues.isEmpty && final.allSatisfy(\.complete) {
                    record.summary.status = .completed
                    if record.snapshotSource != nil {
                        record.summary.message = "Lote aprobado desde XML aplicado y verificado en Spotify. La presencia en Música corresponde a la exportación indicada."
                    } else if record.scopedApproval == true {
                        record.summary.message = "Lote confirmado aplicado y verificado mediante lectura. Las demás diferencias siguen en su comparación."
                    } else { record.summary.message = "El alcance seleccionado está igualado y fue verificado mediante una nueva lectura." }
                } else {
                    record.summary.status = .partial
                    record.summary.message = "Cambios aplicados y verificados. Quedan \(remaining.operations.count) operaciones y \(remaining.issues.count) observaciones por resolver."
                }
            }
        } catch {
            markInterruptedWritesUnknown(&record)
            record.summary.status = .failed
            record.summary.message = error.localizedDescription
            record.summary.logs.append(error.localizedDescription)
        }
        record.summary.verifiedCount = record.executions.filter { $0.state == .verified }.count
        if try await store.load(id: record.id)?.approvalRevoked == true { record.approvalRevoked = true }
        if record.isDemo { record.summary.message = "Demostración: " + record.summary.message }
        try await store.save(record)
        await emit(record, record.summary.message, progress)
        return record
    }

    private var cancellationRequested: Bool { cancelled || Task.isCancelled }

    private func requireApproval(_ record: inout RunRecord) async throws {
        if let request = record.plan.request, let profileID = request.profileID {
            let workspace = try await store.loadWorkspace()
            guard workspace.profiles.contains(where: { $0.id == profileID && $0.request == request }) else {
                throw SyncExecutionError.unsafeResume("La configuración guardada cambió o fue eliminada. Prepará y confirmá una propuesta nueva.")
            }
        }
        if try await store.load(id: record.id)?.approvalRevoked == true { record.approvalRevoked = true }
        guard !record.approvalRevoked else {
            throw SyncExecutionError.unsafeResume("La aprobación fue revocada. Revisá las políticas y confirmá un nuevo análisis.")
        }
    }

    private func requireCompleteBackup(_ record: RunRecord) throws {
        if let source = record.snapshotSource {
            guard source.libraryID == source.library.id, source.documentDigest == source.library.documentDigest,
                  !source.documentDigest.isEmpty, source.library.inventory != nil,
                  record.plan.snapshots.count == 1, record.checkpoints.count == 1,
                  record.plan.snapshots[0].account.service == .spotify, record.checkpoints[0].account.service == .spotify,
                  record.plan.snapshots.allSatisfy(\.complete), record.checkpoints.allSatisfy(\.complete),
                  record.executions.compactMap(\.before).allSatisfy(\.complete),
                  record.plan.operations.allSatisfy({ $0.service == .spotify &&
                    ([.createPlaylist, .addPlaylistTracks, .saveTracks, .saveAlbums].contains($0.kind) ||
                     (source.allowsDestructive == true && source.library.complete && source.library.inventory?.playlistsComplete == true)) }) else {
                throw SyncExecutionError.unsafeResume("La transferencia no conserva una exportación aprobada o un inventario Spotify completo.")
            }
            return
        }
        guard record.plan.snapshots.count == 2, Set(record.plan.snapshots.map { $0.account.service }).count == 2,
              record.checkpoints.count == 2, Set(record.checkpoints.map { $0.account.service }).count == 2,
              record.plan.snapshots.allSatisfy(\.complete), record.checkpoints.allSatisfy(\.complete),
              record.executions.compactMap(\.before).allSatisfy(\.complete) else {
            throw SyncExecutionError.unsafeResume("El respaldo o inventario está incompleto. La vista previa parcial no autoriza escrituras.")
        }
    }

    private func markInterruptedWritesUnknown(_ record: inout RunRecord) {
        for i in record.executions.indices where record.executions[i].state == .applying ||
            (record.executions[i].state == .pending && record.executions[i].before != nil) {
            // Pending with prior write evidence can be a cancelled idempotent retry or a
            // legacy recovery. The original request may still arrive even if no retry was sent.
            record.executions[i].state = .unknown
        }
    }

    private func rememberError(_ message: String, at index: Int, record: inout RunRecord) {
        let previous = record.executions[index].error
        if previous != message { record.executions[index].error = previous.map { $0 + "\n" + message } ?? message }
    }

    private func fetchAll(_ expected: [LibrarySnapshot], providers: [MusicService: any MusicProvider], allowConnectionRebind: Bool = false) async throws -> [LibrarySnapshot] {
        var result: [LibrarySnapshot] = []
        for snapshot in expected {
            guard let provider = providers[snapshot.account.service], provider.service == snapshot.account.service else { throw SyncExecutionError.missingProvider }
            let account = try await provider.account()
            guard account.service == snapshot.account.service, !account.id.isEmpty, account.id == snapshot.account.id,
                  allowConnectionRebind || account.connectionRevision == snapshot.account.connectionRevision else {
                throw SyncExecutionError.stale("Cambió la conexión de \(snapshot.account.service.name).")
            }
            let fresh = try await provider.fetchLibrary()
            guard fresh.account.service == account.service, fresh.account.id == account.id,
                  fresh.account.connectionRevision == account.connectionRevision, fresh.complete else {
                throw SyncExecutionError.stale("\(snapshot.account.service.name) devolvió una identidad diferente o un inventario incompleto.")
            }
            result.append(fresh)
        }
        return result
    }
    private func validate(_ current: [LibrarySnapshot], against expected: [LibrarySnapshot]) throws {
        guard current.count == expected.count, current.allSatisfy(\.complete), expected.allSatisfy(\.complete) else { throw SyncExecutionError.stale("Inventario incompleto.") }
        for old in expected {
            guard let fresh = current.first(where: { $0.account.service == old.account.service }), fresh.stateFingerprint == old.stateFingerprint else {
                throw SyncExecutionError.stale(old.account.service.name + " tiene cambios o una lectura diferente.")
            }
        }
    }
    private func batchIndices(starting index: Int, in record: RunRecord, limit: Int) -> [Int] {
        let op = record.executions[index].operation
        guard [.saveTracks, .removeTracks, .saveAlbums, .removeAlbums].contains(op.kind) else { return [index] }
        var result: [Int] = [], itemCount = 0
        for i in index..<record.executions.count {
            let candidate = record.executions[i]
            guard candidate.state == .pending, candidate.operation.service == op.service, candidate.operation.kind == op.kind,
                  candidate.before?.id == record.executions[index].before?.id else { break }
            let count = max(candidate.operation.tracks.count, candidate.operation.albums.count)
            if !result.isEmpty && itemCount + count > limit { break }
            result.append(i); itemCount += count
        }
        return result
    }
    private func comparisonCopy(_ snapshot: LibrarySnapshot, current: [LibrarySnapshot], allowConnectionRebind: Bool) throws -> LibrarySnapshot {
        guard let fresh = current.first(where: { $0.account.service == snapshot.account.service }),
              fresh.account.id == snapshot.account.id,
              allowConnectionRebind || fresh.account.connectionRevision == snapshot.account.connectionRevision else {
            throw SyncExecutionError.unsafeResume("No puede probarse la continuidad de la cuenta de \(snapshot.account.service.name).")
        }
        var copy = snapshot
        if allowConnectionRebind { copy.account.connectionRevision = fresh.account.connectionRevision }
        return copy
    }

    private func reconcileInterrupted(_ record: inout RunRecord, current: [LibrarySnapshot], allowRetry: Bool, allowConnectionRebind: Bool) throws {
        let unsettled = record.executions.indices.filter { [.applying, .unknown, .failed].contains(record.executions[$0].state) }
        // Record observed effects first. A later unrelated change must not erase successful writes.
        for i in unsettled {
            record.executions[i].state = .unknown
            let execution = record.executions[i]
            guard let originalBefore = execution.before,
                  let after = current.first(where: { $0.account.service == execution.operation.service }) else { continue }
            let before = try comparisonCopy(originalBefore, current: current, allowConnectionRebind: allowConnectionRebind)
            if let receipt = OperationVerifier.receipt(for: execution.operation, before: before, after: after, receipt: execution.receipt) {
                record.executions[i].state = .verified
                record.executions[i].receipt = receipt
                if execution.operation.kind == .createPlaylist, let createdID = receipt.createdID {
                    rememberCreatedPlaylist(operation: execution.operation, createdID: createdID, record: &record)
                }
            }
        }

        var checkpoints = record.checkpoints
        var retries: [Int] = []
        for service in MusicService.allCases {
            let group = unsettled.filter { record.executions[$0].operation.service == service }
            guard let first = group.first else { continue }
            guard let originalBefore = record.executions[first].before,
                  let after = current.first(where: { $0.account.service == service }) else {
                throw SyncExecutionError.unsafeResume("No hay evidencia previa suficiente.")
            }
            let before = try comparisonCopy(originalBefore, current: current, allowConnectionRebind: allowConnectionRebind)
            guard group.allSatisfy({ record.executions[$0].before?.id == before.id }) else {
                throw SyncExecutionError.unsafeResume("Hay resultados inciertos de varios estados previos.")
            }
            // Confirmed siblings from a partially applied batch are approved effects too.
            let batch = record.executions.filter { $0.operation.service == service && $0.before?.id == before.id }
            guard batch.filter({ $0.state == .verified }).allSatisfy({ OperationVerifier.receipt(for: $0.operation, before: before, after: after, receipt: $0.receipt) != nil }),
                  OperationVerifier.unrelatedStateUnchanged(operations: batch.map(\.operation), before: before, after: after) else {
                throw SyncExecutionError.unsafeResume("Hay cambios adicionales en \(service.name) que no estaban aprobados.")
            }
            for i in group where record.executions[i].state != .verified {
                let operation = record.executions[i].operation
                guard OperationVerifier.targetUnchanged(operation, before: before, after: after) else {
                    throw SyncExecutionError.unsafeResume("\(operation.title) cambió y no coincide con el estado anterior ni con el esperado.")
                }
                // Absence is not evidence of non-delivery. Only set-like library writes
                // can safely be retried; creation/append remain unknown even with a receipt ID.
                if allowRetry && OperationVerifier.isIdempotentLibraryWrite(operation) { retries.append(i) }
            }
            checkpoints.removeAll { $0.account.service == service }
            checkpoints.append(after)
        }
        let comparison = try checkpoints.map { try comparisonCopy($0, current: current, allowConnectionRebind: allowConnectionRebind) }
        try validate(current, against: comparison)
        // Promote checkpoints and retries only after both accounts and all siblings pass.
        // plan.snapshots and executions.before remain the immutable original backups.
        record.checkpoints = current
        for i in retries { record.executions[i].state = .pending }
    }
    private func rememberCreatedPlaylist(operation: SyncOperation, createdID: String, record: inout RunRecord) {
        if let source = operation.sourcePlaylist {
            if record.plan.request?.options.existingPlaylist == .copy { return }
            let link = source.service == .spotify ? PlaylistLink(spotifyID: source.playlistID, appleMusicID: createdID) : PlaylistLink(spotifyID: createdID, appleMusicID: source.playlistID)
            if !record.decisions.playlists.contains(link) { record.decisions.playlists.append(link) }
            return
        }
        let sourceService = operation.service.other
        guard let snapshot = record.plan.snapshots.first(where: { $0.account.service == sourceService }) else { return }
        // A source is linked only if the approved name identifies it unambiguously.
        let sources = snapshot.playlists.filter { $0.name == operation.playlistName }
        guard sources.count == 1 else { return }
        let link = sourceService == .spotify ? PlaylistLink(spotifyID: sources[0].id, appleMusicID: createdID) : PlaylistLink(spotifyID: createdID, appleMusicID: sources[0].id)
        if !record.decisions.playlists.contains(link) { record.decisions.playlists.append(link) }
    }
    private func emit(_ record: RunRecord, _ message: String, _ progress: @Sendable (SyncProgress) async -> Void) async {
        await progress(SyncProgress(completed: record.summary.verifiedCount, total: record.summary.totalCount, message: message, logs: record.summary.logs))
    }
}
