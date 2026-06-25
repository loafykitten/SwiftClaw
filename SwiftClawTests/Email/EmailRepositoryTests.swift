import Foundation
import Testing
import SwiftData
@testable import SwiftClaw

@MainActor
struct EmailRepositoryTests {
    private static let accountID = UUID()

    @Test func upsertInsertsNewMessages() async throws {
        let container = try Self.inMemoryContainer()
        let context = ModelContext(container)
        let repository = EmailRepository(modelContext: context)

        let now = Date()
        let fetched = [
            FetchedMessage(
                uid: 1,
                messageID: "<m1@example.com>",
                subject: "Subject 1",
                fromAddress: "sender1@example.com",
                toAddresses: ["me@example.com"],
                ccAddresses: [],
                bccAddresses: [],
                date: now,
                internalDate: now,
                bodyText: "Hello",
                bodyHTML: nil,
                inReplyTo: nil,
                references: [],
                isRead: false,
                isFlagged: false,
                mailbox: "INBOX",
                attachmentDescriptors: []
            )
        ]

        let inserted = repository.upsertMessages(fetched, mailbox: "INBOX", accountID: Self.accountID)
        repository.resolveThreads()

        #expect(inserted == 1)
        #expect(repository.fetchNonArchivedThreadsForReview().count >= 1)
    }

    @Test func upsertIsIdempotentForAlreadyKnownMessages() async throws {
        let container = try Self.inMemoryContainer()
        let context = ModelContext(container)
        let repository = EmailRepository(modelContext: context)

        let fetched = Self.simpleMessage(uid: 1, messageID: "<dup@example.com>", subject: "Dup")

        let firstInsert = repository.upsertMessages([fetched], mailbox: "INBOX", accountID: Self.accountID)
        let secondInsert = repository.upsertMessages([fetched], mailbox: "INBOX", accountID: Self.accountID)

        #expect(firstInsert == 1)
        #expect(secondInsert == 0)
    }

    @Test func archiveExcludesThreadFromReview() async throws {
        let container = try Self.inMemoryContainer()
        let context = ModelContext(container)
        let repository = EmailRepository(modelContext: context)

        let fetched = Self.simpleMessage(uid: 1, messageID: "<archive@example.com>", subject: "Archive me")
        repository.upsertMessages([fetched], mailbox: "INBOX", accountID: Self.accountID)
        repository.resolveThreads()

        let threadsBefore = repository.fetchNonArchivedThreadsForReview()
        #expect(threadsBefore.count == 1)

        if let emailID = threadsBefore.first?.messages.first?.id {
            repository.archive(messageID: emailID)
        }

        let threadsAfter = repository.fetchNonArchivedThreadsForReview()
        #expect(threadsAfter.isEmpty)
    }

    @Test func flagUpdateReconcilesWithFetchedState() async throws {
        let container = try Self.inMemoryContainer()
        let context = ModelContext(container)
        let repository = EmailRepository(modelContext: context)

        let original = Self.simpleMessage(uid: 1, messageID: "<flag@example.com>", subject: "Flag")
        repository.upsertMessages([original], mailbox: "INBOX", accountID: Self.accountID)
        repository.resolveThreads()

        let updated = FetchedMessage(
            uid: 1,
            messageID: "<flag@example.com>",
            subject: "Flag",
            fromAddress: original.fromAddress,
            toAddresses: original.toAddresses,
            ccAddresses: [],
            bccAddresses: [],
            date: original.date,
            internalDate: original.internalDate,
            bodyText: original.bodyText,
            bodyHTML: nil,
            inReplyTo: nil,
            references: [],
            isRead: true,
            isFlagged: true,
            mailbox: "INBOX",
            attachmentDescriptors: []
        )

        let inserted = repository.upsertMessages([updated], mailbox: "INBOX", accountID: Self.accountID)

        #expect(inserted == 0)

        let descriptor = FetchDescriptor<Email>(
            predicate: #Predicate { $0.uid == 1 }
        )
        let refreshed = try context.fetch(descriptor).first
        #expect(refreshed?.isRead == true)
        #expect(refreshed?.isFlagged == true)
    }

