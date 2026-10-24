import Foundation
import SyncCore

/// Inject this boundary in tests. Implementations must not log requests, headers or bodies.
public protocol ProviderHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse
}

public struct ProviderHTTPResponse: Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let data: Data
    public init(statusCode: Int, headers: [String: String] = [:], data: Data = Data()) {
        self.statusCode = statusCode; self.headers = headers; self.data = data
    }
    func header(_ name: String) -> String? { headers.first { $0.key.lowercased() == name.lowercased() }?.value }
}

/// Redirects are refused, including same-origin redirects: an API call must not silently
/// forward credentials or turn a write into a different request.
public final class URLSessionProviderTransport: NSObject, ProviderHTTPTransport, URLSessionTaskDelegate, @unchecked Sendable {
    public override init() { super.init() }
    public func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 45
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil; config.urlCache = nil
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.invalidResponse("El servicio no devolvió una respuesta HTTP.")
        }
        return .init(statusCode: http.statusCode, headers: http.allHeaderFields.reduce(into: [:]) {
            $0[String(describing: $1.key)] = String(describing: $1.value)
        }, data: data)
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest,
                           completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

public struct ProviderRetryPolicy: Sendable {
    public var maximumReadAttempts: Int
    public var maximumDelay: TimeInterval
    public var maximumTotalDelay: TimeInterval
    public init(maximumReadAttempts: Int = 3, maximumDelay: TimeInterval = 5, maximumTotalDelay: TimeInterval = 10) {
        self.maximumReadAttempts = min(3, max(1, maximumReadAttempts))
        self.maximumDelay = min(5, max(0, maximumDelay))
        self.maximumTotalDelay = min(10, max(0, maximumTotalDelay))
    }
}

struct ProviderHTTP: Sendable {
    let transport: any ProviderHTTPTransport
    let retry: ProviderRetryPolicy
    var sleep: @Sendable (TimeInterval) async throws -> Void = { seconds in
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        let read = request.httpMethod == nil || request.httpMethod == "GET"
        var waited: TimeInterval = 0
        for attempt in 0..<(read ? retry.maximumReadAttempts : 1) {
            try Task.checkCancellation()
            let response: ProviderHTTPResponse
            do { response = try await transport.send(request) }
            catch {
                // Never expose an SDK error's description: it can contain tokens and URLs.
                if !read { throw ProviderError.uncertainWrite("La respuesta de la escritura no llegó. Releé el estado antes de reintentar.") }
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                if let safeError = error as? ProviderError { throw safeError }
                throw ProviderError.network("No se pudo completar la lectura del servicio.")
            }
            if (200..<300).contains(response.statusCode) { return response }
            let error = Self.failure(response)
            let retryable = response.statusCode == 429 || (500...599).contains(response.statusCode)
            let delay = Self.retryAfter(response) ?? pow(2, Double(attempt))
            if read && retryable && attempt + 1 < retry.maximumReadAttempts &&
                delay <= retry.maximumDelay && waited + delay <= retry.maximumTotalDelay {
                try await sleep(delay); waited += delay; continue
            }
            if !read && ((500...599).contains(response.statusCode) || response.statusCode == 408) {
                throw ProviderError.uncertainWrite("El servidor falló durante una escritura. Releé el estado antes de reintentar.")
            }
            throw error
        }
        throw ProviderError.network("Se agotaron los intentos de lectura.")
    }

    static func retryAfter(_ response: ProviderHTTPResponse, now: Date = Date()) -> TimeInterval? {
        guard let value = response.header("Retry-After") else { return nil }
        if let seconds = Double(value), seconds.isFinite { return min(86_400_000, max(0, seconds)) }
        let format = DateFormatter(); format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(secondsFromGMT: 0); format.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        return format.date(from: value).map { min(86_400_000, max(0, $0.timeIntervalSince(now))) }
    }
    static func failure(_ response: ProviderHTTPResponse) -> ProviderError {
        switch response.statusCode {
        case 401: return .unauthorized
        case 403: return .forbidden("El servicio denegó acceso (HTTP 403). Revisá permisos y disponibilidad para esta cuenta.")
        case 429: return .rateLimited(seconds: Int(ceil(retryAfter(response) ?? 1)))
        default: return .invalidResponse("El servicio respondió HTTP \(response.statusCode).")
        }
    }
}

enum APIOrigin: String, Sendable {
    case spotify = "https://api.spotify.com"
    case apple = "https://api.music.apple.com"

