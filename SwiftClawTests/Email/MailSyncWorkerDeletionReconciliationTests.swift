import Foundation
import Testing
import SwiftData
@testable import SwiftClaw

/// End-to-end coverage for `MailSyncWorker`'s server-side reconciliation
/// pass: the worker fetches a cheap UID-set (`MailboxUIDSet`) after each
/// upsert and soft-deletes local rows whose UID is no longer on the server
/// (plus refreshes flag drift on persisting rows). Tests mirror the
/// `MailSyncWorkerIncrementalTests` injection style: an in-memory
/// container, in-memory sync-state closures, and a `MockMailClient` that
/// lets us mutate the server mailbox between syncs to simulate server-side
/// deletion / flag changes.
@MainActor
struct MailSyncWorkerDeletionReconciliationTests {
    @Test func serverDeletedMessageIsSoftDeletedLocally() async throws {
        let container = try Self.inMemoryContainer()
        let mock = MockMailClient()
        let accountID = UUID()
        let account = Self.completeAccount(id: accountID)
        await mock.setUIDValidity(7)
        await mock.setMailbox("INBOX", messages: Self.messages(uids: 1...2, accountID: accountID))

        let worker = Self.makeWorker(mock: mock, account: account, container: container)

        // First sync: both messages inserted. Skip reconciliation (no prior
        // state — see the `didHavePriorState` guard in `syncOnce`).
        let firstInserted = await worker.syncOnce()
        #expect(firstInserted == 2)

        // Server removes uid 1 (another client deleted it). The mailbox now
        // only contains uid 2, so the UID-set scan returns {2}.
        await mock.setMailbox("INBOX", messages: [Self.message(uid: 2, accountID: accountID)])

        // Second sync: uid 1 is no longer in the server set → soft-deleted
        // locally. uid 2 stays active. We assert on the local store rather
        // than `MailSyncMonitor.shared.lastRemovedMessageCount` (the monitor
        // is a shared singleton whose state is racy across parallel tests).
        _ = await worker.syncOnce()

        let context = ModelContext(container)
        let allEmails = (try? context.fetch(FetchDescriptor<Email>())) ?? []
        let byUID = Dictionary(allEmails.map { ($0.uid, $0) }, uniquingKeysWith: { a, _ in a })
        #expect(byUID[1]?.isTrashed == true, "uid 1 must be soft-deleted after server removal")
        #expect(byUID[2]?.isTrashed == false, "uid 2 must stay active")
    }

    @Test func archivedMessageIsNotTouchedByReconciliation() async throws {
        let container = try Self.inMemoryContainer()
        let mock = MockMailClient()
        let accountID = UUID()
        let account = Self.completeAccount(id: accountID)
        await mock.setUIDValidity(7)
        await mock.setMailbox("INBOX", messages: Self.messages(uids: 1...2, accountID: accountID))

        let worker = Self.makeWorker(mock: mock, account: account, container: container)

        // First sync: both inserted. Manually archive uid 1 (the user filed
        // it out of Inbox locally — its server-side absence is expected when
        // the server has already moved it via a prior archive-from-elsewhere
        // or the user archived it here and the local archive hasn't mirrored
        // to the server).
        _ = await worker.syncOnce()
        let archiveContext = ModelContext(container)
        let archiveRepo = EmailRepository(modelContext: archiveContext)
        let toArchive = (try? archiveContext.fetch(FetchDescriptor<Email>()))?
            .first(where: { $0.uid == 1 })
        #expect(toArchive != nil)
        if let id = toArchive?.id {
            archiveRepo.archive(messageID: id)
        }

        // Server now only advertises uid 2 (uid 1 is gone from the server,
        // e.g. because the user archived it on the web client too). The
        // reconciliation pass must NOT soft-delete the locally-archived row.
        await mock.setMailbox("INBOX", messages: [Self.message(uid: 2, accountID: accountID)])

        _ = await worker.syncOnce()

        let context = ModelContext(container)
        let allEmails = (try? context.fetch(FetchDescriptor<Email>())) ?? []
        let byUID = Dictionary(allEmails.map { ($0.uid, $0) }, uniquingKeysWith: { a, _ in a })
        #expect(byUID[1]?.isArchived == true, "uid 1 stays archived")
        #expect(byUID[1]?.isTrashed == false, "uid 1 must NOT be soft-deleted by reconciliation")
        #expect(byUID[2]?.isTrashed == false, "uid 2 stays active")
    }

