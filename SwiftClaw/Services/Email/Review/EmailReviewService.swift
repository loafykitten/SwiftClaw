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
    private let userDefaults: UserDefaults

    /// Closure invoked when a review chat is created, so the caller can route
    /// the user to it (or fire a dock badge / toast).
    var onReviewCreated: ((UUID) -> Void)?

    private(set) var lastStatusMessage: String?

    /// The friendly `message` the model wrote for the most recent pass, if it
    /// surfaced any emails. The conversational refresh path reads this to let
    /// the chat assistant relay the summary itself (the inline post is
    /// suppressed there to avoid a duplicate). Nil when the pass surfaced
    /// nothing or hasn't run.
    private(set) var lastSummaryMessage: String?

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

    /// `userDefaults` is injected (defaulting to `.standard`) so tests can run
    /// against an isolated `UserDefaultsFixture` rather than mutating
    /// `UserDefaults.standard` for `clawModel`/persona keys — which would
    /// leak across parallel test suites.
    init(modelContainer: ModelContainer, userDefaults: UserDefaults = .standard) {
        self.modelContainer = modelContainer
        self.userDefaults = userDefaults
    }

    /// Maximum number of threads handed to the LLM in a single pass. Caps
    /// first-run token blowup and pairs with the stamp-after-success contract
    /// so only the threads actually sent are suppressed. User-configurable in
    /// Email settings (`SettingsStorage.loadEmailReviewMaxThreads`).

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
    /// `suppressInlineSummary` (conversational refresh only) posts just the
    /// updated card and skips the inline summary `ChatMessage`, surfacing the
    /// model's summary via `lastSummaryMessage` so the chat assistant can
    /// deliver it as the single closing reply.
    @discardableResult
    func runOnce(
        force: Bool = false,
        targetChatID: UUID? = nil,
        suppressInlineSummary: Bool = false
    ) async -> Bool {
        lastStatusMessage = nil
        lastSummaryMessage = nil
        // Order matters: run every guard that can short-circuit *before*
        // stamping triage suppression, otherwise a failed pass permanently
        // suppresses the threads it was supposed to review. Stamping only on
        // success keeps "nothing-to-do" suppression (the legitimate case)
        // while letting retries land on the next interval.
        guard !ProcessInfo.processInfo.isRunningInPreview else {
            lastStatusMessage = "Review skipped in previews"
            return false
        }

        let context = ModelContext(modelContainer)
        let repository = EmailRepository(modelContext: context)

        // Scheduled passes (`force == false`) keep the cheap "nothing to do"
        // short-circuit the inlined pre-fetch used to give for free: don't burn
        // an inference call when every thread has already been triaged since the
        // last new mail. The forced/conversational path always proceeds — the
        // model + `fetch_inbox_emails` filters drive selection (including
        // archived/trashed steering the eligibility gate wouldn't see).
        if !force, !repository.hasThreadsEligibleForReview() {
            // Distinguish "inbox has mail but everything was triaged in a prior
            // pass" (the suppression path — expected, not an error) from "inbox
            // genuinely has nothing to review" so the log doesn't read like the
            // prior pass produced nothing.
            let allThreadCount = repository.fetchNonArchivedThreadCount()
            if allThreadCount > 0 {
                Self.logger.info("""
                    review: all \(allThreadCount, privacy: .public) inbox thread\(allThreadCount == 1 ? "" : "s") \
                    already triaged since last new mail; skipping
                    """)
                lastStatusMessage = "Review is already up to date"
            } else {
                Self.logger.info("review: inbox has no triageable threads; skipping")
                lastStatusMessage = "No email to review"
            }
            return false
        }

        let modelSelection = SettingsStorage.loadModelSelection(
            forKey: SettingsKeys.clawModel,
            userDefaults: userDefaults
        )
        guard !modelSelection.isEmpty else {
            Self.logger.warning("review skipped — clawModel not configured")
            lastStatusMessage = "Review needs a model in Settings"
            MailSyncMonitor.shared.setStatus("Review needs a model in Settings", syncing: false)
            return false
        }

        Self.logger.info("review: starting pass (force: \(force, privacy: .public))")

        let systemPrompt = Self.systemPrompt(
            isContinuation: targetChatID != nil,
            userDefaults: userDefaults
        )
        let userPrompt = Self.userPrompt()

        // When appending to an existing review chat, replay that chat's history
        // so the model's summary reads as a continuation rather than a fresh
        // cold review.
        var messages: [InferenceMessage] = [.system(systemPrompt)]
        if let targetChatID {
            messages.append(contentsOf: Self.chatHistory(for: targetChatID, in: context))
        }
        messages.append(.user(userPrompt))

        // The model selects which threads to review via `fetch_inbox_emails`;
        // we stamp exactly what it pulled. Suppression is on for scheduled
        // passes and off when forced (so a steered conversational refresh can
        // reach the whole inbox).
        let collector = FetchedThreadCollector()
        let fetchTool = EmailReviewFetchTool(
            modelContainer: modelContainer,
            applySuppression: !force,
            defaults: SettingsStorage.loadEmailReviewFetchDefaults(userDefaults: userDefaults),
            onThreadsFetched: { [collector] ids in collector.add(ids) }
        )
        let notifyTool = EmailReviewNotifyTool(
            modelContainer: modelContainer,
            targetChatID: targetChatID,
            suppressInlineSummary: suppressInlineSummary,
            onReviewCreated: { [weak self] chatID in
                if targetChatID == nil {
                    self?.onReviewCreated?(chatID)
                }
            },
            onSummaryProduced: { [weak self] message in
                self?.lastSummaryMessage = message
            }
        )
        let registry = ToolRegistry(tools: [fetchTool, notifyTool])

        do {
            _ = try await completeProvider(
                messages,
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
            lastStatusMessage = "Review failed"
            return false
        }

        // Stamp ONLY the threads the model actually fetched (and only after a
        // successful pass), advancing each thread's resurface-decay counter. A
        // successful pass that fetched threads but surfaced none still stamps —
        // the legitimate "looked, nothing to do" suppression. If the model
        // fetched nothing, there's nothing to stamp. Batched into one `save()`.
        let fetchedThreads = repository.fetchThreads(withIDs: Array(collector.ids))
        repository.markThreadsReviewed(fetchedThreads, at: Date())
        lastStatusMessage = "Review complete"
        return true
    }

    /// Accumulates the thread IDs the `fetch_inbox_emails` tool returns across
    /// the pass (the model may fetch more than once), so `runOnce` can stamp the
    /// union as reviewed. A reference type so the tool's callback mutates the
    /// same instance `runOnce` reads back.
    @MainActor
    private final class FetchedThreadCollector {
        private(set) var ids: Set<UUID> = []
        func add(_ newIDs: [UUID]) { ids.formUnion(newIDs) }
    }

    /// Prior messages of the target review chat, as inference history. Skips
    /// empty messages (review cards carry their data out-of-band and have no
    /// text content) so the model only sees actual conversation turns.
    private static func chatHistory(for chatID: UUID, in context: ModelContext) -> [InferenceMessage] {
        var descriptor = FetchDescriptor<Chat>(predicate: #Predicate { $0.id == chatID })
        descriptor.fetchLimit = 1
        guard let chat = try? context.fetch(descriptor).first else { return [] }
        return chat.sortedMessages.compactMap { message in
            guard !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return message.inferenceMessage(includingImages: false)
        }
    }

    // MARK: - Prompt construction

    private static func systemPrompt(
        isContinuation: Bool = false,
        userDefaults: UserDefaults
    ) -> String {
        let resolvedPersona = AssistantPersona.personaPrompt(userDefaults: userDefaults)
        // When re-running inside an existing review chat the prior conversation
        // is sent as message history, so the model should pick up the thread
        // rather than greet the user from scratch.
        let continuationNote = isContinuation ? """


        The user has asked you to re-run this analysis during an ongoing conversation, which is \
        included in the messages of this chat. Write your `message` as a natural continuation — \
        don't greet the user again or reintroduce yourself. Pick up where the conversation left \
        off and focus on what's changed or still stands out since the last analysis.

        The user's most recent message may also steer this run — for example, which senders or \
        topics to prioritize, surface, ignore, or treat as deletable. If it does, follow that \
        steering: it takes precedence over the default triage preferences above (including the \
        usual caution around `delete`) for this pass only. Apply it just to this run; don't treat \
        it as a standing rule.
        """ : ""
        let defaults = SettingsStorage.loadEmailReviewFetchDefaults(userDefaults: userDefaults)
        return """
        \(resolvedPersona)

        \(EmailReviewDateContext.currentString())

        You are triaging the user's email inbox on their behalf. Your job is to decide which threads \
        genuinely need the user to do something, and to tell them about those in your own voice.

        Work in two steps. FIRST call `fetch_inbox_emails` to pull the threads to look at — you choose \
        how much of the inbox to see. Its filters are all optional and omitted values use the user's \
        configured defaults: max_age_days \(defaults.maxAgeDescription), limit \(defaults.limit), \
        include flagged=\(defaults.includeFlagged), notated=\(defaults.includeNotated), \
        read=\(defaults.includeRead), unread=\(defaults.includeUnread), \
        archived=\(defaults.includeArchived), trashed=\(defaults.includeTrashed). Let the user's \
        steering override these for this pass — e.g. "this week" → set `max_age_days`, \
        "what's flagged?" → only flagged, "anything in my trash?" → include trashed, \
        "just the unread ones" → exclude read, or use a specific `limit` when they ask for an amount. \
        THEN review what comes back and decide which threads \
        need the user. You may call `fetch_inbox_emails` again with different filters if a first pull \
        clearly missed what the user is after.

        Lean toward surfacing. The user is working toward an inbox where every email is eventually either \
        deleted or archived, and they would much rather see a borderline thread than miss one that mattered. \
        Surface any thread that plausibly needs their attention — an unanswered question or request, a \
        deadline or upcoming event, something to follow up on, or a thread that is flagged or has notes and \
        may need another look. When in doubt, include it.

        Age counts too. A read thread that has simply been sitting unactioned in the inbox is itself worth \
        surfacing — to review/archive, or, when it's low-value, to clear out with `delete`. Some of the \
        threads below may be older mail being re-surfaced for exactly this reason. Favor mail that has gone \
        roughly a week or more without action; if little of that stands out, look further back (around a \
        month) for old low-value mail worth clearing. If the user has named a timeframe or which mail to go \
        after, follow that first.

        For each thread, read the latest message in the context of the whole thread: who is writing, whether \
        it is unread, whether the user is being asked something directly, whether it is already flagged, and \
        — importantly — any notes the user has written on it. A flagged or notated thread is a strong signal \
        it still matters; weight the user's notes heavily. Flagged and notated threads are handed to you on \
        every pass on purpose — use the note's intent and timing to judge whether NOW is the moment to put it \
        back in front of the user. If a note points to a later time that hasn't arrived yet (e.g. "follow up \
        in two months" and it's only been a few weeks), omit it for now rather than surfacing it every pass; \
        when that time has come, surface it. Then pick one action:
        - `reply` — the user clearly owes a response (a direct question or request awaiting their answer).
        - `flag` — should be followed up on later (a deadline, an upcoming event, a commitment), or is \
        already flagged and may still need attention.
        - `review` — needs the user's eyes or judgement. This is also your default: when a thread plausibly \
        matters but no sharper action clearly fits, surface it as `review` rather than dropping it.
        - `delete` — low-value mail the user is unlikely to miss: spam, junk, bulk promotions, automated \
        notifications, receipts and other transactional noise, and old read mail that has clearly served its \
        purpose. Every `delete` is only a suggestion the user confirms on the card, so lean toward offering \
        it for anything genuinely low-value rather than letting it pile up. Still don't suggest deleting mail \
        that looks personal, unresolved, or worth keeping — when a thread might actually matter, surface it \
        as `review` instead and let the user decide.
        Omit a thread only when it clearly needs nothing and isn't even worth a glance. (`archive` is \
        intentionally unavailable here — the user archives from a card's menu.)

        If at least one thread needs action, call `notify_user_about_emails`:
        {
          "email_actions": [
            { "email_guid": "<exact messageID UUID from the data below>", "action": "reply"|"flag"|"review"|"delete", "summary": "<one specific line on why this needs the user>" }
          ],
          "message": "<a short, friendly note to the user — one or two sentences setting up the cards>"
        }

        - `email_guid` MUST be copied exactly from a message's `messageID` in the fetched thread data \
        (usually the latest message in the thread). Never invent or alter a UUID. `subject`, `sender`, \
        and `date` are filled in automatically — do not provide them.
        - Keep each `summary` concrete and specific to that email — what it's about and why it needs the user, \
        not a generic phrase. Mention timing when a date actually matters, but do not add a separate dates list.
        - Write both each `summary` and the `message` in your own voice, per the personality above.

        If, after fetching and reviewing, nothing needs action, output nothing and do not call \
        `notify_user_about_emails`.\(continuationNote)
        """
    }

    private static func userPrompt() -> String {
        """
        Review my inbox. Start by calling `fetch_inbox_emails` to pull the threads worth a look \
        (use the defaults unless I've steered you otherwise), then tell me about anything that needs me. \
        For each thread, focus on the latest message.
        """
    }
}
