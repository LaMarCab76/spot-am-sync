import Foundation
import XCTest
import SyncCore
@testable import MusicProviders

final class AuthorizationTests: XCTestCase {
    func testNativeBrowserAuthorizationChecksCancellationBeforeBindingOrOpening() async throws {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await SpotifyBrowserAuthorization().authorize(url: URL(string: "https://accounts.spotify.com/authorize")!, state: "state")
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
    }
    func testProviderRejectsMismatchedStateBeforeExchangingCode() async throws {
        struct WrongState: SpotifyAuthorizing {
            func authorize(url: URL, state: String) async throws -> URL { URL(string: SpotifyProvider.redirectURI + "?code=code&state=wrong")! }
        }
        let t = ScriptedTransport([]), store = MemoryCredentialStore(nil)
        let p = SpotifyProvider(clientID: "client", transport: t, credentialStore: store, authorizer: WrongState())
        await expectError({ _ = try await p.connect() }, matches: { if case .invalidResponse = $0 { return true }; return false })
        XCTAssertNil(try store.load(clientID: "client")); let requests = await t.requests; XCTAssertTrue(requests.isEmpty)
    }
    func testRFC7636ChallengeAndRandomness() throws {
        XCTAssertEqual(SpotifyPKCE.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let a = try SpotifyPKCE.random(), b = try SpotifyPKCE.random()
        XCTAssertEqual(a.count, 43); XCTAssertNotEqual(a, b); XCTAssertFalse(a.contains("="))
        let url = SpotifyPKCE.authorizationURL(clientID: "public", verifier: a, state: b)
        let request = URLRequest(url: url)
        XCTAssertEqual(query(request, "redirect_uri"), "http://127.0.0.1:43821/callback")
        XCTAssertEqual(query(request, "code_challenge_method"), "S256")
        XCTAssertEqual(Set((query(request, "scope") ?? "").split(separator: " ").map(String.init)), SpotifyPKCE.scopes)
        XCTAssertNil(query(request, "client_secret"))
    }
    func testStateOriginDuplicateCodeAndDeniedCallbacks() throws {
        let good = URL(string: SpotifyProvider.redirectURI + "?code=ok&state=expected")!
        XCTAssertEqual(try SpotifyPKCE.code(from: good, expectedState: "expected"), "ok")
        for url in ["http://127.0.0.1:43821/callback?code=ok&state=wrong", "http://localhost:43821/callback?code=ok&state=expected",
                    "http://127.0.0.1:43821/callback?code=ok&state=expected&state=expected", "http://127.0.0.1:43821/callback?code=a&code=b&state=expected",
                    "http://127.0.0.1:43821/callback?error=access_denied&state=expected", "http://127.0.0.1:43821/wrong?code=ok&state=expected"] {
            XCTAssertThrowsError(try SpotifyPKCE.code(from: URL(string: url)!, expectedState: "expected"))
        }
    }
    func testPKCEExchangePersistsOnlyValidatedScopeAndNeverClientSecret() async throws {
        struct Authorizer: SpotifyAuthorizing {
            func authorize(url: URL, state: String) async throws -> URL {
                XCTAssertEqual(url.host, "accounts.spotify.com")
                return URL(string: SpotifyProvider.redirectURI + "?code=code&state=" + state)!
            }
        }
        let store = MemoryCredentialStore(nil)
        let t = ScriptedTransport([
            .init("POST", "/api/token", json: ["access_token": "new", "refresh_token": "refresh", "expires_in": 3600,
                "token_type": "Bearer", "scope": SpotifyPKCE.scopes.sorted().joined(separator: " ")], validate: { r in
                    let text = String(data: r.httpBody!, encoding: .utf8)!
                    XCTAssertTrue(text.contains("code_verifier=")); XCTAssertTrue(text.contains("redirect_uri=http%3A%2F%2F127.0.0.1%3A43821%2Fcallback"))
                    XCTAssertFalse(text.contains("client_secret"))
                }), spotifyMe])
        let p = SpotifyProvider(clientID: "public", transport: t, credentialStore: store, authorizer: Authorizer())
        let account = try await p.connect()
        XCTAssertEqual(account.id, "user"); XCTAssertEqual(try store.load(clientID: "public")?.refreshToken, "refresh")
        try await p.disconnect(); XCTAssertNil(try store.load(clientID: "public"))
        await t.assertExhausted()
    }
    func testRefreshRetainsOmittedRefreshTokenAndPersistsRotation() async throws {
        for refresh in [nil, "rotated"] as [String?] {
            let store = MemoryCredentialStore(testCredential(expiresAt: .distantPast))
            var token: [String: Any] = ["access_token": "updated", "expires_in": 3600, "token_type": "Bearer"]
            if let refresh { token["refresh_token"] = refresh }
            let t = ScriptedTransport([.init("POST", "/api/token", json: token), spotifyMe])
            _ = try await spotify(t, store: store)
            XCTAssertEqual(try store.load(clientID: "public-client")?.refreshToken, refresh ?? "test-refresh")
            await t.assertExhausted()
        }
    }
    func testConnectDoesNotInventAccountOnHTTPFailure() async throws {
        let t = ScriptedTransport([.init("/v1/me", status: 403)])
        let p = SpotifyProvider(clientID: "client", transport: t, credentialStore: MemoryCredentialStore(), authorizer: RejectBrowser())
        await expectError({ _ = try await p.connect() }, matches: { if case .forbidden = $0 { return true }; return false })
        await expectError({ _ = try await p.account() }, matches: { if case .notConnected = $0 { return true }; return false })
    }
    func testCancelledConnectDoesNotOpenBrowserOrCreateAccount() async throws {
        struct CancelledAuthorizer: SpotifyAuthorizing {
            func authorize(url: URL, state: String) async throws -> URL { throw CancellationError() }
        }
        let t = ScriptedTransport([])
        let p = SpotifyProvider(clientID: "client", transport: t, credentialStore: MemoryCredentialStore(nil), authorizer: CancelledAuthorizer())
        do { _ = try await p.connect(); XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        await expectError({ _ = try await p.account() }, matches: { if case .notConnected = $0 { return true }; return false })
        await t.assertExhausted()
    }
    func testAppleUnsignedPreflightWithoutAskingForAccountAccess() {
        XCTAssertThrowsError(try NativeAppleMusicAuthorization.validateApplication(bundle: Bundle(for: Self.self))) { error in
            XCTAssertTrue(error.localizedDescription.contains("firmada"))
        }
    }
    func testAppleReconnectPreservesGrantChangesRevisionAndRequiresRealStorefront() async throws {
        let t = ScriptedTransport([appleStorefront, appleStorefront, .init("/v1/me/storefront", json: ["data": []])])
        let p = try await apple(t), before = try await p.account()
        try await p.disconnect(); let after = try await p.connect()
        XCTAssertEqual(before.id, after.id); XCTAssertNotEqual(before.connectionRevision, after.connectionRevision)
        XCTAssertEqual(after.id, "apple-music-grant:test-fixture"); XCTAssertEqual(after.storefront, "ar")
        await expectError({ _ = try await p.connect() }, matches: { if case .invalidResponse = $0 { return true }; return false })
        await expectError({ _ = try await p.account() }, matches: { if case .notConnected = $0 { return true }; return false })
        let identifier = await t.sessionIdentifier(); XCTAssertNil(identifier)
    }
}