    @Test func addNoteAttachesToEmailWithAuthor() async throws {
        let container = try Self.inMemoryContainer()
        let context = ModelContext(container)
        let repository = EmailRepository(modelContext: context)

        repository.upsertMessages(
            [Self.simpleMessage(uid: 1, messageID: "<note@example.com>", subject: "Notes")],
            mailbox: "INBOX",
            accountID: Self.accountID
        )

        let descriptor = FetchDescriptor<Email>(
            predicate: #Predicate { $0.uid == 1 }
        )
        let email = try context.fetch(descriptor).first
        #expect(email != nil)

        let note = repository.addNote(emailID: email!.id, author: .ai, content: "AI summary")
        #expect(note?.author == .ai)
        #expect(note?.content == "AI summary")
    }

    @Test func upsertSeparatesMessagesByAccount() async throws {
        // Two accounts, same UID + same mailbox, must not collide — these
        // are different physical messages on different servers.
        let container = try Self.inMemoryContainer()
        let context = ModelContext(container)
        let repository = EmailRepository(modelContext: context)

        let accountA = UUID()
        let accountB = UUID()

        let first = Self.simpleMessage(uid: 1, messageID: "<a@example.com>", subject: "From A")
        let second = Self.simpleMessage(uid: 1, messageID: "<b@example.com>", subject: "From B")

        let firstInserted = repository.upsertMessages([first], mailbox: "INBOX", accountID: accountA)
        let secondInserted = repository.upsertMessages([second], mailbox: "INBOX", accountID: accountB)

        #expect(firstInserted == 1)
        #expect(secondInserted == 1) // would be 0 if accountID weren't part of the dedup key

        let all = try context.fetch(FetchDescriptor<Email>())
        #expect(all.count == 2)
        #expect(all.map(\.accountID).sorted() == [accountA, accountB].sorted())
    }

    // MARK: - H1 — Thread identity stability

    @Test func resolveThreadsPreservesThreadIdAcrossSyncsWithUnrelatedNewMail() async throws {
        // H1 regression: a sync that adds new mail to UNRELATED threads must
        // not regenerate the `EmailThread.id` of an existing thread. This is
        // what keeps `EmailView.selectedThreadID` valid while the user is
        // reading a thread and a background sync lands new mail elsewhere.
        let container = try Self.inMemoryContainer()
        let context = ModelContext(container)
        let repository = EmailRepository(modelContext: context)

        // Sync 1: one message in thread "Alpha".
        repository.upsertMessages(
            [Self.simpleMessage(uid: 1, messageID: "<a1@example.com>", subject: "Alpha")],
            mailbox: "INBOX",
            accountID: Self.accountID
        )
        repository.resolveThreads()
        let alphaThreadID = try #require(try context.fetch(FetchDescriptor<EmailThread>()).first?.id)

        // Sync 2: brand-new mail in a DIFFERENT subject thread ("Beta").
        // The incremental guard means resolveThreads() runs only on insert,
        // which we want here (inserted > 0). Identity must still be preserved
        // for the unrelated "Alpha" thread.
        repository.upsertMessages(
            [Self.simpleMessage(uid: 2, messageID: "<b1@example.com>", subject: "Beta")],
            mailbox: "INBOX",
            accountID: Self.accountID
        )
        repository.resolveThreads()

        let threads = try context.fetch(FetchDescriptor<EmailThread>())
        #expect(threads.count == 2)
        let alphaStillPresent = threads.contains { $0.id == alphaThreadID }
        #expect(alphaStillPresent)

        // The Alpha thread should still own its message.
        let alphaThread = try #require(threads.first { $0.id == alphaThreadID })
        #expect(alphaThread.messages.count == 1)
        #expect(alphaThread.messages.first?.messageID == "<a1@example.com>")
    }

