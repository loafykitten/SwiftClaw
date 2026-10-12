import Foundation
import Testing
import SwiftData
@testable import SwiftClaw

/// `NotificationMailActionHandler` against an in-memory container + spy
/// `MockMailClient`: each quick action mutates the local row AND hits the
/// server client, and responses arriving before `configure(modelContainer:)`
/// queue and drain. Serialized — the handler is a singleton.
@MainActor
@Suite(.serialized)
struct NotificationMailActionHandlerTests {
    @Test func archiveActionMutatesLocallyAndHitsTheServer() async throws {
        let (handler, container, mock, emailID) = try Self.configuredHandler()
        defer { handler.resetForTesting() }

        handler.handle(
            actionIdentifier: NotificationActionID.mailArchive,
            emailID: emailID,
            userText: nil
        )
        await handler.flushActionsForTesting()

        let email = try #require(Self.fetchEmail(emailID, in: container))
        #expect(email.isArchived)
        let move = try #require(await mock.moves.first)
        #expect(move.uid == 5)
        #expect(move.from == "INBOX")
        #expect(move.to == "Archive")
    }

    @Test func deleteActionSoftDeletesLocallyAndMovesToTrash() async throws {
        let (handler, container, mock, emailID) = try Self.configuredHandler()
        defer { handler.resetForTesting() }

        handler.handle(
            actionIdentifier: NotificationActionID.mailDelete,
            emailID: emailID,
            userText: nil
        )
        await handler.flushActionsForTesting()

        let email = try #require(Self.fetchEmail(emailID, in: container))
        #expect(email.isTrashed)
        #expect(await mock.deletes == [5])
    }

    @Test func flagActionFlagsLocallyAndSyncsTheServerFlag() async throws {
        let (handler, container, mock, emailID) = try Self.configuredHandler()
        defer { handler.resetForTesting() }

        handler.handle(
            actionIdentifier: NotificationActionID.mailFlag,
            emailID: emailID,
            userText: nil
        )
        await handler.flushActionsForTesting()

        let email = try #require(Self.fetchEmail(emailID, in: container))
        #expect(email.isFlagged)
        let update = try #require(await mock.flagUpdates.first)
        #expect(update.uid == 5)
        #expect(update.updates.isFlagged == true)
        #expect(update.updates.isRead == nil)
    }

    @Test func replyActionForwardsTheUserTextToTheReplySender() async throws {
        let container = try EmailRepositoryTests.inMemoryContainer()
        let emailID = try Self.seedEmail(in: container)
        let mock = MockMailClient()
        let handler = NotificationMailActionHandler.shared
        handler.resetForTesting()
        defer { handler.resetForTesting() }

        var sentReplies: [(emailID: UUID, text: String)] = []
        handler.configureForTesting(
            clientFactory: { _ in mock },
            replySender: { email, text, _ in
                sentReplies.append((email.id, text))
            }
        )
        handler.configure(modelContainer: container)

        handler.handle(
            actionIdentifier: NotificationActionID.mailReply,
            emailID: emailID,
            userText: "On my way!"
        )
        // Whitespace-only inline replies are dropped rather than sent.
        handler.handle(
            actionIdentifier: NotificationActionID.mailReply,
            emailID: emailID,
            userText: "   "
        )
        await handler.flushActionsForTesting()

        #expect(sentReplies.count == 1)
        #expect(sentReplies.first?.emailID == emailID)
        #expect(sentReplies.first?.text == "On my way!")
    }

    @Test func actionsTappedBeforeConfigurationQueueAndDrain() async throws {
        let container = try EmailRepositoryTests.inMemoryContainer()
        let emailID = try Self.seedEmail(in: container)
        let mock = MockMailClient()
        let handler = NotificationMailActionHandler.shared
        handler.resetForTesting()
        defer { handler.resetForTesting() }
        handler.configureForTesting(clientFactory: { _ in mock })

        // Cold-launch action tap: no container yet — must queue, not drop.
        handler.handle(
            actionIdentifier: NotificationActionID.mailArchive,
            emailID: emailID,
            userText: nil
        )
        await handler.flushActionsForTesting()
        #expect(Self.fetchEmail(emailID, in: container)?.isArchived == false)

        handler.configure(modelContainer: container)
        await handler.flushActionsForTesting()

        let email = try #require(Self.fetchEmail(emailID, in: container))
        #expect(email.isArchived)
        #expect(await mock.moves.count == 1)
    }

    @Test func missingEmailIsALoggedNoOp() async throws {
        let (handler, _, mock, _) = try Self.configuredHandler()
        defer { handler.resetForTesting() }

        handler.handle(
            actionIdentifier: NotificationActionID.mailArchive,
            emailID: UUID(),
            userText: nil
        )
        await handler.flushActionsForTesting()

        #expect(await mock.moves.isEmpty)
    }

    // MARK: - Helpers

    /// Seeds one unread INBOX message (uid 5) and returns a handler wired to
    /// the container + a spy client.
    private static func configuredHandler() throws -> (
        NotificationMailActionHandler,
        ModelContainer,
        MockMailClient,
        UUID
    ) {
        let container = try EmailRepositoryTests.inMemoryContainer()
        let emailID = try seedEmail(in: container)
        let mock = MockMailClient()
        let handler = NotificationMailActionHandler.shared
        handler.resetForTesting()
        handler.configureForTesting(clientFactory: { _ in mock })
        handler.configure(modelContainer: container)
        return (handler, container, mock, emailID)
    }

    private static func seedEmail(in container: ModelContainer) throws -> UUID {
        let repository = EmailRepository(modelContext: ModelContext(container))
        let outcome = repository.upsertMessages(
            [EmailRepositoryTests.simpleMessage(uid: 5, messageID: "<act@example.com>", subject: "Act on me")],
            mailbox: "INBOX",
            accountID: UUID()
        )
        return try #require(outcome.inserted.first?.id)
    }

    private static func fetchEmail(_ id: UUID, in container: ModelContainer) -> Email? {
        EmailRepository(modelContext: ModelContext(container)).fetchEmail(by: id)
    }
}
