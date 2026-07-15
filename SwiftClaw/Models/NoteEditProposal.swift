import Foundation
import SwiftData

/// A pending (or resolved) AI-proposed change to a note, gated behind
/// explicit user approval via a review card. Lives in the main local store
/// (not the CloudKit-shaped calendar/reminders configuration) — proposals are
/// device-local, keyed to on-disk vault paths/hashes that have no meaning
/// synced to another device.
///
/// `baseContentHash` is the vault-relative note's `sha256` at proposal time,
/// nil only for `.create` (there is no "current" content to guard against).
/// Approval re-reads the note and re-checks this hash immediately before
/// mutating — see `NoteProposalDispatcher` — so an edit made to the note
/// between proposal and approval is never silently clobbered.
///
/// `originatingVaultID` is the `VaultConfigurationStore.vaultID` in effect
/// when the proposal was created — optional/defaulted so existing stored
/// proposals migrate lightly, but a nil value is treated as unbound and
/// expires at approval time rather than risking an operation against an
/// unknown vault. Approval compares a nonnil id against the *current*
/// configured vault identity before any read or mutation, so switching vaults
/// between proposing and approving can never write into, or read a
/// hash-collision from, the wrong vault — see `NoteProposalDispatcher`.
///
/// `cardPostedAt` marks when `NotesProposalCoordinator` appended this
/// proposal's review card to its chat. It lets `drain` rehydrate a proposal
/// whose card was never posted (the completion that created it failed or was
/// cancelled before draining, or the in-memory queue was lost to a process
/// restart) without ever posting a second card for one already shown.
@Model
final class NoteEditProposal {
    @Attribute(.unique) var id: UUID
    var kindRawValue: String
    var notePath: String
    var newPath: String?
    var baseContentHash: String?
    var proposedContent: String?
    var appendText: String?
    var summary: String
    var statusRawValue: String
    var createdAt: Date
    var resolvedAt: Date?
    var chatID: UUID?
    var originatingVaultID: String?
    var cardPostedAt: Date?

    init(
        id: UUID = UUID(),
        kind: Kind,
        notePath: String,
        newPath: String? = nil,
        baseContentHash: String? = nil,
        proposedContent: String? = nil,
        appendText: String? = nil,
        summary: String,
        status: Status = .pending,
        createdAt: Date = .now,
        resolvedAt: Date? = nil,
        chatID: UUID? = nil,
        originatingVaultID: String? = nil,
        cardPostedAt: Date? = nil
    ) {
        self.id = id
        self.kindRawValue = kind.rawValue
        self.notePath = notePath
        self.newPath = newPath
        self.baseContentHash = baseContentHash
        self.proposedContent = proposedContent
        self.appendText = appendText
        self.summary = summary
        self.statusRawValue = status.rawValue
        self.createdAt = createdAt
        self.resolvedAt = resolvedAt
        self.chatID = chatID
        self.originatingVaultID = originatingVaultID
        self.cardPostedAt = cardPostedAt
    }

    enum Kind: String, Codable, Sendable {
        case create
        case edit
        case append
        case rename
    }

    enum Status: String, Codable, Sendable {
        case pending
        /// Durable intermediate state: persisted immediately before the file
        /// mutation begins, so a crash/restart (or a failed post-mutation
        /// save) between the file mutation and the terminal `.applied` save
        /// never leaves a proposal that looks re-approvable — see
        /// `NoteProposalDispatcher.approve`. Never re-applied: `perform`'s
        /// idempotency guard only proceeds from `.pending`.
        case applying
        case applied
        case rejected
        case conflicted
        case expired
    }

    var kind: Kind {
        get { Kind(rawValue: kindRawValue) ?? .edit }
        set { kindRawValue = newValue.rawValue }
    }

    var status: Status {
        get { Status(rawValue: statusRawValue) ?? .pending }
        set { statusRawValue = newValue.rawValue }
    }
}
