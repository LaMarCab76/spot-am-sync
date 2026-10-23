import AppKit
import CryptoKit
import Foundation
import Network
import Security
import SyncCore

public struct SpotifyCredential: Codable, Sendable {
    public let accessToken: String
    public let refreshToken: String
    public let expiresAt: Date
    public let scopes: Set<String>
    public init(accessToken: String, refreshToken: String, expiresAt: Date, scopes: Set<String>) {
        self.accessToken = accessToken; self.refreshToken = refreshToken
        self.expiresAt = expiresAt; self.scopes = scopes
    }
}

public protocol SpotifyCredentialStore: Sendable {
    func load(clientID: String) throws -> SpotifyCredential?
    func save(_ credential: SpotifyCredential, clientID: String) throws
    func delete(clientID: String) throws
}

public struct KeychainSpotifyCredentialStore: SpotifyCredentialStore {
    public init() {}
    private func query(_ clientID: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "SpotAMSync.Spotify.PKCE",
         kSecAttrAccount as String: clientID, kSecAttrSynchronizable as String: false]
    }
    public func load(clientID: String) throws -> SpotifyCredential? {
        var q = query(clientID); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let credential = try? JSONDecoder().decode(SpotifyCredential.self, from: data) else {
            throw ProviderError.invalidResponse("No se pudieron leer las credenciales de Spotify del Llavero.")
        }
        return credential
    }
    public func save(_ credential: SpotifyCredential, clientID: String) throws {
        let data = try JSONEncoder().encode(credential)
        let updates = [kSecValueData as String: data] as CFDictionary
        let status = SecItemUpdate(query(clientID) as CFDictionary, updates)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else {
            throw ProviderError.invalidResponse("No se pudo actualizar la credencial en el Llavero.")
        }
        var q = query(clientID); q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else {
            throw ProviderError.invalidResponse("No se pudo guardar la credencial en el Llavero.")
        }
    }
    public func delete(clientID: String) throws {
        let status = SecItemDelete(query(clientID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ProviderError.invalidResponse("No se pudo eliminar la credencial de Spotify del Llavero.")
        }
    }
}

public protocol SpotifyAuthorizing: Sendable {
    /// Returns the redirect URL. The provider independently verifies state and callback origin.
    func authorize(url: URL, state: String) async throws -> URL
}

enum SpotifyPKCE {
    static let redirectURI = "http://127.0.0.1:43821/callback"
    static let scopes: Set<String> = ["playlist-read-private", "playlist-read-collaborative",
        "playlist-modify-private", "playlist-modify-public", "user-library-read", "user-library-modify"]
    static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw ProviderError.invalidResponse("No se pudo generar una autorización segura.")
        }
        return base64URL(Data(bytes))
    }
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func challenge(_ verifier: String) -> String { base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) }
    static func authorizationURL(clientID: String, verifier: String, state: String) -> URL {
        var url = URLComponents(string: "https://accounts.spotify.com/authorize")!
        url.queryItems = ["client_id": clientID, "response_type": "code", "redirect_uri": redirectURI,
            "code_challenge_method": "S256", "code_challenge": challenge(verifier), "state": state,
            "scope": scopes.sorted().joined(separator: " ")].sorted { $0.key < $1.key }.map { .init(name: $0.key, value: $0.value) }
        return url.url!
    }
    static func code(from url: URL, expectedState: String) throws -> String {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false), c.scheme == "http",
              c.host == "127.0.0.1", c.port == 43821, c.path == "/callback", c.fragment == nil,
              c.user == nil, c.password == nil else {
            throw ProviderError.invalidResponse("La redirección OAuth no coincide con el callback registrado.")
        }
        let items = c.queryItems ?? []
        guard items.filter({ $0.name == "state" }).count == 1,
              items.first(where: { $0.name == "state" })?.value == expectedState else {
            throw ProviderError.invalidResponse("El estado OAuth no coincide. Se rechazó la autorización.")
        }
        if items.contains(where: { $0.name == "error" }) { throw ProviderError.forbidden("Se canceló o denegó la autorización de Spotify.") }
        guard items.filter({ $0.name == "code" }).count == 1,
              let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw ProviderError.invalidResponse("Spotify no devolvió un código de autorización.")
        }
        return code
    }
    static func form(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let value = fields.sorted { $0.key < $1.key }.map {
            "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&")
        return Data(value.utf8)
    }
}