    @Test func messageArchivedOnAnotherClientIsReclaimedAsArchived() async throws {
        let container = try Self.inMemoryContainer()
        let mock = MockMailClient()
        let accountID = UUID()
        // The account already resolved its `\Archive` SPECIAL-USE folder, so
        // the worker syncs Archive alongside INBOX/Sent/Trash.
        let account = Self.completeAccount(
            id: accountID,
            trashMailbox: "Trash",
            sentMailbox: "Sent",
            archiveMailbox: "Archive"
        )
        await mock.setUIDValidity(7)
        await mock.setMailbox("INBOX", messages: [Self.message(uid: 1, accountID: accountID)])

        let worker = Self.makeWorker(mock: mock, account: account, container: container)

        // First sync: uid 1 lands in INBOX.
        _ = await worker.syncOnce()

        // The user archives it from another client: it leaves INBOX and
        // reappears in the Archive folder under a fresh server UID. The INBOX
        // reconcile soft-deletes the local row, then the Archive sync must
        // reclaim that same row as archived rather than leaving a trashed
        // duplicate behind.
        await mock.setMailbox("INBOX", messages: [])
        await mock.setMailbox("Archive", messages: [
            Self.simpleMessage(uid: 55, messageID: "<m1@example.com>", subject: "Message 1")
        ])

        _ = await worker.syncOnce()

        let context = ModelContext(container)
        let all = (try? context.fetch(FetchDescriptor<Email>())) ?? []
        let matches = all.filter { $0.messageID == "<m1@example.com>" }
        #expect(matches.count == 1, "the archived message must not be duplicated")
        #expect(matches.first?.isArchived == true, "reclaimed as archived, not trashed")
        #expect(matches.first?.isTrashed == false, "must not stay soft-deleted")
        #expect(matches.first?.mailbox == "Archive", "row moved into the Archive mailbox")
        #expect(matches.first?.uid == 55, "row adopts the server Archive UID")
    }

    @Test func newlyArrivedMessageIsNotOrphaned() async throws {
        let container = try Self.inMemoryContainer()
        let mock = MockMailClient()
        let accountID = UUID()
        let account = Self.completeAccount(id: accountID)
        await mock.setUIDValidity(7)
        await mock.setMailbox("INBOX", messages: Self.messages(uids: 1...1, accountID: accountID))

        let worker = Self.makeWorker(mock: mock, account: account, container: container)

        _ = await worker.syncOnce()

        // New mail arrives (uid 2) AND the server UID-set scan runs after
        // the upsert. The just-arrived message is present in both the server
        // snapshot and the local store → must NOT be orphaned/re-soft-deleted
        // by the reconciliation pass.
        await mock.addMessage(Self.message(uid: 2, accountID: accountID), to: "INBOX")
        let insertedSecondSync = await worker.syncOnce()
        #expect(insertedSecondSync == 1, "uid 2 was inserted this sync")

        let context = ModelContext(container)
        let allEmails = (try? context.fetch(FetchDescriptor<Email>())) ?? []
        let byUID = Dictionary(allEmails.map { ($0.uid, $0) }, uniquingKeysWith: { a, _ in a })
        #expect(byUID[1]?.isTrashed == false, "uid 1 stays active — still on server")
        #expect(byUID[2]?.isTrashed == false, "uid 2 must NOT be orphaned — it's in the server set")
        #expect(byUID[2] != nil, "uid 2 was actually inserted")
    }

