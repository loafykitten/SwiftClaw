import Foundation
import SwiftData
import os

/// System-only tool that creates a calendar-review chat with a card of
/// events worth the user's attention. Mirrors `EmailReviewNotifyTool`
/// (idempotency latch, stringified-array tolerance, honest failure) with a
/// single action: `review` (view the event). NOT registered on
/// `ToolRegistry.shared`.
final class CalendarReviewNotifyTool: Tool {
    private static let logger = AppLog.make("calendar.review.tool")

    let name = "notify_user_about_events"
    let displayName = "Notify User About Events"
    let description = """
    Notifies the user about calendar events that deserve attention. \
    Call this only when at least one event is worth surfacing. \
    If nothing needs the user, output nothing and do not call any tool.
    """
    let systemImage = "calendar.badge.exclamationmark"
    let parameters: [ToolParameter] = [
        ToolParameter(name: "event_actions", type: .array, description: """
        Array of objects, each describing one event: \
        { "event_guid": "<exact eventGUID from the fetched data>", "summary": "<one specific line on why this matters>" }
        """, isRequired: true),
        ToolParameter(name: "message", type: .string, description: """
        A friendly summary message shown above the cards. One or two sentences.
        """, isRequired: true),
        ToolParameter(name: "notification_summary", type: .string, description: """
        A compact version for the system notification banner: one plain sentence, \
        under 20 words, no greeting and no markdown.
        """, isRequired: false),
    ]

    var isConfigured: Bool { true }
    var isEnabled: Bool { true }

    private struct CalendarReviewAction: Codable {
        let eventGUID: String
        let summary: String?

        enum CodingKeys: String, CodingKey {
            case eventGUID = "event_guid"
            case summary
        }
    }

    private let modelContainer: ModelContainer
    private let targetChatID: UUID?
    private let onReviewCreated: (@MainActor (UUID, String) -> Void)?
    /// Idempotency latch — see `EmailReviewNotifyTool.hasCreatedChatForRun`.
    @MainActor private var hasCreatedChatForRun = false

    init(
        modelContainer: ModelContainer,
        targetChatID: UUID? = nil,
        onReviewCreated: (@MainActor (UUID, String) -> Void)? = nil
    ) {
        self.modelContainer = modelContainer
        self.targetChatID = targetChatID
        self.onReviewCreated = onReviewCreated
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        guard let actionsJSON = arguments["event_actions"],
              let message = arguments["message"]?.stringValue else {
            throw ToolError.missingArgument("event_actions/message")
        }
        let notificationSummary: String = {
            let compact = arguments["notification_summary"]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let compact, !compact.isEmpty else { return message }
            return compact
        }()

        // Accept a real array or a JSON-encoded array string (some
        // OpenAI-compatible proxies stringify tool arguments).
        let actions: [CalendarReviewAction]
        switch actionsJSON {
        case .array:
            let data = try JSONEncoder().encode(actionsJSON)
            actions = try JSONDecoder().decode([CalendarReviewAction].self, from: data)
        case .string(let jsonString):
            guard let data = jsonString.data(using: .utf8) else {
                throw ToolError.invalidArguments("event_actions string is not valid UTF-8")
            }
            do {
                actions = try JSONDecoder().decode([CalendarReviewAction].self, from: data)
            } catch {
                throw ToolError.invalidArguments("event_actions is not a JSON-encoded array: \(error.localizedDescription)")
            }
        default:
            throw ToolError.invalidArguments("event_actions must be an array or a JSON-array string")
        }

        let actionsWithGUIDs = actions.compactMap { action -> (CalendarReviewAction, UUID)? in
            guard let uuid = UUID(uuidString: action.eventGUID) else { return nil }
            return (action, uuid)
        }
        guard !actionsWithGUIDs.isEmpty else {
            throw ToolError.invalidArguments("event_actions contained no valid event GUIDs")
        }

        let title = "\(Chat.calendarReviewTitlePrefix) \(Date.now.formatted(.dateTime.month(.abbreviated).day()))"
        let outcome: CreationOutcome = await MainActor.run {
            if self.hasCreatedChatForRun {
                return .skippedIdempotent
            }
            let context = modelContainer.mainContext
            let repository = CalendarRepository(modelContext: context)

            // Drop GUIDs that resolve to nothing — the model can hallucinate
            // syntactically valid UUIDs, and a card action routed at a
            // missing event helps no one. All-unresolved fails the call just
            // like all-malformed does (mirrors ReminderReviewNotifyTool).
            let resolved = actionsWithGUIDs.compactMap { action, uuid -> (CalendarReviewAction, UUID, CalendarEvent)? in
                guard let event = repository.event(withID: uuid) else { return nil }
                return (action, uuid, event)
            }
            guard !resolved.isEmpty else { return .noStoredEvents }

            let reviewItems: [ReviewItem] = resolved.map { action, uuid, event in
                ReviewItem(
                    itemID: uuid,
                    actionToken: .review,
                    actionLabel: "View",
                    summary: action.summary,
                    subject: event.title,
                    date: {
                        // For a recurring series the master's startDate is
                        // the original DTSTART (possibly years back); the
                        // card should show the occurrence the review is
                        // actually about — the next upcoming one.
                        let displayStart = Self.upcomingStart(of: event, repository: repository)
                        return event.isAllDay
                            ? displayStart.formatted(.dateTime.weekday(.abbreviated).month().day())
                            : displayStart.formatted(date: .abbreviated, time: .shortened)
                    }(),
                    accountLabel: event.calendar?.name
                )
            }
            let payload = ReviewCardPayload(reviewType: .calendar, items: reviewItems)

            let createdChatID: UUID? = if let targetChatID {
                self.appendReview(to: targetChatID, in: context, payload: payload, message: message)
            } else {
                self.createReviewChat(
                    in: context,
                    title: title,
                    payload: payload,
                    message: message,
                    notificationSummary: notificationSummary
                )
            }
            guard let createdChatID else { return .failed }
            self.hasCreatedChatForRun = true
            return .created(createdChatID, itemCount: reviewItems.count)
        }

        switch outcome {
        case .skippedIdempotent:
            return "Already created a review chat for this pass — additional `notify_user_about_events` call ignored."
        case .noStoredEvents:
            throw ToolError.invalidArguments("event_actions contained no GUIDs matching stored events — use IDs returned by fetch_events")
        case .failed:
            throw ToolError.executionFailed("the review chat could not be saved and was NOT created")
        case .created(_, let count):
            return "\(targetChatID == nil ? "Created" : "Updated") review chat with \(count) item\(count == 1 ? "" : "s")."
        }
    }

