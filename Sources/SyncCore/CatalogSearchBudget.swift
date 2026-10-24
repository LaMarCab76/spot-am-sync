import Foundation

public struct CatalogBudgetExceeded: Error { public init() {} }

/// One budget per search, including HTTP retries. Library inventory reads use
/// their existing exhaustive paginator and never share this discovery limit.
public actor CatalogRequestBudget {
    public init() {}
    private var remaining = 12
    public func claim() throws {
        guard remaining > 0 else { throw CatalogBudgetExceeded() }
        remaining -= 1
    }
}
