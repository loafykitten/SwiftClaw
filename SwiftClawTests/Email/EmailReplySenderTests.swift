import Foundation
import Testing
import SwiftData
@testable import SwiftClaw

/// `EmailReplySender` — the shared draft-building + send path behind the
/// composer sheet and the notification inline-reply action — with a spy
/// `MockMailClient` so no SMTP traffic happens.
@MainActor
struct EmailReplySenderTests {
    @Test func draftPrefillsRecipientsSubjectAndQuote() throws {
        let container = try EmailRepositoryTests.inMemoryContainer()
        let email = try Self.seedEmail(in: container)

        let draft = EmailReplySender.draft(replyingTo: email)

        #expect(draft.toAddresses == email.fromAddress)
        #expect(draft.subject == "Re: \(email.subject)")
        #expect(draft.bodyText.contains("> Body"), "the original body is quoted")
        #expect(draft.bodyText.contains("wrote:"))
    }

    @Test func draftDoesNotDoubleTheReplyMarker() throws {
        let container = try EmailRepositoryTests.inMemoryContainer()
        let email = try Self.seedEmail(in: container, subject: "Re: Already a reply")

        let draft = EmailReplySender.draft(replyingTo: email)

        #expect(draft.subject == "Re: Already a reply")
    }

    @Test func sendThreadsTheReplyAndSeedsTheSentRow() async throws {
        let container = try EmailRepositoryTests.inMemoryContainer()
        let context = ModelContext(container)
        let email = try Self.seedEmail(in: container)
        let mock = MockMailClient()

        try await EmailReplySender.send(
            replyingTo: email,
            account: Self.account(),
            toAddresses: ["sender@example.com"],
            ccAddresses: [],
            subject: "Re: Original",
            bodyText: "Sounds good.",
            modelContext: context,
            clientFactory: { _ in mock }
        )

        let outgoing = try #require(await mock.sentEmails.first)
        #expect(outgoing.toAddresses == ["sender@example.com"])
        #expect(outgoing.subject == "Re: Original")
        #expect(outgoing.inReplyTo == email.messageID)
        #expect(outgoing.references == email.allReferenceIDs)
        let messageID = try #require(outgoing.messageID)
        #expect(messageID.hasSuffix("@example.com>"), "Message-ID host comes from the account domain")

        // The local Sent seed row exists and shares the outgoing Message-ID,
        // so the next Sent-folder sync promotes instead of duplicating.
        let sentRows = ((try? context.fetch(FetchDescriptor<Email>())) ?? [])
            .filter { $0.mailbox == "Sent" }
        #expect(sentRows.count == 1)
        #expect(sentRows.first?.messageID == outgoing.messageID)
        #expect(sentRows.first?.isLocallySynthetic == true)
    }

    @Test func quickReplyWithoutAConfiguredAccountThrows() async throws {
        let container = try EmailRepositoryTests.inMemoryContainer()
        let context = ModelContext(container)
        // Seeded with a random accountID that no stored account matches.
        let email = try Self.seedEmail(in: container)
        let mock = MockMailClient()

        await #expect(throws: EmailReplySenderError.self) {
            try await EmailReplySender.sendQuickReply(
                to: email,
                bodyText: "Hi",
                modelContext: context,
                clientFactory: { _ in mock }
            )
        }
        #expect(await mock.sentEmails.isEmpty)
    }

    // MARK: - Helpers

    private static func seedEmail(
        in container: ModelContainer,
        subject: String = "Original"
    ) throws -> Email {
        let repository = EmailRepository(modelContext: ModelContext(container))
        let outcome = repository.upsertMessages(
            [EmailRepositoryTests.simpleMessage(
                uid: 1,
                messageID: "<orig@example.com>",
                subject: subject
            )],
            mailbox: "INBOX",
            accountID: UUID()
        )
        let id = try #require(outcome.inserted.first?.id)
        return try #require(repository.fetchEmail(by: id))
    }

    private static func account() -> StoredEmailAccount {
        StoredEmailAccount(
            id: UUID(),
            displayName: "Me",
            imapHost: "imap.example.com",
            imapUsername: "me@example.com",
            smtpHost: "smtp.example.com",
            smtpUsername: "me@example.com",
            fromAddress: "me@example.com"
        )
    }
}
