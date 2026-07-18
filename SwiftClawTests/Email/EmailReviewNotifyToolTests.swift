import Foundation
import Testing
import SwiftData
@testable import SwiftClaw

/// Covers review-card creation, updates, callback summaries, idempotency, and
/// the alternate argument form emitted by some model providers.
@MainActor
@Suite(.serialized)
struct EmailReviewNotifyToolTests {
    @Test func executeCreatesOrderedReviewChatAndTriagesEmails() async throws {
        let routerFixture = try Self.isolateRouterUnreadStore()
        defer { Self.restoreRouter(routerFixture) }
        let container = try Self.inMemoryContainer()
        let setupContext = ModelContext(container)

        let email = Self.email(
            messageID: "<triage@example.com>",
            subject: "Needs a reply",
            fromAddress: "\"Boss Person\" <boss@example.com>",
            bodyText: "Please reply by Friday."
        )
        setupContext.insert(email)
        try setupContext.save()

        let tool = EmailReviewNotifyTool(
            modelContainer: container,
            accountLabelProvider: { _ in "Work" }
        )

        let arguments = Self.arguments(
            message: "Two items need attention.",
            emailID: email.id,
            action: .flag,
            summary: "Awaiting reply"
        )

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
        #expect(card.items[0].sender == "Boss Person <boss@example.com>")
        #expect(card.items[0].date?.isEmpty == false)
        #expect(card.items[0].accountLabel == "Work")

        // (2) The summary text message comes second.
        let summaryMessage = messages[1]
        #expect(summaryMessage.sortIndex == 1)
        #expect(summaryMessage.content == "Two items need attention.")
        #expect(!summaryMessage.content.contains("Dates:"))
        #expect(summaryMessage.reviewCard == nil)
    }

    /// Single-account users get no account chip on review cards: a nil from
    /// the label provider must flow through as a nil `accountLabel`, not a
    /// placeholder string.
    @Test func executeLeavesAccountLabelNilWhenProviderReturnsNil() async throws {
        let routerFixture = try Self.isolateRouterUnreadStore()
        defer { Self.restoreRouter(routerFixture) }
        let container = try Self.inMemoryContainer()
        let setupContext = ModelContext(container)
        let email = Self.email(
            messageID: "<single@example.com>",
            subject: "Only account",
            fromAddress: "boss@example.com"
        )
        setupContext.insert(email)
        try setupContext.save()

        let tool = EmailReviewNotifyTool(
            modelContainer: container,
            accountLabelProvider: { _ in nil }
        )

        _ = try await tool.execute(arguments: Self.arguments(message: "One item.", emailID: email.id))

        let readContext = ModelContext(container)
        let chat = try #require(try readContext.fetch(FetchDescriptor<Chat>()).first)
        let card = try #require(chat.sortedMessages.first?.reviewCard)
        #expect(card.items[0].accountLabel == nil)
    }

    /// A `flag` suggestion for an email that is already flagged is a no-op
    /// the user reads as the review repeating itself — the tool must
    /// downgrade it to `review` no matter what the model proposed.
    @Test func executeDowngradesFlagActionForAlreadyFlaggedEmail() async throws {
        let routerFixture = try Self.isolateRouterUnreadStore()
        defer { Self.restoreRouter(routerFixture) }
        let container = try Self.inMemoryContainer()
        let setupContext = ModelContext(container)

        let flagged = Self.email(
            messageID: "<flagged@example.com>",
            subject: "Already flagged"
        )
        flagged.isFlagged = true
        setupContext.insert(flagged)
        try setupContext.save()

        let tool = EmailReviewNotifyTool(
            modelContainer: container,
            accountLabelProvider: { _ in nil }
        )

        _ = try await tool.execute(arguments: Self.arguments(
            message: "One flagged item.",
            emailID: flagged.id,
            action: .flag,
            summary: "Still needs attention"
        ))

        let readContext = ModelContext(container)
        let chat = try #require(try readContext.fetch(FetchDescriptor<Chat>()).first)
        let card = try #require(chat.sortedMessages.first?.reviewCard)
        #expect(card.items.count == 1)
        #expect(card.items[0].action == .review)
        #expect(card.items[0].actionLabel == ReviewActionToken.review.displayName)
    }

