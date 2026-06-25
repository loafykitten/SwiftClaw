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
        This chat is an email review follow-up. The referenced emails are below.
        \(EmailReviewDateContext.currentString())
        Use the email_guid exactly when calling email tools. You can add AI notes,
        set/unset flags, or re-run the inbox analysis when the user asks; otherwise
        just answer normally.

        \(emailBlocks.joined(separator: "\n\n---\n\n"))
        """
    }

    private static func makeEmailBlock(_ email: Email) -> String {
        """
        email_guid: \(email.id.uuidString)
        subject: \(email.subject)
        from: \(email.fromAddress)
        to: \(email.toAddresses.joined(separator: ", "))
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
        let status = await EmailWorkflowManager.shared.reviewNow(appendingTo: chatID)
        guard status == "Review complete" else {
            // Nothing to review / no model / failure — let the model relay it.
            return status ?? "Ran an updated email analysis for this chat."
        }
        // The review pass has already posted its own continuation summary (and
        // any updated card) directly to this chat, so the model should not
        // restate it — just acknowledge briefly.
        return """
        The inbox has been re-analyzed and any updated review card and summary have been posted \
        directly to this chat. Do not restate the analysis — just briefly acknowledge that it's \
        done, or ask if they'd like anything else.
        """
    }
}
