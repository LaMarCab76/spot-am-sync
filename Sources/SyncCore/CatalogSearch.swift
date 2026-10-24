import Foundation

public enum CatalogSearchCoverage: String, Codable, Sendable {
    case complete, limited, failed, partialFailure
    /// Retained for decisions saved by the first staged-search release.
    case partial
    public var label: String {
        switch self {
        case .complete: return "Búsqueda completa"
        case .partial: return "Búsqueda incompleta"
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
        else if coverage == .partial || other.coverage == .partial { coverage = .partial }
    }
}

public typealias SearchCoverage = CatalogSearchCoverage
public enum SearchStage: String, Codable, CaseIterable, Sendable {
    case identifier, metadata, albumTracks, artistTitle
    public var label: String {
        switch self {
        case .identifier: return "ISRC"
        case .metadata: return "Artista, álbum y canción"
        case .albumTracks: return "Canciones del álbum"
        case .artistTitle: return "Artista y canción"
        }
    }
}

public struct TrackSearchQuery: Codable, Hashable, Sendable {
    public var title: String
    public var artist: String
    public var album: String
    public var isrc: String?
    public var stage: SearchStage
    public var country: String?
    public init(title: String, artist: String, album: String = "", isrc: String? = nil, stage: SearchStage = .metadata) {
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.artist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        self.album = album.trimmingCharacters(in: .whitespacesAndNewlines)
        self.isrc = isrc; self.stage = stage
    }
    public init(_ track: Track, stage: SearchStage = .metadata) {
        self.init(title: track.title, artist: track.artist, album: track.albumTitle, isrc: track.isrc, stage: stage)
    }
    public var valid: Bool { !title.isEmpty || !artist.isEmpty || !album.isEmpty }
}

public struct TrackSearchResult: Codable, Equatable, Sendable {
    public var candidates: [Track]
    public var coverage: SearchCoverage
    public var notes: [String]
    public var stages: [SearchStage]
    public var retryAfterSeconds: Int?
    public var authorizationFailed: Bool?
    public init(candidates: [Track] = [], coverage: SearchCoverage = .complete, notes: [String] = [], stages: [SearchStage] = []) {
        self.candidates = candidates; self.coverage = coverage; self.notes = notes; self.stages = stages
    }
}

public enum TrackDecision: String, Codable, Sendable { case automatic, manual, pending, omitted }

/// Shared by the official workflow and the XML checklist. Search failure never proves absence.
public enum CatalogSearch {
    public static func search(source: Track, provider: any MusicProvider, query: TrackSearchQuery? = nil) async throws -> TrackSearchResult {
        let base = query ?? TrackSearchQuery(source)
        guard base.valid else { return .init(coverage: .failed, notes: ["Ingresá un artista, álbum o canción."]) }
        var result = TrackSearchResult()
        let budget = CatalogRequestBudget()
        var hadFailure = false
        for stage in SearchStage.allCases {
            try Task.checkCancellation()
            if stage == .identifier && (query != nil || base.isrc?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false) { continue }
            if stage == .albumTracks && base.album.isEmpty { continue }
            var request = base; request.stage = stage
            do {
                let page = try await provider.searchCatalog(request, budget: budget)
                result.candidates = CatalogMatcher.ranked(source, candidates: result.candidates + page.candidates)
                if result.candidates.count > 200 {
                    result.candidates = Array(result.candidates.prefix(200)); result.coverage = result.coverage == .complete ? .limited : result.coverage
                    result.notes.append("Se muestran las 200 opciones mejor alineadas. Afiná artista, álbum o canción para consultar otras.")
                }
                result.stages.append(stage)
                result.notes += page.notes
                var combined = CatalogSearchResult(candidates: result.candidates, coverage: result.coverage)
                combined.merge(.init(coverage: page.coverage))
                result.coverage = combined.coverage
                if page.coverage == .failed || page.coverage == .partialFailure { hadFailure = true }
                if page.authorizationFailed == true { result.authorizationFailed = true; break }
                if let wait = page.retryAfterSeconds { result.retryAfterSeconds = wait; break }
                if query == nil, result.coverage == .complete,
                   CatalogMatcher.track(source, candidates: result.candidates, sourceService: provider.service.other).selected != nil { break }
            } catch is CancellationError { throw CancellationError() }
            catch {
                if error is CatalogBudgetExceeded {
                    result.coverage = hadFailure ? (result.candidates.isEmpty ? .failed : .partialFailure) : .limited
                    result.notes.append("Se alcanzó el presupuesto de solicitudes de catálogo."); break
                }
                hadFailure = true
                result.coverage = result.candidates.isEmpty ? .failed : .partialFailure
                result.notes.append("\(stage.label): \(error.localizedDescription)")
                if case ProviderError.unauthorized = error { result.authorizationFailed = true; break }
                if case ProviderError.notConnected = error { result.authorizationFailed = true; break }
                if case ProviderError.rateLimited(let seconds) = error { result.retryAfterSeconds = seconds; break }
                if case ProviderError.forbidden = error { break }
            }
        }
        if result.candidates.isEmpty && hadFailure { result.coverage = .failed }
        result.notes = Array(Set(result.notes)).sorted()
        return result
    }

