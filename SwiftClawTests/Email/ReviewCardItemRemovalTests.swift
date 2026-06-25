import Foundation
import Testing
import SwiftData
@testable import SwiftClaw

/// Validates the persistence path `ChatMessageRow.onItemActioned` uses to drop
/// an acted-upon item from a review card: read `message.reviewCard`, drop the
/// item with the matching `id`, assign the mutated payload back through the
/// settable `reviewCard` accessor, and save. The row should vanish from the
/// card on the next render and stay gone across a fresh `ModelContext`.
@MainActor
struct ReviewCardItemRemovalTests {
    @Test func removingItemShrinksPayloadAndPersists() async throws {
        let container = try Self.inMemoryContainer()
        let context = ModelContext(container)

        let item1 = ReviewItem(itemID: UUID(), actionToken: .flag, actionLabel: "Flag")
        let item2 = ReviewItem(itemID: UUID(), actionToken: .delete, actionLabel: "Delete")
        let item3 = ReviewItem(itemID: UUID(), actionToken: .review, actionLabel: "Review")

        let chat = Chat(title: "Inbox review — whenever", modelSelection: "")
        let message = ChatMessage(role: .assistant, content: "", sortIndex: 0,
                                  reviewCard: ReviewCardPayload(reviewType: .email, items: [item1, item2, item3]))
        message.chat = chat
        context.insert(chat)
        context.insert(message)
        try context.save()

        // Mirror the `ChatMessageRow.onItemActioned` mutation exactly.
        guard var updated = message.reviewCard else {
            Issue.record("payload should be present before removal"); return
        }
        updated.items.removeAll { $0.id == item2.id }
        message.reviewCard = updated
        try context.save()

        // Read back from a fresh context — the removal must persist.
        let readContext = ModelContext(container)
        let readMessage = try #require(readContext.fetch(FetchDescriptor<ChatMessage>()).first)
        let readCard = try #require(readMessage.reviewCard)
        #expect(readCard.items.count == 2)
        #expect(readCard.items.contains { $0.id == item2.id } == false)
        #expect(readCard.items.map(\.id) == [item1.id, item3.id])
    }

    @Test func removingLastItemLeavesEmptyPayloadThatPersists() async throws {
        let container = try Self.inMemoryContainer()
        let context = ModelContext(container)

        let onlyItem = ReviewItem(itemID: UUID(), actionToken: .flag, actionLabel: "Flag")
        let chat = Chat(title: "Inbox review — solo", modelSelection: "")
        let message = ChatMessage(role: .assistant, content: "", sortIndex: 0,
                                  reviewCard: ReviewCardPayload(reviewType: .email, items: [onlyItem]))
        message.chat = chat
        context.insert(chat)
        context.insert(message)
        try context.save()

        var updated = message.reviewCard!
        updated.items.removeAll { $0.id == onlyItem.id }
        message.reviewCard = updated
        try context.save()

        // Empty-card state: the payload still decodes but has no items — the
        // renderer shows the "All caught up" line for this case.
        let readContext = ModelContext(container)
        let readMessage = try #require(readContext.fetch(FetchDescriptor<ChatMessage>()).first)
        let readCard = try #require(readMessage.reviewCard)
        #expect(readCard.items.isEmpty)
        #expect(readCard.reviewType == .email)
    }

    // MARK: - Helpers

    private static func inMemoryContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Item.self, Chat.self, ChatMessage.self,
            Email.self, EmailThread.self, EmailNote.self, EmailAttachment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }
}
