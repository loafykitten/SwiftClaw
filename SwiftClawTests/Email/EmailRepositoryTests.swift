import Foundation
import Testing
import SwiftData
@testable import SwiftClaw

@MainActor
struct EmailRepositoryTests {
    private static let accountID = UUID()

    @Test func archiveUpsertReclaimsSoftDeletedInboxRow() throws {
        let container = try Self.inMemoryContainer()
        let repository = EmailRepository(modelContext: ModelContext(container))

        // A message arrives in INBOX, then is archived from another client —
        // the INBOX deletion pass soft-deletes the local row.
        repository.upsertMessages(
            [Self.simpleMessage(uid: 1, messageID: "<a@example.com>", subject: "Hi")],
            mailbox: "INBOX",
            accountID: Self.accountID
        )
        repository.reconcileDeletions(serverUIDs: [], mailbox: "INBOX", accountID: Self.accountID)

        // The Archive-folder sync brings the same message back under a new UID.
        repository.upsertMessages(
            [Self.simpleMessage(uid: 99, messageID: "<a@example.com>", subject: "Hi")],
            mailbox: "Archive",
            accountID: Self.accountID,
            role: .archive
        )

        let context = ModelContext(container)
        let matches = ((try? context.fetch(FetchDescriptor<Email>())) ?? [])
            .filter { $0.messageID == "<a@example.com>" }
        #expect(matches.count == 1, "reclaim must not leave a duplicate row")
        #expect(matches.first?.isArchived == true)
        #expect(matches.first?.isDeleted == false)
        #expect(matches.first?.mailbox == "Archive")
        #expect(matches.first?.uid == 99)
    }

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

        let inserted = repository.upsertMessages(fetched, mailbox: "INBOX", accountID: Self.accountID).insertedCount
        repository.resolveThreads()