    @Test func uidValidityChangeReconcilesOldUidRows() async throws {
        let container = try Self.inMemoryContainer()
        let mock = MockMailClient()
        let accountID = UUID()
        let account = Self.completeAccount(id: accountID)
        await mock.setUIDValidity(7)
        await mock.setMailbox("INBOX", messages: Self.messages(uids: 100...101, accountID: accountID))

        let worker = Self.makeWorker(mock: mock, account: account, container: container)

        // First sync under UIDVALIDITY=7: uids 100 + 101 land locally.
        _ = await worker.syncOnce()

        // Folder rebuild: UIDVALIDITY bumps 7 → 99 and the UIDs get
        // reassigned into the low range (1...3). Phase 17 / §1.1 already
        // re-fetches with `sinceUID: nil` so the rebuilt messages land
        // locally under their new UIDs. The Phase 19 reconciliation pass
        // then naturally retires the old-UID rows (100, 101) because
        // they're no longer in the server set — closing the latent stale-
        // rows-after-rebuild gap.
        await mock.setUIDValidity(99)
        await mock.setMailbox("INBOX", messages: Self.messages(uids: 1...3, accountID: accountID))

        let inserted = await worker.syncOnce()
        #expect(inserted == 3, "rebuilt messages inserted under new UIDs")

        let context = ModelContext(container)
        let allEmails = (try? context.fetch(FetchDescriptor<Email>())) ?? []
        // The reset invalidates the old rows' UIDs (they're dead numbers
        // under the new UIDVALIDITY), so look them up by Message-ID.
        let byMessageID = Dictionary(
            allEmails.compactMap { email in email.messageID.map { ($0, email) } },
            uniquingKeysWith: { a, _ in a }
        )
        #expect(byMessageID["<m100@example.com>"]?.isTrashed == true, "old-UID row soft-deleted post-rebuild")
        #expect(byMessageID["<m101@example.com>"]?.isTrashed == true, "old-UID row soft-deleted post-rebuild")
        #expect(byMessageID["<m100@example.com>"]?.serverUID == nil, "old UID no longer addressable")
        #expect(byMessageID["<m1@example.com>"]?.isTrashed == false, "new-UID row stays active")
        #expect(byMessageID["<m2@example.com>"]?.isTrashed == false, "new-UID row stays active")
        #expect(byMessageID["<m3@example.com>"]?.isTrashed == false, "new-UID row stays active")
    }

    @Test func trashSyncPromotesMovedLocalRowToServerUID() async throws {
        let container = try Self.inMemoryContainer()
        let context = ModelContext(container)
        let repository = EmailRepository(modelContext: context)
        let mock = MockMailClient()
        let accountID = UUID()
        let account = Self.completeAccount(id: accountID, trashMailbox: "Trash")
        await mock.setUIDValidity(7)
        await mock.setMailbox("INBOX", messages: [])

        let messageID = "<trash-promote@example.com>"
        _ = repository.upsertMessages(
            [Self.simpleMessage(uid: 1, messageID: messageID, subject: "Trash promote")],
            mailbox: "INBOX",
            accountID: accountID
        )
        let local = try #require(try context.fetch(FetchDescriptor<Email>()).first)
        repository.delete(messageID: local.id, movedToMailbox: "Trash")

        await mock.setMailbox(
            "Trash",
            messages: [Self.simpleMessage(uid: 77, messageID: messageID, subject: "Trash promote")]
        )

        let worker = Self.makeWorker(mock: mock, account: account, container: container)
        _ = await worker.syncOnce()

        let verifyContext = ModelContext(container)
        let refreshed = (try? verifyContext.fetch(FetchDescriptor<Email>())) ?? []
        #expect(refreshed.count == 1, "Trash sync promotes the local row instead of inserting a duplicate")
        #expect(refreshed.first?.uid == 77)
        #expect(refreshed.first?.mailbox == "Trash")
        #expect(refreshed.first?.isTrashed == true)
    }

