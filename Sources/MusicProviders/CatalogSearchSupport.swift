import Foundation
import SyncCore

func searchFailure<Item>(_ error: Error, candidates: [Item] = []) throws -> CatalogSearchResult<Item> {
    if error is CancellationError { throw CancellationError() }
    return .init(candidates: candidates,
                 coverage: error is CatalogBudgetExceeded ? .limited : candidates.isEmpty ? .failed : .partialFailure,
                 notes: [error is CatalogBudgetExceeded ? "Se alcanzó el presupuesto de 12 solicitudes de catálogo." : (error as? ProviderError)?.localizedDescription ?? "No se pudo completar la búsqueda."])
}
