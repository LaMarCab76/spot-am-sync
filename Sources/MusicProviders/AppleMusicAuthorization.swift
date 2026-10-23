import Foundation
import CryptoKit
import MusicKit
import Security
import SyncCore

public protocol AppleMusicAuthorizing: Sendable {
    func authorize() async throws
}

/// MusicKit supplies both developer and user tokens. No manually supplied token,
/// Apple ID, Music.app automation, or favorites permission is involved.
public struct NativeAppleMusicAuthorization: AppleMusicAuthorizing {
    public init() {}
    public func authorize() async throws {
        try Self.validateApplication()
        let status = await MusicAuthorization.request()
        try Task.checkCancellation()
        switch status {
        case .authorized: return
        case .denied: throw ProviderError.forbidden("El acceso a Apple Music fue denegado. Habilitalo en Ajustes del Sistema > Privacidad y seguridad > Multimedia y Apple Music.")
        case .restricted: throw ProviderError.forbidden("El acceso a Apple Music está restringido por el sistema.")
        case .notDetermined: throw ProviderError.unauthorized
        @unknown default: throw ProviderError.unauthorized
        }
    }
    static func validateApplication(bundle: Bundle = .main) throws {
        guard bundle.bundleURL.pathExtension == "app", let id = bundle.bundleIdentifier, !id.isEmpty,
              let usage = bundle.object(forInfoDictionaryKey: "NSAppleMusicUsageDescription") as? String,
              !usage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderError.unsupported("Apple Music requiere una app macOS empaquetada y firmada, Bundle ID explícito con MusicKit habilitado y NSAppleMusicUsageDescription en Info.plist. Un ejecutable SwiftPM sin empaquetar no puede autorizarse.")
        }
        var code: SecCode?, staticCode: SecStaticCode?, info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCheckValidity(code, [], nil) == errSecSuccess,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any],
              let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty else {
            throw ProviderError.unsupported("Apple Music requiere firma con un equipo de Apple Developer y un App ID con el servicio MusicKit habilitado. La firma ad hoc o ausente no habilita tokens de producción.")
        }
        // MusicKit is an App Service bound to the registered bundle ID. There is no
        // public API for querying that registration; the authenticated storefront
        // request is the runtime check. Do not invent an entitlement key here.
    }
}

/// One provider owns one session transport. The identifier describes the authorized
/// grant, not an Apple ID. Implementations must bind every send to that grant until
/// endSession, never silently acquire another user's credentials, and never log tokens.
/// Tests can implement this boundary without invoking MusicKit or the keychain.
public protocol AppleMusicSessionTransport: ProviderHTTPTransport {
    func beginSession() async throws
    func endSession() async
    func sessionIdentifier() async -> String?
}

// Separate the native SDK boundary so token/header tests need no Apple account.
protocol AppleMusicTokenProviding: Sendable {
    func developerToken() async throws -> String
    func userToken(for developerToken: String) async throws -> String
}

private actor NativeAppleMusicTokenProvider: AppleMusicTokenProviding {
    private let provider = DefaultMusicTokenProvider()
    func developerToken() async throws -> String {
        guard MusicAuthorization.currentStatus == .authorized else { throw ProviderError.unauthorized }
        return try await provider.developerToken(options: [])
    }
    func userToken(for developerToken: String) async throws -> String {
        guard MusicAuthorization.currentStatus == .authorized else { throw ProviderError.unauthorized }
        return try await provider.userToken(for: developerToken, options: [])
    }
}

/// Uses MusicKit's public token provider only when explicitly opening a session.
/// REST calls use an ephemeral URLSession with redirects disabled, not the global
/// MusicDataRequest token provider. Tokens stay in memory and are never refreshed
/// during reads or writes; HTTP 401 requires an explicit reconnect.
public actor MusicKitHTTPTransport: AppleMusicSessionTransport {
    private let tokenProvider: any AppleMusicTokenProviding
    private let transport: any ProviderHTTPTransport
    private var generation = UUID()
    private var session: Session?
    private struct Session {
        let developerToken: String
        let userToken: String
        let identifier: String
    }

    public init() {
        tokenProvider = NativeAppleMusicTokenProvider()
        transport = URLSessionProviderTransport()
    }
    init(tokenProvider: any AppleMusicTokenProviding, transport: any ProviderHTTPTransport) {
        self.tokenProvider = tokenProvider; self.transport = transport
    }
    public func sessionIdentifier() -> String? { session?.identifier }
    public func endSession() { generation = UUID(); session = nil }

    public func beginSession() async throws {
        endSession(); let epoch = generation
        do {
            try check(epoch)
            let developerToken = try await tokenProvider.developerToken()
            try check(epoch)
            guard Self.validToken(developerToken) else { throw ProviderError.unauthorized }
            let userToken = try await tokenProvider.userToken(for: developerToken)
            try check(epoch)
            // Header values must be nonempty printable ASCII; never echo bad values.
            guard Self.validToken(userToken) else { throw ProviderError.unauthorized }
            let digest = SHA256.hash(data: Data(userToken.utf8)).map { String(format: "%02x", $0) }.joined()
            session = Session(developerToken: developerToken, userToken: userToken,
                              identifier: "apple-music-grant:sha256:\(digest)")
        } catch {
            if epoch == generation { endSession() }
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            if case ProviderError.notConnected = error { throw ProviderError.notConnected }
            if case ProviderError.unauthorized = error { throw ProviderError.unauthorized }
            // SDK diagnostics may include tokens. Do not propagate their description.
            throw ProviderError.network("MusicKit no pudo abrir la sesión. Verificá la firma, el App ID con MusicKit habilitado, la autorización y la conexión de red; luego volvé a conectar.")
        }
    }
    private static func validToken(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (33...126).contains($0) }
    }
    private func check(_ epoch: UUID) throws {
        try Task.checkCancellation()
        guard generation == epoch else { throw ProviderError.notConnected }
    }
    public func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        try Task.checkCancellation()
        guard let url = request.url else { throw ProviderError.invalidResponse("URL de Apple Music ausente.") }
        _ = try APIOrigin.apple.url(url.absoluteString)
        guard let session else { throw ProviderError.notConnected }
        let epoch = generation
        var authenticated = request
        authenticated.setValue("Bearer \(session.developerToken)", forHTTPHeaderField: "Authorization")
        authenticated.setValue(session.userToken, forHTTPHeaderField: "Music-User-Token")
        let response: ProviderHTTPResponse
        do { response = try await transport.send(authenticated) }
        catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            // URLSession and injected transports must not leak credential-bearing errors.
            throw ProviderError.network("No se pudo completar la solicitud de Apple Music.")
        }
        let read = request.httpMethod == nil || request.httpMethod == "GET"
        guard epoch == generation, !Task.isCancelled else {
            if !read { throw ProviderError.uncertainWrite("La sesión cambió durante la escritura de Apple Music. Releé la biblioteca.") }
            try check(epoch)
            throw ProviderError.notConnected
        }
        if response.statusCode == 401 { endSession() }
        return response
    }
}
