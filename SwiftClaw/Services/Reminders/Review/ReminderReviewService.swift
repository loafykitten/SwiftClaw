import Foundation
import SwiftData
import os

/// Drives the periodic AI review of the user's reminders — the Inbox Review
/// pattern applied to to-dos (see `CalendarReviewService`, the template).
/// Builds a `.standalone` prompt, hands the model a scoped `ToolRegistry`
/// holding only the reminders fetch + notify tools, and lets the model decide
/// whether anything deserves a review chat.
typealias ReminderReviewInferenceComplete = @Sendable (
    [InferenceMessage],
    String,
    InferenceSystemPromptMode,
    [any Tool]
) async throws -> String

@MainActor
final class ReminderReviewService {
    private static let logger = AppLog.make("reminders.review")

    /// How far ahead the scheduled-pass guards look — matches the fetch
    /// tool's default `due_within_days` so a pass is only skipped when the
    /// default fetch would come back empty or unchanged.
    private static let guardHorizon: TimeInterval = 7 * 24 * 3600

    private let modelContainer: ModelContainer
    private let userDefaults: UserDefaults

    /// Memory availability through this service's injected defaults — the
    /// global `MemoryFeatureModel.shared.isAvailable` reads `.standard`,
    /// which tests must not depend on.
    private var isMemoryAvailable: Bool {
        SettingsStorage.isMemoryEnabled(userDefaults: userDefaults)
            && MemoryFeatureModel.shared.repository != nil
    }

    /// Invoked when a review chat is created (chatID + notification-sized
    /// summary) so the workflow manager can route + notify.
    var onReviewCreated: ((UUID, String) -> Void)?

    private(set) var lastStatusMessage: String?

    /// Testable inference seam — tests inject a variant instead of hitting
    /// the network (see `EmailReviewService.completeProvider`).
    var completeProvider: ReminderReviewInferenceComplete = { messages, model, mode, tools in
        try await InferenceService.shared.complete(
            messages: messages,
            model: model,
            systemPromptMode: mode,
            tools: tools
        )
    }

    /// Testable seam over the router's unread set for the unread-review guard.
    var unreadChatIDsProvider: () -> Set<UUID> = { AppRouter.shared.unreadChatIDs }

    init(modelContainer: ModelContainer, userDefaults: UserDefaults = .standard) {
        self.modelContainer = modelContainer
        self.userDefaults = userDefaults
    }

    /// Runs one review pass. Returns `true` when the inference call succeeded
    /// (whether or not a review chat was created). Stamps `lastReviewedAt` on
    /// the reminders the model actually fetched, only after success — a
    /// transient failure must not suppress them.
    @discardableResult
    func runOnce(force: Bool = false, targetChatID: UUID? = nil) async -> Bool {
        lastStatusMessage = nil
        guard !ProcessInfo.processInfo.isRunningInPreview else {
            lastStatusMessage = "Review skipped in previews"
            return false
        }

        let context = ModelContext(modelContainer)
        let repository = ReminderRepository(modelContext: context)

        // Don't pile a new review onto one the user hasn't opened yet
        // (scheduled passes only — manual runs always proceed).
        if !force, hasUnreadReviewChat(in: context) {
            Self.logger.info("reminders review: previous review chat still unread; skipping scheduled pass")
            lastStatusMessage = "Previous review is still unread"
            return false
        }

        // Cheap short-circuits (scheduled passes only): nothing pending in
        // the default fetch window, or everything there was already reviewed
        // and hasn't changed since — without the latter, every pass after
        // the user opens a review re-sends the same unchanged to-dos and can
        // recreate the same review chat.
        if !force {
            let scope = reviewScope(repository: repository)
            if scope.isEmpty {
                Self.logger.info("reminders review: nothing pending; skipping")
                lastStatusMessage = "No pending reminders to review"
                return false
            }
            let hasUnreviewedChange = scope.contains { reminder in
                guard let reviewedAt = reminder.lastReviewedAt else { return true }
                return reminder.modifiedAt > reviewedAt
            }
            if !hasUnreviewedChange {
                Self.logger.info("reminders review: nothing new since the last review; skipping")
                lastStatusMessage = "Nothing new since the last review"
                return false
            }
        }

        let modelSelection = SettingsStorage.loadModelSelection(
            forKey: SettingsKeys.clawModel,
            userDefaults: userDefaults
        )
        guard !modelSelection.isEmpty else {
            Self.logger.warning("reminders review skipped — clawModel not configured")
            lastStatusMessage = "Review needs a model in Settings"
            return false
        }

        Self.logger.info("reminders review: starting pass (force: \(force, privacy: .public))")

        let collector = FetchedReminderCollector()
        let memoryCollector = MemoryProposalRunCollector()
        let reviewChatCapture = MemoryReviewChatCapture()
        let fetchTool = ReminderReviewFetchTool(
            modelContainer: modelContainer,
            onRemindersFetched: { [collector] ids in collector.add(ids) }
        )
        let notifyTool = ReminderReviewNotifyTool(
            modelContainer: modelContainer,
            targetChatID: targetChatID,
            onReviewCreated: { [weak self] chatID, summary in
                reviewChatCapture.chatID = chatID
                if targetChatID == nil {
                    self?.onReviewCreated?(chatID, summary)
                }
            }
        )
        var reviewTools: [any Tool] = [fetchTool, notifyTool]
        if isMemoryAvailable {
            reviewTools.append(ProposeMemoryTool(
                feature: .reminders,
                modelContainer: modelContainer,
                collector: memoryCollector
            ))
        }
        let registry = ToolRegistry(tools: reviewTools)

        var systemPrompt = Self.systemPrompt(userDefaults: userDefaults)
        if let memoryBlock = MemoryReviewContextBuilder.block(for: .reminders, isEnabled: isMemoryAvailable) {
            systemPrompt += "\n\n\(memoryBlock)"
        }
        let messages: [InferenceMessage] = [
            .system(systemPrompt),
            .user(Self.userPrompt()),
        ]

        do {
            _ = try await completeProvider(messages, modelSelection, .standalone, registry.availableTools)
        } catch {
            Self.logger.error("reminders review complete() failed: \(String(describing: error))")
            lastStatusMessage = "Review failed"
            return false
        }

        // Any memory proposals this run raised get their cards now — into
        // the run's review chat when one exists, else the shared
        // "Memory suggestions" chat. The router also sweeps this source's
        // orphans from runs that were interrupted before routing.
        MemoryReviewProposalRouter.route(
            proposalIDs: memoryCollector.proposalIDs,
            for: .reminders,
            preferredChatID: targetChatID ?? reviewChatCapture.chatID,
            modelContainer: modelContainer
        )

        // Stamp only what the model actually pulled, only after success.
        let fetched = collector.ids.compactMap { repository.reminder(withID: $0) }
        let stamp = Date.now
        for reminder in fetched {
            reminder.lastReviewedAt = stamp
        }
        if !fetched.isEmpty {
            repository.saveChanges()
        }
        lastStatusMessage = "Review complete"
        return true
    }