    @Test func resolveThreadsPreservesThreadIdWhenReplyArrivesInSameThread() async throws {
        // H1 regression, more focused: when a reply arrives for an EXISTING
        // thread, the thread's id must survive re-clustering (the new message
        // has a References header pointing back to the original).
        let container = try Self.inMemoryContainer()
        let context = ModelContext(container)
        let repository = EmailRepository(modelContext: context)

        let original = FetchedMessage(
            uid: 1,
            messageID: "<orig@example.com>",
            subject: "Project",
            fromAddress: "boss@example.com",
            toAddresses: ["me@example.com"],
            ccAddresses: [],
            bccAddresses: [],
            date: .now,
            internalDate: .now,
            bodyText: "Kickoff",
            bodyHTML: nil,
            inReplyTo: nil,
            references: [],
            isRead: false,
            isFlagged: false,
            mailbox: "INBOX",
            attachmentDescriptors: []
        )
        repository.upsertMessages([original], mailbox: "INBOX", accountID: Self.accountID)
        repository.resolveThreads()
        let originalThreadID = try #require(try context.fetch(FetchDescriptor<EmailThread>()).first?.id)

        let reply = FetchedMessage(
            uid: 2,
            messageID: "<reply@example.com>",
            subject: "Re: Project",
            fromAddress: "boss@example.com",
            toAddresses: ["me@example.com"],
            ccAddresses: [],
            bccAddresses: [],
            date: .now.addingTimeInterval(60),
            internalDate: .now.addingTimeInterval(60),
            bodyText: "Following up",
            bodyHTML: nil,
            inReplyTo: "<orig@example.com>",
            references: ["<orig@example.com>"],
            isRead: false,
            isFlagged: false,
            mailbox: "INBOX",
            attachmentDescriptors: []
        )
        repository.upsertMessages([reply], mailbox: "INBOX", accountID: Self.accountID)
        repository.resolveThreads()

        let threads = try context.fetch(FetchDescriptor<EmailThread>())
        #expect(threads.count == 1)
        let thread = try #require(threads.first)
        #expect(thread.id == originalThreadID) // ← identity preserved
        #expect(thread.messages.count == 2)
    }

    @Test func resolveThreadsIsSafelyCallableOnNoChange() async throws {
        // Guard verification: calling resolveThreads() multiple times with
        // no intervening upsert must not delete or recreate threads.
        let container = try Self.inMemoryContainer()
        let context = ModelContext(container)
        let repository = EmailRepository(modelContext: context)

        repository.upsertMessages(
            [Self.simpleMessage(uid: 1, messageID: "<s@example.com>", subject: "Stable")],
            mailbox: "INBOX",
            accountID: Self.accountID
        )
        repository.resolveThreads()
        let firstThreadID = try #require(try context.fetch(FetchDescriptor<EmailThread>()).first?.id)

        // Re-run with no input change (MailSyncWorker.upsert guards this path
        // when inserted == 0, but resolveThreads itself must be safe too).
        repository.resolveThreads()
        repository.resolveThreads()

        let threads = try context.fetch(FetchDescriptor<EmailThread>())
        #expect(threads.count == 1)
        #expect(threads.first?.id == firstThreadID)
    }

    // MARK: - H3 — Review triage suppression via lastReviewedAt

    @Test func reviewSuppressionExcludesThreadUntilNewMailArrives() async throws {
        // H3 regression: a thread the review pass has already looked at must
        // NOT be re-surfaced on the next pass — UNLESS a newer message has
        // landed in it since last review.
        let container = try Self.inMemoryContainer()
        let context = ModelContext(container)
        let repository = EmailRepository(modelContext: context)

        // Seed a thread; verify it shows up for review.
        let original = Self.simpleMessage(uid: 1, messageID: "<r1@example.com>", subject: "Review me")
        repository.upsertMessages([original], mailbox: "INBOX", accountID: Self.accountID)
        repository.resolveThreads()

        let firstFetch = repository.fetchNonArchivedThreadsForReview()
        #expect(firstFetch.count == 1)

        // Simulate the review pass: stamp every fetched thread.
        let reviewTime = Date()
        repository.markThreadsReviewed(firstFetch, at: reviewTime)

        // Next pass — no new mail — thread must be suppressed.
        let secondFetch = repository.fetchNonArchivedThreadsForReview()
        #expect(secondFetch.isEmpty)

        // A reply arrives (date LATER than the review stamp). Thread must
        // re-surface for review now that there's something fresh to triage.
        let reply = FetchedMessage(
            uid: 2,
            messageID: "<r2@example.com>",
            subject: "Re: Review me",
            fromAddress: original.fromAddress,
            toAddresses: original.toAddresses,
            ccAddresses: [],
            bccAddresses: [],
            date: reviewTime.addingTimeInterval(3_600),
            internalDate: reviewTime.addingTimeInterval(3_600),
            bodyText: "Update",
            bodyHTML: nil,
            inReplyTo: "<r1@example.com>",
            references: ["<r1@example.com>"],
            isRead: false,
            isFlagged: false,
            mailbox: "INBOX",
            attachmentDescriptors: []
        )
        repository.upsertMessages([reply], mailbox: "INBOX", accountID: Self.accountID)
        repository.resolveThreads()

        let thirdFetch = repository.fetchNonArchivedThreadsForReview()
        #expect(thirdFetch.count == 1)
    }