    @Test func executeIsIdempotentWithinARun() async throws {
        // M1 regression: an agentic loop can call notify_user_about_emails
        // more than once in its 8-round budget. The second call must be a
        // no-op rather than creating a duplicate "Inbox review — …" chat.
        let routerFixture = try Self.isolateRouterUnreadStore()
        defer { Self.restoreRouter(routerFixture) }
        let container = try Self.inMemoryContainer()
        let setupContext = ModelContext(container)
        let email = Self.email(
            messageID: "<dup@example.com>",
            subject: "Two calls"
        )
        setupContext.insert(email)
        try setupContext.save()

        let tool = EmailReviewNotifyTool(modelContainer: container)
        let arguments = Self.arguments(message: "Once.", emailID: email.id, action: .flag)

        _ = try await tool.execute(arguments: arguments)
        let secondResult = try await tool.execute(arguments: arguments)

        // Second call must short-circuit (no duplicate chat).
        #expect(secondResult.contains("ignored"))

        let readContext = ModelContext(container)
        let chats = try readContext.fetch(FetchDescriptor<Chat>())
        #expect(chats.count == 1)
    }

    @Test func executeCanAppendUpdatedReviewToExistingChat() async throws {
        let routerFixture = try Self.isolateRouterUnreadStore()
        defer { Self.restoreRouter(routerFixture) }
        let container = try Self.inMemoryContainer()
        let setupContext = ModelContext(container)
        let email = Self.email(
            messageID: "<update@example.com>",
            subject: "Updated analysis"
        )
        let chat = Chat(title: "Inbox review — existing", modelSelection: "test")
        let existing = ChatMessage(role: .assistant, content: "Earlier analysis", sortIndex: 0)
        existing.chat = chat
        setupContext.insert(email)
        setupContext.insert(chat)
        setupContext.insert(existing)
        try setupContext.save()

        let tool = EmailReviewNotifyTool(modelContainer: container, targetChatID: chat.id)
        let arguments = Self.arguments(
            message: "Updated analysis found one item.",
            emailID: email.id,
            summary: "Fresh review"
        )

        let result = try await tool.execute(arguments: arguments)
        #expect(result.contains("Updated review chat"))

        let readContext = ModelContext(container)
        let chats = try readContext.fetch(FetchDescriptor<Chat>())
        #expect(chats.count == 1)
        let refreshed = try #require(chats.first)
        let messages = refreshed.sortedMessages
        #expect(messages.count == 3)
        #expect(messages[0].content == "Earlier analysis")
        let card = try #require(messages[1].reviewCard)
        #expect(card.items.count == 1)
        #expect(card.items[0].itemID == email.id)
        #expect(messages[2].content == "Updated analysis found one item.")
    }

    @Test func appendingUpdatedReviewCollapsesPriorCardIntoLabel() async throws {
        let routerFixture = try Self.isolateRouterUnreadStore()
        defer { Self.restoreRouter(routerFixture) }
        let container = try Self.inMemoryContainer()
        let setupContext = ModelContext(container)
        let email = Self.email(
            messageID: "<update@example.com>",
            subject: "Updated analysis"
        )
        let chat = Chat(title: "Inbox review — existing", modelSelection: "test")
        let priorCard = ChatMessage(
            role: .assistant,
            content: "",
            sortIndex: 0,
            reviewCard: ReviewCardPayload(
                reviewType: .email,
                items: [ReviewItem(itemID: email.id, actionToken: .review, actionLabel: "Review")]
            )
        )
        priorCard.chat = chat
        setupContext.insert(email)
        setupContext.insert(chat)
        setupContext.insert(priorCard)
        try setupContext.save()

        let tool = EmailReviewNotifyTool(modelContainer: container, targetChatID: chat.id)
        _ = try await tool.execute(arguments: Self.arguments(
            message: "Updated analysis found one item.",
            emailID: email.id,
            summary: "Fresh review"
        ))

        let readContext = ModelContext(container)
        let refreshed = try #require(try readContext.fetch(FetchDescriptor<Chat>()).first)
        let messages = refreshed.sortedMessages
        #expect(messages.count == 3)
        // Prior card is superseded: no payload, collapsed to the label.
        #expect(messages[0].reviewCard == nil)
        #expect(messages[0].content == "An updated analysis has been requested.")
        // The fresh card is the only live one.
        #expect(messages[1].reviewCard?.items.count == 1)
        #expect(messages[2].content == "Updated analysis found one item.")
    }

