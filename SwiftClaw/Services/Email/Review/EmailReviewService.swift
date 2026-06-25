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
    private static let logger = AppLog.make("mail.review")

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
        let systemPrompt = Self.systemPrompt()
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

    private static func systemPrompt(
        persona: String = AssistantPersona.personaPrompt()
    ) -> String {
        return """
        \(persona)

        You are triaging the user's email inbox on their behalf. Your job is to decide which threads \
        genuinely need the user to do something, and to tell them about those in your own voice.

        Be selective. Most inbox mail needs no action; surfacing everything trains the user to ignore you. \
        Only raise a thread when doing nothing would cost the user something real — a missed reply, a \
        deadline, a commitment to follow up on. When you are unsure an item matters, leave it out.

        For each thread, read the latest message in the context of the whole thread: who is writing, whether \
        it is unread, whether the user is being asked something directly, and — importantly — any notes the \
        user has already written on it. Those notes are the user's own annotations; weight them heavily. \
        Then pick one action:
        - `reply` — the user clearly owes a response (a direct question or request awaiting their answer).
        - `flag` — needs follow-up later but not an immediate reply (a deadline, a commitment, something to revisit).
        - `review` — needs the user's eyes or judgement, but the right move isn't a simple reply or flag \
        (a long or ambiguous thread). Use this only when an item genuinely needs attention and none of the \
        sharper actions fit — not as a catch-all.
        - `delete` — obvious spam or low-value bulk mail (newsletters, promotions) the user would not miss.
        Anything that needs no action: omit it entirely. (`archive` is intentionally unavailable here — the \
        user can archive from a card's menu.)

        If at least one thread needs action, call `notify_user_about_emails`:
        {
          "email_actions": [
            { "email_guid": "<exact messageID UUID from the data below>", "action": "reply"|"flag"|"review"|"delete", "summary": "<one specific line on why this needs the user>" }
          ],
          "message": "<a short, friendly note to the user — one or two sentences setting up the cards>"
        }

        - `email_guid` MUST be copied exactly from a message's `messageID` in the data below (usually the \
        latest message in the thread). Never invent or alter a UUID. `subject`, `sender`, and `date` are \
        filled in automatically — do not provide them.
        - Keep each `summary` concrete and specific to that email — what it's about and why it needs the user, \
        not a generic phrase. Mention timing when a date actually matters, but do not add a separate dates list.
        - Write both each `summary` and the `message` in your own voice, per the personality above.

        If nothing needs action, output nothing and do not call any tool.
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
        let reviewableMessages = thread.reviewableMessages
        let latest = thread.latestReviewableMessage
        let messages = reviewableMessages.map { message in
            EmailReviewMessageDescriptor(
                messageID: message.id,
                subject: message.subject,
                fromAddress: message.fromAddress,
                date: EmailReviewDateFormatter.string(from: message.date),
                snippet: message.snippet,
                isRead: message.isRead,
                isFlagged: message.isFlagged,
                notes: message.sortedNoteDescriptors
            )
        }
        return EmailReviewThreadDescriptor(
            threadID: thread.id,
            subject: latest?.subject ?? "",
            latestMessageDate: latest.map { EmailReviewDateFormatter.string(from: $0.date) } ?? "",
            participantSummary: thread.reviewParticipantSummary,
            snippet: latest?.snippet ?? "",
            unreadCount: thread.reviewUnreadCount,
            isFlagged: thread.isReviewFlagged,
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
