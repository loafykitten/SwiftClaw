import Foundation
import Testing
import SwiftData
@testable import SwiftClaw

/// Focused coverage for `EmailReviewActionDispatcher`. Uses a `MockMailClient`
/// resolved by the injected factory so each `ReviewActionToken` can be
/// asserted against the right local mutation + the right server-side call.
/// Also asserts that a removed account (factory returns `nil`) still applies
/// the local mutation while skipping the server-side call — the contract
/// that keeps a deleted account from bricking review-card actions on its
/// old mail.
@MainActor
struct EmailReviewActionDispatcherTests {
    @Test
    func eachActionTokenProducesRightLocalMutationAndServerCall() async throws {
        let container = try Self.inMemoryContainer()
        let mock = MockMailClient()
        let dispatcher = EmailReviewActionDispatcher(
            modelContainer: container,
            mailClientFactory: { _ in mock }
        )

        // Seed one email per action token so the per-token assertions don't
        // collide (bit-flag mutations would otherwise step on each other across
        // a single shared email).
        let reviewEmail = Self.seed(container: container, subject: "Review me", uid: 1, isRead: false)
        let flagEmail = Self.seed(container: container, subject: "Flag me", uid: 2, isRead: true, isFlagged: false)
        let replyEmail = Self.seed(container: container, subject: "Reply me", uid: 3, isRead: false, isFlagged: false)
        let archiveEmail = Self.seed(container: container, subject: "Archive me", uid: 4)
        let deleteEmail = Self.seed(container: container, subject: "Delete me", uid: 5)

        await dispatcher.perform(action: .review, itemID: reviewEmail.id)
        await dispatcher.perform(action: .flag, itemID: flagEmail.id)
        await dispatcher.perform(action: .reply, itemID: replyEmail.id)
        await dispatcher.perform(action: .archive, itemID: archiveEmail.id)
        await dispatcher.perform(action: .delete, itemID: deleteEmail.id)

        // Local mutations persisted across fresh contexts.
        #expect(try Self.refresh(reviewEmail.id, in: container)?.isRead == true)
        let flagRefreshed = try Self.refresh(flagEmail.id, in: container)
        #expect(flagRefreshed?.isFlagged == true) // toggled from false → true
        let replyRefreshed = try Self.refresh(replyEmail.id, in: container)
        #expect(replyRefreshed?.isFlagged == true)
        #expect(replyRefreshed?.isRead == true)
        #expect(try Self.refresh(archiveEmail.id, in: container)?.isArchived == true)
        #expect(try Self.refresh(deleteEmail.id, in: container)?.isDeleted == true)

        // Server-side calls landed on the mock. `review`/`flag`/`reply` set
        // flags (3 calls); `.archive` + `.delete` go through `move` (C3 makes
        // delete a recoverable move to Trash rather than an expunge).
        let flagCallCount = await mock.flagUpdates.count
        #expect(flagCallCount == 3)
        let moves = await mock.moves
        #expect(moves.count == 2) // archive + delete-to-Trash
    }

    @Test
    func removedAccountStillAppliesLocalMutation() async throws {
        // When `mailClientFactory` returns `nil` (the account was removed),
        // the dispatcher must still flip the local flag so the review card
        // reflects the action — it just skips the server-side sync.
        let container = try Self.inMemoryContainer()
        let dispatcher = EmailReviewActionDispatcher(
            modelContainer: container,
            mailClientFactory: { _ in nil }
        )

        let email = Self.seed(container: container, subject: "Orphan", uid: 1, isRead: false)

        await dispatcher.perform(action: .archive, itemID: email.id)

        #expect(try Self.refresh(email.id, in: container)?.isArchived == true)
    }

    // MARK: - Helpers

    private static func inMemoryContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Item.self, Chat.self, ChatMessage.self,
            Email.self, EmailThread.self, EmailNote.self, EmailAttachment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    @discardableResult
    private static func seed(
        container: ModelContainer,
        subject: String,
        uid: Int,
        isRead: Bool = false,
        isFlagged: Bool = false
    ) -> Email {
        let context = ModelContext(container)
        let email = Email(
            messageID: "<\(subject)@example.com>",
            subject: subject,
            fromAddress: "sender@example.com",
            toAddresses: ["me@example.com"],
            date: .now,
            bodyText: "Body",
            isRead: isRead,
            isFlagged: isFlagged,
            accountID: UUID(),
            uid: uid
        )
        context.insert(email)
        try? context.save()
        return email
    }

    private static func refresh(_ id: UUID, in container: ModelContainer) throws -> Email? {
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<Email>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
}
