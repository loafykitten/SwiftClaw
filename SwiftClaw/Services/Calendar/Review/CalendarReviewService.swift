import Foundation
import SwiftData
import os

/// Drives the periodic AI review of the user's calendar — the Inbox Review
/// pattern applied to the schedule (see `EmailReviewService`, the template).
/// Builds a `.standalone` prompt, hands the model a scoped `ToolRegistry`
/// holding only the calendar fetch + notify tools, and lets the model decide
/// whether anything deserves a review chat.
typealias CalendarReviewInferenceComplete = @Sendable (
    [InferenceMessage],
    String,
    InferenceSystemPromptMode,
    [any Tool]
) async throws -> String

@MainActor
final class CalendarReviewService {
    private static let logger = AppLog.make("calendar.review")

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
    var completeProvider: CalendarReviewInferenceComplete = { messages, model, mode, tools in
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
    /// the events the model actually fetched, only after success — a
    /// transient failure must not suppress them.
    @discardableResult
    func runOnce(force: Bool = false, targetChatID: UUID? = nil) async -> Bool {
        lastStatusMessage = nil
        guard !ProcessInfo.processInfo.isRunningInPreview else {
            lastStatusMessage = "Review skipped in previews"
            return false
        }

        let context = ModelContext(modelContainer)
        let repository = CalendarRepository(modelContext: context)

        // Don't pile a new review onto one the user hasn't opened yet
        // (scheduled passes only — manual runs always proceed).
        if !force, hasUnreadReviewChat(in: context) {
            Self.logger.info("calendar review: previous review chat still unread; skipping scheduled pass")
            lastStatusMessage = "Previous review is still unread"
            return false
        }

        // Cheap short-circuits (scheduled passes only): an empty week, or a
        // week where every event was already reviewed and hasn't changed
        // since — without the latter, every pass after the user opens a
        // review re-sends the same unchanged schedule and can recreate the
        // same review chat.
        let week = DateInterval(start: .now, duration: 7 * 24 * 3600)
        if !force {
            let upcoming = repository.occurrences(in: week)
            if upcoming.isEmpty {
                Self.logger.info("calendar review: no upcoming occurrences; skipping")
                lastStatusMessage = "Nothing on the calendar to review"
                return false
            }
            let masters = repository.events(withIDs: Array(Set(upcoming.map(\.eventID))))
            let hasUnreviewedChange = masters.contains { event in
                guard let reviewedAt = event.lastReviewedAt else { return true }
                return event.modifiedAt > reviewedAt
            }
            if !hasUnreviewedChange {
                Self.logger.info("calendar review: nothing new since the last review; skipping")
                lastStatusMessage = "Nothing new since the last review"
                return false
            }
        }

        let modelSelection = SettingsStorage.loadModelSelection(
            forKey: SettingsKeys.clawModel,
            userDefaults: userDefaults
        )
        guard !modelSelection.isEmpty else {
            Self.logger.warning("calendar review skipped — clawModel not configured")
            lastStatusMessage = "Review needs a model in Settings"
            return false
        }

        Self.logger.info("calendar review: starting pass (force: \(force, privacy: .public))")

        let collector = FetchedEventCollector()
        let memoryCollector = MemoryProposalRunCollector()
        let reviewChatCapture = MemoryReviewChatCapture()
        let fetchTool = CalendarReviewFetchTool(
            modelContainer: modelContainer,
            onEventsFetched: { [collector] versions in collector.add(versions) }
        )
        let notifyTool = CalendarReviewNotifyTool(
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
                feature: .calendar,
                modelContainer: modelContainer,
                collector: memoryCollector
            ))
        }
        let registry = ToolRegistry(tools: reviewTools)

        var systemPrompt = Self.systemPrompt(userDefaults: userDefaults)
        if let memoryBlock = MemoryReviewContextBuilder.block(for: .calendar, isEnabled: isMemoryAvailable) {
            systemPrompt += "\n\n\(memoryBlock)"
        }
        let messages: [InferenceMessage] = [
            .system(systemPrompt),
            .user(Self.userPrompt()),
        ]

        do {
            _ = try await completeProvider(messages, modelSelection, .standalone, registry.availableTools)
        } catch {
            Self.logger.error("calendar review complete() failed: \(String(describing: error))")
            lastStatusMessage = "Review failed"
            return false
        }

