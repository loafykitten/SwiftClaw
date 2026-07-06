import Foundation
import SwiftData
import os

/// System-only tool that creates a review chat listing emails that need
/// attention. NOT registered on `ToolRegistry.shared` — the assistant must
/// never be able to invoke it during normal user chats. Constructed by
/// `EmailReviewService` in a one-off `ToolRegistry(tools: [EmailReviewNotifyTool()])`.
final class EmailReviewNotifyTool: Tool {
    private static let logger = AppLog.make("mail.review.tool")

    let name = "notify_user_about_emails"
    let displayName = "Notify User About Emails"
    let description = """
    Notifies the user about emails that need attention. \
    Call this only when at least one email needs an action (review, flag, reply, delete). \
    If no emails need attention, output nothing and do not call any tool.
    """
    let systemImage = "envelope.badge"
    let parameters: [ToolParameter] = [
        ToolParameter(name: "email_actions", type: .array, description: """
        Array of objects, each describing one email that needs attention: \
        { "email_guid": "<UUID>", "action": "review"|"flag"|"reply"|"delete", "summary": "<short reason>" }
        """, isRequired: true),
        ToolParameter(name: "message", type: .string, description: """
        A friendly summary message shown above the cards. One or two sentences.
        """, isRequired: true),
        ToolParameter(name: "notification_summary", type: .string, description: """
        A compact version of the summary for the system notification banner: \
        one plain sentence, under 20 words, no greeting and no markdown. \
        Lead with the single most important item.
        """, isRequired: false),
    ]

    var isConfigured: Bool { true }
    var isEnabled: Bool { true }
    var requiresExplicitEnable: Bool { false }

    private let modelContainer: ModelContainer
    private let targetChatID: UUID?
    /// When true, post only the updated card and skip the inline summary
    /// `ChatMessage`. Set by the conversational refresh path so the chat
    /// assistant delivers the single closing summary instead of the review
    /// pass posting one *and* the assistant adding a redundant acknowledgment.
    private let suppressInlineSummary: Bool
    /// Called with the new chat's ID and a notification-sized summary (the
    /// model's `notification_summary` when provided, otherwise its full
    /// `message`), so the caller can both route the user and post a
    /// notification carrying the text.
    private let onReviewCreated: (@MainActor (UUID, String) -> Void)?
    /// Surfaces the model's `message` back to the caller so a conversational
    /// refresh can relay it as the assistant's reply.
    private let onSummaryProduced: (@MainActor (String) -> Void)?
    private let accountLabelProvider: @MainActor (UUID) -> String?

    /// Idempotency guard against the agentic loop calling this tool more
    /// than once per `EmailReviewService.runOnce()` pass: the first call
    /// creates the review chat; subsequent calls within the same run are a
    /// no-op returning a friendly message instead of producing duplicate
    /// review chats. Reset by constructing a fresh tool instance (which
    /// `EmailReviewService` does every run).
    @MainActor private var hasCreatedChatForRun: Bool = false