    @Test func trashSyncMarksServerTrashRowsDeletedLocally() async throws {
        let container = try Self.inMemoryContainer()
        let mock = MockMailClient()
        let accountID = UUID()
        let account = Self.completeAccount(id: accountID, trashMailbox: "Trash")
        await mock.setUIDValidity(7)
        await mock.setMailbox("INBOX", messages: [])
        await mock.setMailbox(
            "Trash",
            messages: [Self.simpleMessage(uid: 8, messageID: "<server-trash@example.com>", subject: "Server trash")]
        )

        let worker = Self.makeWorker(mock: mock, account: account, container: container)
        _ = await worker.syncOnce()

        let context = ModelContext(container)
        let trashed = try #require(try context.fetch(FetchDescriptor<Email>()).first)
        #expect(trashed.mailbox == "Trash")
        #expect(trashed.isTrashed == true)
    }

    @Test func reconcileDeletionsPreservesNotesViaSoftDelete() async throws {
        let container = try Self.inMemoryContainer()
        let context = ModelContext(container)
        let repository = EmailRepository(modelContext: context)

        // Seed one local INBOX row with a user-authored note. The cascade
        // delete rule on `EmailNote.email` means a HARD delete would destroy
        // the note; the soft-delete path must keep both the row + note.
        let fetched = Self.simpleMessage(uid: 1, messageID: "<n@example.com>", subject: "With note")
        let note = EmailNote(email: nil, author: .user, content: "remember to follow up")
        _ = repository.upsertMessages([fetched], mailbox: "INBOX", accountID: Self.noteAccountID)
        let storedEmail = (try? context.fetch(FetchDescriptor<Email>()))?.first
        #expect(storedEmail != nil)
        if let email = storedEmail {
            email.notes.append(note)
        }
        try? context.save()
        let noteIDBefore = note.id

        // Reconcile against an empty server set → the row soft-deletes, the
        // note survives.
        let removed = repository.reconcileDeletions(
            serverUIDs: [],
            mailbox: "INBOX",
            accountID: Self.noteAccountID
        )
        #expect(removed == 1)

        let afterEmails = (try? context.fetch(FetchDescriptor<Email>())) ?? []
        #expect(afterEmails.count == 1, "row preserved (soft-deleted, not hard-deleted)")
        #expect(afterEmails.first?.isTrashed == true)

        let afterNotes = (try? context.fetch(FetchDescriptor<EmailNote>())) ?? []
        #expect(afterNotes.count == 1, "note survived the soft-delete")
        #expect(afterNotes.first?.id == noteIDBefore)
    }

    @Test func reconcileFlagsFromSnapshotRefreshesFlagDrift() async throws {
        let container = try Self.inMemoryContainer()
        let context = ModelContext(container)
        let repository = EmailRepository(modelContext: context)

        // Locally the message is unread + unflagged.
        _ = repository.upsertMessages(
            [Self.simpleMessage(uid: 5, messageID: "<f@example.com>", subject: "Flag drift")],
            mailbox: "INBOX",
            accountID: Self.noteAccountID
        )
        let stored = (try? context.fetch(FetchDescriptor<Email>()))?.first
        #expect(stored?.isRead == false)
        #expect(stored?.isFlagged == false)

        // Server-side: another client marked it read + flagged.
        let snapshot = MailboxUIDSet(
            uidValidity: 1,
            uids: [5],
            flagsByUID: [5: MailFlagSnapshot(isRead: true, isFlagged: true)]
        )
        let changed = repository.reconcileFlagsFromSnapshot(
            snapshot,
            mailbox: "INBOX",
            accountID: Self.noteAccountID
        )
        #expect(changed == 2, "read + flagged both flipped")

        let refreshed = (try? context.fetch(FetchDescriptor<Email>()))?.first
        #expect(refreshed?.isRead == true)
        #expect(refreshed?.isFlagged == true)
    }