        #expect(inserted == 1)
        #expect(repository.fetchNonArchivedThreadsForReview().count >= 1)
        #expect(try context.fetch(FetchDescriptor<EmailThread>()).first?.accountID == Self.accountID)
    }

    @Test func upsertIsIdempotentForAlreadyKnownMessages() async throws {
        let container = try Self.inMemoryContainer()
        let context = ModelContext(container)
        let repository = EmailRepository(modelContext: context)

        let fetched = Self.simpleMessage(uid: 1, messageID: "<dup@example.com>", subject: "Dup")

        let firstInsert = repository.upsertMessages([fetched], mailbox: "INBOX", accountID: Self.accountID).insertedCount
        let secondInsert = repository.upsertMessages([fetched], mailbox: "INBOX", accountID: Self.accountID).insertedCount

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

    @Test func openedEmailStillQualifiesForReviewWhenNotArchived() async throws {
        let container = try Self.inMemoryContainer()
        let context = ModelContext(container)
        let repository = EmailRepository(modelContext: context)

        let fetched = Self.simpleMessage(
            uid: 1,
            messageID: "<opened@example.com>",
            subject: "Opened but needs review",
            isRead: true
        )
        repository.upsertMessages([fetched], mailbox: "INBOX", accountID: Self.accountID)
        repository.resolveThreads()

        let threads = repository.fetchNonArchivedThreadsForReview()
        #expect(threads.count == 1)
        #expect(threads.first?.latestReviewableMessage?.isRead == true)
    }

    @Test func archivedLatestMessageDoesNotRetriggerReviewedThread() async throws {
        let container = try Self.inMemoryContainer()
        let context = ModelContext(container)
        let repository = EmailRepository(modelContext: context)
        let activeDate = Date().addingTimeInterval(-120)
        let archivedDate = Date().addingTimeInterval(-60)

        let active = Self.simpleMessage(
            uid: 1,
            messageID: "<active-reviewed@example.com>",
            subject: "Mixed reviewed",
            date: activeDate
        )
        let archived = Self.simpleMessage(
            uid: 2,
            messageID: "<archived-reviewed@example.com>",
            subject: "Mixed reviewed",
            date: archivedDate
        )
        repository.upsertMessages([active, archived], mailbox: "INBOX", accountID: Self.accountID)
        repository.resolveThreads()

        let archivedEmail = try #require(
            try context.fetch(FetchDescriptor<Email>()).first { $0.uid == 2 }
        )
        repository.archive(messageID: archivedEmail.id)

        let threads = repository.fetchNonArchivedThreadsForReview()
        #expect(threads.count == 1)
        repository.markThreadsReviewed(threads, at: activeDate.addingTimeInterval(30))

        #expect(repository.fetchNonArchivedThreadsForReview().isEmpty)
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

        let inserted = repository.upsertMessages([updated], mailbox: "INBOX", accountID: Self.accountID).insertedCount

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

        let firstInserted = repository.upsertMessages([first], mailbox: "INBOX", accountID: accountA).insertedCount
        let secondInserted = repository.upsertMessages([second], mailbox: "INBOX", accountID: accountB).insertedCount

        #expect(firstInserted == 1)
        #expect(secondInserted == 1) // would be 0 if accountID weren't part of the dedup key

        let all = try context.fetch(FetchDescriptor<Email>())
        #expect(all.count == 2)
        #expect(all.map(\.accountID).sorted() == [accountA, accountB].sorted())
    }

    @Test func resolveThreadsSeparatesSameMessageIDByAccount() async throws {
        let container = try Self.inMemoryContainer()
        let context = ModelContext(container)
        let repository = EmailRepository(modelContext: context)
        let accountA = UUID()
        let accountB = UUID()

        repository.upsertMessages(
            [Self.simpleMessage(uid: 1, messageID: "<shared@example.com>", subject: "Shared")],
            mailbox: "INBOX",
            accountID: accountA
        )
        repository.upsertMessages(
            [Self.simpleMessage(uid: 1, messageID: "<shared@example.com>", subject: "Shared")],
            mailbox: "INBOX",
            accountID: accountB
        )
        repository.resolveThreads()

        let threads = try context.fetch(FetchDescriptor<EmailThread>())
        #expect(threads.count == 2)
        #expect(Set(threads.compactMap(\.accountID)) == Set([accountA, accountB]))
        #expect(threads.allSatisfy { thread in
            Set(thread.messages.map(\.accountID)).count == 1
        })
    }

    @Test func resolveThreadsSeparatesReplySubjectsByAccount() async throws {
        let container = try Self.inMemoryContainer()
        let context = ModelContext(container)
        let repository = EmailRepository(modelContext: context)
        let accountA = UUID()
        let accountB = UUID()

        repository.upsertMessages(
            [Self.simpleMessage(uid: 1, messageID: "<reply-a@example.com>", subject: "Re: Shared Subject")],
            mailbox: "INBOX",
            accountID: accountA
        )
        repository.upsertMessages(
            [Self.simpleMessage(uid: 1, messageID: "<reply-b@example.com>", subject: "Re: Shared Subject")],
            mailbox: "INBOX",
            accountID: accountB
        )
        repository.resolveThreads()

        let threads = try context.fetch(FetchDescriptor<EmailThread>())
        #expect(threads.count == 2)
        #expect(Set(threads.compactMap(\.accountID)) == Set([accountA, accountB]))
    }

    @Test func resolveThreadsSplitsExistingMixedAccountThread() async throws {
        let container = try Self.inMemoryContainer()
        let context = ModelContext(container)
        let repository = EmailRepository(modelContext: context)
        let accountA = UUID()
        let accountB = UUID()
        let mixedThread = EmailThread(subjectNormalized: "Legacy")
        let first = Email(
            messageID: "<legacy-shared@example.com>",
            subject: "Legacy",
            date: Date().addingTimeInterval(-60),
            accountID: accountA,
            uid: 1,
            thread: mixedThread
        )
        let second = Email(
            messageID: "<legacy-shared@example.com>",
            subject: "Legacy",
            date: Date(),
            accountID: accountB,
            uid: 1,
            thread: mixedThread
        )
        mixedThread.messages = [first, second]
        context.insert(mixedThread)
        context.insert(first)
        context.insert(second)
        try context.save()
        let originalThreadID = mixedThread.id

        repository.resolveThreads()

        let threads = try context.fetch(FetchDescriptor<EmailThread>())
        #expect(threads.count == 2)
        #expect(threads.contains { $0.id == originalThreadID })
        #expect(Set(threads.compactMap(\.accountID)) == Set([accountA, accountB]))
        #expect(threads.allSatisfy { thread in
            Set(thread.messages.map(\.accountID)).count == 1
        })
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

    @Test func accountScopedResolveLeavesOtherAccountThreadUntouched() throws {
        let container = try Self.inMemoryContainer()
        let context = ModelContext(container)
        let repository = EmailRepository(modelContext: context)
        let accountA = UUID()
        let accountB = UUID()

        repository.upsertMessages(
            [Self.simpleMessage(uid: 1, messageID: "<a@example.com>", subject: "Alpha")],
            mailbox: "INBOX",
            accountID: accountA
        )
        repository.upsertMessages(
            [Self.simpleMessage(uid: 1, messageID: "<b@example.com>", subject: "Beta")],
            mailbox: "INBOX",
            accountID: accountB
        )
        repository.resolveThreads()
        let before = try context.fetch(FetchDescriptor<EmailThread>())
        let accountAThreadID = try #require(before.first { $0.accountID == accountA }?.id)
        let accountBThreadID = try #require(before.first { $0.accountID == accountB }?.id)

        repository.upsertMessages(
            [Self.simpleMessage(uid: 2, messageID: "<a2@example.com>", subject: "Other")],
            mailbox: "INBOX",
            accountID: accountA
        )
        repository.resolveThreads(for: accountA)

        let after = try context.fetch(FetchDescriptor<EmailThread>())
        #expect(after.contains { $0.id == accountAThreadID })
        #expect(after.contains { $0.id == accountBThreadID })
        #expect(after.first { $0.id == accountBThreadID }?.messages.count == 1)
    }

    @Test func preparedAttachmentIsRemovedWhenSwiftDataSaveFails() throws {
        struct ExpectedSaveError: Error {}

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("email-attachment-save-failure-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EmailAttachmentStore(rootDirectory: root)
        let original = Self.simpleMessage(
            uid: 1,
            messageID: "<attachment@example.com>",
            subject: "Attachment"
        )
        let message = FetchedMessage(
            uid: original.uid,
            messageID: original.messageID,
            subject: original.subject,
            fromAddress: original.fromAddress,
            toAddresses: original.toAddresses,
            ccAddresses: original.ccAddresses,
            bccAddresses: original.bccAddresses,
            date: original.date,
            internalDate: original.internalDate,
            bodyText: original.bodyText,
            bodyHTML: original.bodyHTML,
            inReplyTo: original.inReplyTo,
            references: original.references,
            isRead: original.isRead,
            isFlagged: original.isFlagged,
            mailbox: original.mailbox,
            attachmentDescriptors: [
                FetchedAttachmentDescriptor(
                    filename: "unsafe/name.txt",
                    mimeType: "text/plain",
                    sizeBytes: 4,
                    partNumber: "1",
                    data: Data("test".utf8)
                )
            ]
        )
        let prepared = store.prepare([message])
        let preparedMessage = try #require(prepared.first)
        let fileURL = store.absoluteURL(
            forEmailID: preparedMessage.emailID,
            filename: "unsafe/name.txt"
        )
        #expect(FileManager.default.fileExists(atPath: fileURL.path))

        let container = try Self.inMemoryContainer()
        let context = ModelContext(container)
        let repository = EmailRepository(
            modelContext: context,
            attachmentStore: store,
            saveUpsertChanges: { throw ExpectedSaveError() }
        )
        let outcome = repository.upsertPreparedMessages(
            prepared,
            mailbox: "INBOX",
            accountID: Self.accountID
        )

        #expect(outcome.insertedCount == 0)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
        #expect(try context.fetch(FetchDescriptor<Email>()).isEmpty)
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

    @Test func staleReviewedThreadResurfacesAfterResurfaceInterval() async throws {
        // A read thread the user never actioned must come back for triage once
        // it's gone stale — old read mail shouldn't be suppressed forever just
        // because no new mail landed. (The user is clearing toward an empty
        // inbox: every thread should eventually be archived or deleted.)
        let container = try Self.inMemoryContainer()
        let context = ModelContext(container)
        let repository = EmailRepository(modelContext: context)

        let readDate = Date().addingTimeInterval(-3_600)
        let message = Self.simpleMessage(
            uid: 1,
            messageID: "<stale-read@example.com>",
            subject: "Old read mail",
            isRead: true,
            date: readDate
        )
        repository.upsertMessages([message], mailbox: "INBOX", accountID: Self.accountID)
        repository.resolveThreads()

        let firstFetch = repository.fetchNonArchivedThreadsForReview()
        #expect(firstFetch.count == 1)

        // Reviewed now → suppressed on the very next pass (no new mail, not yet
        // stale): the resurface window hasn't elapsed.
        let reviewTime = Date()
        repository.markThreadsReviewed(firstFetch, at: reviewTime)
        #expect(repository.fetchNonArchivedThreadsForReview(now: reviewTime).isEmpty)

        // Past the resurface interval the same unactioned thread comes back.
        let later = reviewTime.addingTimeInterval(EmailRepository.reviewResurfaceInterval + 60)
        #expect(repository.fetchNonArchivedThreadsForReview(now: later).count == 1)
    }

    @Test func flaggedOrNotatedThreadsBypassSuppression() async throws {
        // The user's explicit "this still matters" markers must reach the model
        // on EVERY pass — a thread flagged + notated to revisit months later
        // should never be suppressed, so the model can judge when it's time.
        let container = try Self.inMemoryContainer()
        let context = ModelContext(container)
        let repository = EmailRepository(modelContext: context)

        let flagged = Self.simpleMessage(
            uid: 1,
            messageID: "<flagged@example.com>",
            subject: "Flagged for later",
            isRead: true
        )
        let notated = Self.simpleMessage(
            uid: 2,
            messageID: "<notated@example.com>",
            subject: "Notated for later",
            isRead: true
        )
        repository.upsertMessages([flagged, notated], mailbox: "INBOX", accountID: Self.accountID)
        repository.resolveThreads()

        let flaggedEmail = try #require(
            try context.fetch(FetchDescriptor<Email>()).first { $0.uid == 1 }
        )
        _ = repository.setFlag(messageID: flaggedEmail.id, isFlagged: true)
        let notatedEmail = try #require(
            try context.fetch(FetchDescriptor<Email>()).first { $0.uid == 2 }
        )
        _ = repository.addNote(emailID: notatedEmail.id, author: .user, content: "Revisit in two months")

        // Review + stamp both threads now. Despite being just-reviewed with no
        // new mail and not yet stale, they must still come back next pass.
        let reviewTime = Date()
        let firstFetch = repository.fetchNonArchivedThreadsForReview()
        #expect(firstFetch.count == 2)
        repository.markThreadsReviewed(firstFetch, at: reviewTime)

        let nextFetch = repository.fetchNonArchivedThreadsForReview(now: reviewTime)
        #expect(nextFetch.count == 2)
    }

    @Test func reviewCapDoesNotHideOlderEligibleThreadsBehindNewestMail() async throws {
        // Regression: the per-pass cap used to be applied as a DB `fetchLimit`
        // (newest N threads) BEFORE the suppression filter. Once those newest
        // threads were reviewed, every older eligible thread stayed hidden
        // behind them. The cap must apply AFTER filtering so older eligible
        // mail still surfaces. (Read threads — unread threads intentionally
        // override the cap, so the limit only trims plain-read mail.)
        let container = try Self.inMemoryContainer()
        let context = ModelContext(container)
        let repository = EmailRepository(modelContext: context)

        // Two newest threads, plus one older thread.
        for index in 1...3 {
            let message = Self.simpleMessage(
                uid: index,
                messageID: "<cap-\(index)@example.com>",
                subject: "Thread \(index)",
                isRead: true,
                date: Date().addingTimeInterval(TimeInterval(-index * 60))
            )
            repository.upsertMessages([message], mailbox: "INBOX", accountID: Self.accountID)
            repository.resolveThreads()
        }

        // Review only the two newest threads (cap of 2).
        let reviewTime = Date()
        let newestTwo = repository.fetchNonArchivedThreadsForReview(limit: 2)
        #expect(newestTwo.count == 2)
        repository.markThreadsReviewed(newestTwo, at: reviewTime)

        // The next pass must still surface the older, never-reviewed thread —
        // not return empty because the newest two filled the fetch window.
        let next = repository.fetchNonArchivedThreadsForReview(limit: 2, now: reviewTime)
        #expect(next.count == 1)
        #expect(next.first?.latestReviewableMessage?.subject == "Thread 3")
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
        #expect(sent.thread?.accountID == account.id)

        // Re-ingesting the same outgoing (e.g. user re-triggered send
        // via a future path) must be idempotent on messageID.
        let sameAgain = repository.upsertSentMessage(outgoing, account: account, sentMailbox: "Sent")
        #expect(sameAgain?.id == sent.id)
        #expect(try context.fetch(FetchDescriptor<Email>()).filter { $0.mailbox == "Sent" }.count == 1)
    }

    @Test func upsertOutcomeReportsExactlyTheInsertedRows() throws {
        let container = try Self.inMemoryContainer()
        let context = ModelContext(container)
        let repository = EmailRepository(modelContext: context)

        // Seed one message, then upsert it again alongside two new ones: the
        // outcome must list only the two inserts, with summaries matching the
        // persisted rows.
        repository.upsertMessages(
            [Self.simpleMessage(uid: 1, messageID: "<known@example.com>", subject: "Known")],
            mailbox: "INBOX",
            accountID: Self.accountID
        )

        let outcome = repository.upsertMessages(
            [
                Self.simpleMessage(uid: 1, messageID: "<known@example.com>", subject: "Known"),
                Self.simpleMessage(uid: 2, messageID: "<new2@example.com>", subject: "New two"),
                Self.simpleMessage(uid: 3, messageID: "<new3@example.com>", subject: "New three", isRead: true),
            ],
            mailbox: "INBOX",
            accountID: Self.accountID
        )

        #expect(outcome.insertedCount == 2)
        #expect(outcome.inserted.map(\.subject) == ["New two", "New three"])
        #expect(outcome.inserted.map(\.isRead) == [false, true])

        let rowsByID = Dictionary(
            uniqueKeysWithValues: ((try? context.fetch(FetchDescriptor<Email>())) ?? []).map { ($0.id, $0) }
        )
        for summary in outcome.inserted {
            let row = try #require(rowsByID[summary.id])
            #expect(summary.subject == row.subject)
            #expect(summary.fromDisplay == row.displayFromAddress)
            #expect(summary.snippet == row.snippet)
            #expect(summary.isRead == row.isRead)
        }
    }

    // MARK: - Helpers

    static func inMemoryContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Email.self, EmailThread.self, EmailNote.self, EmailAttachment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    static func simpleMessage(
        uid: Int,
        messageID: String,
        subject: String,
        isRead: Bool = false,
        date: Date = .now,
        inReplyTo: String? = nil,
        references: [String] = []
    ) -> FetchedMessage {
        FetchedMessage(
            uid: uid,
            messageID: messageID,
            subject: subject,
            fromAddress: "sender@example.com",
            toAddresses: ["me@example.com"],
            ccAddresses: [],
            bccAddresses: [],
            date: date,
            internalDate: date,
            bodyText: "Body",
            bodyHTML: nil,
            inReplyTo: inReplyTo,
            references: references,
            isRead: isRead,
            isFlagged: false,
            mailbox: "INBOX",
            attachmentDescriptors: []
        )
    }
}