    init(
        modelContainer: ModelContainer,
        targetChatID: UUID? = nil,
        suppressInlineSummary: Bool = false,
        onReviewCreated: (@MainActor (UUID, String) -> Void)? = nil,
        onSummaryProduced: (@MainActor (String) -> Void)? = nil,
        // Labels match the inbox convention: only shown when more than one
        // account is configured — a single-account card never needs one.
        accountLabelProvider: @escaping @MainActor (UUID) -> String? = { accountID in
            let store = EmailAccountStore.shared
            guard store.accounts.count > 1 else { return nil }
            return store.account(for: accountID)?.effectiveDisplayName
                ?? EmailAccountLabeler.removedAccountLabel
        }
    ) {
        self.modelContainer = modelContainer
        self.targetChatID = targetChatID
        self.suppressInlineSummary = suppressInlineSummary
        self.onReviewCreated = onReviewCreated
        self.onSummaryProduced = onSummaryProduced
        self.accountLabelProvider = accountLabelProvider
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        guard let actionsJSON = arguments["email_actions"],
              let message = arguments["message"]?.stringValue else {
            throw ToolError.missingArgument("email_actions/message")
        }
        // Prefer the model's dedicated one-liner for the notification banner;
        // fall back to the full message (the notification service caps it).
        let notificationSummary: String = {
            let compact = arguments["notification_summary"]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let compact, !compact.isEmpty else { return message }
            return compact
        }()

        // The model is supposed to send `email_actions` as a JSON array (the
        // schema now declares `"type": "array"`). Some OpenAI-compatible
        // proxies still stringify tool arguments regardless of the schema, so
        // accept either an actual array or a JSON-encoded array string.
        let actions: [EmailReviewAction]
        switch actionsJSON {
        case .array:
            let actionsData = try JSONEncoder().encode(actionsJSON)
            actions = try JSONDecoder().decode([EmailReviewAction].self, from: actionsData)
        case .string(let jsonString):
            guard let jsonData = jsonString.data(using: .utf8) else {
                throw ToolError.invalidArguments("email_actions string is not valid UTF-8")
            }
            do {
                actions = try JSONDecoder().decode([EmailReviewAction].self, from: jsonData)
            } catch {
                throw ToolError.invalidArguments("email_actions is not a JSON-encoded array: \(error.localizedDescription)")
            }
        default:
            throw ToolError.invalidArguments("email_actions must be an array or a JSON-array string")
        }

        // Look up the referenced emails up-front so the review-card rows
        // can display subject + sender. Without this the renderer falls back
        // to the literal "Email" placeholder for every row. The lookup + the
        // chat insert share one `ModelContext` so we don't open + close a
        // second context moments later just to write the chat.
        let actionsWithGUIDs = actions.compactMap { action -> (EmailReviewAction, UUID)? in
            guard let uuid = UUID(uuidString: action.emailGUID) else { return nil }
            return (action, uuid)
        }

        let title = "\(Chat.emailReviewTitlePrefix) \(EmailReviewDateFormatter.string(from: .now))"
        let outcome: CreationOutcome = await MainActor.run {
            // Idempotency guard: a single review pass must produce at most one
            // review chat. `InferenceService.complete(...)` runs up to 8
            // tool-calling rounds; without this guard the model could call
            // `notify_user_about_emails` repeatedly and create duplicate
            // "Inbox review — …" chats in one pass. The latch is only stamped
            // *after* a confirmed save below, so a failed attempt leaves it
            // false and a later round can retry — while a successful create
            // blocks every subsequent round, preserving the at-most-one
            // guarantee.
            if self.hasCreatedChatForRun {
                return .skippedIdempotent
            }

            // Use the container's main context (we're on MainActor) so mutations
            // to an existing chat — collapsing a prior card into its label — land
            // on the same objects the chat view observes. A separate context
            // would persist the change but leave the UI's cached card instance
            // stale, so the superseded card would linger on screen.
            let context = modelContainer.mainContext
            let repository = EmailRepository(modelContext: context)

            // Batch-fetch subjects + senders in the same context the chat
            // insert will use — one `ModelContext` for the whole tool call.
            var emailMetadata: [UUID: (subject: String, sender: String, date: String, accountLabel: String?)] = [:]
            for (_, uuid) in actionsWithGUIDs where emailMetadata[uuid] == nil {
                if let email = repository.fetchEmail(by: uuid) {
                    emailMetadata[uuid] = (
                        email.subject,
                        email.displayFromAddress,
                        EmailReviewDateFormatter.string(from: email.date),
                        self.accountLabelProvider(email.accountID)
                    )
                }
            }

            let reviewItems: [ReviewItem] = actionsWithGUIDs.map { action, uuid in
                let token = ReviewActionToken(rawValue: action.actionToken) ?? .review
                let meta = emailMetadata[uuid]
                return ReviewItem(
                    itemID: uuid,
                    actionToken: token,
                    actionLabel: token.displayName,
                    summary: action.summary,
                    subject: meta?.subject,
                    sender: meta?.sender,
                    date: meta?.date,
                    accountLabel: meta?.accountLabel
                )
            }

            let payload = ReviewCardPayload(reviewType: .email, items: reviewItems)
            let createdChatID: UUID? = if let targetChatID {
                self.appendReview(
                    to: targetChatID,
                    in: context,
                    payload: payload,
                    message: message
                )
            } else {
                self.createReviewChat(
                    in: context,
                    title: title,
                    payload: payload,
                    message: message,
                    notificationSummary: notificationSummary
                )
            }

            // Only latch *after* a confirmed save. A nil result means the save
            // threw or the target chat was missing — nothing was persisted, so
            // leave the latch clear and report the failure honestly instead of
            // masquerading as the idempotency no-op.
            guard let createdChatID else {
                return .failed
            }
            self.hasCreatedChatForRun = true
            return .created(createdChatID)
        }

        switch outcome {
        case .skippedIdempotent:
            return "Already created a review chat for this pass — additional `notify_user_about_emails` call ignored."
        case .failed:
            // Honest failure: the review chat could NOT be saved and was not
            // created. Surfacing this (rather than a success string) keeps the
            // model from telling the user their review is ready when nothing
            // exists, and the unset latch lets a later round retry.
            throw ToolError.executionFailed("the review chat could not be saved and was NOT created")
        case .created:
            break
        }

        // Surface the model's summary so a conversational refresh can relay it
        // as the assistant's single closing message (it was suppressed inline).
        await MainActor.run { self.onSummaryProduced?(message) }

        let itemCount = actionsWithGUIDs.count
        if targetChatID != nil {
            return "Updated review chat with \(itemCount) item\(itemCount == 1 ? "" : "s")."
        } else {
            return "Created review chat with \(itemCount) item\(itemCount == 1 ? "" : "s")."
        }
    }

