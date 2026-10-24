import Foundation
import XCTest
import SyncCore
@testable import MusicProviders

final class HTTPAndPaginationTests: XCTestCase {
    func testHTTPRedirectsCannotForwardCredentialsEvenWithinSameOrigin() throws {
        let transport = URLSessionProviderTransport(), session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let original = try APIOrigin.apple.url("/v1/me/library/songs")
        let task = session.dataTask(with: original) // Deliberately never resumed; no network.
        let response = try XCTUnwrap(HTTPURLResponse(url: original, statusCode: 307, httpVersion: nil, headerFields: nil))
        for destination in ["https://evil.example/v1/me/library/songs", "https://api.music.apple.com/v1/me/library/albums"] {
            var request = URLRequest(url: URL(string: destination)!)
            request.setValue("Bearer fixture-developer", forHTTPHeaderField: "Authorization")
            request.setValue("fixture-user", forHTTPHeaderField: "Music-User-Token")
            var completed = false
            transport.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: request) {
                XCTAssertNil($0); completed = true
            }
            XCTAssertTrue(completed)
        }
    }
    func testTrustedOriginsRejectInjectedNextURLs() throws {
        for path in ["https://evil.example/v1/me/tracks", "//evil.example/v1/me/tracks", "http://api.spotify.com/v1/me/tracks",
                     "https://api.spotify.com.evil.example/v1/me/tracks", "https://name@api.spotify.com/v1/me/tracks",
                     "https://api.spotify.com:444/v1/me/tracks", "https://api.spotify.com/v1/me/tracks#secret", "/api/token"] {
            XCTAssertThrowsError(try APIOrigin.spotify.url(path), path)
        }
        XCTAssertEqual(try APIOrigin.apple.url("/v1/me/library/songs?offset=100").host, "api.music.apple.com")
    }
    func testPartialFailurePreservesPriorPageAndDoesNotSendHostileNext() async throws {
        let t = ScriptedTransport([.init("/v1/me/tracks", json: spPage([1], total: 2, next: "https://evil.example/v1/me/tracks"))])
        let h = ProviderHTTP(transport: t, retry: .init(maximumReadAttempts: 1))
        let result = try await collectPages(origin: .spotify, path: "/v1/me/tracks", spotify: true) {
            try JSONValue.decode(await h.send(URLRequest(url: $0)).data)
        }
        XCTAssertEqual(result.items.count, 1); XCTAssertFalse(result.complete); XCTAssertFalse(result.notes.isEmpty)
        await t.assertExhausted(); let requests = await t.requests; XCTAssertEqual(requests.count, 1)
    }
    func testPageCycleMissingTotalMalformedAndPrematureTerminationAreIncomplete() async throws {
        let fixtures: [Any] = [spPage([1], total: 2), ["items": [], "next": NSNull(), "offset": 0],
                               spPage([1], total: 2, next: "/v1/me/tracks"), ["notItems": []]]
        for fixture in fixtures {
            let t = ScriptedTransport([.init("/v1/me/tracks", json: fixture)])
            let h = ProviderHTTP(transport: t, retry: .init())
            let result = try await collectPages(origin: .spotify, path: "/v1/me/tracks", spotify: true) {
                try JSONValue.decode(await h.send(URLRequest(url: $0)).data)
            }
            XCTAssertFalse(result.complete); await t.assertExhausted()
        }
    }
    func testReadRetryAfterIsBoundedAndDateHeaderIsParsed() async throws {
        let long = ScriptedTransport([.init("/v1/me/tracks", status: 429, headers: ["Retry-After": "7200"])])
        let h = ProviderHTTP(transport: long, retry: .init(), sleep: { _ in XCTFail("Must not wait hours") })
        await expectError({ _ = try await h.send(URLRequest(url: APIOrigin.spotify.url("/v1/me/tracks"))) }, matches: {
            if case .rateLimited(let seconds) = $0 { return seconds == 7200 }; return false
        })
        let short = ScriptedTransport([.init("/v1/me/tracks", status: 429, headers: ["Retry-After": "1"]), .init("/v1/me/tracks", json: spPage())])
        let h2 = ProviderHTTP(transport: short, retry: .init(), sleep: { XCTAssertEqual($0, 1) })
        _ = try await h2.send(URLRequest(url: APIOrigin.spotify.url("/v1/me/tracks"))); await short.assertExhausted()
        let date = ProviderHTTPResponse(statusCode: 429, headers: ["Retry-After": "Thu, 01 Jan 1970 00:00:03 GMT"])
        XCTAssertEqual(ProviderHTTP.retryAfter(date, now: Date(timeIntervalSince1970: 0)), 3)
    }
    func testWritesNeverRetryAndServerFailureIsUncertain() async throws {
        for status in [429, 500] {
            let t = ScriptedTransport([.init("POST", "/v1/me/playlists", status: status, headers: ["Retry-After": "0"])])
            let h = ProviderHTTP(transport: t, retry: .init(), sleep: { _ in XCTFail("Write retry") })
            var request = URLRequest(url: try APIOrigin.spotify.url("/v1/me/playlists")); request.httpMethod = "POST"
            await expectError({ _ = try await h.send(request) }, matches: {
                switch $0 { case .uncertainWrite: return status == 500; case .rateLimited: return status == 429; default: return false }
            })
            let requests = await t.requests; XCTAssertEqual(requests.count, 1)
        }
    }
    func testMalformedAndSuccessErrorBodyAreExplicit() {
        for text in ["<html>Bad gateway</html>", "[]", "{\"error\":{\"message\":\"secret\"}}", "{\"errors\":[{}]}"] {
            XCTAssertThrowsError(try JSONValue.decode(Data(text.utf8))) { XCTAssertFalse($0.localizedDescription.contains("secret")) }
        }
    }
    func testTransportErrorsDoNotLeakSensitiveDetails() async throws {
        struct Failing: ProviderHTTPTransport {
            func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
                throw NSError(domain: "secret_access_token", code: 1, userInfo: [NSLocalizedDescriptionKey: "secret_access_token"])
            }
        }
        let h = ProviderHTTP(transport: Failing(), retry: .init())
        do { _ = try await h.send(URLRequest(url: APIOrigin.spotify.url("/v1/me"))); XCTFail() }
        catch { XCTAssertFalse(error.localizedDescription.contains("secret_access_token")) }
    }
}
