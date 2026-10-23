import Foundation
import XCTest
import SyncCore
@testable import MusicProviders

private actor FixtureAppleTokens: AppleMusicTokenProviding {
    private var developer: String
    private var user: String
    private(set) var developerCalls = 0
    private(set) var userCalls = 0
    init(developer: String = "fixture-developer-A", user: String = "fixture-user-A") {
        self.developer = developer; self.user = user
    }
    func change(developer: String = "fixture-developer-B", user: String = "fixture-user-B") {
        self.developer = developer; self.user = user
    }
    func developerToken() -> String { developerCalls += 1; return developer }
    func userToken(for developerToken: String) -> String {
        userCalls += 1; XCTAssertEqual(developerToken, developer); return user
    }
}

private actor SessionGate {
    let entered: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    init(_ entered: XCTestExpectation) { self.entered = entered }
    func pause() async {
        entered.fulfill()
        if !released { await withCheckedContinuation { continuation = $0 } }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}

private struct GatedAppleTokens: AppleMusicTokenProviding {
    let gate: SessionGate
    func developerToken() async throws -> String { "fixture-developer-A" }
    func userToken(for developerToken: String) async throws -> String {
        await gate.pause(); return "fixture-user-A"
    }
}

private struct GatedAppleHTTP: ProviderHTTPTransport {
    let gate: SessionGate
    let upstream: ScriptedTransport
    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        if request.url?.path != "/v1/me/storefront" { await gate.pause() }
        return try await upstream.send(request)
    }
}

final class AppleMusicSessionTests: XCTestCase {
    private func provider(_ session: any AppleMusicSessionTransport) -> AppleMusicProvider {
        AppleMusicProvider(transport: session, authorization: TestAppleAuthorization())
    }
    private var emptyLibrary: [ScriptedTransport.Step] {
        [.init("/v1/me/library/playlists", json: ["data": []]),
         .init("/v1/me/library/songs", json: ["data": []]),
         .init("/v1/me/library/albums", json: ["data": []])]
    }
    private var save: SyncOperation {
        .init(service: .appleMusic, kind: .saveTracks, title: "Save",
              tracks: [Track(id: "1", catalogID: "1", title: "One", artist: "Artist")])
    }

    func testSameGrantSurvivesNewProviderAndDeveloperTokenButOtherGrantWithIdenticalLibraryDiffers() async throws {
        var accounts: [ConnectedAccount] = [], libraries: [LibrarySnapshot] = []
        for (developer, user) in [("fixture-developer-A", "fixture-user-A"),
                                  ("fixture-developer-B", "fixture-user-A"),
                                  ("fixture-developer-B", "fixture-user-B")] {
            let http = ScriptedTransport([appleStorefront] + emptyLibrary)
            let tokens = FixtureAppleTokens(developer: developer, user: user)
            let transport = MusicKitHTTPTransport(tokenProvider: tokens, transport: http)
            let p = provider(transport)
            let account = try await p.connect()
            accounts.append(account); libraries.append(try await p.fetchLibrary())
            XCTAssertEqual(account.displayName, "Apple Music (sesión autorizada)")
            XCTAssertFalse(account.displayName.contains(account.id))
            let persisted = String(decoding: try JSONEncoder().encode(account), as: UTF8.self)
            XCTAssertFalse(persisted.contains(developer)); XCTAssertFalse(persisted.contains(user))
            try await p.disconnect(); await http.assertExhausted()
        }
        XCTAssertEqual(accounts[0].id, accounts[1].id)
        XCTAssertNotEqual(accounts[1].id, accounts[2].id)
        XCTAssertEqual(Set(accounts.map(\.connectionRevision)).count, 3)
        XCTAssertTrue(accounts[0].id.hasPrefix("apple-music-grant:sha256:"))
        XCTAssertEqual(accounts[0].id.count, "apple-music-grant:sha256:".count + 64)
        XCTAssertTrue(libraries.allSatisfy { $0.complete && $0.playlists.isEmpty && $0.savedTracks.isEmpty && $0.savedAlbums.isEmpty })
    }

