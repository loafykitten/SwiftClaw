import Foundation
import Testing
import SwiftData
@testable import SwiftClaw

@MainActor
struct EmailReviewFollowUpToolsTests {
    @Test
    func contextIncludesReferencedEmailsAndNotes() throws {
        let container = try Self.inMemoryContainer()
        let context = ModelContext(container)
        let repository = EmailRepository(modelContext: context)
        let email = Self.seed(
            context: context,
            subject: "Cake colors",
            bodyText: String(repeating: "Chocolate vanilla ", count: 80),
            isFlagged: true
        )
        repository.addNote(emailID: email.id, author: .user, content: "Ask by the 19th.")

        let payload = ReviewCardPayload(
            reviewType: .email,
            items: [ReviewItem(itemID: email.id, actionToken: .reply, actionLabel: "Reply")]
        )

        let injected = try #require(
            EmailReviewFollowUpContextBuilder.makeContext(for: [payload], in: context)
        )

        #expect(injected.contains("email_guid: \(email.id.uuidString)"))
        #expect(injected.contains("subject: Cake colors"))
        #expect(injected.contains("Current user date/time:"))
        #expect(injected.contains("flagged: true"))
        #expect(injected.contains("- user: Ask by the 19th."))
        #expect(injected.contains("body_excerpt:"))
        #expect(injected.count < 1_500)
    }

    @Test
    func addNoteToolCreatesAINote() async throws {
        let container = try Self.inMemoryContainer()
        let setupContext = ModelContext(container)
        let email = Self.seed(context: setupContext, subject: "Needs note")
        let tool = EmailReviewAddNoteTool(modelContainer: container)

        let result = try await tool.execute(arguments: [
            "email_guid": .string(email.id.uuidString),
            "note": .string("Needs a reply by Friday.")
        ])

        #expect(result.contains("Added note"))

        let readContext = ModelContext(container)
        let fetched = try Self.fetchEmail(email.id, in: readContext)
        let refreshed = try #require(fetched)
        #expect(refreshed.notes.count == 1)
        #expect(refreshed.notes.first?.author == .ai)
        #expect(refreshed.notes.first?.content == "Needs a reply by Friday.")
    }

    @Test
    func setFlagToolUpdatesLocalFlag() async throws {
        let container = try Self.inMemoryContainer()
        let setupContext = ModelContext(container)
        let email = Self.seed(context: setupContext, subject: "Flag me", isFlagged: false)
        let tool = EmailReviewSetFlagTool(modelContainer: container)

        let result = try await tool.execute(arguments: [
            "email_guid": .string(email.id.uuidString),
            "flagged": .bool(true)
        ])

        #expect(result.contains("flag set to true"))

        let readContext = ModelContext(container)
        let fetched = try Self.fetchEmail(email.id, in: readContext)
        let refreshed = try #require(fetched)
        #expect(refreshed.isFlagged == true)
    }

    @Test
    func refreshToolReturnsStatusWithoutThrowing() async throws {
        // The workflow manager isn't started in tests (no review service), so
        // the tool should fall back to its confirmation string rather than throw.
        let tool = EmailReviewRefreshTool(chatID: UUID())
        let result = try await tool.execute(arguments: [:])
        #expect(!result.isEmpty)
    }

    private static func inMemoryContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Item.self, Chat.self, ChatMessage.self,
            Email.self, EmailThread.self, EmailNote.self, EmailAttachment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    @discardableResult
    private static func seed(
        context: ModelContext,
        subject: String,
        bodyText: String = "Body",
        isFlagged: Bool = false
    ) -> Email {
        let email = Email(
            messageID: "<\(UUID().uuidString)@example.com>",
            subject: subject,
            fromAddress: "suzy@example.com",
            toAddresses: ["me@example.com"],
            date: Date(timeIntervalSince1970: 1_782_000_000),
            bodyText: bodyText,
            isFlagged: isFlagged,
            accountID: UUID(),
            uid: Int.random(in: 1...10_000)
        )
        context.insert(email)
        try? context.save()
        return email
    }

    private static func fetchEmail(_ id: UUID, in context: ModelContext) throws -> Email? {
        var descriptor = FetchDescriptor<Email>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
}
