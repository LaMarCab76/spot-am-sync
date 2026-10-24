import Foundation

public enum CatalogSearchCoverage: String, Codable, Sendable {
    case complete, limited, failed, partialFailure
    public var label: String {
        switch self {
        case .complete: return "Búsqueda completa"
        case .limited: return "Búsqueda limitada"
        case .failed: return "No se pudo buscar"
        case .partialFailure: return "Búsqueda parcialmente fallida"
        }
    }
}

public struct CatalogSearchResult<Item: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    public var candidates: [Item]
    public var coverage: CatalogSearchCoverage
    public var notes: [String]
    public init(candidates: [Item] = [], coverage: CatalogSearchCoverage = .complete, notes: [String] = []) {
        self.candidates = candidates; self.coverage = coverage; self.notes = notes
    }
    public mutating func merge(_ other: Self) {
        candidates += other.candidates
        notes += other.notes
        if [.failed, .partialFailure].contains(coverage) || [.failed, .partialFailure].contains(other.coverage) {
            coverage = candidates.isEmpty ? .failed : .partialFailure
        } else if coverage == .limited || other.coverage == .limited { coverage = .limited }
    }
}
