import Foundation
import SwiftData
import os

/// Drives the periodic AI review of the user's inbox. Owned by the scheduler;
/// ticks on `SettingsKeys.emailReviewIntervalSeconds`, separately from the
/// mail-pull sync. Builds a `.system` review prompt, calls
/// `InferenceService.shared.complete(... tools: oneOffRegistry.availableTools)`
/// with a scoped `ToolRegistry` containing only `EmailReviewNotifyTool`, and
/// relies on the model deciding whether to invoke the tool (no action → no
/// tool call → no chat → no notification).
typealias EmailReviewInferenceComplete = @Sendable (
    [InferenceMessage],
    String,
    InferenceSystemPromptMode,
    [any Tool]
) async throws -> String

@MainActor
final class EmailReviewService {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.caffeineplz.SwiftClaw",
        category: "mail.review"
    )

    private let modelContainer: ModelContainer

    /// Closure invoked when a review chat is created, so the caller can route
    /// the user to it (or fire a dock badge / toast).
    var onReviewCreated: ((UUID) -> Void)?

    /// Testable inference seam. Defaults to the real
    /// `InferenceService.shared.complete(...)` call; tests inject a
    /// throwing/succeeding variant to assert the stamp-after-success contract
    /// + batch-cap behavior without hitting the network.
    var completeProvider: EmailReviewInferenceComplete = { messages, model, mode, tools in
        try await InferenceService.shared.complete(
            messages: messages,
            model: model,
            systemPromptMode: mode,
            tools: tools
        )
    }

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    /// Maximum number of threads handed to the LLM in a single pass. Caps
    /// first-run token blowup and pairs with the stamp-after-success contract
    /// so only the threads actually sent are suppressed.
    static let maxThreadsPerPass = 40

    /// Runs one review pass. Returns `true` when the inference call
    /// succeeded (whether or not the model created a review chat); `false`
    /// when there was nothing to review, the model wasn't configured, or the
    /// inference call threw. Stamps `lastReviewedAt` only on success so a
    /// transient failure doesn't permanently suppress the threads the pass
    /// was supposed to review.
    /// `force` skips the `lastReviewedAt` triage-suppression filter so the
    /// manual "Review Now" button can re-triage an inbox where every thread
    /// was already reviewed in a prior pass. The scheduled loop keeps
    /// `force: false` so the H3 "no re-send until new mail" contract holds.
    @discardableResult
    func runOnce(force: Bool = false) async -> Bool {
        // Order matters: run every guard that can short-circuit *before*
        // stamping triage suppression, otherwise a failed pass permanently
        // suppresses the threads it was supposed to review. Stamping only on
        // success keeps "nothing-to-do" suppression (the legitimate case)
        // while letting retries land on the next interval.
        guard !ProcessInfo.processInfo.isRunningInPreview else { return false }

        let context = ModelContext(modelContainer)
        let repository = EmailRepository(modelContext: context)
        let threads = repository.fetchNonArchivedThreadsForReview(
            limit: Self.maxThreadsPerPass,
            force: force
        )
        guard !threads.isEmpty else {
            // Distinguish "inbox has mail but everything was triaged in a
            // prior pass" (the H3 suppression path — expected, not an error)
            // from "inbox genuinely has nothing to review" so the log line
            // doesn't read like the prior pass produced nothing. Under
            // `force` this branch only fires when the inbox is genuinely
            // empty.
            let allThreadCount = repository.fetchNonArchivedThreadCount()
            if allThreadCount > 0 {
                Self.logger.info("""
                    review: all \(allThreadCount, privacy: .public) inbox thread\(allThreadCount == 1 ? "" : "s") \
                    already triaged since last new mail; skipping
                    """)
            } else {
                Self.logger.info("review: inbox has no triageable threads; skipping")
            }
            return false
        }

        let modelSelection = UserDefaults.standard.string(forKey: SettingsKeys.clawModel) ?? ""
        guard !modelSelection.isEmpty else {
            Self.logger.warning("review skipped — clawModel not configured")
            MailSyncMonitor.shared.setStatus("Review needs a model in Settings", syncing: false)
            return false
        }

        let descriptors = threads.map { Self.descriptor(for: $0) }
        let systemPrompt = Self.systemPrompt(for: descriptors)
        let userPrompt = Self.userPrompt(for: descriptors)

        let tool = EmailReviewNotifyTool(modelContainer: modelContainer) { [weak self] chatID in
            self?.onReviewCreated?(chatID)
        }
        let registry = ToolRegistry(tools: [tool])

        do {
            _ = try await completeProvider(
                [
                    .system(systemPrompt),
                    .user(userPrompt)
                ],
                modelSelection,
                .standalone,
                registry.availableTools
            )
        } catch {
            // Do NOT stamp: a transient failure (network blip, rate limit,
            // context overflow) must not suppress these threads forever. The
            // next pass will retry them.
            Self.logger.error("""
                review complete() failed: \(String(describing: error))
                """)
            return false
        }

        // Stamp ONLY the threads we actually sent (and only after a
        // successful pass). A successful pass that produces no tool call
        // still stamps — that's the legitimate "nothing to do" suppression.
        // Batched into a single `save()` (one per pass rather than one per
        // thread).
        repository.markThreadsReviewed(threads, at: Date())
        return true
    }

    // MARK: - Prompt construction

    private static func systemPrompt(for threads: [EmailReviewThreadDescriptor]) -> String {
        let schema = """
        {
          "reviewType": "email",
          "items": [
            {
              "id": "<uuid>",
              "itemID": "<email UUID — pass back as email_guid>",
              "actionToken": "review" | "flag" | "reply" | "delete",
              "actionLabel": "Review" | "Flag" | "Reply" | "Delete",
              "summary": "<one-line reason>",
              "subject": "<optional>",
              "sender": "<optional>"
            }
          ]
        }
        """

        return """
        You are reviewing the user's inbox. For each thread below, decide what (if anything) the user should do: \
        review, flag, reply, delete, or nothing. If no action is needed for an item, omit it. If no items need \
        attention, output nothing and do not call any tool. Otherwise, call `notify_user_about_emails` with the \
        items requiring action plus a friendly summary message for the user.

        The JSON value to pass as the `email_actions` tool argument:
        {
          "email_actions": [
            { "email_guid": "<UUID>", "action": "review"|"flag"|"reply"|"delete", "summary": "<short reason>" }
          ]
        }

        The `email_guid` value MUST be the exact UUID passed in the thread/messages below. The action token must \
        be one of: review, flag, reply, delete. Use `review` for items where context is needed (long thread, \
        unanswered question), `flag` for items to follow up on, `reply` when the user clearly owes a response, \
        and `delete` only for obvious spam/newsletters. Default to "review" when unsure. (Note: `archive` is \
        intentionally NOT offered to the model — the user can still choose it from a review card's context menu.)

        ReviewCardPayload schema (for your context only):
        \(schema)
        """
    }

    private static func userPrompt(for threads: [EmailReviewThreadDescriptor]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = (try? encoder.encode(threads)) ?? Data()
        let json = String(data: data, encoding: .utf8) ?? "[]"
        return """
        Review the following inbox threads and decide which (if any) need the user's attention. \
        For each thread, focus on the latest message. The list below has already been filtered \
        to threads not yet reviewed since their most recent message arrived — so every thread \
        you see is genuinely unreviewed.

        Threads (JSON):
        \(json)
        """
    }

    private static func descriptor(for thread: EmailThread) -> EmailReviewThreadDescriptor {
        let messages = thread.sortedMessages.map { message in
            EmailReviewMessageDescriptor(
                messageID: message.id,
                subject: message.subject,
                fromAddress: message.fromAddress,
                snippet: message.snippet,
                isRead: message.isRead,
                isFlagged: message.isFlagged,
                notes: message.sortedNoteDescriptors
            )
        }
        return EmailReviewThreadDescriptor(
            threadID: thread.id,
            subject: thread.latestMessage?.subject ?? "",
            participantSummary: thread.participantSummary,
            snippet: thread.latestMessage?.snippet ?? "",
            unreadCount: thread.unreadCount,
            isFlagged: thread.isFlagged,
            messages: messages
        )
    }
}

private extension Email {
    var sortedNoteDescriptors: [EmailReviewNoteDescriptor] {
        notes
            .sorted { $0.createdAt < $1.createdAt }
            .map { EmailReviewNoteDescriptor(author: $0.author.rawValue, content: $0.content) }
    }
}
