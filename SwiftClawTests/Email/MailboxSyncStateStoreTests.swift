import Foundation
import Testing
@testable import SwiftClaw

/// Verifies the incremental-sync high-water mark persistence layer. The
/// `MailSyncWorker` reads/writes per-`(account, mailbox)` UIDVALIDITY +
/// lastSeenUID through this store to skip already-fetched messages on
/// subsequent polls.
@MainActor
struct MailboxSyncStateStoreTests {
    @Test func updatePersistsAcrossInstances() throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }

        let store = MailboxSyncStateStore(userDefaults: fixture.defaults)
        let accountID = UUID()
        #expect(store.state(for: accountID, mailbox: "INBOX") == nil)

        store.update(
            MailboxSyncState(uidValidity: 17, lastSeenUID: 999),
            for: accountID,
            mailbox: "INBOX"
        )

        let reload = MailboxSyncStateStore(userDefaults: fixture.defaults)
        let recovered = try #require(reload.state(for: accountID, mailbox: "INBOX"))
        #expect(recovered.uidValidity == 17)
        #expect(recovered.lastSeenUID == 999)
    }

    @Test func resetRemovesSingleMailboxEntry() throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }

        let store = MailboxSyncStateStore(userDefaults: fixture.defaults)
        let accountID = UUID()
        store.update(
            MailboxSyncState(uidValidity: 1, lastSeenUID: 10),
            for: accountID,
            mailbox: "INBOX"
        )
        store.update(
            MailboxSyncState(uidValidity: 1, lastSeenUID: 4),
            for: accountID,
            mailbox: "Archive"
        )

        store.reset(for: accountID, mailbox: "INBOX")

        #expect(store.state(for: accountID, mailbox: "INBOX") == nil)
        #expect(store.state(for: accountID, mailbox: "Archive") != nil)
    }

    @Test func resetAllDropsEveryMailboxForAccount() throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }

        let store = MailboxSyncStateStore(userDefaults: fixture.defaults)
        let accountID = UUID()
        let other = UUID()
        store.update(MailboxSyncState(uidValidity: 1, lastSeenUID: 10), for: accountID, mailbox: "INBOX")
        store.update(MailboxSyncState(uidValidity: 1, lastSeenUID: 10), for: accountID, mailbox: "Archive")
        store.update(MailboxSyncState(uidValidity: 1, lastSeenUID: 10), for: other, mailbox: "INBOX")

        store.resetAll(for: accountID)

        #expect(store.state(for: accountID, mailbox: "INBOX") == nil)
        #expect(store.state(for: accountID, mailbox: "Archive") == nil)
        #expect(store.state(for: other, mailbox: "INBOX") != nil)
    }

    @Test func stateIsScopedByAccountAndMailbox() throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }

        let store = MailboxSyncStateStore(userDefaults: fixture.defaults)
        let a = UUID()
        let b = UUID()
        store.update(MailboxSyncState(uidValidity: 7, lastSeenUID: 1), for: a, mailbox: "INBOX")
        store.update(MailboxSyncState(uidValidity: 7, lastSeenUID: 100), for: b, mailbox: "INBOX")

        #expect(store.state(for: a, mailbox: "INBOX")?.lastSeenUID == 1)
        #expect(store.state(for: b, mailbox: "INBOX")?.lastSeenUID == 100)
    }

    @Test func closuresProviderAndUpdaterRoundTrip() async throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }

        let store = MailboxSyncStateStore(userDefaults: fixture.defaults)
        let provider = store.provider()
        let updater = store.updater()
        let accountID = UUID()

        // Before any write: nil.
        #expect(await provider(accountID, "INBOX") == nil)

        // Write through the updater closure.
        await updater(MailboxSyncState(uidValidity: 9, lastSeenUID: 42), accountID, "INBOX")

        // Read through the provider closure.
        let snapshot = await provider(accountID, "INBOX")
        let recovered = try #require(snapshot)
        #expect(recovered.uidValidity == 9)
        #expect(recovered.lastSeenUID == 42)
    }

}
