import Foundation
import SwiftData

enum EmailReviewFollowUpContextBuilder {
    private static let bodyExcerptLimit = 500

    @MainActor
    static func makeContext(
        for payloads: [ReviewCardPayload],
        in modelContext: ModelContext
    ) -> String? {
        let emailIDs = payloads
            .filter { $0.reviewType == .email }
            .flatMap(\.items)
            .map(\.itemID)
        let uniqueEmailIDs = Array(NSOrderedSet(array: emailIDs)).compactMap { $0 as? UUID }
        guard !uniqueEmailIDs.isEmpty else { return nil }

        let repository = EmailRepository(modelContext: modelContext)
        let emailBlocks = uniqueEmailIDs.compactMap { emailID -> String? in
            guard let email = repository.fetchEmail(by: emailID) else { return nil }
            return makeEmailBlock(email)
        }
        guard !emailBlocks.isEmpty else { return nil }

        return """
        This chat is an email review follow-up. You ARE connected to the user's inbox in this chat
        through your email tools — never say you lack email access or can't see their email.
        \(EmailReviewDateContext.currentString())
        Use the email_guid exactly when calling email tools. You can add AI notes, set/unset flags,
        or re-run the inbox analysis (refresh_email_review) when the user asks for more to review;
        otherwise just answer normally. Report results truthfully — never claim a card or new emails
        appeared unless the tool says so; if a refresh finds nothing, say so and ask what to focus on.
        The referenced emails are below.

        \(emailBlocks.joined(separator: "\n\n---\n\n"))
        """
    }

    /// Grounding for a review chat that currently has no resolvable emails —
    /// the user actioned/cleaned every card item, or the emails were removed.
    /// Without this the chat would lose all email context once the card empties
    /// and the assistant would wrongly claim it has no email access.
    static func capabilityOnlyContext() -> String {
        """
        This chat is an email review follow-up. You ARE connected to the user's inbox in this chat
        through your email tools — never say you lack email access or can't see their email.
        \(EmailReviewDateContext.currentString())
        There are no specific emails attached right now (the review card was cleared). When the user
        asks for more emails to review, or to re-check or refresh the inbox, call refresh_email_review
        to run a fresh analysis — it posts an updated review card ONLY if something needs attention.
        Always report results truthfully: never say a card was posted or that new emails turned up unless
        your tool result actually says so. If a refresh surfaces nothing, say so plainly. It's fine not to
        know what they want reviewed — ask for specifics (a sender, a timeframe, or whether to dig into
        older/already-read mail) rather than implying something happened that didn't. Don't promise to keep
        reviewing in the background; you review when they ask. Otherwise just answer normally.
        """
    }

    private static func makeEmailBlock(_ email: Email) -> String {
        """
        email_guid: \(email.id.uuidString)
        subject: \(email.subject)
        from: \(email.displayFromAddress)
        to: \(email.displayToAddresses.joined(separator: ", "))
        date: \(EmailReviewDateFormatter.string(from: email.date))
        read: \(email.isRead)
        flagged: \(email.isFlagged)
        notes:
        \(notesText(for: email))
        body_excerpt:
        \(excerpt(from: email.plainTextBody))
        """
    }

    private static func notesText(for email: Email) -> String {
        let notes = email.notes.sorted { $0.createdAt < $1.createdAt }
        guard !notes.isEmpty else { return "- none" }
        return notes.map { "- \($0.author.rawValue): \($0.content)" }.joined(separator: "\n")
    }

    private static func excerpt(from body: String) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > bodyExcerptLimit else { return trimmed }
        return String(trimmed.prefix(bodyExcerptLimit)) + "..."
    }
}

final class EmailReviewAddNoteTool: Tool {
    let name = "add_email_note"
    let displayName = "Add Email Note"
    let description = """
    Adds an AI-authored note to a referenced review email. Use only when the \
    user asks you to remember, note, annotate, or track something about a \
    specific email.
    """
    let systemImage = "note.text.badge.plus"
    let parameters: [ToolParameter] = [
        ToolParameter(
            name: "email_guid",
            type: .string,
            description: "The exact email_guid from the review context.",
            isRequired: true
        ),
        ToolParameter(
            name: "note",
            type: .string,
            description: "The note to attach to the email.",
            isRequired: true
        ),
    ]

    var isConfigured: Bool { true }
    var requiresExplicitEnable: Bool { false }

