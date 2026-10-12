import Foundation
import Testing
import SwiftData
@testable import SwiftClaw

/// Server-identity invariants: a local row's `uid` may only be used to
/// address the server while it actually names that message in `mailbox`
/// (`Email.serverUID`). Covers pending moves to Trash, synthetic Sent echoes,
/// UIDVALIDITY resets, restored messages, durable flag retries, persistence
/// failures, and attachment-file lifetime.
@MainActor
struct EmailServerIdentityTests {
    private static let accountID = UUID()

    // MARK: - Pending move to Trash

    @Test func deletedRowCannotAddressTrashUntilTrashSyncRekeysIt() async throws {
        let container = try EmailRepositoryTests.inMemoryContainer()
        let context = ModelContext(container)
        let repository = EmailRepository(modelContext: context)
        let mock = MockMailClient()
        repository.upsertMessages(
            [EmailRepositoryTests.simpleMessage(uid: 5, messageID: "<doomed@example.com>", subject: "Doomed")],
            mailbox: "INBOX",
            accountID: Self.accountID
        )
        let email = try #require(try context.fetch(FetchDescriptor<Email>()).first)

        await EmailServerAction.delete(email: email, repository: repository, mailClient: mock)

        #expect(email.mailbox == "Trash")
        #expect(try Self.stored(email.id, in: container)?.isTrashed == true)
        #expect(email.serverUID == nil, "INBOX uid 5 means nothing in Trash")
        #expect(await mock.moves.map(\.uid) == [5])

        // Neither a flag change nor Delete Permanently may reach the server
        // with the stale number — Trash uid 5 could be an unrelated message.
        await EmailServerAction.toggleFlag(email: email, repository: repository, mailClient: mock)
        #expect(await mock.flagUpdates.isEmpty)
        #expect(email.needsFlagSync, "change stays pending for the retry pass")

        // An unrelated Trash message that happens to own uid 5 stays separate.
        repository.upsertMessages(
            [EmailRepositoryTests.simpleMessage(uid: 5, messageID: "<other@example.com>", subject: "Other")],
            mailbox: "Trash",
            accountID: Self.accountID,
            role: .trash
        )
        #expect(email.subject == "Doomed")
        #expect(email.serverUID == nil)
        #expect(try context.fetch(FetchDescriptor<Email>()).count == 2)

        // The real Trash copy arrives: matched by Message-ID, the row adopts
        // its UID and stays deleted.
        repository.upsertMessages(
            [EmailRepositoryTests.simpleMessage(uid: 41, messageID: "<doomed@example.com>", subject: "Doomed")],
            mailbox: "Trash",
            accountID: Self.accountID,
            role: .trash
        )
        #expect(email.serverUID == 41)
        #expect(try Self.stored(email.id, in: container)?.isTrashed == true)
        #expect(try context.fetch(FetchDescriptor<Email>()).count == 2)
    }

    @Test func failedTrashMoveRestoresTheSourceIdentity() async throws {
        let container = try EmailRepositoryTests.inMemoryContainer()
        let context = ModelContext(container)
        let repository = EmailRepository(modelContext: context)
        let mock = MockMailClient()
        await mock.setMoveError(MailClientError.fetchFailed("offline"))
        repository.upsertMessages(
            [EmailRepositoryTests.simpleMessage(uid: 5, messageID: "<stays@example.com>", subject: "Stays")],
            mailbox: "INBOX",
            accountID: Self.accountID
        )
        let email = try #require(try context.fetch(FetchDescriptor<Email>()).first)

        await EmailServerAction.delete(email: email, repository: repository, mailClient: mock)

        #expect(try Self.stored(email.id, in: container)?.isTrashed == true, "the local delete still applies")
        #expect(email.mailbox == "INBOX")
        #expect(email.serverUID == 5, "the message never left INBOX")
    }

    @Test func deleteWithoutAnAccountKeepsTheSourceIdentity() async throws {
        let container = try EmailRepositoryTests.inMemoryContainer()
        let context = ModelContext(container)
        let repository = EmailRepository(modelContext: context)
        repository.upsertMessages(
            [EmailRepositoryTests.simpleMessage(uid: 5, messageID: "<orphan@example.com>", subject: "Orphan")],
            mailbox: "INBOX",
            accountID: Self.accountID
        )
        let email = try #require(try context.fetch(FetchDescriptor<Email>()).first)

        await EmailServerAction.delete(email: email, repository: repository, mailClient: nil)

        #expect(try Self.stored(email.id, in: container)?.isTrashed == true)
        #expect(email.mailbox == "INBOX")
        #expect(email.serverUID == 5)
    }