    /// Conversational refresh path: `suppressInlineSummary: true` posts just
    /// the card (no inline summary `ChatMessage`), so the chat assistant
    /// delivers the summary as its single closing reply — no duplicate
    /// "card posted above" follow-up.
    @Test func suppressInlineSummaryOmitsSummaryMessage() async throws {
        let routerFixture = try Self.isolateRouterUnreadStore()
        defer { Self.restoreRouter(routerFixture) }
        let container = try Self.inMemoryContainer()
        let setupContext = ModelContext(container)
        let email = Self.email(
            messageID: "<suppress@example.com>",
            subject: "Conversational refresh"
        )
        let chat = Chat(title: "Inbox review — existing", modelSelection: "test")
        let priorCard = ChatMessage(
            role: .assistant,
            content: "",
            sortIndex: 0,
            reviewCard: ReviewCardPayload(
                reviewType: .email,
                items: [ReviewItem(itemID: email.id, actionToken: .review, actionLabel: "Review")]
            )
        )
        priorCard.chat = chat
        setupContext.insert(email)
        setupContext.insert(chat)
        setupContext.insert(priorCard)
        try setupContext.save()

        let tool = EmailReviewNotifyTool(
            modelContainer: container,
            targetChatID: chat.id,
            suppressInlineSummary: true
        )
        _ = try await tool.execute(arguments: Self.arguments(
            message: "Updated analysis found one item.",
            emailID: email.id,
            summary: "Fresh review"
        ))

        let readContext = ModelContext(container)
        let refreshed = try #require(try readContext.fetch(FetchDescriptor<Chat>()).first)
        let messages = refreshed.sortedMessages
        // Exactly 2 messages: the prior card collapsed to the label + the
        // fresh card. No inline summary — the assistant relays it instead.
        #expect(messages.count == 2)
        #expect(messages[0].reviewCard == nil)
        #expect(messages[0].content == "An updated analysis has been requested.")
        #expect(messages[1].reviewCard?.items.count == 1)
        #expect(messages[1].content.isEmpty)
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
        let routerFixture = try Self.isolateRouterUnreadStore()
        defer { Self.restoreRouter(routerFixture) }
        let container = try Self.inMemoryContainer()
        let setupContext = ModelContext(container)
        let email = Self.email(
            messageID: "<stringified@example.com>",
            subject: "String-form arg"
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

    @Test(arguments: [
        (
            "A long, friendly multi-sentence walkthrough of the whole inbox.",
            "2 threads need your eyes.",
            "2 threads need your eyes."
        ),
        ("Full summary message.", "   ", "Full summary message."),
    ])
    func reviewCallbackPrefersANonemptyNotificationSummary(
        _ message: String,
        _ notificationSummary: String,
        _ expected: String
    ) async throws {
        let routerFixture = try Self.isolateRouterUnreadStore()
        defer { Self.restoreRouter(routerFixture) }
        let container = try Self.inMemoryContainer()

        var receivedSummaries: [String] = []
        let tool = EmailReviewNotifyTool(
            modelContainer: container,
            onReviewCreated: { _, summary in receivedSummaries.append(summary) },
            accountLabelProvider: { _ in nil }
        )

        var arguments = Self.arguments(
            message: message,
            emailID: UUID(),
            summary: "Needs attention"
        )
        arguments["notification_summary"] = .string(notificationSummary)
        _ = try await tool.execute(arguments: arguments)

        #expect(receivedSummaries == [expected])
    }

    // MARK: - Helpers

    /// Keeps review-chat unread state out of the developer's real defaults.
    private static func isolateRouterUnreadStore() throws -> UserDefaultsFixture {
        let fixture = try UserDefaultsFixture()
        AppRouter.shared.resetForTesting(unreadStore: fixture.defaults)
        return fixture
    }

    private static func restoreRouter(_ fixture: UserDefaultsFixture) {
        AppRouter.shared.resetForTesting()
        fixture.cleanup()
    }

    private static func email(
        messageID: String,
        subject: String,
        fromAddress: String = "sender@example.com",
        bodyText: String = "Body"
    ) -> Email {
        Email(
            messageID: messageID,
            subject: subject,
            fromAddress: fromAddress,
            toAddresses: ["me@example.com"],
            date: .now,
            bodyText: bodyText
        )
    }

    private static func arguments(
        message: String,
        emailID: UUID,
        action: ReviewActionToken = .review,
        summary: String = "x"
    ) -> [String: JSONValue] {
        [
            "message": .string(message),
            "email_actions": .array([
                .object([
                    "email_guid": .string(emailID.uuidString),
                    "action": .string(action.rawValue),
                    "summary": .string(summary),
                ]),
            ]),
        ]
    }

    static func inMemoryContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Item.self, Chat.self, ChatMessage.self,
            Email.self, EmailThread.self, EmailNote.self, EmailAttachment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }
}