    @Test func combinedReconciliationUpdatesFlagsAndDeletesInOnePass() throws {
        let container = try Self.inMemoryContainer()
        let context = ModelContext(container)
        let repository = EmailRepository(modelContext: context)
        repository.upsertMessages(
            [
                Self.simpleMessage(uid: 1, messageID: "<gone@example.com>", subject: "Gone"),
                Self.simpleMessage(uid: 2, messageID: "<kept@example.com>", subject: "Kept"),
            ],
            mailbox: "INBOX",
            accountID: Self.noteAccountID
        )
        let snapshot = MailboxUIDSet(
            uidValidity: 1,
            uids: [2],
            flagsByUID: [2: MailFlagSnapshot(isRead: true, isFlagged: true)]
        )

        let outcome = repository.reconcileMailbox(
            snapshot,
            mailbox: "INBOX",
            accountID: Self.noteAccountID
        )

        let byUID = Dictionary(
            uniqueKeysWithValues: try context.fetch(FetchDescriptor<Email>()).map { ($0.uid, $0) }
        )
        #expect(outcome.removedCount == 1)
        #expect(outcome.changedFlagCount == 2)
        #expect(byUID[1]?.isTrashed == true)
        #expect(byUID[2]?.isRead == true)
        #expect(byUID[2]?.isFlagged == true)
    }

    // MARK: - Helpers

    private static let noteAccountID = UUID()

    private static func completeAccount(
        id: UUID,
        trashMailbox: String? = nil,
        sentMailbox: String? = nil,
        archiveMailbox: String? = nil
    ) -> StoredEmailAccount {
        StoredEmailAccount(
            id: id,
            displayName: "Test",
            imapHost: "imap.example.com",
            imapUsername: "me@example.com",
            smtpHost: "smtp.example.com",
            smtpUsername: "me@example.com",
            fromAddress: "me@example.com",
            archiveMailbox: archiveMailbox,
            trashMailbox: trashMailbox,
            sentMailbox: sentMailbox
        )
    }

    private static func makeWorker(
        mock: MockMailClient,
        account: StoredEmailAccount,
        container: ModelContainer
    ) -> MailSyncWorker {
        var states: [String: MailboxSyncState] = [:]
        let provider: @Sendable (UUID, String) async -> MailboxSyncState? = { id, mailbox in
            await MainActor.run { states[MailboxSyncStateStore.key(for: id, mailbox: mailbox)] }
        }
        let updater: @Sendable (MailboxSyncState, UUID, String) async -> Void = { state, id, mailbox in
            await MainActor.run { states[MailboxSyncStateStore.key(for: id, mailbox: mailbox)] = state }
        }
        return MailSyncWorker(
            accountsProvider: { [account] },
            modelContainer: container,
            clientFactory: { _ in mock },
            syncStateProvider: provider,
            syncStateUpdater: updater,
            // This suite exercises deletion reconciliation directly, so force
            // the full UID-set scan on every pass rather than the throttled
            // production cadence.
            reconcileEveryNPasses: 1
        )
    }

    private static func message(uid: Int, accountID: UUID) -> FetchedMessage {
        FetchedMessage(
            uid: uid,
            messageID: "<m\(uid)@example.com>",
            subject: "Message \(uid)",
            fromAddress: "sender@example.com",
            toAddresses: ["me@example.com"],
            ccAddresses: [],
            bccAddresses: [],
            date: .now,
            internalDate: .now,
            bodyText: "Body \(uid)",
            bodyHTML: nil,
            inReplyTo: nil,
            references: [],
            isRead: false,
            isFlagged: false,
            mailbox: "INBOX",
            attachmentDescriptors: []
        )
    }

    private static func messages(uids: ClosedRange<Int>, accountID: UUID) -> [FetchedMessage] {
        uids.map { message(uid: $0, accountID: accountID) }
    }

    private static func simpleMessage(uid: Int, messageID: String, subject: String) -> FetchedMessage {
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

    private static func inMemoryContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Email.self, EmailThread.self, EmailNote.self, EmailAttachment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }
}
