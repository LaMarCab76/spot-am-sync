import Foundation
import XCTest
import SyncCore
@testable import MusicProviders

/// Exercises the real macOS listener with synthetic OAuth values. No browser,
/// Spotify endpoint, account, token exchange, or Keychain access is involved.
@MainActor
final class SpotifyLoopbackTests: XCTestCase {
    private let authorizationURL = URL(string: "https://example.invalid/authorize")!

    private func completeCallback() async throws {
        let opened = expectation(description: "Browser opens only after the listener is ready")
        let session = SpotifyLoopbackSession(url: authorizationURL, state: "fixture-state", timeout: 5) { url in
            XCTAssertEqual(url.host, "example.invalid")
            opened.fulfill()
            return true
        }
        let authorization = Task { try await session.run() }
        defer { session.cancel(); authorization.cancel() }
        await fulfillment(of: [opened], timeout: 3)

        let callback = URL(string: SpotifyProvider.redirectURI + "?code=fixture-code&state=fixture-state")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        let http = URLSession(configuration: configuration)
        defer { http.invalidateAndCancel() }
        let (data, response) = try await http.data(from: callback)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(text.contains("fixture-code")); XCTAssertFalse(text.contains("fixture-state"))
        let result = try await authorization.value
        XCTAssertEqual(result, callback)
    }

    func testNativeCallbackCompletesAndCanListenAgain() async throws {
        try await completeCallback()
        try await completeCallback()
    }

    func testCancellationReleasesListenerForAnotherAttempt() async throws {
        let opened = expectation(description: "Listener ready")
        let session = SpotifyLoopbackSession(url: authorizationURL, state: "fixture-state", timeout: 5) { _ in
            opened.fulfill(); return true
        }
        let authorization = Task { try await session.run() }
        defer { session.cancel(); authorization.cancel() }
        await fulfillment(of: [opened], timeout: 3)
        session.cancel()
        do { _ = try await authorization.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        try await completeCallback()
    }

    func testBrowserOpenFailureReleasesListenerForAnotherAttempt() async throws {
        let session = SpotifyLoopbackSession(url: authorizationURL, state: "fixture-state", timeout: 5) { _ in false }
        defer { session.cancel() }
        do { _ = try await session.run(); XCTFail("Expected browser error") }
        catch let error as ProviderError { XCTAssertTrue(error.localizedDescription.contains("navegador")) }
        catch { XCTFail("Unexpected error: \(error)") }
        try await completeCallback()
    }
}
