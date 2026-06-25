import Foundation
import Testing
import SwiftData
@testable import SwiftClaw

/// Phase 11 / Phase 14 — asserts `notify_user_about_emails` parses the
/// model's `email_actions` JSON, creates a `Chat` + two ordered `ChatMessage`s
/// (card first, summary second), encodes a decodable `reviewCardData`, and
/// populates each review-card row's `subject` + `sender` from the referenced
/// `Email`. Idempotency: two calls within the same tool instance produce only
/// one review chat — the second call is a no-op (Phase 14 / M1 regression).
///
/// Note: triage suppression used to be done by writing an AI note on every
/// reviewed email here in the tool. As of H3 it's tracked separately via
/// `EmailThread.lastReviewedAt`, stamped by `EmailReviewService.runOnce()`
/// (NOT the tool). So this test no longer asserts an AI note — see
/// `EmailReviewTriageTrackingTests` / `EmailRepositoryTests.reviewSuppressionViaLastReviewedAt`
/// for the new suppression behavior.
@MainActor
struct EmailReviewNotifyToolTests {
    @Test func executeCreatesOrderedReviewChatAndTriagesEmails() async throws {
        let container = try Self.inMemoryContainer()
        let setupContext = ModelContext(container)

        // An email the model will surface for review.
        let email = Email(
            messageID: "<triage@example.com>",
            subject: "Needs a reply",
            fromAddress: "boss@example.com",
            toAddresses: ["me@example.com"],
            date: .now,
            bodyText: "Please reply by Friday."
        )
        setupContext.insert(email)
        try setupContext.save()

        let tool = EmailReviewNotifyTool(modelContainer: container)

        let arguments: [String: JSONValue] = [
            "message": .string("Two items need attention."),
            "email_actions": .array([
                .object([
                    "email_guid": .string(email.id.uuidString),
                    "action": .string("flag"),
                    "summary": .string("Awaiting reply")
                ])
            ])
        ]

        let result = try await tool.execute(arguments: arguments)

        #expect(result.contains("1 item") || result.contains("1 items"))

        // Read back the created chat + messages from a fresh context.
        let readContext = ModelContext(container)
        let chatDescriptor = FetchDescriptor<Chat>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        let chats = try readContext.fetch(chatDescriptor)
        let chat = try #require(chats.first)
        #expect(chat.title.hasPrefix("Inbox review —"))

        let messages = chat.sortedMessages
        #expect(messages.count == 2)

        // (1) The card message comes first (lower sortIndex), carrying the
        // decodable review payload and empty text content.
        let cardMessage = messages[0]
        #expect(cardMessage.sortIndex == 0)
        #expect(cardMessage.content.isEmpty)
        let card = try #require(cardMessage.reviewCard)
        #expect(card.reviewType == .email)
        #expect(card.items.count == 1)
        #expect(card.items[0].action == .flag)
        #expect(card.items[0].itemID == email.id)
        // The tool must look up the Email by its itemID and populate the
        // review-card row with subject + sender — otherwise every card row
        // renders the literal placeholder "Email".
        #expect(card.items[0].subject == "Needs a reply")
        #expect(card.items[0].sender == "boss@example.com")
        #expect(card.items[0].date?.isEmpty == false)

        // (2) The summary text message comes second.
        let summaryMessage = messages[1]
        #expect(summaryMessage.sortIndex == 1)
        #expect(summaryMessage.content == "Two items need attention.")
        #expect(!summaryMessage.content.contains("Dates:"))
        #expect(summaryMessage.reviewCard == nil)
    }

    @Test func executeIsIdempotentWithinARun() async throws {
        // M1 regression: an agentic loop can call notify_user_about_emails
        // more than once in its 8-round budget. The second call must be a
        // no-op rather than creating a duplicate "Inbox review — …" chat.
        let container = try Self.inMemoryContainer()
        let setupContext = ModelContext(container)
        let email = Email(
            messageID: "<dup@example.com>",
            subject: "Two calls",
            fromAddress: "boss@example.com",
            toAddresses: ["me@example.com"],
            date: .now,
            bodyText: "Trigger"
        )
        setupContext.insert(email)
        try setupContext.save()

        let tool = EmailReviewNotifyTool(modelContainer: container)
        let arguments: [String: JSONValue] = [
            "message": .string("Once."),
            "email_actions": .array([
                .object([
                    "email_guid": .string(email.id.uuidString),
                    "action": .string("flag"),
                    "summary": .string("x")
                ])
            ])
        ]

        _ = try await tool.execute(arguments: arguments)
        let secondResult = try await tool.execute(arguments: arguments)

        // Second call must short-circuit (no duplicate chat).
        #expect(secondResult.contains("ignored"))

        let readContext = ModelContext(container)
        let chats = try readContext.fetch(FetchDescriptor<Chat>())
        #expect(chats.count == 1)
    }

    @Test func executeRejectsMissingArguments() async throws {
        let container = try Self.inMemoryContainer()
        let tool = EmailReviewNotifyTool(modelContainer: container)

        await #expect(throws: ToolError.self) {
            _ = try await tool.execute(arguments: ["message": .string("hi")])
        }
    }

    /// Some OpenAI-compatible proxies stringify array tool arguments even when
    /// the schema declares `"type": "array"`. `execute` must accept either an
    /// actual JSON array or a JSON-encoded array string and decode both into
    /// `[EmailReviewAction]`.
    @Test func executeAcceptsStringifiedArrayArgument() async throws {
        let container = try Self.inMemoryContainer()
        let setupContext = ModelContext(container)
        let email = Email(
            messageID: "<stringified@example.com>",
            subject: "String-form arg",
            fromAddress: "sender@example.com",
            toAddresses: ["me@example.com"],
            date: .now,
            bodyText: "Body"
        )
        setupContext.insert(email)
        try setupContext.save()

        let tool = EmailReviewNotifyTool(modelContainer: container)

        // The model wrapped the array in a JSON string instead of emitting it
        // as a top-level array — exactly the failure seen against the live
        // Neuralwatt proxy.
        let jsonString = """
            [{"email_guid":"\(email.id.uuidString)","action":"review","summary":"see"}]
            """

        let arguments: [String: JSONValue] = [
            "message": .string("One item via stringified array."),
            "email_actions": .string(jsonString)
        ]

        let result = try await tool.execute(arguments: arguments)
        #expect(result.contains("1 item") || result.contains("1 items"))

        let readContext = ModelContext(container)
        let chats = try readContext.fetch(FetchDescriptor<Chat>())
        let chat = try #require(chats.first)
        let card = try #require(chat.sortedMessages.first?.reviewCard)
        #expect(card.items.count == 1)
        #expect(card.items[0].action == .review)
        #expect(card.items[0].itemID == email.id)
    }

    // MARK: - Helpers

    static func inMemoryContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Item.self, Chat.self, ChatMessage.self,
            Email.self, EmailThread.self, EmailNote.self, EmailAttachment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }
}