    private let modelContainer: ModelContainer

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        guard let guid = arguments["email_guid"]?.stringValue,
              let emailID = UUID(uuidString: guid) else {
            throw ToolError.invalidArguments("email_guid must be a UUID")
        }
        guard let noteValue = arguments["note"]?.stringValue else {
            throw ToolError.missingArgument("note")
        }
        let note = noteValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !note.isEmpty else { throw ToolError.missingArgument("note") }

        return try await MainActor.run {
            let context = ModelContext(modelContainer)
            let repository = EmailRepository(modelContext: context)
            guard repository.addNote(emailID: emailID, author: .ai, content: note) != nil else {
                throw ToolError.executionFailed("Email not found.")
            }
            return "Added note to email \(emailID.uuidString)."
        }
    }
}

final class EmailReviewSetFlagTool: Tool {
    let name = "set_email_flag"
    let displayName = "Set Email Flag"
    let description = """
    Sets or clears the local flag on a referenced review email. Use only when \
    the user asks to flag, unflag, mark for follow-up, or clear follow-up.
    """
    let systemImage = "flag"
    let parameters: [ToolParameter] = [
        ToolParameter(
            name: "email_guid",
            type: .string,
            description: "The exact email_guid from the review context.",
            isRequired: true
        ),
        ToolParameter(
            name: "flagged",
            type: .boolean,
            description: "true to flag the email, false to clear the flag.",
            isRequired: true
        ),
    ]

    var isConfigured: Bool { true }
    var requiresExplicitEnable: Bool { false }

    private let modelContainer: ModelContainer

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        guard let guid = arguments["email_guid"]?.stringValue,
              let emailID = UUID(uuidString: guid) else {
            throw ToolError.invalidArguments("email_guid must be a UUID")
        }
        guard let flagged = arguments["flagged"]?.boolValue else {
            throw ToolError.missingArgument("flagged")
        }

        return try await MainActor.run {
            let context = ModelContext(modelContainer)
            let repository = EmailRepository(modelContext: context)
            guard repository.setFlag(messageID: emailID, isFlagged: flagged) != nil else {
                throw ToolError.executionFailed("Email not found.")
            }
            return "Email \(emailID.uuidString) flag set to \(flagged)."
        }
    }
}

/// Lets the user ask the assistant to re-run inbox triage from inside a review
/// chat — the conversational equivalent of the review card's sparkle button.
/// Runs a fresh analysis and appends an updated card to this chat, collapsing
/// the prior one into its label.
final class EmailReviewRefreshTool: Tool {
    let name = "refresh_email_review"
    let displayName = "Refresh Email Review"
    let description = """
    Re-runs inbox triage and appends an updated review card to this chat, \
    superseding the previous one. Use when the user asks you to re-check, \
    refresh, re-run, or update the email review or analysis.
    """
    let systemImage = "sparkles"
    let parameters: [ToolParameter] = []

    var isConfigured: Bool { true }
    var requiresExplicitEnable: Bool { false }

    private let chatID: UUID

    init(chatID: UUID) {
        self.chatID = chatID
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        // Conversational path: the review pass posts only the updated card (the
        // inline summary is suppressed). `summary` is non-nil ONLY when the pass
        // actually surfaced emails and posted a card.
        let outcome = await EmailWorkflowManager.shared.conversationalReview(appendingTo: chatID)

        if let summary = outcome.summary {
            // A fresh card WAS posted — relay the model's summary as the single
            // reply (no "posted above", no second recap).
            return """
            An updated review card has been posted to this chat. Relay the following to the user as your \
            reply, in your own warm voice — this is the only message they'll see about the refresh, so \
            don't add a separate recap or point them elsewhere:

            \(summary)
            """
        }

        // No emails were surfaced, so NO new card exists. Be honest — never tell
        // the user a card or new emails appeared when they didn't. It's fine not
        // to know what to include: say plainly that nothing new stood out and
        // offer next steps or ask for direction.
        return """
        This pass surfaced nothing new, so NO review card was posted (status: \(outcome.status)). \
        Do NOT tell the user a card appeared, that the inbox was re-scanned with results, or that new \
        emails are ready — none of that is true and it breaks their trust. Instead, honestly tell them \
        nothing new stood out right now. It's completely fine not to know what they want reviewed: offer \
        to dig through older or already-read mail if they'd like, or ask what to focus on — a specific \
        sender, a timeframe, or old mail to clear. Keep it brief and warm.
        """
    }
}
