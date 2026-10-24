import Foundation
import SyncCore

struct CatalogBudgetExceeded: Error {}

/// One budget per search, including HTTP retries. Library inventory reads use
/// their existing exhaustive paginator and never share this discovery limit.
actor CatalogRequestBudget {
    private var remaining = 12
    func claim() throws {
        guard remaining > 0 else { throw CatalogBudgetExceeded() }
        remaining -= 1
    }
}

func searchFailure<Item>(_ error: Error, candidates: [Item] = []) throws -> CatalogSearchResult<Item> {
    if error is CancellationError { throw CancellationError() }
    return .init(candidates: candidates,
                 coverage: error is CatalogBudgetExceeded ? .limited : candidates.isEmpty ? .failed : .partialFailure,
                 notes: [error is CatalogBudgetExceeded ? "Se alcanzó el presupuesto de 12 solicitudes de catálogo." : (error as? ProviderError)?.localizedDescription ?? "No se pudo completar la búsqueda."])
}
