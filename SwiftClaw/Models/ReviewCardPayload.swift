import Foundation

nonisolated enum ReviewType: String, Codable, Sendable {
    case email
    case calendar
    case reminders
    /// A single AI-proposed note create/edit/append/rename, gated behind
    /// explicit approval. See `NoteEditProposal`/`NoteProposalDispatcher`.
    case noteProposal
    /// Reserved for a future Notes vault-hygiene digest card (broken links,
    /// conflict copies, freshness) — not produced anywhere yet.
    case notes
    /// Disclosure chip for autonomous memory writes to "AI writes freely"
    /// collections — "Memory added to X", View + one-tap Undo. See
    /// `MemoryCardCoordinator`.
    case memoryWrite
    /// A single AI-proposed memory write gated behind explicit approval
    /// (asks-first collections and background `propose_memory`) — Accept /
    /// Edit / Dismiss. See `MemoryProposal`/`MemoryProposalDispatcher`.
    case memoryProposal
    /// Forward-compat bucket for review types this build doesn't know about.
    /// An unknown `reviewType` decodes to `.unknown` instead of throwing —
    /// that way the whole payload isn't silently dropped (`try?` returns nil)
    /// and the registry can render a generic card.
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ReviewType(rawValue: raw) ?? .unknown
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

nonisolated enum ReviewActionToken: String, Codable, Sendable, CaseIterable, Identifiable {
    case review
    case flag
    case reply
    case delete
    case archive
    /// Generic approve/reject, shared by every proposal-style review card
    /// (note proposals today; email drafts a documented follow-up) rather
    /// than a domain-specific token per card type.
    case approve
    case reject
    /// Open the proposal's content for modification before applying —
    /// memory proposal cards' Edit (saving is accept-with-modified-text).
    case edit
    /// Reverse a disclosed autonomous write — memory write chips' one-tap
    /// Undo (a hard delete; the activity feed keeps the audit snapshot).
    case undo

    var id: String { rawValue }

    /// Human-readable label shown on buttons + review-card context menus.
    var displayName: String {
        switch self {
        case .review: "Review"
        case .flag: "Flag"
        case .reply: "Reply"
        case .delete: "Delete"
        case .archive: "Archive"
        case .approve: "Approve"
        case .reject: "Reject"
        case .edit: "Edit"
        case .undo: "Undo"
        }
    }

}

nonisolated struct ReviewItem: Codable, Sendable, Identifiable, Hashable {
    var id: UUID
    var itemID: UUID
    var actionToken: String
    var actionLabel: String
    var summary: String?
    var subject: String?
    var sender: String?
    var date: String?
    var accountLabel: String?

    init(
        id: UUID = UUID(),
        itemID: UUID,
        actionToken: ReviewActionToken,
        actionLabel: String,
        summary: String? = nil,
        subject: String? = nil,
        sender: String? = nil,
        date: String? = nil,
        accountLabel: String? = nil
    ) {
        self.id = id
        self.itemID = itemID
        self.actionToken = actionToken.rawValue
        self.actionLabel = actionLabel
        self.summary = summary
        self.subject = subject
        self.sender = sender
        self.date = date
        self.accountLabel = accountLabel
    }

    var action: ReviewActionToken? {
        ReviewActionToken(rawValue: actionToken)
    }
}

nonisolated struct ReviewCardPayload: Codable, Sendable, Hashable {
    var reviewType: ReviewType
    var items: [ReviewItem]
}