    /// Outcome of a single `notify_user_about_emails` invocation, distinguishing
    /// the idempotency no-op from a genuine save failure so the two are never
    /// conflated into one ambiguous `nil`.
    private enum CreationOutcome {
        case skippedIdempotent
        case created(UUID)
        case failed
    }

    @MainActor
    @discardableResult
    private func createReviewChat(
        in context: ModelContext,
        title: String,
        payload: ReviewCardPayload,
        message: String,
        notificationSummary: String
    ) -> UUID? {
        let chat = Chat(
            title: title,
            modelSelection: SettingsStorage.loadModelSelection(forKey: SettingsKeys.clawModel)
        )
        context.insert(chat)

        let cardMessage = ChatMessage(
            role: .assistant,
            content: "",
            sortIndex: 0,
            reviewCard: payload
        )
        cardMessage.chat = chat
        context.insert(cardMessage)

        let summaryMessage = ChatMessage(
            role: .assistant,
            content: message,
            sortIndex: 1
        )
        summaryMessage.chat = chat
        context.insert(summaryMessage)

        chat.updatedAt = .now

        do {
            try context.save()
            Self.logger.info("""
                created review chat \"\(title, privacy: .public)\" \
                with \(payload.items.count, privacy: .public) items
                """)
            AppRouter.shared.noteNewChatMessages(in: chat.id)
            onReviewCreated?(chat.id, notificationSummary)
            return chat.id
        } catch {
            Self.logger.error("""
                failed to save review chat: \(String(describing: error))
                """)
            return nil
        }
    }

    @MainActor
    @discardableResult
    private func appendReview(
        to chatID: UUID,
        in context: ModelContext,
        payload: ReviewCardPayload,
        message: String
    ) -> UUID? {
        var descriptor = FetchDescriptor<Chat>(
            predicate: #Predicate { $0.id == chatID }
        )
        descriptor.fetchLimit = 1
        guard let chat = try? context.fetch(descriptor).first else {
            Self.logger.error("failed to append review: target chat not found")
            return nil
        }

        // Supersede any prior card(s) so the chat shows a single live card —
        // each stale card collapses into a plain status label.
        for message in chat.messages where message.reviewCard != nil {
            message.reviewCard = nil
            message.content = "An updated analysis has been requested."
        }

        let nextIndex = (chat.messages.map(\.sortIndex).max() ?? -1) + 1
        let cardMessage = ChatMessage(
            role: .assistant,
            content: "",
            sortIndex: nextIndex,
            reviewCard: payload
        )
        cardMessage.chat = chat
        context.insert(cardMessage)

        // The conversational refresh path suppresses this inline summary so the
        // chat assistant delivers the single closing message — without it the
        // chat would show the review pass's summary *and* the assistant's
        // acknowledgment back to back, repeating itself.
        if !suppressInlineSummary {
            let summaryMessage = ChatMessage(
                role: .assistant,
                content: message,
                sortIndex: nextIndex + 1
            )
            summaryMessage.chat = chat
            context.insert(summaryMessage)
        }

        chat.updatedAt = .now

        do {
            try context.save()
            Self.logger.info("""
                appended updated review to chat \(chatID.uuidString, privacy: .public) \
                with \(payload.items.count, privacy: .public) items
                """)
            AppRouter.shared.noteNewChatMessages(in: chat.id)
            return chat.id
        } catch {
            Self.logger.error("""
                failed to save updated review in existing chat: \(String(describing: error))
                """)
            return nil
        }
    }
}
