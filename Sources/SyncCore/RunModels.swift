import Foundation

public enum RunStatus: String, Codable, Sendable {
    case completed, partial, cancelled, failed, running, interrupted
    public var label: String {
        switch self {
        case .completed: return "Igualado"
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
    public init(operation: SyncOperation, state: ExecutionState = .pending, before: LibrarySnapshot? = nil, receipt: MutationReceipt? = nil, error: String? = nil) {
        self.operation = operation; self.state = state; self.before = before; self.receipt = receipt; self.error = error
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
    public init(summary: RunSummary, plan: SyncPlan, decisions: MatchDecisions, executions: [OperationExecution], checkpoints: [LibrarySnapshot], finalSnapshots: [LibrarySnapshot] = [], remainingPlan: SyncPlan? = nil, isDemo: Bool = false, approvalRevoked: Bool = false) {
        self.summary = summary; self.plan = plan; self.decisions = decisions; self.executions = executions
        self.checkpoints = checkpoints; self.finalSnapshots = finalSnapshots; self.remainingPlan = remainingPlan; self.isDemo = isDemo
        self.approvalRevoked = approvalRevoked
    }

    private enum CodingKeys: String, CodingKey {
        case summary, plan, decisions, executions, checkpoints, finalSnapshots, remainingPlan, isDemo, approvalRevoked
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        summary = try values.decode(RunSummary.self, forKey: .summary)
        plan = try values.decode(SyncPlan.self, forKey: .plan)
        decisions = try values.decode(MatchDecisions.self, forKey: .decisions)
        executions = try values.decode([OperationExecution].self, forKey: .executions)
        checkpoints = try values.decode([LibrarySnapshot].self, forKey: .checkpoints)
        finalSnapshots = try values.decode([LibrarySnapshot].self, forKey: .finalSnapshots)
        remainingPlan = try values.decodeIfPresent(SyncPlan.self, forKey: .remainingPlan)
        isDemo = try values.decode(Bool.self, forKey: .isDemo)
        approvalRevoked = try values.decodeIfPresent(Bool.self, forKey: .approvalRevoked) ?? false
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
