import Foundation

public enum RunStatus: String, Codable, Sendable {
    case completed, partial, cancelled, failed, running, interrupted
    public var label: String {
        switch self {
        case .completed: return "Verificado"
        case .partial: return "Con diferencias pendientes"
        case .cancelled: return "Cancelado"
        case .failed: return "Necesita revisión"
        case .running: return "Sincronizando"
        case .interrupted: return "Interrumpido"
        }
    }
}

public struct RunSummary: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var startedAt: Date
    public var status: RunStatus
    public var verifiedCount: Int
    public var totalCount: Int
    public var message: String
    public var logs: [String]
    public init(id: UUID = UUID(), startedAt: Date = Date(), status: RunStatus = .running, verifiedCount: Int = 0, totalCount: Int = 0, message: String = "", logs: [String] = []) {
        self.id = id; self.startedAt = startedAt; self.status = status; self.verifiedCount = verifiedCount
        self.totalCount = totalCount; self.message = message; self.logs = logs
    }
}

public enum ExecutionState: String, Codable, Sendable { case pending, applying, verified, failed, unknown, rejected }

public struct OperationExecution: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID { operation.id }
    public var operation: SyncOperation
    public var state: ExecutionState
    public var before: LibrarySnapshot?
    public var receipt: MutationReceipt?
    public var error: String?
    public var parentOperationID: UUID?
    public var createdByOperationID: UUID?
    public var creationDependencyID: UUID?
    /// Used only by RunRecord's compact wire format; decoded records restore `before`.
    var beforeSnapshotID: UUID?
    public init(operation: SyncOperation, state: ExecutionState = .pending, before: LibrarySnapshot? = nil, receipt: MutationReceipt? = nil, error: String? = nil, parentOperationID: UUID? = nil, creationDependencyID: UUID? = nil) {
        self.operation = operation; self.state = state; self.before = before; self.receipt = receipt; self.error = error
        self.parentOperationID = parentOperationID; self.creationDependencyID = creationDependencyID
    }
}

public struct RunRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID { summary.id }
    public var summary: RunSummary
    public var plan: SyncPlan
    public var decisions: MatchDecisions
    public var executions: [OperationExecution]
    public var checkpoints: [LibrarySnapshot]
    public var finalSnapshots: [LibrarySnapshot]
    public var remainingPlan: SyncPlan?
    public var isDemo: Bool
    public var approvalRevoked: Bool
    public var snapshotSource: SnapshotTransferSource?
    public var scopedApproval: Bool?
    public init(summary: RunSummary, plan: SyncPlan, decisions: MatchDecisions, executions: [OperationExecution], checkpoints: [LibrarySnapshot], finalSnapshots: [LibrarySnapshot] = [], remainingPlan: SyncPlan? = nil, isDemo: Bool = false, approvalRevoked: Bool = false) {
        self.summary = summary; self.plan = plan; self.decisions = decisions; self.executions = executions
        self.checkpoints = checkpoints; self.finalSnapshots = finalSnapshots; self.remainingPlan = remainingPlan; self.isDemo = isDemo
        self.approvalRevoked = approvalRevoked
    }

    private enum CodingKeys: String, CodingKey {
        case summary, plan, decisions, executions, checkpoints, finalSnapshots, remainingPlan, isDemo, approvalRevoked, executionSnapshots, snapshotSource, scopedApproval
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        summary = try values.decode(RunSummary.self, forKey: .summary)
        plan = try values.decode(SyncPlan.self, forKey: .plan)
        decisions = try values.decode(MatchDecisions.self, forKey: .decisions)
        executions = try values.decode([OperationExecution].self, forKey: .executions)
        let evidence = try values.decodeIfPresent([LibrarySnapshot].self, forKey: .executionSnapshots) ?? []
        for i in executions.indices {
            if let id = executions[i].beforeSnapshotID {
                let matching = evidence.filter { $0.id == id }
                guard matching.count == 1, executions[i].before == nil else {
                    throw DecodingError.dataCorruptedError(forKey: .executionSnapshots, in: values, debugDescription: "Missing or contradictory execution evidence")
                }
                executions[i].before = matching[0]; executions[i].beforeSnapshotID = nil
            }
        }
        checkpoints = try values.decode([LibrarySnapshot].self, forKey: .checkpoints)
        finalSnapshots = try values.decode([LibrarySnapshot].self, forKey: .finalSnapshots)
        remainingPlan = try values.decodeIfPresent(SyncPlan.self, forKey: .remainingPlan)
        isDemo = try values.decode(Bool.self, forKey: .isDemo)
        approvalRevoked = try values.decodeIfPresent(Bool.self, forKey: .approvalRevoked) ?? false
        snapshotSource = try values.decodeIfPresent(SnapshotTransferSource.self, forKey: .snapshotSource)
        scopedApproval = try values.decodeIfPresent(Bool.self, forKey: .scopedApproval)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        var compact = executions, evidence: [UUID: LibrarySnapshot] = [:]
        for i in compact.indices {
            guard let snapshot = compact[i].before else { continue }
            if let existing = evidence[snapshot.id], existing != snapshot {
                throw EncodingError.invalidValue(snapshot.id, .init(codingPath: encoder.codingPath, debugDescription: "Conflicting execution snapshot IDs"))
            }
            evidence[snapshot.id] = snapshot
            compact[i].before = nil; compact[i].beforeSnapshotID = snapshot.id
        }
        try values.encode(summary, forKey: .summary)
        try values.encode(plan, forKey: .plan)
        try values.encode(decisions, forKey: .decisions)
        try values.encode(compact, forKey: .executions)
        try values.encode(evidence.values.sorted { $0.id.uuidString < $1.id.uuidString }, forKey: .executionSnapshots)
        try values.encode(checkpoints, forKey: .checkpoints)
        try values.encode(finalSnapshots, forKey: .finalSnapshots)
        try values.encodeIfPresent(remainingPlan, forKey: .remainingPlan)
        try values.encode(isDemo, forKey: .isDemo)
        try values.encode(approvalRevoked, forKey: .approvalRevoked)
        try values.encodeIfPresent(snapshotSource, forKey: .snapshotSource)
        try values.encodeIfPresent(scopedApproval, forKey: .scopedApproval)
    }
}

public enum SyncExecutionError: Error, LocalizedError {
    case stale(String), invalidSelection, busy, missingProvider, persistence(String), unsafeResume(String)
    public var errorDescription: String? {
        switch self {
        case .stale(let text): return "La biblioteca cambió desde la revisión. \(text) Volvé a analizar antes de aplicar cambios."
        case .invalidSelection: return "La selección no coincide con las operaciones permitidas de este plan."
        case .busy: return "Ya hay una sincronización en curso."
        case .missingProvider: return "Falta una cuenta conectada."
        case .persistence(let text): return "No se pudo guardar el respaldo: \(text)"
        case .unsafeResume(let text): return "La ejecución requiere un nuevo análisis: \(text)"
        }
    }
}

public struct SyncProgress: Sendable {
    public var completed: Int
    public var total: Int
    public var message: String
    public var logs: [String]
    public init(completed: Int, total: Int, message: String, logs: [String]) {
        self.completed = completed; self.total = total; self.message = message; self.logs = logs
    }
}
