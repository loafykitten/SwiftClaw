import Foundation
import SwiftData

/// One row of the Memory activity feed — the audit trail behind the
/// chip-undo decision: entry mutations hard-delete/replace rather than
/// tombstone, and this event's `snapshotText` preserves what the store said
/// before the mutation (Notes-revisions philosophy: snapshot, not tombstone).
///
/// `MemoryRepository` writes one event in the same save as every mutation.
/// Collection-level events (create/delete/access change) carry a nil
/// `entryID`; `snapshotText` then holds the collection title.
@Model
final class MemoryActivityEvent {
    @Attribute(.unique) var id: UUID
    var kindRawValue: String
    var entryID: UUID?
    var collectionID: UUID?
    /// The text this mutation would otherwise lose: the previous body for
    /// edits/supersessions, the deleted body for deletes/undos, the new body
    /// for additions.
    var snapshotText: String?
    var actorRawValue: String
    var chatID: UUID?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        kind: Kind,
        entryID: UUID? = nil,
        collectionID: UUID? = nil,
        snapshotText: String? = nil,
        actor: MemoryActor,
        chatID: UUID? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.kindRawValue = kind.rawValue
        self.entryID = entryID
        self.collectionID = collectionID
        self.snapshotText = snapshotText
        self.actorRawValue = actor.rawValue
        self.chatID = chatID
        self.createdAt = createdAt
    }

    enum Kind: String, Codable, Sendable {
        case added
        case edited
        case superseded
        case movedCollection
        case deleted
        case accessChanged
        case undone
        case proposalAccepted
        case proposalDismissed
    }

    var kind: Kind {
        get { Kind(rawValue: kindRawValue) ?? .edited }
        set { kindRawValue = newValue.rawValue }
    }

    var actor: MemoryActor {
        get { MemoryActor(rawValue: actorRawValue) ?? .user }
        set { actorRawValue = newValue.rawValue }
    }
}