        // Any memory proposals this run raised get their cards now — into
        // the run's review chat when one exists, else the shared
        // "Memory suggestions" chat. The router also sweeps this source's
        // orphans from runs that were interrupted before routing.
        MemoryReviewProposalRouter.route(
            proposalIDs: memoryCollector.proposalIDs,
            for: .calendar,
            preferredChatID: targetChatID ?? reviewChatCapture.chatID,
            modelContainer: modelContainer
        )

        // Stamp only what the model actually pulled, only after success,
        // and only rows still at the version it saw: an edit that landed
        // mid-pass was never reviewed and must keep triggering the next one.
        // A fresh context so the comparison reads committed values, not this
        // pass's earlier-fetched objects.
        let stampRepository = CalendarRepository(modelContext: ModelContext(modelContainer))
        let stamp = Date.now
        var stampedAny = false
        for event in stampRepository.events(withIDs: Array(collector.versions.keys)) {
            guard let seen = collector.versions[event.id], event.modifiedAt <= seen else { continue }
            event.lastReviewedAt = stamp
            stampedAny = true
        }
        if stampedAny {
            stampRepository.saveChanges()
        }
        lastStatusMessage = "Review complete"
        return true
    }

    private func hasUnreadReviewChat(in context: ModelContext) -> Bool {
        let unreadIDs = Array(unreadChatIDsProvider())
        guard !unreadIDs.isEmpty else { return false }
        let descriptor = FetchDescriptor<Chat>(
            predicate: #Predicate { unreadIDs.contains($0.id) }
        )
        guard let chats = try? context.fetch(descriptor) else { return false }
        return chats.contains { !$0.isArchived && $0.isCalendarReviewChat }
    }

    /// Accumulates fetched event versions (ID -> `modifiedAt` the model saw)
    /// across the pass. The model may fetch more than once; the newest
    /// version it saw wins.
    @MainActor
    private final class FetchedEventCollector {
        private(set) var versions: [UUID: Date] = [:]
        func add(_ newVersions: [UUID: Date]) {
            versions.merge(newVersions) { max($0, $1) }
        }
    }

    // MARK: - Prompts

    private static func systemPrompt(userDefaults: UserDefaults) -> String {
        let persona = AssistantPersona.personaPrompt(userDefaults: userDefaults)
        return """
        \(persona)

        \(PromptDateContext.currentString())

        You are reviewing the user's calendar on their behalf. Your job is to spot what \
        genuinely deserves their attention in the days ahead and tell them about it in your own voice.

        Work in two steps. FIRST call `fetch_calendar_events` to pull the upcoming schedule — \
        the defaults cover the next 7 days; widen or narrow the window if the user has steered you. \
        THEN look for things worth surfacing:
        - Conflicts: overlapping timed events the user may not have noticed.
        - Crunch: back-to-back blocks with no gap, or a day that looks unusually packed.
        - Preparation: events whose title, notes, or URL suggest something to do beforehand \
        (a meeting with an agenda link, a trip, an appointment needing documents).
        - Standouts: anything unusual or important in the next day or two the user should have on their radar.

        Do NOT surface routine recurring events just because they exist — a daily standup is not news. \
        Events marked "previously reviewed: yes" were already surfaced to the user in an earlier \
        review and haven't changed since — mention one again only if something new makes it newly \
        relevant (a fresh conflict, a changed neighbor). \
        Quality over quantity: a short list of things that matter beats an exhaustive digest.

        If at least one event is worth surfacing, call `notify_user_about_events`:
        {
          "event_actions": [
            { "event_guid": "<exact eventGUID from the fetched data>", "summary": "<one specific line on why this matters>" }
          ],
          "message": "<a short, friendly note setting up the cards — one or two sentences>"
        }
        - `event_guid` MUST be copied exactly from the fetched data. Never invent or alter a UUID.
        - Keep each `summary` concrete: what it is and why it needs the user, with timing when it matters.

        If, after fetching and reviewing, nothing genuinely needs the user, output nothing and \
        do not call `notify_user_about_events`.
        """
    }

    private static func userPrompt() -> String {
        """
        Review my calendar. Start by calling `fetch_calendar_events` for the coming days, \
        then tell me about anything that needs me — conflicts, prep work, or standouts.
        """
    }
}
