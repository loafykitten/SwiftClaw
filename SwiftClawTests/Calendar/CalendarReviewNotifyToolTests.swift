import Foundation
import SwiftData
import Testing
@testable import SwiftClaw

@MainActor
struct CalendarReviewNotifyToolTests {
    private static func makeContainer() throws -> ModelContainer {
        let schema = Schema([CalendarEvent.self, UserCalendar.self, Chat.self, ChatMessage.self])
        return try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
    }

    @MainActor
    private static func insertEvent(into container: ModelContainer, title: String) -> CalendarEvent {
        let repository = CalendarRepository(modelContext: container.mainContext)
        return repository.insert(CalendarEvent(
            title: title,
            startDate: .now.addingTimeInterval(24 * 3600),
            endDate: .now.addingTimeInterval(25 * 3600),
            calendar: repository.defaultCalendar()
        ))
    }

    private static func actionsJSON(for event: CalendarEvent) -> JSONValue {
        .array([
            .object([
                "event_guid": .string(event.id.uuidString),
                "summary": .string("Needs prep"),
            ]),
        ])
    }

    @Test func createsReviewChatWithCalendarCard() async throws {
        let container = try Self.makeContainer()
        let event = Self.insertEvent(into: container, title: "Board meeting")
        var created: (UUID, String)?
        let tool = CalendarReviewNotifyTool(
            modelContainer: container,
            onReviewCreated: { chatID, summary in created = (chatID, summary) }
        )

        let result = try await tool.execute(arguments: [
            "event_actions": Self.actionsJSON(for: event),
            "message": .string("One thing needs you."),
            "notification_summary": .string("Board meeting needs prep"),
        ])
        #expect(result.contains("Created review chat with 1 item"))
        #expect(created?.1 == "Board meeting needs prep")

        let chats = try container.mainContext.fetch(FetchDescriptor<Chat>())
        let reviewChat = try #require(chats.first { $0.isCalendarReviewChat })
        let card = try #require(reviewChat.messages.compactMap(\.reviewCard).first)
        #expect(card.reviewType == .calendar)
        #expect(card.items.count == 1)
        #expect(card.items.first?.subject == "Board meeting")
        #expect(card.items.first?.itemID == event.id)
        #expect(card.items.first?.summary == "Needs prep")
    }

    @Test func secondCallInSameRunIsIdempotentNoOp() async throws {
        let container = try Self.makeContainer()
        let event = Self.insertEvent(into: container, title: "Dinner")
        let tool = CalendarReviewNotifyTool(modelContainer: container)
        let arguments: [String: JSONValue] = [
            "event_actions": Self.actionsJSON(for: event),
            "message": .string("Heads up."),
        ]

        _ = try await tool.execute(arguments: arguments)
        let second = try await tool.execute(arguments: arguments)
        #expect(second.contains("ignored"))

        let chats = try container.mainContext.fetch(FetchDescriptor<Chat>())
        #expect(chats.count { $0.isCalendarReviewChat } == 1)
    }

    @Test func acceptsStringifiedActionArray() async throws {
        let container = try Self.makeContainer()
        let event = Self.insertEvent(into: container, title: "Flight")
        let tool = CalendarReviewNotifyTool(modelContainer: container)

        let json = """
        [{"event_guid": "\(event.id.uuidString)", "summary": "Check in opens"}]
        """
        let result = try await tool.execute(arguments: [
            "event_actions": .string(json),
            "message": .string("Travel day coming."),
        ])
        #expect(result.contains("1 item"))
    }

    @Test func rejectsPayloadWithoutValidGUIDs() async throws {
        let container = try Self.makeContainer()
        let tool = CalendarReviewNotifyTool(modelContainer: container)
        await #expect(throws: ToolError.self) {
            _ = try await tool.execute(arguments: [
                "event_actions": .array([
                    .object(["event_guid": .string("not-a-uuid"), "summary": .string("?")]),
                ]),
                "message": .string("hm"),
            ])
        }
    }
}
