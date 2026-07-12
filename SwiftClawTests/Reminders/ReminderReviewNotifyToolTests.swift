import Foundation
import SwiftData
import Testing
@testable import SwiftClaw

@MainActor
struct ReminderReviewNotifyToolTests {
    private static func makeContainer() throws -> ModelContainer {
        let schema = Schema([Reminder.self, ReminderList.self, Chat.self, ChatMessage.self])
        return try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
    }

    @MainActor
    private static func insertReminder(into container: ModelContainer, title: String) -> Reminder {
        let repository = ReminderRepository(modelContext: container.mainContext)
        return repository.insert(
            Reminder(title: title, dueDate: .now.addingTimeInterval(24 * 3600), hasDueTime: true),
            into: repository.defaultList()
        )
    }

    private static func actionsJSON(for reminder: Reminder) -> JSONValue {
        .array([
            .object([
                "reminder_guid": .string(reminder.id.uuidString),
                "summary": .string("Slipping overdue"),
            ]),
        ])
    }

    @Test func createsReviewChatWithRemindersCard() async throws {
        let container = try Self.makeContainer()
        let reminder = Self.insertReminder(into: container, title: "Renew passport")
        var created: (UUID, String)?
        let tool = ReminderReviewNotifyTool(
            modelContainer: container,
            onReviewCreated: { chatID, summary in created = (chatID, summary) }
        )

        let result = try await tool.execute(arguments: [
            "reminder_actions": Self.actionsJSON(for: reminder),
            "message": .string("One thing needs you."),
            "notification_summary": .string("Passport renewal is slipping"),
        ])
        #expect(result.contains("Created review chat with 1 item"))
        #expect(created?.1 == "Passport renewal is slipping")

        let chats = try container.mainContext.fetch(FetchDescriptor<Chat>())
        let reviewChat = try #require(chats.first { $0.isRemindersReviewChat })
        let card = try #require(reviewChat.messages.compactMap(\.reviewCard).first)
        #expect(card.reviewType == .reminders)
        #expect(card.items.count == 1)
        #expect(card.items.first?.subject == "Renew passport")
        #expect(card.items.first?.itemID == reminder.id)
        #expect(card.items.first?.summary == "Slipping overdue")
        #expect(card.items.first?.accountLabel == reminder.list?.name)
    }

    @Test func secondCallInSameRunIsIdempotentNoOp() async throws {
        let container = try Self.makeContainer()
        let reminder = Self.insertReminder(into: container, title: "Water plants")
        let tool = ReminderReviewNotifyTool(modelContainer: container)
        let arguments: [String: JSONValue] = [
            "reminder_actions": Self.actionsJSON(for: reminder),
            "message": .string("Heads up."),
        ]

        _ = try await tool.execute(arguments: arguments)
        let second = try await tool.execute(arguments: arguments)
        #expect(second.contains("ignored"))

        let chats = try container.mainContext.fetch(FetchDescriptor<Chat>())
        #expect(chats.count { $0.isRemindersReviewChat } == 1)
    }

    @Test func acceptsStringifiedActionArray() async throws {
        let container = try Self.makeContainer()
        let reminder = Self.insertReminder(into: container, title: "File taxes")
        let tool = ReminderReviewNotifyTool(modelContainer: container)

        let json = """
        [{"reminder_guid": "\(reminder.id.uuidString)", "summary": "Deadline approaching"}]
        """
        let result = try await tool.execute(arguments: [
            "reminder_actions": .string(json),
            "message": .string("Tax season."),
        ])
        #expect(result.contains("1 item"))
    }

    @Test func rejectsPayloadWithoutValidGUIDs() async throws {
        let container = try Self.makeContainer()
        let tool = ReminderReviewNotifyTool(modelContainer: container)
        await #expect(throws: ToolError.self) {
            _ = try await tool.execute(arguments: [
                "reminder_actions": .array([
                    .object(["reminder_guid": .string("not-a-uuid"), "summary": .string("?")]),
                ]),
                "message": .string("hm"),
            ])
        }
    }
}
