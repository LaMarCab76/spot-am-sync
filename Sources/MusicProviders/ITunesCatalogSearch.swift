import Foundation
import SyncCore

/// Public discovery only. iTunes IDs remain namespaced and never become MusicKit song IDs.
public actor ITunesCatalogSearch {
    private let http: ProviderHTTP
    private var nextRequestAt = Date.distantPast
    private var cache: [TrackSearchQuery: (Date, TrackSearchResult)] = [:]
    public init(transport: any ProviderHTTPTransport = URLSessionProviderTransport()) {
        http = ProviderHTTP(transport: transport, retry: .init(maximumReadAttempts: 1))
    }
    public func search(_ query: TrackSearchQuery) async throws -> TrackSearchResult {
        guard query.valid, let country = query.country?.uppercased(), country.count == 2,
              country.unicodeScalars.allSatisfy({ (65...90).contains(Int($0.value)) }) else {
            throw ProviderError.invalidResponse("Elegí un país de búsqueda de dos letras, por ejemplo AR.")
        }
        if let cached = cache[query], Date().timeIntervalSince(cached.0) < 300 { return cached.1 }
        var result = TrackSearchResult(coverage: .partial, notes: ["Opciones del catálogo público iTunes para \(country). No confirman disponibilidad en Apple Music ni presencia en tu biblioteca. La búsqueda pública no ofrece paginación exhaustiva."])
        var successfulRequests = 0, failed = false
        let stages = [[query.artist, query.album, query.title], [query.artist, query.title]]
        var seenTerms = Set<String>()
        for terms in stages {
            let term = terms.filter { !$0.isEmpty }.joined(separator: " ")
            guard seenTerms.insert(term).inserted else { continue }
            do {
                let items = try await request(path: "/search", parameters: ["term": term, "country": country, "media": "music", "entity": "song", "limit": "50"])
                result.candidates += items.compactMap(Self.track)
                successfulRequests += 1
            } catch is CancellationError { throw CancellationError() }
            catch { result.notes.append(error.localizedDescription); failed = true; break }
        }
        if !query.album.isEmpty && !failed {
            do {
                let albums = try await request(path: "/search", parameters: ["term": "\(query.artist) \(query.album)", "country": country, "media": "music", "entity": "album", "limit": "3"])
                successfulRequests += 1
                for album in albums.prefix(3) {
                    guard let id = album["collectionId"].int else { continue }
                    let tracks = try await request(path: "/lookup", parameters: ["id": String(id), "country": country, "entity": "song", "limit": "200"])
                    result.candidates += tracks.compactMap(Self.track)
                }
            } catch is CancellationError { throw CancellationError() }
            catch { result.notes.append(error.localizedDescription); failed = true }
        }
        let source = Track(id: "query", title: query.title, artist: query.artist, albumTitle: query.album)
        result.candidates = CatalogMatcher.ranked(source, candidates: result.candidates)
        if failed && successfulRequests == 0 { result.coverage = .failed }
        if !failed { cache[query] = (Date(), result) }
        return result
    }

    private func request(path: String, parameters: [String: String]) async throws -> [JSONValue] {
        // The public API documents roughly 20 calls/minute. Reserve slots before awaiting.
        let now = Date(), slot = max(now, nextRequestAt)
        nextRequestAt = slot.addingTimeInterval(3.1)
        if slot > now { try await Task.sleep(nanoseconds: UInt64(slot.timeIntervalSince(now) * 1_000_000_000)) }
        try Task.checkCancellation()
        var url = URLComponents(); url.scheme = "https"; url.host = "itunes.apple.com"; url.path = path
        url.queryItems = parameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: url.url!); request.timeoutInterval = 30
        let response: ProviderHTTPResponse
        do { response = try await http.send(request) }
        catch ProviderError.rateLimited(let seconds) {
            nextRequestAt = max(nextRequestAt, Date().addingTimeInterval(Double(seconds)))
            throw ProviderError.rateLimited(seconds: seconds)
        }
        let value = try JSONValue.decode(response.data)
        guard let items = value["results"].array, value["resultCount"].int == items.count else { throw ProviderError.invalidResponse("La búsqueda pública devolvió una respuesta incompleta.") }
        return items
    }
    private static func track(_ item: JSONValue) -> Track? {
        guard item["wrapperType"].string == "track", item["kind"].string == "song",
              let id = item["trackId"].int, let title = item["trackName"].nonempty, let artist = item["artistName"].nonempty else { return nil }
        let rating = item["trackExplicitness"].string
        let explicit: Bool? = rating == "explicit" ? true : ["notExplicit", "cleaned"].contains(rating ?? "") ? false : nil
        var result = Track(id: "itunes:\(id)", title: title, artist: artist, albumTitle: item["collectionName"].string ?? "",
                           durationMS: item["trackTimeMillis"].int ?? 0, explicit: explicit)
        result.url = item["trackViewUrl"].nonempty; result.releaseDate = item["releaseDate"].nonempty
        result.albumID = item["collectionId"].int.map { "itunes:\($0)" }
        result.discNumber = item["discNumber"].int; result.trackNumber = item["trackNumber"].int
        return result
    }
}
