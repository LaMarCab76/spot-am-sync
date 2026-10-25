import Foundation

/// An explicitly approved, immutable local source. This is never an Apple cloud
/// authorization or an assertion that the exported document is the live library.
public struct SnapshotTransferSource: Codable, Equatable, Sendable {
    public var libraryID: String
    public var documentDigest: String
    public var importedAt: Date
    public var exportedAt: Date?
    public var approvedAt: Date
    public var differenceIDs: [String]
    public var library: ManualMusicLibrary
    public var allowsDestructive: Bool?

    public init(library: ManualMusicLibrary, differenceIDs: [String], approvedAt: Date = Date(), allowsDestructive: Bool = false) throws {
        guard let digest = library.documentDigest, !digest.isEmpty, library.inventory != nil else {
            throw SyncExecutionError.invalidSelection
        }
        libraryID = library.id; documentDigest = digest; importedAt = library.importedAt
        exportedAt = library.exportedAt; self.approvedAt = approvedAt
        self.differenceIDs = differenceIDs.sorted(); self.library = library
        self.allowsDestructive = allowsDestructive
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.libraryID == rhs.libraryID && lhs.documentDigest == rhs.documentDigest &&
        lhs.importedAt == rhs.importedAt && lhs.exportedAt == rhs.exportedAt &&
        lhs.approvedAt == rhs.approvedAt && lhs.differenceIDs == rhs.differenceIDs && lhs.allowsDestructive == rhs.allowsDestructive
    }
}