    /// The reminders a default fetch would return: pending masters that are
    /// undated or due within the guard horizon (overdue included).
    private func reviewScope(repository: ReminderRepository) -> [Reminder] {
        let horizon = Date.now.addingTimeInterval(Self.guardHorizon)
        return repository.pendingReminders().filter { reminder in
            guard let due = reminder.dueDate else { return true }
            return due <= horizon
        }
    }

    private func hasUnreadReviewChat(in context: ModelContext) -> Bool {
        let unreadIDs = Array(unreadChatIDsProvider())
        guard !unreadIDs.isEmpty else { return false }
        let descriptor = FetchDescriptor<Chat>(
            predicate: #Predicate { unreadIDs.contains($0.id) }
        )
        guard let chats = try? context.fetch(descriptor) else { return false }
        return chats.contains { !$0.isArchived && $0.isRemindersReviewChat }
    }

    /// Accumulates fetched reminder IDs across the pass (the model may fetch
    /// more than once).
    @MainActor
    private final class FetchedReminderCollector {
        private(set) var ids: Set<UUID> = []
        func add(_ newIDs: [UUID]) { ids.formUnion(newIDs) }
    }

    // MARK: - Prompts

    private static func systemPrompt(userDefaults: UserDefaults) -> String {
        let persona = AssistantPersona.personaPrompt(userDefaults: userDefaults)
        return """
        \(persona)

        \(PromptDateContext.currentString())

        You are reviewing the user's reminders on their behalf. Your job is to spot what \
        genuinely deserves their attention and tell them about it in your own voice.

        Work in two steps. FIRST call `fetch_reminders` to pull the pending to-dos — \
        the defaults cover everything overdue, due in the next 7 days, and undated; \
        widen or narrow the window if the user has steered you. \
        THEN look for things worth surfacing:
        - Overdue: reminders past their due date, especially ones slipping for days.
        - Imminent: due today or tomorrow, especially timed, high-priority, or flagged ones.
        - Crunch: a day where several due dates stack up.
        - Stalled: undated or long-lived reminders that look important but aren't moving \
        (a flagged item with no due date, a checklist barely started).

        Do NOT surface routine recurring reminders just because they exist — a daily "take \
        vitamins" is not news. Reminders marked "previously reviewed: yes" were already \
        surfaced to the user in an earlier review and haven't changed since — mention one \
        again only if something new makes it newly relevant (it slipped overdue, its day \
        got crowded). \
        Quality over quantity: a short list of things that matter beats an exhaustive digest.

        If at least one reminder is worth surfacing, call `notify_user_about_reminders`:
        {
          "reminder_actions": [
            { "reminder_guid": "<exact reminderGUID from the fetched data>", "summary": "<one specific line on why this matters>" }
          ],
          "message": "<a short, friendly note setting up the cards — one or two sentences>"
        }
        - `reminder_guid` MUST be copied exactly from the fetched data. Never invent or alter a UUID.
        - Keep each `summary` concrete: what it is and why it needs the user, with timing when it matters.

        If, after fetching and reviewing, nothing genuinely needs the user, output nothing and \
        do not call `notify_user_about_reminders`.
        """
    }

    private static func userPrompt() -> String {
        """
        Review my reminders. Start by calling `fetch_reminders` for what's pending, \
        then tell me about anything that needs me — overdue work, imminent due dates, or stalled items.
        """
    }
}