    // MARK: - Sent-message local ingestion

    @Test func upsertSentMessageThreadsReplyIntoIncomingThread() async throws {
        // 2.1 (review): a sent reply must show up locally so the user
        // actually sees what they just sent. Sent sync later promotes the
        // synthetic row to the real server UID; this local ingest keeps the
        // UI immediate.
        let container = try Self.inMemoryContainer()
        let context = ModelContext(container)
        let repository = EmailRepository(modelContext: context)

        // Incoming message in INBOX.
        let incoming = FetchedMessage(
            uid: 1,
            messageID: "<incoming@example.com>",
            subject: "Hello",
            fromAddress: "friend@example.com",
            toAddresses: ["me@example.com"],
            ccAddresses: [],
            bccAddresses: [],
            date: .now,
            internalDate: .now,
            bodyText: "Hi",
            bodyHTML: nil,
            inReplyTo: nil,
            references: [],
            isRead: false,
            isFlagged: false,
            mailbox: "INBOX",
            attachmentDescriptors: []
        )
        repository.upsertMessages([incoming], mailbox: "INBOX", accountID: Self.accountID)
        repository.resolveThreads()

        let originalThreadID = try #require(try context.fetch(FetchDescriptor<EmailThread>()).first?.id)

        // User replies. The outgoing email carries `In-Reply-To` /
        // `References` pointing at the incoming message, so the local seed
        // must thread into the same `EmailThread`.
        let outgoing = OutgoingEmail(
            fromAddress: "me@example.com",
            toAddresses: ["friend@example.com"],
            ccAddresses: [],
            bccAddresses: [],
            subject: "Re: Hello",
            bodyText: "Reply body",
            messageID: "<reply@example.com>",
            inReplyTo: "<incoming@example.com>",
            references: ["<incoming@example.com>"]
        )
        let account = StoredEmailAccount(
            id: Self.accountID,
            displayName: "Me",
            imapHost: "imap.example.com",
            imapUsername: "me@example.com",
            smtpHost: "smtp.example.com",
            smtpUsername: "me@example.com",
            fromAddress: "me@example.com"
        )

        let sent = try #require(repository.upsertSentMessage(outgoing, account: account, sentMailbox: "Sent"))
        #expect(sent.mailbox == "Sent")
        #expect(sent.isRead == true) // own send — already seen
        #expect(sent.accountID == account.id)
        #expect(sent.thread?.id == originalThreadID)

        // Re-ingesting the same outgoing (e.g. user re-triggered send
        // via a future path) must be idempotent on messageID.
        let sameAgain = repository.upsertSentMessage(outgoing, account: account, sentMailbox: "Sent")
        #expect(sameAgain?.id == sent.id)
        #expect(try context.fetch(FetchDescriptor<Email>()).filter { $0.mailbox == "Sent" }.count == 1)
    }

    // MARK: - Helpers

    static func inMemoryContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Email.self, EmailThread.self, EmailNote.self, EmailAttachment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    static func simpleMessage(uid: Int, messageID: String, subject: String) -> FetchedMessage {
        FetchedMessage(
            uid: uid,
            messageID: messageID,
            subject: subject,
            fromAddress: "sender@example.com",
            toAddresses: ["me@example.com"],
            ccAddresses: [],
            bccAddresses: [],
            date: .now,
            internalDate: .now,
            bodyText: "Body",
            bodyHTML: nil,
            inReplyTo: nil,
            references: [],
            isRead: false,
            isFlagged: false,
            mailbox: "INBOX",
            attachmentDescriptors: []
        )
    }
}