    private enum CreationOutcome {
        case skippedIdempotent
        case noStoredEvents
        case created(UUID, itemCount: Int)
        case failed
    }

    /// The start of the event's next upcoming occurrence (looking two months
    /// out, overrides included), falling back to the stored start for
    /// one-offs, past events, and series with no near-term occurrence.
    @MainActor
    private static func upcomingStart(of event: CalendarEvent, repository: CalendarRepository) -> Date {
        guard event.isRecurring else { return event.displayInterval().start }
        let window = DateInterval(start: .now, duration: 60 * 24 * 3600)
        let occurrences = CalendarOccurrenceBuilder.occurrences(
            from: [event] + repository.overrides(of: event),
            in: window,
            visibleCalendarsOnly: false
        )
        return occurrences.first?.start ?? event.displayInterval().start
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

        let cardMessage = ChatMessage(role: .assistant, content: "", sortIndex: 0, reviewCard: payload)
        cardMessage.chat = chat
        context.insert(cardMessage)

        let summaryMessage = ChatMessage(role: .assistant, content: message, sortIndex: 1)
        summaryMessage.chat = chat
        context.insert(summaryMessage)

        chat.refreshLatestVisibleMessageAt()
        chat.updatedAt = .now

        do {
            try context.save()
            Self.logger.info("""
                created calendar review chat with \(payload.items.count, privacy: .public) items
                """)
            AppRouter.shared.noteNewChatMessages(in: chat.id)
            onReviewCreated?(chat.id, notificationSummary)
            return chat.id
        } catch {
            Self.logger.error("failed to save calendar review chat: \(String(describing: error))")
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
        var descriptor = FetchDescriptor<Chat>(predicate: #Predicate { $0.id == chatID })
        descriptor.fetchLimit = 1
        guard let chat = try? context.fetch(descriptor).first else {
            Self.logger.error("failed to append calendar review: target chat not found")
            return nil
        }
        for message in chat.messages where message.reviewCard != nil {
            message.reviewCard = nil
            message.content = "An updated analysis has been requested."
        }
        let nextIndex = (chat.messages.map(\.sortIndex).max() ?? -1) + 1
        let cardMessage = ChatMessage(role: .assistant, content: "", sortIndex: nextIndex, reviewCard: payload)
        cardMessage.chat = chat
        context.insert(cardMessage)
        let summaryMessage = ChatMessage(role: .assistant, content: message, sortIndex: nextIndex + 1)
        summaryMessage.chat = chat
        context.insert(summaryMessage)
        chat.refreshLatestVisibleMessageAt()
        chat.updatedAt = .now
        do {
            try context.save()
            AppRouter.shared.noteNewChatMessages(in: chat.id)
            return chat.id
        } catch {
            Self.logger.error("failed to save updated calendar review: \(String(describing: error))")
            return nil
        }
    }
}
