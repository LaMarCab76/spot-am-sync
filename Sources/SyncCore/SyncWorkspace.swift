import Foundation

public struct PlaylistReference: Codable, Hashable, Sendable, Identifiable {
    public var service: MusicService
    public var playlistID: String
    public var id: String { "\(service.rawValue):\(playlistID)" }
    public init(service: MusicService, playlistID: String) { self.service = service; self.playlistID = playlistID }
}

public enum ExistingPlaylistPolicy: String, Codable, CaseIterable, Sendable {
    case update, copy
    public var title: String { self == .update ? "Actualizar la vinculada" : "Crear una copia independiente" }
}

public struct SyncOptions: Codable, Equatable, Sendable {
    public var existingPlaylist: ExistingPlaylistPolicy = .update
    public var keepOrder = true
    public var skipDuplicates = false
    public init() {}
}

public struct PlaylistTarget: Codable, Equatable, Sendable {
    public var source: PlaylistReference
    public var targetID: String
    public init(source: PlaylistReference, targetID: String) { self.source = source; self.targetID = targetID }
}

/// Immutable scope captured in the preview and journal. Full inventories remain in
/// SyncPlan for stale checks; narrowing the scope never fabricates complete reads.
public struct SyncRequest: Codable, Equatable, Sendable {
    public var profileID: UUID?
    public var revision: Int
    public var name: String
    public var mode: SyncMode
    public var playlists: [PlaylistReference]
    public var includeSavedLibrary: Bool
    public var options: SyncOptions
    public var accountIDs: [MusicService: String]
    public var storefronts: [MusicService: String]
    public var copyTargets: [PlaylistTarget]
    public var playlistTargets: [PlaylistTarget]?
    public init(profileID: UUID? = nil, revision: Int = 1, name: String, mode: SyncMode,
                playlists: [PlaylistReference], includeSavedLibrary: Bool = false,
                options: SyncOptions = .init(), accounts: [ConnectedAccount], copyTargets: [PlaylistTarget] = [], playlistTargets: [PlaylistTarget] = []) {
        self.profileID = profileID; self.revision = revision; self.name = name; self.mode = mode
        self.playlists = Array(Set(playlists)).sorted { $0.id < $1.id }
        self.includeSavedLibrary = includeSavedLibrary; self.options = options
        self.accountIDs = Dictionary(accounts.map { ($0.service, $0.id) }, uniquingKeysWith: { first, _ in first })
        self.storefronts = Dictionary(accounts.compactMap { account in account.storefront.map { (account.service, $0) } }, uniquingKeysWith: { first, _ in first })
        self.copyTargets = copyTargets
        self.playlistTargets = playlistTargets
    }
    public func matches(accounts: [ConnectedAccount]) -> Bool {
        accounts.count == 2 && MusicService.allCases.allSatisfy { service in
            let found = accounts.filter { $0.service == service }
            return found.count == 1 && !found[0].id.isEmpty && accountIDs[service] == found[0].id && storefronts[service] == found[0].storefront
        }
    }
}

public enum ReviewFrequency: String, Codable, CaseIterable, Sendable {
    case hourly, daily, weekly
    public var title: String {
        switch self { case .hourly: return "Cada hora"; case .daily: return "Diaria"; case .weekly: return "Semanal" }
    }
}

/// A schedule authorizes reads only. No approval or execution flag exists here.
public struct ReviewSchedule: Codable, Equatable, Sendable {
    public var enabled = false
    public var frequency: ReviewFrequency = .daily
    public var hour = 9
    public var minute = 0
    public var weekday = 2
    public var timeZoneID = TimeZone.current.identifier
    public var nextReview: Date?
    public var lastReview: Date?
    public init() {}
    public func next(after date: Date) -> Date? {
        guard (0...23).contains(hour), (0...59).contains(minute), (1...7).contains(weekday),
              let zone = TimeZone(identifier: timeZoneID) else { return nil }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        var components = DateComponents()
        components.minute = minute; components.second = 0
        if frequency != .hourly { components.hour = hour }
        if frequency == .weekly { components.weekday = weekday }
        return calendar.nextDate(after: date, matching: components, matchingPolicy: .nextTime, repeatedTimePolicy: .first)
    }
}

public struct SyncProfile: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID { request.profileID! }
    public var request: SyncRequest
    public var schedule: ReviewSchedule
    public var isDemo: Bool
    public init(request: SyncRequest, schedule: ReviewSchedule = .init(), isDemo: Bool = false) {
        self.request = request; if self.request.profileID == nil { self.request.profileID = UUID() }
        self.schedule = schedule; self.isDemo = isDemo
    }
    private enum CodingKeys: String, CodingKey { case request, schedule, isDemo }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        request = try values.decode(SyncRequest.self, forKey: .request)
        guard request.profileID != nil, request.revision > 0 else {
            throw DecodingError.dataCorruptedError(forKey: .request, in: values, debugDescription: "La configuración no tiene una identidad y revisión válidas.")
        }
        schedule = try values.decode(ReviewSchedule.self, forKey: .schedule)
        isDemo = try values.decodeIfPresent(Bool.self, forKey: .isDemo) ?? false
    }
}

public enum ReviewJobState: String, Codable, Sendable, CaseIterable {
    case queued, analyzing, ready, applying, paused, completed, attention
    public var title: String {
        switch self {
        case .queued: return "En cola"; case .analyzing: return "Analizando"; case .ready: return "Para revisar"
        case .applying: return "Aplicando"; case .paused: return "En pausa"; case .completed: return "Finalizada"
        case .attention: return "Requiere revisión"
        }
    }
    public var pending: Bool { self != .completed }
}

