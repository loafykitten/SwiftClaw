import Foundation
import SwiftData

/// A pending (or resolved) AI-proposed memory write awaiting explicit user
/// approval via a review card — the `NoteEditProposal` pattern (statuses,
/// `chatID`, `cardPostedAt` drain), not the vault-shaped type. One record
/// serves both asks-first chat writes and background `propose_memory` runs.
///
/// Unlike `NoteEditProposal` there is no `conflicted` status: memory has no
/// base-hash race. A proposal whose target collection vanished before
/// approval routes its entry into the Inbox instead — the design's
/// "never force-file" rule.
///
/// `cardPostedAt` marks when the card coordinator appended this proposal's
/// review card to its chat, letting a drain rehydrate a proposal whose card
/// was never posted without ever posting a second card for one already shown.
@Model
final class MemoryProposal {
    @Attribute(.unique) var id: UUID
    /// The exact entry text that acceptance will save (possibly edited in
    /// the card's Edit sheet first).
    var entryText: String
    /// The existing collection to file into; nil when the proposal asks for
    /// a new collection via `newCollectionTitle`.
    var targetCollectionID: UUID?
    /// For an asks-first supersession: the entry `entryText` replaces.
    /// If it's gone (or already superseded) by acceptance time, the text is
    /// added as a plain new entry instead — the fact still lands.
    var supersedesEntryID: UUID?
    var newCollectionTitle: String?
    /// Optional longer description carried through for `newCollectionTitle`.
    var newCollectionDetails: String?
    /// Requested access level for `newCollectionTitle`; an asksFirst
    /// creation seeds its initial entry inside this same accepted proposal.
    var newCollectionAccessLevelRawValue: String?
    var scopeRawValue: String?
    var tagsData: Data?
    /// One-line rationale shown on the review card.
    var summary: String
    var statusRawValue: String
    var sourceRawValue: String
    var chatID: UUID?
    var createdAt: Date
    var resolvedAt: Date?
    var cardPostedAt: Date?

    init(
        id: UUID = UUID(),
        entryText: String,
        targetCollectionID: UUID? = nil,
        supersedesEntryID: UUID? = nil,
        newCollectionTitle: String? = nil,
        newCollectionDetails: String? = nil,
        newCollectionAccessLevel: MemoryCollection.AccessLevel? = nil,
        scope: WorkspaceFeature? = nil,
        tags: [String] = [],
        summary: String,
        status: Status = .pending,
        source: Source,
        chatID: UUID? = nil,
        createdAt: Date = .now,
        resolvedAt: Date? = nil,
        cardPostedAt: Date? = nil
    ) {
        self.id = id
        self.entryText = entryText
        self.targetCollectionID = targetCollectionID
        self.supersedesEntryID = supersedesEntryID
        self.newCollectionTitle = newCollectionTitle
        self.newCollectionDetails = newCollectionDetails
        self.newCollectionAccessLevelRawValue = newCollectionAccessLevel?.rawValue
        self.scopeRawValue = scope?.rawValue
        self.tagsData = MemoryTagsCoding.encode(tags)
        self.summary = summary
        self.statusRawValue = status.rawValue
        self.sourceRawValue = source.rawValue
        self.chatID = chatID
        self.createdAt = createdAt
        self.resolvedAt = resolvedAt
        self.cardPostedAt = cardPostedAt
    }

    enum Status: String, Codable, Sendable {
        case pending
        /// Durable intermediate state persisted immediately before the
        /// repository write begins, so a crash between the write and the
        /// terminal `.applied` save never leaves a proposal that looks
        /// re-approvable (`NoteEditProposal.Status.applying` precedent).
        case applying
        case applied
        /// Durable: rejected proposals persist and their texts feed review
        /// runs' "previously declined — do not re-propose" context.
        case rejected
        case expired
    }

    /// Where the proposal originated — interactive chat (an asks-first
    /// write) or a background review service's `propose_memory`.
    enum Source: String, Codable, Sendable {
        case chat
        case emailReview
        case calendarReview
        case remindersReview
        case notesReview
    }

    var status: Status {
        get { Status(rawValue: statusRawValue) ?? .pending }
        set { statusRawValue = newValue.rawValue }
    }

    var source: Source {
        get { Source(rawValue: sourceRawValue) ?? .chat }
        set { sourceRawValue = newValue.rawValue }
    }

    var newCollectionAccessLevel: MemoryCollection.AccessLevel? {
        get { newCollectionAccessLevelRawValue.flatMap(MemoryCollection.AccessLevel.init(rawValue:)) }
        set { newCollectionAccessLevelRawValue = newValue?.rawValue }
    }

    var scope: WorkspaceFeature? {
        get { scopeRawValue.flatMap(WorkspaceFeature.init(rawValue:)) }
        set { scopeRawValue = newValue?.rawValue }
    }

    var tags: [String] {
        get { MemoryTagsCoding.decode(tagsData) }
        set { tagsData = MemoryTagsCoding.encode(newValue) }
    }
}
