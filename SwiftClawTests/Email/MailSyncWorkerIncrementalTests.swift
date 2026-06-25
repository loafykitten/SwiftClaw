import Foundation
import Testing
import SwiftData
@testable import SwiftClaw

/// End-to-end coverage for the incremental-fetch behavior of
/// `MailSyncWorker`. The worker is constructed with an injected
/// `clientFactory` returning a `MockMailClient` and a pair of in-memory
/// closures standing in for `MailboxSyncStateStore`, so we can assert:
///
/// - First sync fetches the whole mailbox (sinceUID == nil) and records
///   the observed UIDVALIDITY + maxUID.
/// - Second sync passes the recorded lastSeenUID as `sinceUID` and only
///   newly-arrived messages are inserted.
/// - A UIDVALIDITY change forces a full re-fetch.
@MainActor
struct MailSyncWorkerIncrementalTests {
    @Test func firstSyncFetchesEverythingThenIncrementalOnly() async throws {
        let container = try Self.inMemoryContainer()
        let mock = MockMailClient()
        let accountID = UUID()
        let account = Self.completeAccount(id: accountID)
        await mock.setUIDValidity(7)
        await mock.setMailbox("INBOX", messages: Self.messages(uids: 1...3, accountID: accountID))

        var states: [String: MailboxSyncState] = [:]
        let provider: @Sendable (UUID, String) async -> MailboxSyncState? = { id, mailbox in
            await MainActor.run { states[MailboxSyncStateStore.key(for: id, mailbox: mailbox)] }
        }
        let updater: @Sendable (MailboxSyncState, UUID, String) async -> Void = { state, id, mailbox in
            await MainActor.run { states[MailboxSyncStateStore.key(for: id, mailbox: mailbox)] = state }
        }

        let worker = MailSyncWorker(
            accountsProvider: { [account] },
            modelContainer: container,
            clientFactory: { _ in mock },
            syncStateProvider: provider,
            syncStateUpdater: updater
        )

        // First sync: sinceUID should be nil → all three messages fetched
        // and inserted; recorded state has uidValidity=7, lastSeenUID=3.
        let firstInserted = await worker.syncOnce()
        #expect(firstInserted == 3)

        let firstState = try #require(states[MailboxSyncStateStore.key(for: accountID, mailbox: "INBOX")])
        #expect(firstState.uidValidity == 7)
        #expect(firstState.lastSeenUID == 3)

        // Second sync: same UIDVALIDITY, sinceUID=3 → no new mail.
        let secondInserted = await worker.syncOnce()
        #expect(secondInserted == 0)

        // A new message arrives (uid 4). Third sync: sinceUID=3, fetches
        // only uid 4 and inserts one row.
        await mock.addMessage(Self.message(uid: 4, accountID: accountID), to: "INBOX")
        let thirdInserted = await worker.syncOnce()
        #expect(thirdInserted == 1)

        let thirdState = try #require(states[MailboxSyncStateStore.key(for: accountID, mailbox: "INBOX")])
        #expect(thirdState.lastSeenUID == 4)
        #expect(thirdState.uidValidity == 7)
    }

    @Test func uidValidityChangeTriggersFullRefetch() async throws {
        let container = try Self.inMemoryContainer()
        let mock = MockMailClient()
        let accountID = UUID()
        let account = Self.completeAccount(id: accountID)
        await mock.setUIDValidity(7)
        await mock.setMailbox("INBOX", messages: Self.messages(uids: 100...101, accountID: accountID))

        var states: [String: MailboxSyncState] = [:]
        let provider: @Sendable (UUID, String) async -> MailboxSyncState? = { id, mailbox in
            await MainActor.run { states[MailboxSyncStateStore.key(for: id, mailbox: mailbox)] }
        }
        let updater: @Sendable (MailboxSyncState, UUID, String) async -> Void = { state, id, mailbox in
            await MainActor.run { states[MailboxSyncStateStore.key(for: id, mailbox: mailbox)] = state }
        }

        let worker = MailSyncWorker(
            accountsProvider: { [account] },
            modelContainer: container,
            clientFactory: { _ in mock },
            syncStateProvider: provider,
            syncStateUpdater: updater
        )

        // First sync: validity=7, mailbox=[uid=100, uid=101]. Recorded
        // high-water is 101.
        _ = await worker.syncOnce()
        #expect(states[MailboxSyncStateStore.key(for: accountID, mailbox: "INBOX")]?.lastSeenUID == 101)
        #expect(states[MailboxSyncStateStore.key(for: accountID, mailbox: "INBOX")]?.uidValidity == 7)

        // Simulate a folder rebuild: UIDVALIDITY bumps 7 → 99 and the server
        // hands us freshly-numbered messages in the low UID range (1...3)
        // that are all *below* the stale high-water of 101. Under the buggy
        // incremental path (sinceUID=101) the server would hand back no
        // messages (none have UID > 101) and the new mail would be silently
        // lost. The fix detects the UIDVALIDITY mismatch and re-fetches with
        // `sinceUID == nil`, so the rebuilt messages all land locally.
        await mock.setUIDValidity(99)
        await mock.setMailbox("INBOX", messages: Self.messages(uids: 1...3, accountID: accountID))

        let inserted = await worker.syncOnce()
        #expect(inserted == 3)

        let finalState = try #require(states[MailboxSyncStateStore.key(for: accountID, mailbox: "INBOX")])
        #expect(finalState.uidValidity == 99)
        #expect(finalState.lastSeenUID == 3)
    }

    // MARK: - Helpers

    private static func completeAccount(id: UUID) -> StoredEmailAccount {
        StoredEmailAccount(
            id: id,
            displayName: "Test",
            imapHost: "imap.example.com",
            imapUsername: "me@example.com",
            smtpHost: "smtp.example.com",
            smtpUsername: "me@example.com",
            fromAddress: "me@example.com"
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

    private static func inMemoryContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Email.self, EmailThread.self, EmailNote.self, EmailAttachment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }
}