    public static func match(source: Track, sourceService: MusicService, result: TrackSearchResult, previous: TrackMatch? = nil) -> TrackMatch {
        var match = CatalogMatcher.track(source, candidates: result.candidates, sourceService: sourceService)
        match.candidates = result.candidates
        match.searchCoverage = result.coverage; match.searchNotes = result.notes; match.searchStages = result.stages
        match.decision = match.selected == nil ? nil : .automatic
        if result.coverage != .complete {
            match.selected = nil; match.confidence = .review; match.decision = nil
            match.reason = "La búsqueda está incompleta. Podés revisar los resultados o reintentar; no se confirmó ausencia."
        }
        if let previous, previous.source == source {
            match.rejectedCandidateIDs = previous.rejectedCandidateIDs
            let rejected = Set(previous.rejectedCandidateIDs ?? [])
            match.candidates.removeAll { rejected.contains($0.playableID) }
            if let chosen = match.selected, rejected.contains(chosen.playableID) { match.selected = nil; match.confidence = .review; match.decision = .pending }
            if previous.decision == .pending || previous.decision == .omitted {
                match.selected = nil; match.confidence = .review; match.decision = previous.decision
                match.reason = previous.decision == .omitted ? "Omitida por vos. No autoriza bajas de posibles equivalentes." : "Pendiente por decisión tuya."
            } else if (previous.decision == .manual || previous.manualSelection == true), let selected = previous.selected,
                      match.candidates.filter({ $0.playableID == selected.playableID }).count == 1,
                      let found = match.candidates.first(where: { $0.playableID == selected.playableID }),
                      CatalogMatcher.sameIdentityMetadata(found, selected), found.available, !found.isLocal {
                match.selected = found; match.confidence = .review; match.decision = .manual; match.manualSelection = true
                match.reason = "Elección manual revalidada para estas cuentas y región."
            }
        }
        return match
    }
}

public extension MusicProvider {
    func searchCatalog(_ query: TrackSearchQuery) async throws -> TrackSearchResult {
        let source = Track(id: "search", title: query.title, artist: query.artist, albumTitle: query.album,
                           isrc: query.stage == .identifier ? query.isrc : nil)
        let result = try await searchTracks(matching: source)
        return .init(candidates: result.candidates, coverage: result.coverage, notes: result.notes, stages: [query.stage])
    }
    func searchCatalog(_ query: TrackSearchQuery, budget: CatalogRequestBudget) async throws -> TrackSearchResult {
        try await searchCatalog(query)
    }
    func catalogTrack(id: String) async throws -> Track? { nil }
}
