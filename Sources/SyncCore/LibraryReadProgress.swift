import Foundation

/// Transient read progress, never a snapshot or evidence for a write.
public struct LibraryReadProgress: Equatable, Sendable {
    public enum Stage: String, Sendable { case savedTracks, savedAlbums, playlistList, playlistTracks }
    public struct PlaylistStatus: Equatable, Sendable, Identifiable {
        public enum State: String, Sendable { case pending, reading, complete, partial }
        public var id: Int
        public var name: String
        public var state: State = .pending
        public var received: Int = 0
        public var total: Int?
        public init(id: Int, name: String, total: Int? = nil) {
            self.id = id; self.name = name; self.total = total
        }
    }
    public var stage: Stage
    public var received: Int
    public var total: Int?
    public var itemName: String?
    public var itemReceived: Int?
    public var itemTotal: Int?
    public var playlists: [PlaylistStatus]
    public var waitingUntil: Date?
    public init(stage: Stage, received: Int = 0, total: Int? = nil, itemName: String? = nil,
                itemReceived: Int? = nil, itemTotal: Int? = nil, playlists: [PlaylistStatus] = [], waitingUntil: Date? = nil) {
        self.stage = stage; self.received = received; self.total = total; self.itemName = itemName
        self.itemReceived = itemReceived; self.itemTotal = itemTotal; self.playlists = playlists; self.waitingUntil = waitingUntil
    }
}

public typealias LibraryReadObserver = @Sendable (LibraryReadProgress) async -> Void
