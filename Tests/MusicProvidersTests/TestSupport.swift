import Foundation
import XCTest
import SyncCore
@testable import MusicProviders

actor ScriptedTransport: AppleMusicSessionTransport {
    struct Step: @unchecked Sendable {
        let method: String
        let path: String
        let response: ProviderHTTPResponse
        let validate: ((URLRequest) throws -> Void)?
        init(_ path: String, status: Int = 200, json: Any? = nil, headers: [String: String] = [:], raw: String? = nil,
             validate: ((URLRequest) throws -> Void)? = nil) {
            self.init("GET", path, status: status, json: json, headers: headers, raw: raw, validate: validate)
        }
        init(_ method: String, _ path: String, status: Int = 200, json: Any? = nil,
             headers: [String: String] = [:], raw: String? = nil, validate: ((URLRequest) throws -> Void)? = nil) {
            self.method = method; self.path = path; self.validate = validate
            self.response = ProviderHTTPResponse(statusCode: status, headers: headers,
                data: raw.map { Data($0.utf8) } ?? json.map { try! JSONSerialization.data(withJSONObject: $0) } ?? Data())
        }
    }
    private var steps: [Step]
    private(set) var requests: [URLRequest] = []
    private var sessionActive = false
    init(_ steps: [Step]) { self.steps = steps }
    func beginSession() { sessionActive = true }
    func endSession() { sessionActive = false }
    func sessionIdentifier() -> String? { sessionActive ? "apple-music-grant:test-fixture" : nil }
    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        requests.append(request)
        guard !steps.isEmpty else { XCTFail("Unexpected request: \(request.httpMethod ?? "GET") \(request.url?.path ?? "")"); throw ProviderError.network("No fixture") }
        let step = steps.removeFirst()
        XCTAssertEqual(request.httpMethod ?? "GET", step.method)
        XCTAssertEqual(request.url?.path, step.path)
        try step.validate?(request)
        return step.response
    }
    func assertExhausted(file: StaticString = #filePath, line: UInt = #line) { XCTAssertTrue(steps.isEmpty, "Unused fixtures: \(steps.count)", file: file, line: line) }
}

final class MemoryCredentialStore: SpotifyCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: SpotifyCredential?
    init(_ credential: SpotifyCredential? = testCredential()) { stored = credential }
    func load(clientID: String) throws -> SpotifyCredential? { lock.lock(); defer { lock.unlock() }; return stored }
    func save(_ credential: SpotifyCredential, clientID: String) throws { lock.lock(); defer { lock.unlock() }; stored = credential }
    func delete(clientID: String) throws { lock.lock(); defer { lock.unlock() }; stored = nil }
}
struct RejectBrowser: SpotifyAuthorizing {
    func authorize(url: URL, state: String) async throws -> URL { XCTFail("Tests must not open a browser"); throw ProviderError.unauthorized }
}
struct TestAppleAuthorization: AppleMusicAuthorizing {
    func authorize() async throws {}
}
func testCredential(expiresAt: Date = Date().addingTimeInterval(3600)) -> SpotifyCredential {
    .init(accessToken: "test-access", refreshToken: "test-refresh", expiresAt: expiresAt, scopes: SpotifyPKCE.scopes)
}
func spotify(_ transport: ScriptedTransport, store: MemoryCredentialStore = .init()) async throws -> SpotifyProvider {
    let provider = SpotifyProvider(clientID: "public-client", transport: transport, credentialStore: store, authorizer: RejectBrowser(), retryPolicy: .init(maximumReadAttempts: 1))
    _ = try await provider.connect(); return provider
}
func apple(_ transport: ScriptedTransport) async throws -> AppleMusicProvider {
    let provider = AppleMusicProvider(transport: transport, authorization: TestAppleAuthorization(), retryPolicy: .init(maximumReadAttempts: 1))
    _ = try await provider.connect(); return provider
}
let spotifyMe = ScriptedTransport.Step("/v1/me", json: ["id": "user", "display_name": "Test User"])
let appleStorefront = ScriptedTransport.Step("/v1/me/storefront", json: ["data": [["id": "ar", "type": "storefronts"]]])
func spPage(_ items: [Any] = [], offset: Int = 0, total: Int? = nil, next: String? = nil) -> [String: Any] {
    ["items": items, "offset": offset, "total": total ?? items.count, "next": next as Any? ?? NSNull()]
}
func spTrack(_ id: String, isrc: String? = "ARTEST1234567") -> [String: Any] {
    var t: [String: Any] = ["id": id, "type": "track", "name": "Song \(id)", "artists": [["name": "Artist"]],
                           "duration_ms": 120000, "album": ["name": "Album"], "is_playable": true]
    if let isrc { t["external_ids"] = ["isrc": isrc] }; return t
}
func amSong(_ id: String, libraryID: String? = nil) -> [String: Any] {
    let attributes: [String: Any] = ["name": "Song \(id)", "artistName": "Artist", "albumName": "Album", "durationInMillis": 120000,
                                   "isrc": "ARTEST1234567", "playParams": ["id": libraryID ?? id, "catalogId": id]]
    if let libraryID {
        return ["id": libraryID, "type": "library-songs", "attributes": attributes,
                "relationships": ["catalog": ["data": [amSong(id)]]]]
    }
    return ["id": id, "type": "songs", "attributes": attributes]
}
func query(_ request: URLRequest, _ key: String) -> String? {
    URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == key }?.value
}
func body(_ request: URLRequest) throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]) }
func expectError(_ block: () async throws -> Void, matches: (ProviderError) -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
    do { try await block(); XCTFail("Expected provider error", file: file, line: line) }
    catch let error as ProviderError { XCTAssertTrue(matches(error), "Unexpected error: \(error)", file: file, line: line) }
    catch { XCTFail("Unexpected error type: \(type(of: error))", file: file, line: line) }
}