    func url(_ path: String, query: [URLQueryItem] = []) throws -> URL {
        guard let base = URL(string: rawValue), let result = URL(string: path, relativeTo: base)?.absoluteURL,
              let parts = URLComponents(url: result, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.host == base.host, parts.port == nil || parts.port == 443,
              parts.user == nil, parts.password == nil, parts.fragment == nil,
              parts.path.hasPrefix("/v1/"), !parts.path.contains(".."), !parts.path.contains("\\") else {
            throw ProviderError.invalidResponse("El servicio devolvió una URL de paginación no confiable.")
        }
        var components = parts
        if !query.isEmpty { components.queryItems = (components.queryItems ?? []) + query }
        guard let url = components.url else { throw ProviderError.invalidResponse("URL de API inválida.") }
        return url
    }
}

func resourceID(_ value: String) throws -> String {
    guard !value.isEmpty, value.utf8.count <= 300,
          value.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-")).contains($0) }),
          value != ".", value != ".." else { throw ProviderError.invalidResponse("Identificador de recurso inválido.") }
    return value
}

// A lossless JSON DTO retains null/unknown array members. Resource conversion below
// assigns placeholders instead of compactMap-ing unavailable tracks out of inventories.
indirect enum JSONValue: Decodable, Sendable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let x = try? c.decode(Bool.self) { self = .bool(x) }
        else if let x = try? c.decode(String.self) { self = .string(x) }
        else if let x = try? c.decode(Double.self) { self = .number(x) }
        else if let x = try? c.decode([JSONValue].self) { self = .array(x) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
    subscript(_ key: String) -> JSONValue { if case .object(let x) = self { return x[key] ?? .null }; return .null }
    var string: String? { if case .string(let x) = self { return x }; return nil }
    var nonempty: String? { string.flatMap { $0.isEmpty ? nil : $0 } }
    var int: Int? { if case .number(let x) = self, x >= 0, x < Double(Int.max), x.rounded() == x { return Int(x) }; return nil }
    var bool: Bool? { if case .bool(let x) = self { return x }; return nil }
    var array: [JSONValue]? { if case .array(let x) = self { return x }; return nil }
    var isObject: Bool { if case .object = self { return true }; return false }
    var isNull: Bool { if case .null = self { return true }; return false }
    func contains(_ key: String) -> Bool { if case .object(let x) = self { return x[key] != nil }; return false }
    static func decode(_ data: Data) throws -> JSONValue {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data), value.isObject,
              value["error"].isNull, value["errors"].isNull else {
            throw ProviderError.invalidResponse("El servicio devolvió JSON inválido o un cuerpo de error.")
        }
        return value
    }
}

struct CollectedPage: Sendable {
    var items: [JSONValue] = []
    var complete = true
    var notes: [String] = []
    var failure: ProviderError?
}

/// Collects every page, preserves already-read data on failure, and distinguishes
/// a genuine empty collection from a forbidden/malformed/truncated collection.
func collectPages(origin: APIOrigin, path: String, initial: JSONValue? = nil,
                  spotify: Bool, envelope: String? = nil, maximumPages: Int = 10_000,
                  fetch: (URL) async throws -> JSONValue) async throws -> CollectedPage {
    var output = CollectedPage(), next: String? = path, first = initial
    var visited = Set<String>(), expected: Int?
    do {
        let expectedPath = try origin.url(path).path
        while let current = next {
            try Task.checkCancellation()
            if visited.count >= maximumPages {
                output.complete = false; output.notes.append("Se alcanzó el límite de páginas de esta búsqueda. Afiná los términos para consultar más opciones.")
                break
            }
            let url = try origin.url(current)
            guard url.path == expectedPath, visited.insert(url.absoluteString).inserted, visited.count <= 10_000 else {
                throw ProviderError.invalidResponse("La paginación cambió de recurso, se repite o supera el límite de seguridad.")
            }
            let response: JSONValue
            if let value = first { response = value; first = nil } else { response = try await fetch(url) }
            let page = envelope.map { response[$0] } ?? response
            guard let values = page[spotify ? "items" : "data"].array,
                  page["next"].isNull || page["next"].nonempty != nil else {
                throw ProviderError.invalidResponse("La colección no contiene una página válida.")
            }
            let total = spotify ? page["total"].int : page["meta"]["total"].int
            if spotify && (total == nil || !page.contains("next") || page["offset"].int != output.items.count) {
                throw ProviderError.invalidResponse("La página de Spotify no declara total, next u offset coherentes.")
            }
            if let total {
                if let expected, expected != total { output.complete = false; output.notes.append("El total cambió durante la lectura.") }
                expected = total
            }
            output.items.append(contentsOf: values)
            next = page["next"].string
            if values.isEmpty && next != nil { throw ProviderError.invalidResponse("Página vacía con continuación; inventario incompleto.") }
        }
        if let expected, output.items.count != expected {
            output.complete = false; output.notes.append("El número de elementos no coincide con el total declarado.")
        }
    } catch is CancellationError { throw CancellationError() }
    catch ProviderError.unauthorized { throw ProviderError.unauthorized }
    catch ProviderError.notConnected { throw ProviderError.notConnected }
    catch {
        output.complete = false
        output.failure = error as? ProviderError
        output.notes.append((error as? ProviderError)?.errorDescription ?? "Lectura incompleta.")
    }
    return output
}

func jsonBody(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
func chunks<T>(_ values: [T], size: Int) -> [[T]] {
    stride(from: 0, to: values.count, by: size).map { Array(values[$0..<min($0 + size, values.count)]) }
}
func unknownTrack(_ id: String) -> Track {
    Track(id: "unknown:\(id)", title: "Elemento no disponible", artist: "", available: false)
}