    func testExplicitReconnectSameGrantHasNewRevisionAndReacquiresTokens() async throws {
        let http = ScriptedTransport([appleStorefront, appleStorefront])
        let tokens = FixtureAppleTokens(), transport = MusicKitHTTPTransport(tokenProvider: tokens, transport: http)
        let p = provider(transport), before = try await p.connect()
        await tokens.change(user: "fixture-user-A")
        let after = try await p.connect()
        XCTAssertEqual(before.id, after.id); XCTAssertNotEqual(before.connectionRevision, after.connectionRevision)
        let calls = await tokens.userCalls; XCTAssertEqual(calls, 2)
        await http.assertExhausted()
    }

    func testHeadersStayPinnedForReadsAndWritesAfterGlobalTokenSourceChanges() async throws {
        func validate(_ request: URLRequest) {
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-developer-A")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Music-User-Token"), "fixture-user-A")
        }
        let http = ScriptedTransport([
            .init("/v1/me/library/songs", json: ["data": []], validate: validate),
            .init("POST", "/v1/me/library", status: 202, validate: validate)])
        let tokens = FixtureAppleTokens(), transport = MusicKitHTTPTransport(tokenProvider: tokens, transport: http)
        try await transport.beginSession()
        let before = await transport.sessionIdentifier()
        await tokens.change()
        for method in ["GET", "POST"] {
            let path = method == "GET" ? "/v1/me/library/songs" : "/v1/me/library"
            var request = URLRequest(url: try APIOrigin.apple.url(path)); request.httpMethod = method
            request.setValue("untrusted-developer", forHTTPHeaderField: "Authorization")
            request.setValue("untrusted-user", forHTTPHeaderField: "Music-User-Token")
            _ = try await transport.send(request)
        }
        let after = await transport.sessionIdentifier(), developerCalls = await tokens.developerCalls, userCalls = await tokens.userCalls
        XCTAssertEqual(before, after); XCTAssertEqual(developerCalls, 1); XCTAssertEqual(userCalls, 1)
        await http.assertExhausted()
    }

    func testTokensCannotBeSentOutsideAppleAPIOrigin() async throws {
        let http = ScriptedTransport([]), tokens = FixtureAppleTokens()
        let transport = MusicKitHTTPTransport(tokenProvider: tokens, transport: http)
        try await transport.beginSession()
        for url in ["https://evil.example/v1/me/library", "https://api.music.apple.com.evil.example/v1/me/library",
                    "http://api.music.apple.com/v1/me/library", "https://api.music.apple.com:444/v1/me/library",
                    "https://user@api.music.apple.com/v1/me/library", "https://api.music.apple.com/v1/me/library#fragment"] {
            await expectError({ _ = try await transport.send(URLRequest(url: URL(string: url)!)) }, matches: {
                if case .invalidResponse = $0 { return true }; return false
            })
        }
        let requests = await http.requests; XCTAssertTrue(requests.isEmpty)
    }

    func testDisconnectClearsAccountAndSessionAndBlocksFurtherRequests() async throws {
        let http = ScriptedTransport([appleStorefront]), tokens = FixtureAppleTokens()
        let transport = MusicKitHTTPTransport(tokenProvider: tokens, transport: http), p = provider(transport)
        _ = try await p.connect(); try await p.disconnect()
        let identifier = await transport.sessionIdentifier(); XCTAssertNil(identifier)
        await expectError({ _ = try await p.account() }, matches: { if case .notConnected = $0 { return true }; return false })
        await expectError({ _ = try await transport.send(URLRequest(url: APIOrigin.apple.url("/v1/me/storefront"))) }, matches: {
            if case .notConnected = $0 { return true }; return false
        })
        let requests = await http.requests, calls = await tokens.userCalls
        XCTAssertEqual(requests.count, 1); XCTAssertEqual(calls, 1)
    }

    func test401OnReadOrWriteInvalidatesSessionWithoutReplayOrBindingNewUser() async throws {
        for method in ["GET", "POST"] {
            let failure = ScriptedTransport.Step(method, method == "GET" ? "/v1/me/library/playlists" : "/v1/me/library", status: 401)
            let http = ScriptedTransport([appleStorefront, failure, appleStorefront]), tokens = FixtureAppleTokens()
            let transport = MusicKitHTTPTransport(tokenProvider: tokens, transport: http), p = provider(transport)
            let before = try await p.connect(); await tokens.change()
            await expectError({
                if method == "GET" { _ = try await p.fetchLibrary() } else { _ = try await p.perform(self.save) }
            }, matches: { if case .unauthorized = $0 { return true }; return false })
            let identifier = await transport.sessionIdentifier(), calls = await tokens.userCalls, requests = await http.requests
            XCTAssertNil(identifier); XCTAssertEqual(calls, 1); XCTAssertEqual(requests.count, 2)
            XCTAssertEqual(requests.last?.value(forHTTPHeaderField: "Music-User-Token"), "fixture-user-A")
            await expectError({ _ = try await p.account() }, matches: { if case .notConnected = $0 { return true }; return false })
            await expectError({ _ = try await p.perform(self.save) }, matches: { if case .notConnected = $0 { return true }; return false })
            let after = try await p.connect()
            XCTAssertNotEqual(before.id, after.id); XCTAssertNotEqual(before.connectionRevision, after.connectionRevision)
            await http.assertExhausted()
        }
    }

    func test401AfterPlaylistCreationRemainsUncertainAndPreservesRecoveryID() async throws {
        let http = ScriptedTransport([appleStorefront,
            .init("POST", "/v1/me/library/playlists", status: 201, json: ["data": [["id": "p.created", "type": "library-playlists"]]]),
            .init("POST", "/v1/me/library/playlists/p.created/tracks", status: 401)])
        let tokens = FixtureAppleTokens(), transport = MusicKitHTTPTransport(tokenProvider: tokens, transport: http)
        let p = provider(transport); _ = try await p.connect()
        await expectError({ _ = try await p.perform(.init(service: .appleMusic, kind: .createPlaylist, title: "Create", playlistName: "New", tracks: self.save.tracks)) }, matches: {
            if case .uncertainWrite(let message) = $0 { return message.contains("p.created") }; return false
        })
        let identifier = await transport.sessionIdentifier(), calls = await tokens.userCalls
        XCTAssertNil(identifier); XCTAssertEqual(calls, 1); await http.assertExhausted()
    }

    func testFailedStorefrontDiscardsTokensAndDoesNotPublishIdentity() async throws {
        for step in [ScriptedTransport.Step("/v1/me/storefront", status: 403), .init("/v1/me/storefront", json: ["data": []])] {
            let http = ScriptedTransport([step]), tokens = FixtureAppleTokens()
            let transport = MusicKitHTTPTransport(tokenProvider: tokens, transport: http), p = provider(transport)
            await expectError({ _ = try await p.connect() }, matches: {
                switch $0 { case .forbidden, .invalidResponse: return true; default: return false }
            })
            let identifier = await transport.sessionIdentifier(); XCTAssertNil(identifier)
            await expectError({ _ = try await p.account() }, matches: { if case .notConnected = $0 { return true }; return false })
            await http.assertExhausted()
        }
    }

    func testAuthorizationFailureCannotAcquireTokensOrSendRequests() async throws {
        struct Denied: AppleMusicAuthorizing { func authorize() async throws { throw ProviderError.unauthorized } }
        let tokens = FixtureAppleTokens(), http = ScriptedTransport([])
        let transport = MusicKitHTTPTransport(tokenProvider: tokens, transport: http)
        let p = AppleMusicProvider(transport: transport, authorization: Denied())
        await expectError({ _ = try await p.connect() }, matches: { if case .unauthorized = $0 { return true }; return false })
        let calls = await tokens.developerCalls, identifier = await transport.sessionIdentifier(), requests = await http.requests
        XCTAssertEqual(calls, 0); XCTAssertNil(identifier); XCTAssertTrue(requests.isEmpty)
    }

    func testPlainTransportCannotInventFallbackIdentity() async throws {
        struct Plain: ProviderHTTPTransport {
            func send(_ request: URLRequest) async throws -> ProviderHTTPResponse { XCTFail("Unbound request"); return .init(statusCode: 200) }
        }
        let p = AppleMusicProvider(transport: Plain(), authorization: TestAppleAuthorization())
        await expectError({ _ = try await p.connect() }, matches: { if case .unsupported = $0 { return true }; return false })
        await expectError({ _ = try await p.account() }, matches: { if case .notConnected = $0 { return true }; return false })
    }

    func testSessionWithoutIdentifierFailsBeforeStorefrontAndIsCleared() async throws {
        actor MissingIdentity: AppleMusicSessionTransport {
            let identifier: String?
            private(set) var active = false
            init(_ identifier: String?) { self.identifier = identifier }
            func beginSession() { active = true }
            func endSession() { active = false }
            func sessionIdentifier() -> String? { identifier }
            func send(_ request: URLRequest) async throws -> ProviderHTTPResponse { XCTFail("Request without identity"); return .init(statusCode: 200) }
        }
        for identifier: String? in [nil, ""] {
            let session = MissingIdentity(identifier), p = provider(session)
            await expectError({ _ = try await p.connect() }, matches: { if case .invalidResponse = $0 { return true }; return false })
            let active = await session.active; XCTAssertFalse(active)
            await expectError({ _ = try await p.account() }, matches: { if case .notConnected = $0 { return true }; return false })
        }
    }

    func testSDKAndTransportErrorsNeverExposeTokenDiagnostics() async throws {
        struct FailingTokens: AppleMusicTokenProviding {
            let failDeveloper: Bool
            func developerToken() async throws -> String {
                if failDeveloper { throw ProviderError.network("fixture-developer-A fixture-user-A") }; return "fixture-developer-A"
            }
            func userToken(for developerToken: String) async throws -> String {
                throw NSError(domain: "fixture-developer-A", code: 1, userInfo: [NSLocalizedDescriptionKey: "fixture-user-A"])
            }
        }
        struct FailingHTTP: ProviderHTTPTransport {
            func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
                throw ProviderError.network("fixture-developer-A fixture-user-A")
            }
        }
        for failDeveloper in [false, true] {
            let transport = MusicKitHTTPTransport(tokenProvider: FailingTokens(failDeveloper: failDeveloper), transport: ScriptedTransport([]))
            do { try await transport.beginSession(); XCTFail("Expected token failure") }
            catch { assertRedacted(error) }
            let identifier = await transport.sessionIdentifier(); XCTAssertNil(identifier)
        }
        let transport = MusicKitHTTPTransport(tokenProvider: FixtureAppleTokens(), transport: FailingHTTP())
        try await transport.beginSession()
        for method in ["GET", "POST"] {
            var request = URLRequest(url: try APIOrigin.apple.url("/v1/me/library")); request.httpMethod = method
            do { _ = try await ProviderHTTP(transport: transport, retry: .init()).send(request); XCTFail("Expected transport failure") }
            catch { assertRedacted(error) }
        }
    }
    private func assertRedacted(_ error: Error, file: StaticString = #filePath, line: UInt = #line) {
        let diagnostics = error.localizedDescription + String(describing: error) + String(reflecting: error)
        XCTAssertFalse(diagnostics.contains("fixture-developer-A"), file: file, line: line)
        XCTAssertFalse(diagnostics.contains("fixture-user-A"), file: file, line: line)
    }

    func testEmptyOrHeaderInjectedTokensCannotOpenSession() async throws {
        for (developer, user) in [("", "user"), ("dev", ""), ("dev\r\nInjected: bad", "user"), ("dev", "user\nInjected: bad")] {
            let transport = MusicKitHTTPTransport(tokenProvider: FixtureAppleTokens(developer: developer, user: user), transport: ScriptedTransport([]))
            await expectError({ try await transport.beginSession() }, matches: { if case .unauthorized = $0 { return true }; return false })
            let identifier = await transport.sessionIdentifier(); XCTAssertNil(identifier)
        }
    }

    func testDisconnectWhileAcquiringTokensCannotResurrectSession() async throws {
        let entered = expectation(description: "Token request entered"), http = ScriptedTransport([])
        let gate = SessionGate(entered)
        let transport = MusicKitHTTPTransport(tokenProvider: GatedAppleTokens(gate: gate), transport: http), p = provider(transport)
        let task = Task { try await p.connect() }
        await fulfillment(of: [entered], timeout: 2)
        try await p.disconnect(); await gate.release()
        await expectError({ _ = try await task.value }, matches: { if case .notConnected = $0 { return true }; return false })
        let identifier = await transport.sessionIdentifier(), requests = await http.requests
        XCTAssertNil(identifier); XCTAssertTrue(requests.isEmpty)
    }

    func testCancellationWhileAcquiringTokensLeavesNoSessionOrAccount() async throws {
        let entered = expectation(description: "Token request entered"), http = ScriptedTransport([])
        let gate = SessionGate(entered)
        let transport = MusicKitHTTPTransport(tokenProvider: GatedAppleTokens(gate: gate), transport: http), p = provider(transport)
        let task = Task { try await p.connect() }
        await fulfillment(of: [entered], timeout: 2)
        task.cancel(); await gate.release()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        let identifier = await transport.sessionIdentifier(), requests = await http.requests
        XCTAssertNil(identifier); XCTAssertTrue(requests.isEmpty)
        await expectError({ _ = try await p.account() }, matches: { if case .notConnected = $0 { return true }; return false })
    }

    func testDisconnectDuringWriteKeepsOutcomeUncertainWithoutReauth() async throws {
        let entered = expectation(description: "Write entered"), tokens = FixtureAppleTokens()
        let gate = SessionGate(entered), http = ScriptedTransport([appleStorefront, .init("POST", "/v1/me/library", status: 202)])
        let transport = MusicKitHTTPTransport(tokenProvider: tokens, transport: GatedAppleHTTP(gate: gate, upstream: http))
        let p = provider(transport); _ = try await p.connect()
        let task = Task { try await p.perform(self.save) }
        await fulfillment(of: [entered], timeout: 2)
        try await p.disconnect(); await gate.release()
        await expectError({ _ = try await task.value }, matches: { if case .uncertainWrite = $0 { return true }; return false })
        let identifier = await transport.sessionIdentifier(), calls = await tokens.userCalls
        XCTAssertNil(identifier); XCTAssertEqual(calls, 1); await http.assertExhausted()
    }

    func testLate401FromOldSessionCannotInvalidateNewGrant() async throws {
        let entered = expectation(description: "Read entered"), tokens = FixtureAppleTokens()
        let gate = SessionGate(entered), http = ScriptedTransport([.init("/v1/me/library/songs", status: 401)])
        let transport = MusicKitHTTPTransport(tokenProvider: tokens, transport: GatedAppleHTTP(gate: gate, upstream: http))
        try await transport.beginSession()
        let before = await transport.sessionIdentifier()
        let task = Task { try await transport.send(URLRequest(url: APIOrigin.apple.url("/v1/me/library/songs"))) }
        await fulfillment(of: [entered], timeout: 2)
        await tokens.change(); try await transport.beginSession()
        let newGrant = await transport.sessionIdentifier(); XCTAssertNotEqual(before, newGrant)
        await gate.release()
        await expectError({ _ = try await task.value }, matches: { if case .notConnected = $0 { return true }; return false })
        let identifier = await transport.sessionIdentifier(); XCTAssertEqual(identifier, newGrant)
        await http.assertExhausted()
    }
}