    @Test func trashCopyWithoutExpungeKeepsTheRowInTrash() async throws {
        let container = try EmailRepositoryTests.inMemoryContainer()
        let context = ModelContext(container)
        let repository = EmailRepository(modelContext: context)
        let mock = MockMailClient()
        // No UIDPLUS: copied to Trash, original only flagged \Deleted.
        await mock.setMoveError(MailClientError.movedWithoutExpunge(source: "INBOX", destination: "Trash"))
        repository.upsertMessages(
            [EmailRepositoryTests.simpleMessage(uid: 5, messageID: "<copied@example.com>", subject: "Copied")],
            mailbox: "INBOX",
            accountID: Self.accountID
        )
        let email = try #require(try context.fetch(FetchDescriptor<Email>()).first)

        await EmailServerAction.delete(email: email, repository: repository, mailClient: mock)

        #expect(email.mailbox == "Trash", "the copy is in Trash, so the row isn't reverted to INBOX")
        #expect(email.serverUID == nil, "awaits the Trash sync for its real UID")
    }

    @Test func expungeErrorsExplainWhatWasLeftBehind() {
        let moved = MailClientError.movedWithoutExpunge(source: "INBOX", destination: "Trash")
            .localizedDescription
        #expect(moved.contains("\"Trash\"") && moved.contains("\"INBOX\""))
        let flagged = MailClientError.targetedExpungeUnsupported(mailbox: "Trash").localizedDescription
        #expect(flagged.contains("marked deleted in \"Trash\""))
    }

    @Test func deletePermanentlyWaitsForTheTrashIdentity() async throws {
        let container = try EmailRepositoryTests.inMemoryContainer()
        let context = ModelContext(container)
        let repository = EmailRepository(modelContext: context)
        let mock = MockMailClient()
        repository.upsertMessages(
            [EmailRepositoryTests.simpleMessage(uid: 5, messageID: "<pending@example.com>", subject: "Pending")],
            mailbox: "INBOX",
            accountID: Self.accountID
        )
        let email = try #require(try context.fetch(FetchDescriptor<Email>()).first)
        let emailID = email.id
        await EmailServerAction.delete(email: email, repository: repository, mailClient: mock)
        #expect(email.serverUID == nil)

        // Before Trash sync: refused, nothing deleted anywhere.
        let deleted = await EmailServerAction.deletePermanently(email: email, repository: repository, mailClient: mock)
        #expect(!deleted)
        #expect(await mock.permanentDeletes.isEmpty)
        #expect(try Self.stored(emailID, in: container) != nil, "the local row survives")

        // After Trash sync re-keys it: expunged on the server, then locally.
        repository.upsertMessages(
            [EmailRepositoryTests.simpleMessage(uid: 41, messageID: "<pending@example.com>", subject: "Pending")],
            mailbox: "Trash",
            accountID: Self.accountID,
            role: .trash
        )
        #expect(await EmailServerAction.deletePermanently(email: email, repository: repository, mailClient: mock))
        #expect(await mock.permanentDeletes == [41])
        #expect(try Self.stored(emailID, in: container) == nil)
    }

    @Test func deletePermanentlyRemovesAPlaceholderThatCanNeverResolve() async throws {
        let container = try EmailRepositoryTests.inMemoryContainer()
        let mock = MockMailClient()
        await mock.setUIDValidity(7)
        await mock.setMailbox("INBOX", messages: [
            EmailRepositoryTests.simpleMessage(uid: 1, messageID: "<gone@example.com>", subject: "Gone"),
        ])
        let worker = Self.makeWorker(mock: mock, container: container, reconcileEveryNPasses: 100)
        _ = await worker.syncOnce()
        // A UIDVALIDITY reset and a refetch that no longer has the message.
        await mock.setUIDValidity(8)
        await mock.setMailbox("INBOX", messages: [])
        _ = await worker.syncOnce()

        let context = ModelContext(container)
        let repository = EmailRepository(modelContext: context)
        let email = try #require(try context.fetch(FetchDescriptor<Email>()).first)
        let emailID = email.id
        #expect(email.serverUID == nil)
        #expect(!email.isAwaitingServerIdentity, "no sync will ever re-key it")

        #expect(await EmailServerAction.deletePermanently(email: email, repository: repository, mailClient: mock))
        #expect(await mock.permanentDeletes.isEmpty, "nothing on the server to address")
        #expect(try Self.stored(emailID, in: container) == nil)
    }