public struct ReviewJob: Codable, Equatable, Sendable, Identifiable {
    public var id = UUID()
    public var request: SyncRequest
    public var state: ReviewJobState = .queued
    public var createdAt: Date
    public var scheduled: Bool
    public var isDemo: Bool
    public var message = "Pendiente de lectura. No hay cambios autorizados."
    public var plan: SyncPlan?
    public var decisions: MatchDecisions?
    public var runID: UUID?
    public init(request: SyncRequest, scheduled: Bool = false, isDemo: Bool = false, createdAt: Date = Date()) {
        self.request = request; self.scheduled = scheduled; self.isDemo = isDemo; self.createdAt = createdAt
    }
}

public enum CandidateOrder: String, Codable, CaseIterable, Sendable {
    case metadata, duration, studio
    public var title: String {
        switch self { case .metadata: return "Artista y edición"; case .duration: return "Duración más cercana"; case .studio: return "Versiones de estudio primero" }
    }
}

public struct AppPreferences: Codable, Equatable, Sendable {
    public var defaultMode: SyncMode = .spotifyBase
    public var options = SyncOptions()
    public var notifyReview = true
    public var notifyDone = true
    public var notifyFailure = true
    public var candidateOrder: CandidateOrder = .metadata
    public var spotifyClientID = ""
    public init() {}
    private enum CodingKeys: String, CodingKey { case defaultMode, options, notifyReview, notifyDone, notifyFailure, candidateOrder, spotifyClientID }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        defaultMode = try values.decodeIfPresent(SyncMode.self, forKey: .defaultMode) ?? .spotifyBase
        options = try values.decodeIfPresent(SyncOptions.self, forKey: .options) ?? .init()
        notifyReview = try values.decodeIfPresent(Bool.self, forKey: .notifyReview) ?? true
        notifyDone = try values.decodeIfPresent(Bool.self, forKey: .notifyDone) ?? true
        notifyFailure = try values.decodeIfPresent(Bool.self, forKey: .notifyFailure) ?? true
        candidateOrder = try values.decodeIfPresent(CandidateOrder.self, forKey: .candidateOrder) ?? .metadata
        spotifyClientID = try values.decodeIfPresent(String.self, forKey: .spotifyClientID) ?? ""
    }
}

public enum LegacyPreferencesImporter {
    /// Electron stored demo connectivity beside preferences. Only this whitelist
    /// crosses the boundary; connections, runs, schedules and mock music do not.
    public static func decode(_ data: Data, current: AppPreferences) throws -> AppPreferences {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let settings = root["settings"] as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
        var result = current
        switch settings["defaultDirection"] as? String {
        case "s2a": result.defaultMode = .spotifyBase; case "a2s": result.defaultMode = .appleMusicBase; case "both": result.defaultMode = .merge; default: break
        }
        if let value = settings["ifExists"] as? String, let policy = ExistingPlaylistPolicy(rawValue: value) { result.options.existingPlaylist = policy }
        if let value = settings["notifyDone"] as? Bool { result.notifyDone = value }
        if let value = settings["notifyReview"] as? Bool { result.notifyReview = value }
        if let value = settings["notifyFail"] as? Bool { result.notifyFailure = value }
        if settings["preferStudio"] as? Bool == true { result.candidateOrder = .studio }
        return result
    }
}

public struct SyncWorkspace: Codable, Equatable, Sendable {
    public var version = 1
    public var preferences = AppPreferences()
    public var profiles: [SyncProfile] = []
    public var jobs: [ReviewJob] = []
    public init() {}

    public mutating func recoverAfterRestart() {
        for i in jobs.indices {
            if jobs[i].state == .analyzing { jobs[i].state = .queued }
            if jobs[i].state == .applying {
                jobs[i].state = .attention
                jobs[i].message = "La app se cerró durante una ejecución. Comprobá el historial antes de preparar nuevos cambios."
            }
        }
    }

    /// Pure scheduler: dedupes proposals and advances once, without replaying missed
    /// intervals. Disconnected identities never consume their pending occurrence.
    @discardableResult
    public mutating func enqueueDue(at now: Date, accounts: [ConnectedAccount]) -> Int {
        var count = 0
        for i in profiles.indices where profiles[i].schedule.enabled && !profiles[i].isDemo {
            let profile = profiles[i]
            guard profile.request.matches(accounts: accounts) else { continue }
            if profile.schedule.nextReview == nil {
                profiles[i].schedule.nextReview = profile.schedule.next(after: now)
                continue
            }
            guard let due = profile.schedule.nextReview, due <= now,
                  !jobs.contains(where: { $0.request.profileID == profile.id && !$0.isDemo && $0.state.pending }) else { continue }
            jobs.append(ReviewJob(request: profile.request, scheduled: true, createdAt: now))
            profiles[i].schedule.nextReview = profile.schedule.next(after: now)
            count += 1
        }
        return count
    }
}

public enum HistoryCSV {
    public static func encode(_ summaries: [RunSummary]) -> String {
        func cell(_ value: String) -> String {
            // Spreadsheet formula prefixes are data, not executable formulas.
            let protected = value.first.map { "=+-@\t\r".contains($0) } == true ? "'" + value : value
            return "\"" + protected.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        let format = ISO8601DateFormatter()
        let rows = summaries.map { [ $0.id.uuidString, format.string(from: $0.startedAt), $0.status.label,
                                     String($0.verifiedCount), String($0.totalCount), $0.message ].map(cell).joined(separator: ",") }
        return (["id,fecha,estado,verificadas,total,mensaje"] + rows).joined(separator: "\r\n") + "\r\n"
    }
}
