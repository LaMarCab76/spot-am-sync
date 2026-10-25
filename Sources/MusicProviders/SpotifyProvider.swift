import Foundation
import SyncCore

/// Spotify Web API adapter (February 2026 endpoint contract).
/// Configure the public client ID in the UI and register `redirectURI` verbatim.
/// No client secret is required or accepted. Credentials live in the macOS Keychain.
/// API references: https://developer.spotify.com/documentation/web-api/references/changes/february-2026
/// and https://developer.spotify.com/documentation/web-api/reference/save-library-items
public actor SpotifyProvider: MusicProvider {
    public nonisolated let service: MusicService = .spotify
    public nonisolated let mutationLimits: MutationLimits? = .init(libraryItems: 40, playlistItems: 100)
    public nonisolated static let redirectURI = SpotifyPKCE.redirectURI
    public nonisolated let clientID: String
    private let http: ProviderHTTP
    private let credentialStore: any SpotifyCredentialStore
    private let authorizer: any SpotifyAuthorizing
    private var credential: SpotifyCredential?
    private var connected: ConnectedAccount?
    private var generation = UUID()
    private var busy = false
    private var authorizationTask: Task<URL, Error>?
    private var refreshTask: Task<SpotifyCredential, Error>?
    private var searchCache: [TrackSearchQuery: (Date, TrackSearchResult)] = [:]
    private var searchResumeAt = Date.distantPast
    private var apiResumeAt = Date.distantPast
    private var readObserver: LibraryReadObserver?
    private var readProgress: LibraryReadProgress?

    public init(clientID: String) {
        self.clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        http = ProviderHTTP(transport: URLSessionProviderTransport(), retry: .init())
        credentialStore = KeychainSpotifyCredentialStore(); authorizer = SpotifyBrowserAuthorization()
    }
    public init(clientID: String, transport: any ProviderHTTPTransport,
                credentialStore: any SpotifyCredentialStore, authorizer: any SpotifyAuthorizing,
                retryPolicy: ProviderRetryPolicy = .init()) {
        self.clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        http = ProviderHTTP(transport: transport, retry: retryPolicy)
        self.credentialStore = credentialStore; self.authorizer = authorizer
    }
    private func begin() throws {
        guard !busy else { throw ProviderError.unsupported("Ya hay una operación de Spotify en curso.") }
        busy = true
    }
    public func account() throws -> ConnectedAccount {
        guard let connected else { throw ProviderError.notConnected }; return connected
    }
    public func capabilities() -> ProviderCapabilities { .spotify }

    /// Reuses a Keychain grant when present, but validates `/me` before publishing
    /// a connected state. `disconnect()` removes that grant; connect then asks again.
    public func connect() async throws -> ConnectedAccount {
        try begin(); defer { busy = false; authorizationTask = nil }
        guard !clientID.isEmpty else { throw ProviderError.unsupported("Ingresá el Client ID público de tu aplicación Spotify.") }
        generation = UUID(); let epoch = generation
        connected = nil; credential = nil
        searchCache.removeAll(); searchResumeAt = .distantPast
        do {
            if let stored = try credentialStore.load(clientID: clientID), SpotifyPKCE.scopes.isSubset(of: stored.scopes) {
                credential = stored
            } else {
                let verifier = try SpotifyPKCE.random(), state = try SpotifyPKCE.random()
                let url = SpotifyPKCE.authorizationURL(clientID: clientID, verifier: verifier, state: state)
                let task = Task { try await authorizer.authorize(url: url, state: state) }
                authorizationTask = task
                let callback = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
                try check(epoch)
                let code = try SpotifyPKCE.code(from: callback, expectedState: state)
                credential = try await exchange(["grant_type": "authorization_code", "code": code,
                    "redirect_uri": Self.redirectURI, "code_verifier": verifier, "client_id": clientID], previous: nil)
                try check(epoch)
                try credentialStore.save(credential!, clientID: clientID)
            }
            let profile = try await get(try APIOrigin.spotify.url("/v1/me"))
            try check(epoch)
            guard let id = profile["id"].nonempty else { throw ProviderError.invalidResponse("Spotify no devolvió el identificador de cuenta.") }
            let result = ConnectedAccount(id: id, service: .spotify, displayName: profile["display_name"].nonempty ?? id)
            connected = result; return result
        } catch { connected = nil; credential = nil; throw error }
    }
    public func disconnect() async throws {
        generation = UUID(); authorizationTask?.cancel(); refreshTask?.cancel()
        connected = nil; credential = nil
        try credentialStore.delete(clientID: clientID)
    }
    private func check(_ epoch: UUID) throws {
        try Task.checkCancellation()
        guard generation == epoch else { throw ProviderError.notConnected }
    }
    private func exchange(_ fields: [String: String], previous: SpotifyCredential?) async throws -> SpotifyCredential {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"; request.httpBody = SpotifyPKCE.form(fields)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let response = try await http.send(request)
        let json = try JSONValue.decode(response.data)
        guard let token = json["access_token"].nonempty, json["token_type"].string?.lowercased() == "bearer",
              let expires = json["expires_in"].int, expires > 0,
              let refresh = json["refresh_token"].nonempty ?? previous?.refreshToken, !refresh.isEmpty else {
            throw ProviderError.invalidResponse("La respuesta de autorización de Spotify está incompleta.")
        }
        let scopes = json["scope"].string.map { Set($0.split(separator: " ").map(String.init)) } ?? previous?.scopes ?? []
        guard SpotifyPKCE.scopes.isSubset(of: scopes) else {
            throw ProviderError.forbidden("Spotify no concedió todos los permisos de biblioteca y playlists. Volvé a conectar.")
        }
        return SpotifyCredential(accessToken: token, refreshToken: refresh, expiresAt: Date().addingTimeInterval(Double(expires)), scopes: scopes)
    }
    private func accessToken(forceRefresh: Bool = false) async throws -> String {
        guard let credential else { throw ProviderError.notConnected }
        if !forceRefresh && credential.expiresAt.timeIntervalSinceNow > 60 { return credential.accessToken }
        let epoch = generation
        if let refreshTask { return try await refreshTask.value.accessToken }
        let task = Task {
            try await self.exchange(["grant_type": "refresh_token", "refresh_token": credential.refreshToken,
                                     "client_id": self.clientID], previous: credential)
        }
        refreshTask = task; defer { refreshTask = nil }
        let updated = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        try check(epoch)
        // Persist rotated refresh tokens before replacing the in-memory grant. A failed
        // Keychain update fails the operation instead of silently losing the rotation.
        try credentialStore.save(updated, clientID: clientID)
        self.credential = updated; return updated.accessToken
    }
    private func request(_ url: URL, method: String = "GET", body: Data? = nil, budget: CatalogRequestBudget? = nil) async throws -> ProviderHTTPResponse {
        _ = try APIOrigin.spotify.url(url.absoluteString)
        try Task.checkCancellation()
        if apiResumeAt > Date() { throw ProviderError.rateLimited(seconds: Int(ceil(apiResumeAt.timeIntervalSinceNow))) }
        let epoch = generation, token = try await accessToken()
        try check(epoch)
        var request = URLRequest(url: url); request.httpMethod = method; request.httpBody = body
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let response: ProviderHTTPResponse
        do { response = try await sendAPI(request, budget: budget) }
        catch ProviderError.unauthorized where method == "GET" {
            let token = try await accessToken(forceRefresh: true); try check(epoch)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            response = try await sendAPI(request, budget: budget)
        }
        if method == "GET" { try check(epoch) }
        else if generation != epoch || Task.isCancelled {
            throw ProviderError.uncertainWrite("La conexión cambió durante una escritura. Releé el estado antes de reintentar.")
        }
        return response
    }
    private func sendAPI(_ request: URLRequest, budget: CatalogRequestBudget?) async throws -> ProviderHTTPResponse {
        do {
            return try await http.send(request, budget: budget, onRetry: { [weak self] seconds in
                await self?.reportWait(seconds)
            })
        } catch ProviderError.rateLimited(let seconds) {
            apiResumeAt = Date().addingTimeInterval(Double(seconds))
            await reportWait(Double(seconds))
            throw ProviderError.rateLimited(seconds: seconds)
        }
    }
    private func reportWait(_ seconds: TimeInterval) async {
        guard var update = readProgress else { return }
        update.waitingUntil = Date().addingTimeInterval(seconds)
        readProgress = update
        await readObserver?(update)
    }
    private func report(_ update: LibraryReadProgress) async throws {
        try Task.checkCancellation()
        readProgress = update
        await readObserver?(update)
        try Task.checkCancellation()
    }
    private func get(_ url: URL, budget: CatalogRequestBudget? = nil) async throws -> JSONValue { try JSONValue.decode(await request(url, budget: budget).data) }
    private func pages(_ path: String, initial: JSONValue? = nil, envelope: String? = nil,
                       onPage: (([JSONValue], Int, Int?) async throws -> Void)? = nil) async throws -> CollectedPage {
        let result = try await collectPages(origin: .spotify, path: path, initial: initial, spotify: true, envelope: envelope,
                                            onPage: onPage) { try await self.get($0) }
        // A quota response applies to the entire read: do not continue with another collection.
        if case .rateLimited(let seconds) = result.failure { throw ProviderError.rateLimited(seconds: seconds) }
        return result
    }

    public func fetchLibrary() async throws -> LibrarySnapshot {
        try await fetchLibrary(progress: { _ in })
    }

    public func fetchLibrary(progress: @escaping LibraryReadObserver) async throws -> LibrarySnapshot {
        try begin()
        defer { busy = false; readObserver = nil; readProgress = nil }
        let account = try account(), epoch = generation
        readObserver = progress
        searchCache.removeAll()
        var coverage = InventoryCoverage(), playlists: [Playlist] = [], savedTracks: [Track] = [], albums: [Album] = []

        try await report(.init(stage: .savedTracks))
        let tracksPage = try await pages("/v1/me/tracks?limit=50", onPage: { values, received, total in
            for (index, value) in values.enumerated() {
                let result = try await self.track(value["track"], fallback: "saved:\(received - values.count + index)")
                savedTracks.append(result)
                coverage.tracks = coverage.tracks && result.available && !result.isLocal
            }
            try await self.report(.init(stage: .savedTracks, received: received, total: total))
        })
        coverage.tracks = coverage.tracks && tracksPage.complete
        coverage.notes += tracksPage.notes.map { "Canciones: " + $0 }

        try await report(.init(stage: .savedAlbums))
        let albumPage = try await pages("/v1/me/albums?limit=50", onPage: { _, received, total in
            try await self.report(.init(stage: .savedAlbums, received: 0, total: total, itemName: "Listando álbumes: \(received) encontrados"))
        })
        coverage.albums = albumPage.complete; coverage.notes += albumPage.notes.map { "Álbumes: " + $0 }
        for (index, value) in albumPage.items.enumerated() {
            try await report(.init(stage: .savedAlbums, received: index, total: albumPage.items.count, itemName: value["album"]["name"].string))
            let result = try await album(value["album"], fallback: "saved:\(index)", onPage: { _, received, total in
                try await self.report(.init(stage: .savedAlbums, received: index, total: albumPage.items.count,
                    itemName: value["album"]["name"].string, itemReceived: received, itemTotal: total))
            })
            albums.append(result); coverage.albums = coverage.albums && result.available && result.isCompleteAlbum
            try await report(.init(stage: .savedAlbums, received: index + 1, total: albumPage.items.count))
        }

        var statuses: [LibraryReadProgress.PlaylistStatus] = []
        try await report(.init(stage: .playlistList))
        let playlistPage = try await pages("/v1/me/playlists?limit=50", onPage: { values, received, total in
            for value in values {
                statuses.append(.init(id: statuses.count, name: value["name"].nonempty ?? "Playlist no disponible",
                    total: value["items"]["total"].int ?? value["tracks"]["total"].int))
            }
            try await self.report(.init(stage: .playlistList, received: received, total: total, playlists: statuses))
        })
        coverage.playlists = playlistPage.complete; coverage.notes += playlistPage.notes.map { "Playlists: " + $0 }
        for (index, value) in playlistPage.items.enumerated() {
            guard let id = value["id"].nonempty else {
                playlists.append(Playlist(id: "unknown:playlist:\(index)", name: "Playlist no disponible", editable: false,
                                          ownership: .unknown, contentsComplete: false))
                coverage.playlists = false; statuses[index].state = .partial
                try await report(.init(stage: .playlistTracks, received: index + 1, total: statuses.count, playlists: statuses))
                continue
            }
            statuses[index].state = .reading
            try await report(.init(stage: .playlistTracks, received: index, total: statuses.count, itemName: statuses[index].name,
                                   itemReceived: 0, itemTotal: statuses[index].total, playlists: statuses))
            let content = try await playlistTracks(id, onPage: { _, received, total in
                statuses[index].received = received; statuses[index].total = total
                try await self.report(.init(stage: .playlistTracks, received: index, total: statuses.count,
                    itemName: statuses[index].name, itemReceived: received, itemTotal: total, playlists: statuses))
            })
            let declaredCount = value["items"]["total"].int ?? value["tracks"]["total"].int
            let contentComplete = content.complete && (declaredCount == nil || declaredCount == content.tracks.count) && value["name"].nonempty != nil
            let owner = value["owner"]["id"].nonempty
            let ownership: PlaylistOwnership = owner == account.id ? .owned : value["collaborative"].bool == true ? .collaborative : owner == nil ? .unknown : .followed
            playlists.append(Playlist(id: id, name: value["name"].nonempty ?? "Playlist sin nombre",
                description: value["description"].string ?? "", tracks: content.tracks,
                editable: ownership == .owned || ownership == .collaborative, ownership: ownership,
                contentsComplete: contentComplete, version: value["snapshot_id"].string))
            playlists[playlists.count - 1].artworkURL = value["images"].array?.first?["url"].nonempty
            coverage.playlists = coverage.playlists && contentComplete
            coverage.notes += content.notes.map { "Contenido de playlist: " + $0 }
            statuses[index].state = contentComplete ? .complete : .partial
            try await report(.init(stage: .playlistTracks, received: index + 1, total: statuses.count, playlists: statuses))
        }
        if Set(playlists.map(\.id)).count != playlists.count { coverage.playlists = false }
        if Set(savedTracks.map(\.id)).count != savedTracks.count { coverage.tracks = false }
        if Set(albums.map(\.id)).count != albums.count { coverage.albums = false }
        if !coverage.complete { coverage.notes.append("Los elementos desconocidos o no disponibles se conservan; no equivalen a una biblioteca vacía.") }
        try check(epoch)
        var snapshot = LibrarySnapshot(account: account, playlists: playlists, savedTracks: savedTracks, savedAlbums: albums, coverage: coverage)
        reuseLibraryMetadata(in: &snapshot)
        try check(epoch)
        return snapshot
    }

    /// Reuse only compatible observations from this read. Contradictory codes and
    /// restrictions are retained; membership/order/duplicates are never deduplicated.
    private func reuseLibraryMetadata(in snapshot: inout LibrarySnapshot) {
        struct Identity: Hashable {
            let id: String, title: String, artist: String, album: String
            let duration: Int
            let explicit: Bool?
            init(_ t: Track) { id = t.id; title = t.title; artist = t.artist; album = t.albumTitle; duration = t.durationMS; explicit = t.explicit }
        }
        let observations = snapshot.savedTracks + snapshot.savedAlbums.flatMap(\.tracks) + snapshot.playlists.flatMap(\.tracks)
        var codes: [Identity: Set<String>] = [:]
        for track in observations where track.available && !track.isLocal {
            if let code = track.isrc { codes[Identity(track), default: []].insert(code) }
        }
        func complete(_ track: Track) -> Track {
            var result = track
            if result.isrc == nil, result.available, !result.isLocal, let known = codes[Identity(result)], known.count == 1 { result.isrc = known.first }
            return result
        }
        snapshot.savedTracks = snapshot.savedTracks.map(complete)
        for i in snapshot.savedAlbums.indices { snapshot.savedAlbums[i].tracks = snapshot.savedAlbums[i].tracks.map(complete) }
        for i in snapshot.playlists.indices { snapshot.playlists[i].tracks = snapshot.playlists[i].tracks.map(complete) }
    }

    private func playlistTracks(_ id: String,
                                onPage: (([JSONValue], Int, Int?) async throws -> Void)? = nil) async throws -> (tracks: [Track], complete: Bool, notes: [String]) {
        let page = try await pages("/v1/playlists/\(resourceID(id))/items?limit=50", onPage: onPage)
        var tracks: [Track] = []
        for (index, wrapper) in page.items.enumerated() {
            try Task.checkCancellation()
            let item = wrapper.contains("item") ? wrapper["item"] : wrapper["track"]
            var result = try await track(item, fallback: "playlist:\(id):\(index)")
            if wrapper["is_local"].bool == true { result.isLocal = true; result.available = false }
            tracks.append(result)
        }
        return (tracks, page.complete && tracks.allSatisfy { $0.available && !$0.isLocal }, page.notes)
    }
    private func track(_ value: JSONValue, fallback: String, albumTitle: String = "") async throws -> Track {
        try Task.checkCancellation()
        guard value["type"].string == "track", let id = value["id"].nonempty else {
            if value["is_local"].bool == true {
                return Track(id: value["uri"].nonempty ?? "unknown:\(fallback)", title: value["name"].nonempty ?? "Archivo local",
                             artist: artist(value), available: false, isLocal: true)
            }
            return unknownTrack(fallback)
        }
        let valid = value["name"].nonempty != nil && !artist(value).isEmpty && value["duration_ms"].int != nil
        var result = Track(id: id, catalogID: id, title: value["name"].nonempty ?? "Canción sin datos", artist: artist(value),
            albumTitle: value["album"]["name"].string ?? albumTitle, durationMS: value["duration_ms"].int ?? 0,
            isrc: value["external_ids"]["isrc"].nonempty, explicit: value["explicit"].bool,
            available: valid && value["is_playable"].bool != false && value["restrictions"].isNull && value["is_local"].bool != true,
            isLocal: value["is_local"].bool == true)
        result.url = value["external_urls"]["spotify"].nonempty
        result.artistNames = value["artists"].array?.compactMap { $0["name"].nonempty }
        result.albumID = value["album"]["id"].nonempty
        result.releaseDate = value["album"]["release_date"].nonempty
        result.discNumber = value["disc_number"].int; result.trackNumber = value["track_number"].int
        return result
    }
    private func artist(_ value: JSONValue) -> String { (value["artists"].array ?? []).compactMap { $0["name"].nonempty }.joined(separator: ", ") }
    private func album(_ value: JSONValue, fallback: String,
                       onPage: (([JSONValue], Int, Int?) async throws -> Void)? = nil) async throws -> Album {
        guard let id = value["id"].nonempty, value["type"].string == "album" else {
            return Album(id: "unknown:album:\(fallback)", title: "Álbum no disponible", artist: "", isCompleteAlbum: false, available: false)
        }
        let title = value["name"].string ?? "Álbum sin datos"
        let page = try await pages("/v1/albums/\(resourceID(id))/tracks?limit=50",
                                   initial: value["tracks"].isObject ? value["tracks"] : nil, onPage: onPage)
        var tracks: [Track] = []
        for (index, item) in page.items.enumerated() { tracks.append(try await track(item, fallback: "album:\(id):\(index)", albumTitle: title)) }
        let complete = page.complete && value["total_tracks"].int == tracks.count && tracks.allSatisfy(\.available)
        return Album(id: id, catalogID: id, title: title, artist: artist(value), upc: value["external_ids"]["upc"].nonempty,
                     tracks: tracks, isCompleteAlbum: complete, available: value["name"].nonempty != nil && !artist(value).isEmpty)
    }

    public func catalogTrack(id: String) async throws -> Track? {
        try begin(); defer { busy = false }; _ = try account()
        let value = try await get(APIOrigin.spotify.url("/v1/tracks/\(resourceID(id))"))
        guard value["id"].nonempty == id else { return nil }
        return try await track(value, fallback: id)
    }

    public func searchCatalog(_ query: TrackSearchQuery) async throws -> TrackSearchResult {
        try await searchCatalog(query, budget: CatalogRequestBudget())
    }

    public func searchCatalog(_ query: TrackSearchQuery, budget: CatalogRequestBudget) async throws -> TrackSearchResult {
        try begin(); defer { busy = false }; _ = try account()
        if searchResumeAt > Date() { throw ProviderError.rateLimited(seconds: Int(ceil(searchResumeAt.timeIntervalSinceNow))) }
        if let cached = searchCache[query], Date().timeIntervalSince(cached.0) < 120 { return cached.1 }
        // Strip query syntax from individual field values; URLComponents handles transport encoding.
        func field(_ name: String, _ value: String) -> String? {
            let text = value.replacingOccurrences(of: "\"", with: " ").replacingOccurrences(of: ":", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : "\(name):\"\(text)\""
        }
        var fields: [String?]
        switch query.stage {
        case .identifier: fields = [field("isrc", query.isrc ?? "")]
        case .metadata: fields = [field("artist", query.artist), field("album", query.album), field("track", query.title)]
        case .albumTracks: fields = [field("artist", query.artist), field("album", query.album)]
        case .artistTitle: fields = [field("artist", query.artist), field("track", query.title)]
        }
        guard !fields.compactMap({ $0 }).isEmpty else { return .init() }
        let albums = query.stage == .albumTracks
        let url = try APIOrigin.spotify.url("/v1/search", query: [.init(name: "q", value: fields.compactMap { $0 }.joined(separator: " ")), .init(name: "type", value: albums ? "album" : "track"), .init(name: "limit", value: "10")])
        let page = try await collectPages(origin: .spotify, path: url.absoluteString, spotify: true, envelope: albums ? "albums" : "tracks", maximumPages: 2, preserveAuthorizationFailure: true) { try await self.get($0, budget: budget) }
        var result = TrackSearchResult(coverage: page.searchCoverage, notes: page.notes, stages: [query.stage])
        var hadFailure = false
        func observe(_ page: CollectedPage) {
            var coverage = CatalogSearchResult(candidates: result.candidates, coverage: result.coverage)
            coverage.merge(.init(coverage: page.searchCoverage))
            result.coverage = coverage.coverage; result.notes += page.notes
            if page.authorizationFailed { result.authorizationFailed = true }
            if page.failure != nil { hadFailure = true }
            if case .rateLimited(let seconds) = page.failure { result.retryAfterSeconds = seconds; searchResumeAt = Date().addingTimeInterval(Double(seconds)) }
        }
        observe(page)
        if albums {
            if page.items.count > 3 { result.coverage = result.coverage == .complete ? .limited : result.coverage; result.notes.append("Se revisaron las primeras tres ediciones del álbum. Afiná el nombre para consultar otras.") }
            for value in page.items.prefix(3) {
                guard result.retryAfterSeconds == nil, result.authorizationFailed != true else { break }
                guard let id = value["id"].nonempty else { result.coverage = .partialFailure; continue }
                let tracks = try await collectPages(origin: .spotify, path: "/v1/albums/\(resourceID(id))/tracks?limit=50", spotify: true, maximumPages: 2, preserveAuthorizationFailure: true) { try await self.get($0, budget: budget) }
                observe(tracks)
                for item in tracks.items { result.candidates.append(try await track(item, fallback: "album-search", albumTitle: value["name"].string ?? query.album)) }
            }
        } else {
            for item in page.items { result.candidates.append(try await track(item, fallback: "search")) }
        }
        if result.candidates.contains(where: { !$0.available }) { result.coverage = .partialFailure }
        if !result.candidates.isEmpty && result.coverage == .failed { result.coverage = .partialFailure }
        if result.candidates.isEmpty && hadFailure { result.coverage = .failed }
        if result.coverage == .complete { searchCache[query] = (Date(), result) }
        return result
    }

    private func catalogPages(_ query: String, type: String, budget: CatalogRequestBudget) async throws -> CollectedPage {
        let url = try APIOrigin.spotify.url("/v1/search", query: [.init(name: "q", value: query), .init(name: "type", value: type), .init(name: "limit", value: "10")])
        return try await collectPages(origin: .spotify, path: url.absoluteString, spotify: true, envelope: type + "s", maximumPages: 2, preserveAuthorizationFailure: true) {
            try await self.get($0, budget: budget)
        }
    }
    public func searchTracks(matching track: Track) async throws -> CatalogSearchResult<Track> {
        try begin(); defer { busy = false }; _ = try account()
        let budget = CatalogRequestBudget()
        let metadata = "track:\(track.title) artist:\(track.artist)"
        var queries: [String] = []
        if let isrc = track.isrc, !isrc.isEmpty { queries.append("isrc:\(isrc)") }
        if !track.albumTitle.isEmpty { queries.append(metadata + " album:\(track.albumTitle)") }
        queries.append(metadata)
        var result = CatalogSearchResult<Track>()
        for query in queries {
            let page = try await catalogPages(query, type: "track", budget: budget)
            var candidates: [Track] = []
            for (i, item) in page.items.enumerated() {
                candidates.append(try await self.track(item, fallback: "search:\(i)"))
                if item["type"].string != "track" || item["id"].nonempty == nil || item["name"].nonempty == nil || artist(item).isEmpty || item["duration_ms"].int == nil {
                    result.merge(.init(coverage: .failed, notes: ["Una canción de catálogo no tiene metadatos suficientes para compararla."]))
                }
            }
            result.merge(.init(candidates: candidates, coverage: page.searchCoverage, notes: page.notes))
            result.candidates = CatalogMatcher.unique(result.candidates)
            if page.authorizationFailed { break }
            if CatalogMatcher.track(track, candidates: result.candidates, sourceService: .appleMusic, coverage: result.coverage).selected != nil { break }
        }
        return result
    }
    public func searchAlbums(matching album: Album) async throws -> CatalogSearchResult<Album> {
        try begin(); defer { busy = false }; _ = try account()
        let budget = CatalogRequestBudget()
        let page = try await catalogPages("album:\(album.title) artist:\(album.artist)", type: "album", budget: budget)
        var result = CatalogSearchResult<Album>(coverage: page.searchCoverage, notes: page.notes)
        var expanded = 0, seen = Set<String>()
        var canExpand = !page.authorizationFailed
        for item in page.items {
            guard let rawID = item["id"].nonempty, let id = try? resourceID(rawID), item["type"].string == "album" else {
                result.merge(.init(coverage: .failed, notes: ["Spotify devolvió una referencia de álbum inválida."])); continue
            }
            guard seen.insert(id).inserted else { continue }
            var candidate = Album(id: id, catalogID: id, title: item["name"].string ?? "", artist: artist(item), upc: item["external_ids"]["upc"].nonempty, isCompleteAlbum: false, available: item["name"].nonempty != nil && !artist(item).isEmpty)
            if expanded < 3 && canExpand {
                expanded += 1
                let tracks = try await collectPages(origin: .spotify, path: "/v1/albums/\(resourceID(id))/tracks?limit=50", initial: item["tracks"].isObject ? item["tracks"] : nil, spotify: true, maximumPages: 2, preserveAuthorizationFailure: true) { try await self.get($0, budget: budget) }
                for (i, value) in tracks.items.enumerated() {
                    candidate.tracks.append(try await self.track(value, fallback: "album-search:\(i)", albumTitle: candidate.title))
                }
                candidate.isCompleteAlbum = tracks.complete && item["total_tracks"].int == candidate.tracks.count && !candidate.tracks.isEmpty && candidate.tracks.allSatisfy(\.available)
                result.merge(.init(candidates: [candidate], coverage: tracks.searchCoverage, notes: tracks.notes))
                if tracks.complete && (!candidate.isCompleteAlbum || !candidate.available) {
                    result.merge(.init(coverage: .failed, notes: ["No se pudo validar el contenido completo de una edición del álbum."]))
                }
                if tracks.authorizationFailed { canExpand = false }
            } else {
                result.merge(.init(candidates: [candidate], coverage: canExpand ? .limited : .failed,
                                   notes: [canExpand ? "Quedaron ediciones sin expandir; se consultan hasta tres álbumes por búsqueda." : "Se necesita reconectar para completar las ediciones pendientes."]))
            }
        }
        return result
    }

    public func perform(_ operation: SyncOperation) async throws -> MutationReceipt {
        try begin(); defer { busy = false }; _ = try account()
        guard operation.service == .spotify, operation.blockedReason == nil else { throw ProviderError.unsupported("La operación no está habilitada para Spotify.") }
        let trackURIs = try operation.tracks.map { track -> String in
            guard track.available && !track.isLocal else { throw ProviderError.unsupported("No se puede escribir una canción local o no disponible.") }
            return "spotify:track:\(try resourceID(track.playableID))"
        }
        let albumURIs = try operation.albums.map { "spotify:album:\(try resourceID($0.playableID))" }
        var successfulWrites = 0, createdID: String?
        func write(_ path: String, _ method: String, body: Data? = nil) async throws -> ProviderHTTPResponse {
            let result = try await request(APIOrigin.spotify.url(path), method: method, body: body)
            successfulWrites += 1
            if !result.data.isEmpty { _ = try JSONValue.decode(result.data) }
            return result
        }
        func append(_ target: String, _ uris: [String]) async throws {
            for batch in chunks(uris, size: 100) {
                let response = try await write("/v1/playlists/\(target)/items", "POST", body: jsonBody(["uris": batch]))
                guard try JSONValue.decode(response.data)["snapshot_id"].nonempty != nil else {
                    throw ProviderError.invalidResponse("Spotify no devolvió la versión después de agregar canciones.")
                }
            }
        }
        do {
            switch operation.kind {
            case .createPlaylist:
                guard let name = operation.playlistName, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ProviderError.invalidResponse("La playlist necesita un nombre.") }
                let response = try await write("/v1/me/playlists", "POST", body: jsonBody(["name": name, "description": operation.playlistDescription ?? "", "public": false]))
                guard let id = try JSONValue.decode(response.data)["id"].nonempty else { throw ProviderError.invalidResponse("Spotify creó una playlist sin devolver su ID.") }
                createdID = try resourceID(id); try await append(id, trackURIs)
            case .addPlaylistTracks:
                try await append(resourceID(operation.targetID ?? ""), trackURIs)
            case .replacePlaylistTracks:
                let id = try resourceID(operation.targetID ?? "")
                guard let expected = operation.beforeTrackIDs else { throw ProviderError.unsupported("El reemplazo requiere el estado anterior aprobado.") }
                let current = try await playlistTracks(id)
                guard current.complete && current.tracks.map(\.playableID) == expected else { throw ProviderError.unsupported("La playlist cambió o no pudo leerse completa. Generá una nueva vista previa.") }
                let response = try await write("/v1/playlists/\(id)/items", "PUT", body: jsonBody(["uris": Array(trackURIs.prefix(100))]))
                guard try JSONValue.decode(response.data)["snapshot_id"].nonempty != nil else { throw ProviderError.invalidResponse("Spotify no devolvió la versión del reemplazo.") }
                try await append(id, Array(trackURIs.dropFirst(100)))
            case .renamePlaylist:
                let id = try resourceID(operation.targetID ?? "")
                var fields: [String: String] = [:]
                if let name = operation.playlistName {
                    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ProviderError.invalidResponse("La playlist necesita un nombre.") }
                    fields["name"] = name
                }
                if let description = operation.playlistDescription { fields["description"] = description }
                guard !fields.isEmpty else { throw ProviderError.invalidResponse("No hay cambios de nombre o descripción para enviar.") }
                _ = try await write("/v1/playlists/\(id)", "PUT", body: jsonBody(fields))
            case .saveTracks, .removeTracks, .saveAlbums, .removeAlbums, .removePlaylist:
                let uris: [String]
                if operation.kind == .removePlaylist { uris = ["spotify:playlist:\(try resourceID(operation.targetID ?? ""))"] }
                else { uris = [.saveAlbums, .removeAlbums].contains(operation.kind) ? albumURIs : trackURIs }
                let method = [.saveTracks, .saveAlbums].contains(operation.kind) ? "PUT" : "DELETE"
                for batch in chunks(uris, size: 40) {
                    let url = try APIOrigin.spotify.url("/v1/me/library", query: [.init(name: "uris", value: batch.joined(separator: ","))])
                    _ = try await write(url.absoluteString, method)
                }
            }
            return MutationReceipt(createdID: createdID, message: "Spotify aceptó la operación. Releé la biblioteca para verificar el resultado.")
        } catch {
            if successfulWrites > 0 {
                let detail = createdID.map { " Playlist creada: \($0)." } ?? ""
                throw ProviderError.uncertainWrite("La operación se aplicó al menos parcialmente.\(detail) Releé el estado; no repitas la operación completa.")
            }
            throw error
        }
    }
}