    @Test func movedRowWithoutAMessageIDIsNotAwaitingIdentity() async throws {
        let container = try EmailRepositoryTests.inMemoryContainer()
        let context = ModelContext(container)
        let repository = EmailRepository(modelContext: context)
        let mock = MockMailClient()
        repository.upsertMessages(
            [EmailRepositoryTests.simpleMessage(uid: 5, messageID: "", subject: "No ID")],
            mailbox: "INBOX",
            accountID: Self.accountID
        )
        let email = try #require(try context.fetch(FetchDescriptor<Email>()).first)
        await EmailServerAction.delete(email: email, repository: repository, mailClient: mock)
        #expect(email.serverUID == nil)
        #expect(!email.isAwaitingServerIdentity, "Trash sync matches by Message-ID, which it lacks")
        #expect(await EmailServerAction.deletePermanently(email: email, repository: repository, mailClient: mock))
    }

    // MARK: - Synthetic Sent echoes

    @Test func anotherClientsSentMessageOnTheNextUIDIsNotSwallowed() async throws {
        let container = try EmailRepositoryTests.inMemoryContainer()
        let context = ModelContext(container)
        let repository = EmailRepository(modelContext: context)
        let mock = MockMailClient()
        repository.upsertMessages(
            [EmailRepositoryTests.simpleMessage(uid: 7, messageID: "<old-sent@example.com>", subject: "Old")],
            mailbox: "Sent",
            accountID: Self.accountID,
            role: .sent
        )
        let echo = try #require(repository.upsertSentMessage(
            OutgoingEmail(
                fromAddress: "me@example.com",
                toAddresses: ["them@example.com"],
                subject: "Mine",
                bodyText: "body",
                messageID: "<mine@example.com>"
            ),
            account: Self.account,
            sentMailbox: "Sent"
        ))

        // Before the old scheme's `max + 1` echo could be promoted, another
        // client's message lands on uid 8.
        let outcome = repository.upsertMessages(
            [EmailRepositoryTests.simpleMessage(uid: 8, messageID: "<theirs@example.com>", subject: "Theirs")],
            mailbox: "Sent",
            accountID: Self.accountID,
            role: .sent
        )

        #expect(outcome.insertedCount == 1)
        #expect(echo.isLocallySynthetic)
        #expect(echo.subject == "Mine")

        await EmailServerAction.setFlags(
            email: echo,
            repository: repository,
            mailClient: mock,
            isRead: nil,
            isFlagged: true
        )
        #expect(await mock.flagUpdates.isEmpty, "the echo has no server UID yet")
    }

    // MARK: - UIDVALIDITY reset

    @Test func uidValidityResetRekeysByMessageIDInsteadOfRecycledUID() async throws {
        let container = try EmailRepositoryTests.inMemoryContainer()
        let mock = MockMailClient()
        await mock.setUIDValidity(7)
        await mock.setMailbox("INBOX", messages: [
            EmailRepositoryTests.simpleMessage(uid: 1, messageID: "<a@example.com>", subject: "A"),
        ])
        let worker = Self.makeWorker(mock: mock, container: container)
        _ = await worker.syncOnce()

        let context = ModelContext(container)
        let original = try #require(try context.fetch(FetchDescriptor<Email>()).first)
        let originalID = original.id
        EmailRepository(modelContext: context).addNote(emailID: originalID, author: .user, content: "keep me")

        // Rebuild: uid 1 now names a different message, A moved to uid 2.
        await mock.setUIDValidity(8)
        await mock.setMailbox("INBOX", messages: [
            EmailRepositoryTests.simpleMessage(uid: 1, messageID: "<b@example.com>", subject: "B"),
            EmailRepositoryTests.simpleMessage(uid: 2, messageID: "<a@example.com>", subject: "A"),
        ])
        _ = await worker.syncOnce()

        let rows = try ModelContext(container).fetch(FetchDescriptor<Email>())
        let byMessageID = Dictionary(uniqueKeysWithValues: rows.map { ($0.messageID ?? "", $0) })
        let a = try #require(byMessageID["<a@example.com>"])
        let b = try #require(byMessageID["<b@example.com>"])
        #expect(rows.count == 2)
        #expect(a.id == originalID, "A keeps its row (and its note)")
        #expect(a.notes.count == 1)
        #expect(a.serverUID == 2)
        #expect(a.subject == "A")
        #expect(b.serverUID == 1)
        #expect(b.subject == "B", "B's content isn't merged into A's row")
    }

    @Test func uidValidityResetRetiresMessagesThatAreGone() async throws {
        let container = try EmailRepositoryTests.inMemoryContainer()
        let mock = MockMailClient()
        await mock.setUIDValidity(7)
        await mock.setMailbox("INBOX", messages: [
            EmailRepositoryTests.simpleMessage(uid: 1, messageID: "<a@example.com>", subject: "A"),
        ])
        // Throttled cadence: the reset must reconcile on its own pass.
        let worker = Self.makeWorker(mock: mock, container: container, reconcileEveryNPasses: 100)
        _ = await worker.syncOnce()

        await mock.setUIDValidity(8)
        await mock.setMailbox("INBOX", messages: [
            EmailRepositoryTests.simpleMessage(uid: 1, messageID: "<b@example.com>", subject: "B"),
        ])
        _ = await worker.syncOnce()

        let rows = try ModelContext(container).fetch(FetchDescriptor<Email>())
        let a = try #require(rows.first { $0.messageID == "<a@example.com>" })
        let b = try #require(rows.first { $0.messageID == "<b@example.com>" })
        #expect(a.isTrashed, "A is no longer on the server")
        #expect(a.serverUID == nil)
        #expect(a.subject == "A")
        #expect(!b.isTrashed)
        #expect(b.serverUID == 1)
        #expect(b.subject == "B")
    }

    // MARK: - Restored messages

    @Test func messageRestoredUnderANewUIDLeavesLocalTrash() throws {
        let container = try EmailRepositoryTests.inMemoryContainer()
        let context = ModelContext(container)
        let repository = EmailRepository(modelContext: context)
        repository.upsertMessages(
            [EmailRepositoryTests.simpleMessage(uid: 3, messageID: "<back@example.com>", subject: "Back")],
            mailbox: "INBOX",
            accountID: Self.accountID
        )
        // Another client moved it out: the reconcile pass soft-deletes it.
        repository.reconcileMailbox(
            MailboxUIDSet(uidValidity: 1, uids: [], flagsByUID: [:]),
            mailbox: "INBOX",
            accountID: Self.accountID
        )
        let email = try #require(try context.fetch(FetchDescriptor<Email>()).first)
        #expect(email.isTrashed)

        // …and back into INBOX, under a new UID.
        repository.upsertMessages(
            [EmailRepositoryTests.simpleMessage(uid: 9, messageID: "<back@example.com>", subject: "Back")],
            mailbox: "INBOX",
            accountID: Self.accountID
        )

        #expect(try Self.stored(email.id, in: container)?.isTrashed == false)
        #expect(email.serverUID == 9)
        #expect(try context.fetch(FetchDescriptor<Email>()).count == 1)
    }

    // MARK: - Flag retry

    @Test func syncRetriesPendingFlagChanges() async throws {
        let container = try EmailRepositoryTests.inMemoryContainer()
        let mock = MockMailClient()
        await mock.setUIDValidity(7)
        await mock.setMailbox("INBOX", messages: [
            EmailRepositoryTests.simpleMessage(uid: 1, messageID: "<f@example.com>", subject: "F"),
        ])
        let worker = Self.makeWorker(mock: mock, container: container)
        _ = await worker.syncOnce()

        // A flag change that never reached the server (failed request, or
        // an AI tool that only mutates locally).
        let context = ModelContext(container)
        let email = try #require(try context.fetch(FetchDescriptor<Email>()).first)
        EmailRepository(modelContext: context).setFlag(messageID: email.id, isFlagged: true)

        await mock.setSetFlagsError(MailClientError.fetchFailed("offline"))
        _ = await worker.syncOnce()
        var refreshed = try #require(try ModelContext(container).fetch(FetchDescriptor<Email>()).first)
        #expect(refreshed.needsFlagSync, "still pending after a failed retry")
        #expect(refreshed.isFlagged, "the stale server snapshot doesn't revert it")

        await mock.setSetFlagsError(nil)
        _ = await worker.syncOnce()
        refreshed = try #require(try ModelContext(container).fetch(FetchDescriptor<Email>()).first)
        #expect(!refreshed.needsFlagSync)
        #expect(refreshed.isFlagged)
        let lastUpdate = try #require(await mock.flagUpdates.last)
        #expect(lastUpdate.uid == 1)
        #expect(lastUpdate.updates.isFlagged == true)
        #expect(lastUpdate.updates.isRead == false)
    }

    @Test func staleAcknowledgementKeepsTheNewerChangePending() throws {
        let container = try EmailRepositoryTests.inMemoryContainer()
        let context = ModelContext(container)
        let repository = EmailRepository(modelContext: context)
        repository.upsertMessages(
            [EmailRepositoryTests.simpleMessage(uid: 1, messageID: "<t@example.com>", subject: "T")],
            mailbox: "INBOX",
            accountID: Self.accountID
        )
        let email = try #require(try context.fetch(FetchDescriptor<Email>()).first)
        repository.setFlag(messageID: email.id, isFlagged: true)
        repository.setFlag(messageID: email.id, isFlagged: false)

        // The ack for the first toggle arrives after the second toggle.
        repository.clearFlagSyncPending(
            messageID: email.id,
            acknowledging: MailFlagUpdate(isRead: nil, isFlagged: true)
        )
        #expect(email.needsFlagSync)

        repository.clearFlagSyncPending(
            messageID: email.id,
            acknowledging: MailFlagUpdate(isRead: nil, isFlagged: false)
        )
        #expect(!email.needsFlagSync)
    }

    @Test func readAcknowledgementDoesNotSettleAnInFlightFlagChange() async throws {
        let container = try EmailRepositoryTests.inMemoryContainer()
        let context = ModelContext(container)
        let repository = EmailRepository(modelContext: context)
        let mock = MockMailClient()
        repository.upsertMessages(
            [EmailRepositoryTests.simpleMessage(uid: 1, messageID: "<i@example.com>", subject: "I")],
            mailbox: "INBOX",
            accountID: Self.accountID
        )
        let email = try #require(try context.fetch(FetchDescriptor<Email>()).first)

        // Opening the message sends a read-only update that is still in flight…
        repository.setRead(messageID: email.id, isRead: true)
        // …when the user flags it; that request (carrying both pending
        // components) fails.
        await mock.setSetFlagsError(MailClientError.fetchFailed("offline"))
        await EmailServerAction.toggleFlag(email: email, repository: repository, mailClient: mock)
        let flagRequest = try #require(await mock.flagUpdates.last)
        #expect(flagRequest.updates.isFlagged == true)
        #expect(flagRequest.updates.isRead == true)

        // The read-only request's ack arrives last.
        repository.clearFlagSyncPending(
            messageID: email.id,
            acknowledging: MailFlagUpdate(isRead: true, isFlagged: nil)
        )
        #expect(email.needsFlagSync, "the flag change was never confirmed")
        #expect(email.pendingFlagUpdate?.isFlagged == true)
        #expect(email.pendingFlagUpdate?.isRead == nil, "the read change is settled")
        let retry = repository.pendingFlagSyncs(mailbox: "INBOX", accountID: Self.accountID)
        #expect(retry.map(\.emailID) == [email.id], "the background retry still picks it up")

        // A later change re-sends only what is still unconfirmed.
        await mock.setSetFlagsError(nil)
        await EmailServerAction.toggleFlag(email: email, repository: repository, mailClient: mock)
        let resend = try #require(await mock.flagUpdates.last)
        #expect(resend.updates.isFlagged == false)
        #expect(resend.updates.isRead == nil, "a settled component isn't overwritten")
        #expect(!email.needsFlagSync)
    }

    @Test func legacyPendingMarkerCountsBothComponents() throws {
        let container = try EmailRepositoryTests.inMemoryContainer()
        let context = ModelContext(container)
        let repository = EmailRepository(modelContext: context)
        repository.upsertMessages(
            [EmailRepositoryTests.simpleMessage(uid: 1, messageID: "<l@example.com>", subject: "L")],
            mailbox: "INBOX",
            accountID: Self.accountID
        )
        let email = try #require(try context.fetch(FetchDescriptor<Email>()).first)
        // Marked before per-component tracking existed.
        email.needsFlagSync = true
        try context.save()

        repository.clearFlagSyncPending(
            messageID: email.id,
            acknowledging: MailFlagUpdate(isRead: false, isFlagged: nil)
        )
        #expect(email.needsFlagSync)
        #expect(email.pendingFlagUpdate?.isFlagged == false)
        #expect(email.pendingFlagUpdate?.isRead == nil)
    }

    @Test func mutatingARowWithALegacyMarkerKeepsBothComponentsPending() throws {
        let container = try EmailRepositoryTests.inMemoryContainer()
        let context = ModelContext(container)
        let repository = EmailRepository(modelContext: context)
        repository.upsertMessages(
            [EmailRepositoryTests.simpleMessage(uid: 1, messageID: "<m@example.com>", subject: "M")],
            mailbox: "INBOX",
            accountID: Self.accountID
        )
        let email = try #require(try context.fetch(FetchDescriptor<Email>()).first)
        // Marked before per-component tracking existed, then opened.
        email.needsFlagSync = true
        try context.save()
        repository.setRead(messageID: email.id, isRead: true)

        #expect(email.pendingFlagUpdate?.isRead == true)
        #expect(email.pendingFlagUpdate?.isFlagged == false, "the unsent flag change still goes out")

        repository.clearFlagSyncPending(
            messageID: email.id,
            acknowledging: MailFlagUpdate(isRead: true, isFlagged: nil)
        )
        #expect(email.needsFlagSync, "a read-only ack can't settle the legacy flag change")
        #expect(email.pendingFlagUpdate?.isFlagged == false)
    }

    // MARK: - Persistence

    @Test func failedSaveIsReportedAndHoldsTheCheckpoint() throws {
        let container = try EmailRepositoryTests.inMemoryContainer()
        let repository = EmailRepository(
            modelContext: ModelContext(container),
            saveUpsertChanges: { throw CocoaError(.fileWriteUnknown) }
        )
        let outcome = repository.upsertMessages(
            [EmailRepositoryTests.simpleMessage(uid: 1, messageID: "<x@example.com>", subject: "X")],
            mailbox: "INBOX",
            accountID: Self.accountID
        )
        #expect(!outcome.persisted)
        #expect(outcome.insertedCount == 0)
    }

    @Test func checkpointIsRecordedOnlyAfterMessagesAreStored() async throws {
        let container = try EmailRepositoryTests.inMemoryContainer()
        let mock = MockMailClient()
        await mock.setUIDValidity(7)
        await mock.setMailbox("INBOX", messages: [
            EmailRepositoryTests.simpleMessage(uid: 1, messageID: "<c@example.com>", subject: "C"),
        ])
        var storedCountsAtCheckpoint: [Int] = []
        let account = Self.account
        let worker = MailSyncWorker(
            accountsProvider: { [account] },
            modelContainer: container,
            clientFactory: { _ in mock },
            syncStateProvider: { _, _ in nil },
            syncStateUpdater: { _, _, mailbox in
                guard mailbox == "INBOX" else { return }
                await MainActor.run {
                    let count = (try? ModelContext(container).fetchCount(FetchDescriptor<Email>())) ?? -1
                    storedCountsAtCheckpoint.append(count)
                }
            },
            newMailNotifier: { _ in }
        )

        _ = await worker.syncOnce()

        #expect(storedCountsAtCheckpoint == [1])
    }

    // MARK: - Attachment files

    @Test func hardDeletedDraftsRemoveTheirAttachmentFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EmailServerIdentityTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EmailAttachmentStore(rootDirectory: root)
        let container = try EmailRepositoryTests.inMemoryContainer()
        let repository = EmailRepository(modelContext: ModelContext(container), attachmentStore: store)

        let draft = Self.message(
            uid: 4,
            messageID: "<draft@example.com>",
            attachments: [("notes.txt", "v1")]
        )
        let prepared = store.prepare([draft])
        repository.upsertPreparedMessages(prepared, mailbox: "Drafts", accountID: Self.accountID, role: .drafts)
        let fileURL = try #require(store.absoluteURL(forRelativePath: prepared[0].attachments[0].filePath))
        #expect(FileManager.default.fileExists(atPath: fileURL.path))

        // The server replaced the draft (new UID); the stale row is removed.
        let outcome = repository.reconcileMailbox(
            MailboxUIDSet(uidValidity: 1, uids: [5], flagsByUID: [:]),
            mailbox: "Drafts",
            accountID: Self.accountID,
            hardDelete: true
        )

        #expect(outcome.removedCount == 1)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test func duplicateAttachmentNamesGetSeparateFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EmailServerIdentityTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EmailAttachmentStore(rootDirectory: root)

        let message = Self.message(
            uid: 1,
            messageID: "<dupes@example.com>",
            attachments: [
                ("report.pdf", "first"),
                ("report.pdf", "second"),
                ("report?.pdf", "third"),
                ("report*.pdf", "fourth"),
            ]
        )
        let attachments = try #require(store.prepare([message]).first).attachments

        let paths = attachments.map(\.filePath)
        #expect(Set(paths.map { $0.lowercased() }).count == 4, "each part gets its own file")
        let contents = try paths.map { path in
            let url = try #require(store.absoluteURL(forRelativePath: path))
            return try String(contentsOf: url, encoding: .utf8)
        }
        #expect(contents == ["first", "second", "third", "fourth"])
        #expect(attachments.map(\.filename) == ["report.pdf", "report.pdf", "report?.pdf", "report*.pdf"])
    }

    @Test func relativeAttachmentPathsCannotEscapeTheRoot() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EmailServerIdentityTests-\(UUID().uuidString)", isDirectory: true)
        let store = EmailAttachmentStore(rootDirectory: root)
        #expect(store.absoluteURL(forRelativePath: "") == nil)
        #expect(store.absoluteURL(forRelativePath: "../outside.txt") == nil)
        #expect(store.absoluteURL(forRelativePath: "\(UUID().uuidString)/file.txt") != nil)
    }

    // MARK: - Helpers

    /// Reads the row back through a fresh context, so assertions see what
    /// was saved rather than the instance the code under test mutated.
    private static func stored(_ id: UUID, in container: ModelContainer) throws -> Email? {
        try ModelContext(container).fetch(FetchDescriptor<Email>(predicate: #Predicate { $0.id == id })).first
    }

    private static var account: StoredEmailAccount {
        StoredEmailAccount(
            id: accountID,
            displayName: "Test",
            imapHost: "imap.example.com",
            imapUsername: "me@example.com",
            smtpHost: "smtp.example.com",
            smtpUsername: "me@example.com",
            fromAddress: "me@example.com"
        )
    }

    private static func makeWorker(
        mock: MockMailClient,
        container: ModelContainer,
        reconcileEveryNPasses: Int = 1
    ) -> MailSyncWorker {
        var states: [String: MailboxSyncState] = [:]
        let account = Self.account
        return MailSyncWorker(
            accountsProvider: { [account] },
            modelContainer: container,
            clientFactory: { _ in mock },
            syncStateProvider: { id, mailbox in
                await MainActor.run { states[MailboxSyncStateStore.key(for: id, mailbox: mailbox)] }
            },
            syncStateUpdater: { state, id, mailbox in
                await MainActor.run { states[MailboxSyncStateStore.key(for: id, mailbox: mailbox)] = state }
            },
            newMailNotifier: { _ in },
            reconcileEveryNPasses: reconcileEveryNPasses
        )
    }

    private static func message(
        uid: Int,
        messageID: String,
        attachments: [(name: String, body: String)]
    ) -> FetchedMessage {
        let base = EmailRepositoryTests.simpleMessage(uid: uid, messageID: messageID, subject: "Attachments")
        return FetchedMessage(
            uid: base.uid,
            messageID: base.messageID,
            subject: base.subject,
            fromAddress: base.fromAddress,
            toAddresses: base.toAddresses,
            ccAddresses: base.ccAddresses,
            bccAddresses: base.bccAddresses,
            date: base.date,
            internalDate: base.internalDate,
            bodyText: base.bodyText,
            bodyHTML: base.bodyHTML,
            inReplyTo: base.inReplyTo,
            references: base.references,
            isRead: base.isRead,
            isFlagged: base.isFlagged,
            mailbox: base.mailbox,
            attachmentDescriptors: attachments.enumerated().map { index, attachment in
                FetchedAttachmentDescriptor(
                    filename: attachment.name,
                    mimeType: "application/octet-stream",
                    sizeBytes: attachment.body.utf8.count,
                    partNumber: "\(index + 2)",
                    data: Data(attachment.body.utf8)
                )
            }
        )
    }
}