/// Opens the system browser after binding only 127.0.0.1:43821. Register exactly
/// http://127.0.0.1:43821/callback in the Spotify dashboard (not localhost).
/// Cancel the calling Task to cancel OAuth; an unattended flow expires after 120s.
public struct SpotifyBrowserAuthorization: SpotifyAuthorizing {
    public let timeout: TimeInterval
    public init(timeout: TimeInterval = 120) { self.timeout = min(300, max(1, timeout)) }
    public func authorize(url: URL, state: String) async throws -> URL {
        let session = SpotifyLoopbackSession(url: url, state: state, timeout: timeout)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await session.run()
        } onCancel: { session.cancel() }
    }
}

private final class SpotifyLoopbackSession: @unchecked Sendable {
    private let queue = DispatchQueue(label: "SpotAMSync.spotify.loopback")
    private let url: URL, state: String, timeout: TimeInterval
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var continuation: CheckedContinuation<URL, Error>?
    private var terminal: Result<URL, Error>?
    private var timer: DispatchWorkItem?
    init(url: URL, state: String, timeout: TimeInterval) { self.url = url; self.state = state; self.timeout = timeout }
    func cancel() { queue.async { self.finish(.failure(CancellationError())) } }
    func run() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                if let result = self.terminal { continuation.resume(with: result); return }
                self.continuation = continuation
                do {
                    let parameters = NWParameters.tcp
                    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: 43821)
                    let listener = try NWListener(using: parameters, on: 43821)
                    self.listener = listener
                    listener.stateUpdateHandler = { [weak self] status in
                        guard let self else { return }
                        switch status {
                        case .ready:
                            Task { @MainActor in
                                guard self.queue.sync(execute: { self.terminal == nil }) else { return }
                                let opened = NSWorkspace.shared.open(self.url)
                                if !opened { self.queue.async { self.finish(.failure(ProviderError.network("No se pudo abrir el navegador del sistema."))) } }
                            }
                        case .failed:
                            self.finish(.failure(ProviderError.network("No se pudo escuchar en 127.0.0.1:43821. Revisá si el puerto está ocupado o falta permiso de red entrante.")))
                        default: break
                        }
                    }
                    listener.newConnectionHandler = { [weak self] connection in
                        guard let self, self.terminal == nil, self.connections.count < 16 else { connection.cancel(); return }
                        self.connections.append(connection); connection.start(queue: self.queue)
                        self.receive(connection, buffer: Data())
                    }
                    let timer = DispatchWorkItem { [weak self] in
                        self?.finish(.failure(ProviderError.network("La autorización de Spotify venció. Volvé a conectar.")))
                    }
                    self.timer = timer; self.queue.asyncAfter(deadline: .now() + self.timeout, execute: timer)
                    listener.start(queue: self.queue)
                } catch { self.finish(.failure(ProviderError.network("No se pudo iniciar el callback local de Spotify en el puerto 43821."))) }
            }
        }
    }
    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
            guard let self, self.terminal == nil else { connection.cancel(); return }
            var buffer = buffer; if let data { buffer.append(data) }
            guard buffer.count <= 16_384, error == nil else { self.close(connection); return }
            guard let request = String(data: buffer, encoding: .utf8), request.contains("\r\n\r\n") else {
                if complete { self.close(connection) } else { self.receive(connection, buffer: buffer) }; return
            }
            let lines = request.components(separatedBy: "\r\n")
            let words = (lines.first ?? "").split(separator: " ")
            let hosts = lines.filter { $0.lowercased().hasPrefix("host:") }
            guard words.count == 3, words[0] == "GET", words[1].hasPrefix("/callback?"),
                  hosts.count == 1, hosts[0].dropFirst(5).trimmingCharacters(in: .whitespaces) == "127.0.0.1:43821",
                  let callback = URL(string: "http://127.0.0.1:43821" + words[1]) else { self.close(connection); return }
            let result: Result<URL, Error>
            do { _ = try SpotifyPKCE.code(from: callback, expectedState: self.state); result = .success(callback) }
            catch { result = .failure(error) }
            // The page is constant; no auth code, state or provider error is echoed.
            let body = "Podés volver a SpotAMSync."
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in self.finish(result) })
        }
    }
    private func close(_ connection: NWConnection) { connection.cancel(); connections.removeAll { $0 === connection } }
    private func finish(_ result: Result<URL, Error>) {
        guard terminal == nil else { return }; terminal = result
        timer?.cancel(); timer = nil; listener?.cancel(); listener = nil
        connections.forEach { $0.cancel() }; connections.removeAll()
        continuation?.resume(with: result); continuation = nil
    }
}
