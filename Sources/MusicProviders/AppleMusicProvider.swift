import Foundation
import SyncCore

/// Native MusicKit authorization + documented Apple Music REST endpoints.
/// The account ID identifies the authorized grant, never an Apple ID. The same
/// grant survives reconnect/restart for read-only reconciliation; each connection
/// has a new revision so execution approvals cannot survive a reconnect.
/// Write contracts: https://developer.apple.com/documentation/applemusicapi/create-a-new-library-playlist
/// https://developer.apple.com/documentation/applemusicapi/add-tracks-to-a-library-playlist
/// https://developer.apple.com/documentation/applemusicapi/add-a-resource-to-a-library
public actor AppleMusicProvider: MusicProvider {
    public nonisolated let service: MusicService = .appleMusic
    public nonisolated let mutationLimits: MutationLimits? = .init(libraryItems: 100, playlistItems: 100)
    private let http: ProviderHTTP
    private let authorization: any AppleMusicAuthorizing
    private let session: (any AppleMusicSessionTransport)?
    private var connected: ConnectedAccount?
    private var generation = UUID()
    private var busy = false
    private var songCache: [String: MappedTrack] = [:]
    private var catalogCache: [String: JSONValue] = [:]
    private var searchCache: [TrackSearchQuery: (Date, TrackSearchResult)] = [:]
    private var searchResumeAt = Date.distantPast
    private struct MappedTrack { var track: Track; var complete: Bool }

    public init() {
        let transport = MusicKitHTTPTransport()
        http = ProviderHTTP(transport: transport, retry: .init()); session = transport
        authorization = NativeAppleMusicAuthorization()
    }
    public init(transport: any ProviderHTTPTransport, authorization: any AppleMusicAuthorizing,
                retryPolicy: ProviderRetryPolicy = .init()) {
        http = ProviderHTTP(transport: transport, retry: retryPolicy); self.authorization = authorization
        session = transport as? any AppleMusicSessionTransport
    }
    private func begin() throws {
        guard !busy else { throw ProviderError.unsupported("Ya hay una operación de Apple Music en curso.") }; busy = true
    }
    public func account() throws -> ConnectedAccount {
        guard let connected else { throw ProviderError.notConnected }; return connected
    }
    public func capabilities() -> ProviderCapabilities { .appleMusic }
    public func connect() async throws -> ConnectedAccount {
        try begin(); defer { busy = false }
        generation = UUID(); let epoch = generation; connected = nil
        songCache.removeAll(); catalogCache.removeAll()
        searchCache.removeAll(); searchResumeAt = .distantPast
        guard let session else {
            throw ProviderError.unsupported("El transporte de Apple Music debe vincular las solicitudes a una sesión autorizada.")
        }
        await session.endSession()
        do {
            try check(epoch)
            try await authorization.authorize()
            try check(epoch)
            try await session.beginSession()
            try check(epoch)
            guard let identifier = await session.sessionIdentifier(), !identifier.isEmpty else {
                throw ProviderError.invalidResponse("Apple Music no devolvió una identidad de sesión verificable.")
            }
            try check(epoch)
            let response = try await get(APIOrigin.apple.url("/v1/me/storefront"))
            try check(epoch)
            guard let data = response["data"].array, data.count == 1,
                  let storefront = data[0]["id"].nonempty, data[0]["type"].string == "storefronts" else {
                throw ProviderError.invalidResponse("Apple Music no devolvió un storefront autenticado válido.")
            }
            _ = try resourceID(storefront)
            let account = ConnectedAccount(id: identifier, service: .appleMusic,
                displayName: "Apple Music (sesión autorizada)", storefront: storefront, connectionRevision: UUID().uuidString)
            connected = account; return account
        } catch {
            await session.endSession()
            throw error
        }
    }
    /// Disconnects this adapter only. MusicKit authorization belongs to macOS;
    /// revoke the app's system permission in System Settings if needed.
    public func disconnect() async throws {
        generation = UUID(); connected = nil; songCache.removeAll(); catalogCache.removeAll()
        await session?.endSession()
    }
    private func check(_ epoch: UUID) throws {
        try Task.checkCancellation(); guard epoch == generation else { throw ProviderError.notConnected }
    }
    private func request(_ url: URL, method: String = "GET", body: Data? = nil, budget: CatalogRequestBudget? = nil) async throws -> ProviderHTTPResponse {
        _ = try APIOrigin.apple.url(url.absoluteString)
        let epoch = generation
        var request = URLRequest(url: url); request.httpMethod = method; request.httpBody = body; request.timeoutInterval = 30
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let response: ProviderHTTPResponse
        do { response = try await http.send(request, budget: budget) }
        catch ProviderError.unauthorized {
            // No refresh or replay, including writes. The next connect must acquire
            // a grant explicitly and receive a fresh connection revision.
            if epoch == generation { try await disconnect() }
            throw ProviderError.unauthorized
        }
        if method == "GET" { try check(epoch) }
        else if epoch != generation || Task.isCancelled { throw ProviderError.uncertainWrite("La conexión cambió durante la escritura de Apple Music. Releé la biblioteca.") }
        return response
    }
    private func get(_ url: URL, budget: CatalogRequestBudget? = nil) async throws -> JSONValue { try JSONValue.decode(await request(url, budget: budget).data) }
    private func pages(_ path: String, initial: JSONValue? = nil, envelope: String? = nil) async throws -> CollectedPage {
        try await collectPages(origin: .apple, path: path, initial: initial, spotify: false, envelope: envelope) { try await self.get($0) }
    }
    private func storefront() throws -> String { try resourceID(account().storefront ?? "") }
    private func relationship(_ resource: JSONValue, base: String, name: String) async throws -> CollectedPage {
        let included = resource["relationships"][name]
        return try await pages(base + "/" + name, initial: included["data"].array != nil ? included : nil)
    }
    private func catalogResource(type: String, id: String) async throws -> JSONValue {
        let key = "\(try storefront()):\(type):\(id)"
        if let cached = catalogCache[key] { return cached }
        let response = try await get(APIOrigin.apple.url("/v1/catalog/\(storefront())/\(type)/\(resourceID(id))"))
        guard let values = response["data"].array, values.count == 1, values[0]["id"].string == id, values[0]["type"].string == type,
              values[0]["attributes"].isObject else { throw ProviderError.invalidResponse("Apple Music no devolvió el recurso de catálogo solicitado.") }
        catalogCache[key] = values[0]; return values[0]
    }
    private func resolveCatalog(_ resource: JSONValue, libraryType: String, catalogType: String) async throws -> (JSONValue?, Bool) {
        let attributes = resource["attributes"]
        let included = resource["relationships"]["catalog"]
        if included["data"].array != nil || attributes["playParams"]["catalogId"].nonempty == nil {
            let page = try await relationship(resource, base: "/v1/me/library/\(libraryType)/\(resourceID(resource["id"].string ?? ""))", name: "catalog")
            guard page.complete else { return (nil, false) }
            if page.items.isEmpty { return (nil, true) }
            guard page.items.count == 1, page.items[0]["type"].string == catalogType, let id = page.items[0]["id"].nonempty else { return (nil, false) }
            if page.items[0]["attributes"].isObject { return (page.items[0], true) }
            return (try await catalogResource(type: catalogType, id: id), true)
        }
        guard let id = attributes["playParams"]["catalogId"].nonempty else { return (nil, false) }
        return (try await catalogResource(type: catalogType, id: id), true)
    }
    private func mappedTrack(_ resource: JSONValue, fallback: String, budget: CatalogRequestBudget? = nil) async throws -> MappedTrack {
        guard let id = resource["id"].nonempty, ["songs", "library-songs"].contains(resource["type"].string ?? "") else {
            return .init(track: unknownTrack(fallback), complete: false)
        }
        let type = resource["type"].string!
        if let cached = songCache["\(type):\(id)"] { return cached }
        var value = resource, catalog: JSONValue?, complete = true
        do {
            if !value["attributes"].isObject {
                let path = type == "songs" ? "/v1/catalog/\(try storefront())/songs/\(try resourceID(id))" : "/v1/me/library/songs/\(try resourceID(id))"
                let response = try await get(APIOrigin.apple.url(path), budget: budget)
                guard let data = response["data"].array, data.count == 1, data[0]["id"].string == id, data[0]["type"].string == type else { throw ProviderError.invalidResponse("Referencia de canción sin detalle válido.") }
                value = data[0]
            }
            if type == "songs" { catalog = value }
            else { (catalog, complete) = try await resolveCatalog(value, libraryType: "songs", catalogType: "songs") }
        } catch is CatalogBudgetExceeded { throw CatalogBudgetExceeded() }
        catch is CancellationError { throw CancellationError() }
        catch ProviderError.unauthorized { throw ProviderError.unauthorized }
        catch ProviderError.notConnected { throw ProviderError.notConnected }
        catch { complete = false }
        let a = value["attributes"], c = catalog?["attributes"] ?? .null
        let title = a["name"].nonempty ?? c["name"].nonempty
        let artist = a["artistName"].nonempty ?? c["artistName"].nonempty
        let duration = a["durationInMillis"].int ?? c["durationInMillis"].int
        let catalogID = catalog?["id"].nonempty
        let available = title != nil && artist != nil && duration != nil && catalogID != nil && c["playParams"].isObject
        let rating = c["contentRating"].string ?? a["contentRating"].string
        var result = MappedTrack(track: Track(id: id, catalogID: catalogID, title: title ?? "Canción no disponible", artist: artist ?? "",
            albumTitle: a["albumName"].string ?? c["albumName"].string ?? "", durationMS: duration ?? 0,
            isrc: c["isrc"].nonempty, explicit: rating.map { $0 == "explicit" }, available: available,
            isLocal: type == "library-songs" && catalogID == nil && complete), complete: complete && available)
        result.track.url = c["url"].nonempty
        result.track.releaseDate = c["releaseDate"].nonempty
        result.track.discNumber = c["discNumber"].int; result.track.trackNumber = c["trackNumber"].int
        songCache["\(type):\(id)"] = result; return result
    }
    private func mappedTracks(_ page: CollectedPage, context: String) async throws -> (tracks: [Track], complete: Bool) {
        var values: [Track] = [], complete = page.complete
        for (index, resource) in page.items.enumerated() {
            let mapped = try await mappedTrack(resource, fallback: "\(context):\(index)")
            values.append(mapped.track); complete = complete && mapped.complete
        }
        return (values, complete)
    }

    public func fetchLibrary() async throws -> LibrarySnapshot {
        try begin(); defer { busy = false }
        let account = try account()
        songCache.removeAll(); catalogCache.removeAll()
        searchCache.removeAll()
        var coverage = InventoryCoverage(), playlists: [Playlist] = [], albums: [Album] = []
        let playlistsPage = try await pages("/v1/me/library/playlists?limit=100")
        coverage.playlists = playlistsPage.complete; coverage.notes += playlistsPage.notes.map { "Playlists: " + $0 }
        for (index, value) in playlistsPage.items.enumerated() {
            guard let id = value["id"].nonempty, value["type"].string == "library-playlists" else {
                playlists.append(Playlist(id: "unknown:playlist:\(index)", name: "Playlist no disponible", editable: false, ownership: .unknown, contentsComplete: false))
                coverage.playlists = false; continue
            }
            let page = try await relationship(value, base: "/v1/me/library/playlists/\(resourceID(id))", name: "tracks")
            let tracks = try await mappedTracks(page, context: "playlist:\(id)")
            let a = value["attributes"], editable = a["canEdit"].bool == true
            // canEdit proves permission, not ownership. Apple does not expose the
            // Apple ID behind this session, so do not infer an owner identity.
            playlists.append(Playlist(id: id, name: a["name"].nonempty ?? "Playlist sin datos", description: a["description"]["standard"].string ?? "",
                tracks: tracks.tracks, editable: editable, ownership: .unknown,
                contentsComplete: tracks.complete && a["name"].nonempty != nil))
            playlists[playlists.count - 1].artworkURL = a["artwork"]["url"].nonempty?.replacingOccurrences(of: "{w}", with: "600").replacingOccurrences(of: "{h}", with: "600")
            coverage.playlists = coverage.playlists && tracks.complete && a["name"].nonempty != nil
            coverage.notes += page.notes.map { "Contenido de playlist: " + $0 }
        }
        let songsPage = try await pages("/v1/me/library/songs?limit=100&include=catalog")
        let songs = try await mappedTracks(songsPage, context: "saved")
        coverage.tracks = songs.complete; coverage.notes += songsPage.notes.map { "Canciones: " + $0 }
        let albumsPage = try await pages("/v1/me/library/albums?limit=100&include=catalog")
        coverage.albums = albumsPage.complete; coverage.notes += albumsPage.notes.map { "Álbumes: " + $0 }
        for (index, value) in albumsPage.items.enumerated() {
            let result = try await libraryAlbum(value, fallback: "album:\(index)")
            albums.append(result.album); coverage.albums = coverage.albums && result.complete
        }
        if Set(playlists.map(\.id)).count != playlists.count { coverage.playlists = false }
        if Set(songs.tracks.map(\.id)).count != songs.tracks.count { coverage.tracks = false }
        if Set(albums.map(\.id)).count != albums.count { coverage.albums = false }
        if !coverage.complete { coverage.notes.append("Hay recursos o relaciones sin cobertura completa; no deben interpretarse como ausencias.") }
        return LibrarySnapshot(account: account, playlists: playlists, savedTracks: songs.tracks, savedAlbums: albums, coverage: coverage)
    }
    private func libraryAlbum(_ value: JSONValue, fallback: String) async throws -> (album: Album, complete: Bool) {
        guard let id = value["id"].nonempty, value["type"].string == "library-albums" else {
            return (Album(id: "unknown:\(fallback)", title: "Álbum no disponible", artist: "", isCompleteAlbum: false, available: false), false)
        }
        let page = try await relationship(value, base: "/v1/me/library/albums/\(resourceID(id))", name: "tracks")
        let library = try await mappedTracks(page, context: "album:\(id)")
        let declaredLibraryCount = value["attributes"]["trackCount"].int
        let libraryComplete = library.complete && (declaredLibraryCount == nil || declaredLibraryCount == library.tracks.count)
        var catalog: JSONValue?, mappingComplete = false, fullTracks: [Track] = [], catalogComplete = false
        do {
            (catalog, mappingComplete) = try await resolveCatalog(value, libraryType: "albums", catalogType: "albums")
            if let catalog, let catalogID = catalog["id"].nonempty {
                let page = try await relationship(catalog, base: "/v1/catalog/\(storefront())/albums/\(resourceID(catalogID))", name: "tracks")
                let mapped = try await mappedTracks(page, context: "catalog-album:\(catalogID)")
                fullTracks = mapped.tracks
                catalogComplete = mapped.complete && catalog["attributes"]["trackCount"].int == mapped.tracks.count && !mapped.tracks.isEmpty
            }
        } catch is CancellationError { throw CancellationError() }
        catch ProviderError.unauthorized { throw ProviderError.unauthorized }
        catch ProviderError.notConnected { throw ProviderError.notConnected }
        catch { mappingComplete = false }
        // Compare the entire catalog multiset, not just Apple's library trackCount:
        // a library-album may contain only one saved song from a 12-track album.
        let isFull = libraryComplete && catalogComplete && library.tracks.map(\.playableID).sorted() == fullTracks.map(\.playableID).sorted()
        let a = value["attributes"], c = catalog?["attributes"] ?? .null
        let valid = a["name"].nonempty != nil && a["artistName"].nonempty != nil
        let result = Album(id: id, catalogID: catalog?["id"].nonempty, title: a["name"].string ?? "Álbum sin datos",
            artist: a["artistName"].string ?? "", upc: c["upc"].nonempty, tracks: library.tracks, isCompleteAlbum: isFull,
            available: valid && catalog != nil)
        return (result, libraryComplete && mappingComplete && catalogComplete && valid)
    }

    public func catalogTrack(id: String) async throws -> Track? {
        try begin(); defer { busy = false }; _ = try account()
        catalogCache.removeValue(forKey: "\(try storefront()):songs:\(id)")
        songCache.removeValue(forKey: "songs:\(id)")
        return try await mappedTrack(catalogResource(type: "songs", id: id), fallback: id).track
    }

    public func searchCatalog(_ query: TrackSearchQuery) async throws -> TrackSearchResult {
        try await searchCatalog(query, budget: CatalogRequestBudget())
    }

    public func searchCatalog(_ query: TrackSearchQuery, budget: CatalogRequestBudget) async throws -> TrackSearchResult {
        try begin(); defer { busy = false }; _ = try account()
        if searchResumeAt > Date() { throw ProviderError.rateLimited(seconds: Int(ceil(searchResumeAt.timeIntervalSinceNow))) }
        if let cached = searchCache[query], Date().timeIntervalSince(cached.0) < 120 { return cached.1 }
        var evidence = CatalogSearchResult<Track>()
        var result = TrackSearchResult(stages: [query.stage])
        func observe(_ page: CollectedPage) {
            evidence.merge(.init(coverage: page.searchCoverage, notes: page.notes))
            if page.authorizationFailed { result.authorizationFailed = true }
            if case .rateLimited(let seconds) = page.failure {
                result.retryAfterSeconds = seconds; searchResumeAt = Date().addingTimeInterval(Double(seconds))
            }
        }
        if query.stage == .identifier {
            guard let isrc = query.isrc, !isrc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return result }
            evidence = try await searchISRC(isrc, budget: budget)
        } else {
            let albums = query.stage == .albumTracks
            let terms: [String]
            switch query.stage {
            case .metadata: terms = [query.artist, query.album, query.title]
            case .albumTracks: terms = [query.artist, query.album]
            default: terms = [query.artist, query.title]
            }
            let page = try await searchPages(term: terms.filter { !$0.isEmpty }.joined(separator: " "), type: albums ? "albums" : "songs", budget: budget)
            observe(page)
            if albums {
                if page.items.count > 3 { evidence.merge(.init(coverage: .limited, notes: ["Se revisaron las primeras tres ediciones. Afiná el álbum para consultar otras."])) }
                for album in page.items.prefix(3) {
                    guard result.retryAfterSeconds == nil, connected != nil else { break }
                    guard let id = album["id"].nonempty, album["type"].string == "albums" else {
                        evidence.merge(.init(coverage: .failed, notes: ["Referencia de álbum inválida."])); continue
                    }
                    let included = album["relationships"]["tracks"]
                    let tracks = try await collectPages(origin: .apple, path: "/v1/catalog/\(storefront())/albums/\(resourceID(id))/tracks", initial: included["data"].array == nil ? nil : included, spotify: false, maximumPages: 2, preserveAuthorizationFailure: true) { try await self.get($0, budget: budget) }
                    observe(tracks)
                    evidence.merge(try await searchTracks(tracks.items.filter { $0["type"].string != "music-videos" }, budget: budget))
                }
            } else {
                evidence.merge(try await searchTracks(page.items, budget: budget))
            }
        }
        result.candidates = CatalogMatcher.unique(evidence.candidates)
        result.coverage = evidence.coverage; result.notes = evidence.notes
        result.authorizationFailed = connected == nil || result.authorizationFailed == true
        if result.coverage == .complete { searchCache[query] = (Date(), result) }
        return result
    }

    private func searchPages(term: String, type: String, budget: CatalogRequestBudget) async throws -> CollectedPage {
        let url = try APIOrigin.apple.url("/v1/catalog/\(storefront())/search", query: [.init(name: "term", value: term), .init(name: "types", value: type), .init(name: "limit", value: "25")])
        return try await collectPages(origin: .apple, path: url.absoluteString, spotify: false, maximumPages: 2, preserveAuthorizationFailure: true) {
            try await self.get($0, budget: budget)["results"][type]
        }
    }

    private func searchTracks(_ resources: [JSONValue], budget: CatalogRequestBudget) async throws -> CatalogSearchResult<Track> {
        var result = CatalogSearchResult<Track>()
        for (index, resource) in resources.enumerated() {
            do {
                guard resource["type"].string == "songs" else { throw ProviderError.invalidResponse("Referencia de canción de catálogo inválida.") }
                let mapped = try await mappedTrack(resource, fallback: "search:\(index)", budget: budget)
                result.merge(.init(candidates: [mapped.track], coverage: mapped.complete ? .complete : .partialFailure,
                                   notes: mapped.complete ? [] : ["No se pudo validar toda la información de una canción del catálogo."]))
            } catch { result.merge(try searchFailure(error)) }
        }
        return result
    }

    private func searchISRC(_ isrc: String, budget: CatalogRequestBudget) async throws -> CatalogSearchResult<Track> {
        var result = CatalogSearchResult<Track>()
        do {
            let url = try APIOrigin.apple.url("/v1/catalog/\(storefront())/songs", query: [.init(name: "filter[isrc]", value: isrc)])
            let response = try await get(url, budget: budget)
            guard let data = response["data"].array else { throw ProviderError.invalidResponse("La respuesta ISRC no contiene canciones válidas.") }
            result.merge(try await searchTracks(data, budget: budget))
            let references = response["meta"]["filters"]["isrc"][isrc]
            if !references.isNull {
                guard let references = references.array else { throw ProviderError.invalidResponse("Las referencias ISRC de Apple Music son inválidas.") }
                var ids = Set<String>()
                for reference in references {
                    guard reference["type"].string == "songs", let id = reference["id"].nonempty else {
                        throw ProviderError.invalidResponse("Apple Music devolvió una referencia ISRC sin identidad verificable.")
                    }
                    ids.insert(try resourceID(id))
                }
                let missing = ids.subtracting(data.compactMap { $0["id"].nonempty }).sorted()
                if !missing.isEmpty {
                    let lookup = try APIOrigin.apple.url("/v1/catalog/\(storefront())/songs", query: [.init(name: "ids", value: missing.prefix(200).joined(separator: ","))])
                    let hydrated = try await get(lookup, budget: budget)
                    guard let resources = hydrated["data"].array else { throw ProviderError.invalidResponse("No se pudieron completar las referencias ISRC.") }
                    result.merge(try await searchTracks(resources, budget: budget))
                    if !Set(missing).isSubset(of: Set(resources.compactMap { $0["id"].nonempty })) {
                        result.merge(.init(coverage: missing.count > 200 ? .limited : .failed, notes: ["Quedaron referencias ISRC sin completar en este territorio."]))
                    }
                }
            }
        } catch ProviderError.rateLimited(let seconds) {
            searchResumeAt = Date().addingTimeInterval(Double(seconds))
            throw ProviderError.rateLimited(seconds: seconds)
        } catch { result.merge(try searchFailure(error)) }
        return result
    }

    public func searchTracks(matching track: Track) async throws -> CatalogSearchResult<Track> {
        try begin(); defer { busy = false }; _ = try account()
        let budget = CatalogRequestBudget()
        var result = CatalogSearchResult<Track>()
        if let isrc = track.isrc, !isrc.isEmpty { result = try await searchISRC(isrc, budget: budget) }
        let metadata = "\(track.title) \(track.artist)"
        let terms = track.albumTitle.isEmpty ? [metadata] : [metadata + " " + track.albumTitle, metadata]
        for term in terms {
            if connected == nil { break }
            result.candidates = CatalogMatcher.unique(result.candidates)
            if CatalogMatcher.track(track, candidates: result.candidates, sourceService: .spotify, coverage: result.coverage).selected != nil { break }
            let page = try await searchPages(term: term, type: "songs", budget: budget)
            result.merge(.init(coverage: page.searchCoverage, notes: page.notes))
            result.merge(try await searchTracks(page.items, budget: budget))
        }
        result.candidates = CatalogMatcher.unique(result.candidates)
        return result
    }

    public func searchAlbums(matching album: Album) async throws -> CatalogSearchResult<Album> {
        try begin(); defer { busy = false }; _ = try account()
        let budget = CatalogRequestBudget()
        let page = try await searchPages(term: "\(album.title) \(album.artist)", type: "albums", budget: budget)
        var result = CatalogSearchResult<Album>(coverage: page.searchCoverage, notes: page.notes)
        var expanded = 0, seen = Set<String>()
        for item in page.items {
            guard let rawID = item["id"].nonempty, let id = try? resourceID(rawID), item["type"].string == "albums" else {
                result.merge(.init(coverage: .failed, notes: ["Referencia de álbum de catálogo inválida."])); continue
            }
            guard seen.insert(id).inserted else { continue }
            let a = item["attributes"]
            var candidate = Album(id: id, catalogID: id, title: a["name"].string ?? "", artist: a["artistName"].string ?? "", upc: a["upc"].nonempty, isCompleteAlbum: false, available: a["name"].nonempty != nil && a["artistName"].nonempty != nil)
            if expanded < 3 && connected != nil {
                expanded += 1
                let included = item["relationships"]["tracks"]
                let tracksPage = try await collectPages(origin: .apple, path: "/v1/catalog/\(storefront())/albums/\(resourceID(id))/tracks", initial: included["data"].array != nil ? included : nil, spotify: false, maximumPages: 2, preserveAuthorizationFailure: true) { try await self.get($0, budget: budget) }
                let tracks = try await searchTracks(tracksPage.items, budget: budget)
                candidate.tracks = tracks.candidates
                candidate.isCompleteAlbum = tracksPage.complete && tracks.coverage == .complete && a["trackCount"].int == candidate.tracks.count && !candidate.tracks.isEmpty
                result.merge(.init(candidates: [candidate], coverage: tracksPage.searchCoverage, notes: tracksPage.notes))
                result.merge(.init(coverage: tracks.coverage, notes: tracks.notes))
                if tracksPage.complete && tracks.coverage == .complete && (!candidate.isCompleteAlbum || !candidate.available) {
                    result.merge(.init(coverage: .failed, notes: ["No se pudo validar el contenido completo de una edición del álbum."]))
                }
            } else {
                result.merge(.init(candidates: [candidate], coverage: connected == nil ? .failed : .limited,
                                   notes: [connected == nil ? "Se necesita reconectar para completar las ediciones pendientes." : "Quedaron ediciones sin expandir; se consultan hasta tres álbumes por búsqueda."]))
            }
        }
        return result
    }

    public func perform(_ operation: SyncOperation) async throws -> MutationReceipt {
        try begin(); defer { busy = false }; _ = try account()
        guard operation.service == .appleMusic, operation.blockedReason == nil,
              ProviderCapabilities.appleMusic.supported.contains(operation.kind) else {
            throw ProviderError.unsupported("Apple Music no documenta esta mutación mediante su API pública. No se ejecutó ninguna escritura.")
        }
        let songIDs = try operation.tracks.map { track -> String in
            guard track.available && !track.isLocal, let id = track.catalogID ?? (track.id.allSatisfy(\.isNumber) ? track.id : nil) else {
                throw ProviderError.unsupported("La escritura requiere una canción de catálogo disponible y su ID de Apple Music.")
            }; return try resourceID(id)
        }
        let albumIDs = try operation.albums.map { album -> String in
            guard album.available, let id = album.catalogID ?? (album.id.allSatisfy(\.isNumber) ? album.id : nil) else {
                throw ProviderError.unsupported("La escritura requiere el ID de catálogo del álbum de Apple Music.")
            }; return try resourceID(id)
        }
        var writes = 0, createdID: String?
        func write(_ url: URL, body: Data? = nil, status: Int) async throws -> ProviderHTTPResponse {
            let response = try await request(url, method: "POST", body: body); writes += 1
            guard response.statusCode == status else { throw ProviderError.invalidResponse("Apple Music devolvió un estado de escritura inesperado.") }
            if !response.data.isEmpty { _ = try JSONValue.decode(response.data) }
            return response
        }
        func append(_ target: String, _ ids: [String]) async throws {
            for batch in chunks(ids, size: 100) {
                _ = try await write(APIOrigin.apple.url("/v1/me/library/playlists/\(target)/tracks"),
                                    body: jsonBody(["data": batch.map { ["id": $0, "type": "songs"] }]), status: 204)
            }
        }
        do {
            switch operation.kind {
            case .createPlaylist:
                guard let name = operation.playlistName, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ProviderError.invalidResponse("La playlist necesita un nombre.") }
                let response = try await write(APIOrigin.apple.url("/v1/me/library/playlists"),
                    body: jsonBody(["attributes": ["name": name, "description": operation.playlistDescription ?? "", "isPublic": false]]), status: 201)
                let json = try JSONValue.decode(response.data)
                guard let resources = json["data"].array, resources.count == 1, resources[0]["type"].string == "library-playlists",
                      let id = resources[0]["id"].nonempty else { throw ProviderError.invalidResponse("Apple Music creó una playlist sin devolver un ID verificable.") }
                createdID = try resourceID(id); try await append(id, songIDs)
            case .addPlaylistTracks:
                try await append(resourceID(operation.targetID ?? ""), songIDs)
            case .saveTracks, .saveAlbums:
                let type = operation.kind == .saveTracks ? "songs" : "albums"
                for batch in chunks(operation.kind == .saveTracks ? songIDs : albumIDs, size: 100) {
                    _ = try await write(APIOrigin.apple.url("/v1/me/library", query: [.init(name: "ids[\(type)]", value: batch.joined(separator: ","))]), status: 202)
                }
            default: throw ProviderError.unsupported("Mutación de Apple Music no soportada.")
            }
            // Apple explicitly documents ignored IDs and eventual consistency for
            // POST /me/library. An HTTP 202 is acceptance, never verified membership.
            return MutationReceipt(createdID: createdID, message: "Apple Music aceptó la solicitud; el resultado todavía no está verificado. Puede ignorar IDs o demorar su incorporación. Releé la biblioteca antes de confirmar.")
        } catch {
            if writes > 0 {
                let detail = createdID.map { " Playlist creada: \($0)." } ?? ""
                throw ProviderError.uncertainWrite("Apple Music pudo aplicar parte de la operación.\(detail) Releé la biblioteca antes de reintentar.")
            }
            throw error
        }
    }
}
