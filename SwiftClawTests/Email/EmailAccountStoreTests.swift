import Foundation
import Testing
@testable import SwiftClaw

@MainActor
struct EmailAccountStoreTests {
    @Test func startsEmptyWithFreshUserDefaults() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let store = EmailAccountStore(userDefaults: fixture.defaults)
        #expect(store.accounts.isEmpty)
        #expect(!store.hasConfiguredAccount)
    }

    @Test func addPersistsAcrossInstances() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let store = EmailAccountStore(userDefaults: fixture.defaults)
        let account = StoredEmailAccount(
            displayName: "Work",
            imapHost: "imap.work.com",
            imapUsername: "me@work.com",
            smtpHost: "smtp.work.com",
            smtpUsername: "me@work.com",
            fromAddress: "me@work.com"
        )
        store.add(account)

        let reload = EmailAccountStore(userDefaults: fixture.defaults)
        #expect(reload.accounts.count == 1)
        #expect(reload.accounts.first?.imapHost == "imap.work.com")
        #expect(reload.account(for: account.id)?.imapHost == "imap.work.com")
        #expect(reload.hasConfiguredAccount)
    }

    @Test func updateReplacesFields() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let store = EmailAccountStore(userDefaults: fixture.defaults)
        let original = StoredEmailAccount(
            displayName: "Work",
            imapHost: "imap.work.com",
            imapUsername: "me@work.com",
            smtpHost: "smtp.work.com",
            smtpUsername: "me@work.com",
            fromAddress: "me@work.com"
        )
        store.add(original)

        var edited = original
        edited.imapHost = "imap.new.com"
        store.update(edited)

        let reload = EmailAccountStore(userDefaults: fixture.defaults)
        #expect(reload.accounts.count == 1)
        #expect(reload.accounts.first?.imapHost == "imap.new.com")
    }

    @Test func removeDeletesAccountAndKeychainPasswords() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let store = EmailAccountStore(userDefaults: fixture.defaults)
        let account = StoredEmailAccount(
            displayName: "Work",
            imapHost: "imap.work.com",
            imapUsername: "me@work.com",
            smtpHost: "smtp.work.com",
            smtpUsername: "me@work.com",
            fromAddress: "me@work.com"
        )
        store.add(account)
        store.setPassword("secret-imap", kind: .imap, for: account)
        store.setPassword("secret-smtp", kind: .smtp, for: account)

        #expect(store.imapPassword(for: account) == "secret-imap")
        #expect(store.smtpPassword(for: account) == "secret-smtp")

        store.remove(account)

        let reload = EmailAccountStore(userDefaults: fixture.defaults)
        #expect(reload.accounts.isEmpty)
        #expect(reload.imapPassword(for: account) == nil)
        #expect(reload.smtpPassword(for: account) == nil)
    }

    @Test func migrateLegacyCreatesAccountFromFlatKeys() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        // Seed the legacy flat keys.
        fixture.defaults.set("imap.legacy.com", forKey: SettingsKeys.emailImapHost)
        fixture.defaults.set(993, forKey: SettingsKeys.emailImapPort)
        fixture.defaults.set("me@legacy.com", forKey: SettingsKeys.emailImapUsername)
        fixture.defaults.set("smtp.legacy.com", forKey: SettingsKeys.emailSmtpHost)
        fixture.defaults.set(587, forKey: SettingsKeys.emailSmtpPort)
        fixture.defaults.set("me@legacy.com", forKey: SettingsKeys.emailSmtpUsername)
        fixture.defaults.set("me@legacy.com", forKey: SettingsKeys.emailFromAddress)

        Keychain.set("legacy-imap-pw", forKey: SettingsKeys.emailImapPassword)
        Keychain.set("legacy-smtp-pw", forKey: SettingsKeys.emailSmtpPassword)
        defer {
            Keychain.delete(SettingsKeys.emailImapPassword)
            Keychain.delete(SettingsKeys.emailSmtpPassword)
        }

        let store = EmailAccountStore(userDefaults: fixture.defaults)
        store.migrateLegacyIfNeeded()

        #expect(store.accounts.count == 1)
        let account = try #require(store.accounts.first)
        #expect(account.imapHost == "imap.legacy.com")
        #expect(account.imapPort == 993)
        #expect(account.imapUsername == "me@legacy.com")
        #expect(account.smtpHost == "smtp.legacy.com")
        #expect(account.fromAddress == "me@legacy.com")
        #expect(store.imapPassword(for: account) == "legacy-imap-pw")
        #expect(store.smtpPassword(for: account) == "legacy-smtp-pw")

        // Clean up the per-account Keychain entries created by migration.
        defer {
            Keychain.delete(EmailAccountKeychainKeys.imapPassword(for: account.id))
            Keychain.delete(EmailAccountKeychainKeys.smtpPassword(for: account.id))
        }

        // Legacy keys should be cleared.
        #expect(fixture.defaults.string(forKey: SettingsKeys.emailImapHost) == nil)
        #expect(fixture.defaults.string(forKey: SettingsKeys.emailSmtpHost) == nil)

        // Idempotent: running again is a no-op.
        let store2 = EmailAccountStore(userDefaults: fixture.defaults)
        store2.migrateLegacyIfNeeded()
        #expect(store2.accounts.count == 1)
    }

    @Test func migrateLegacyIsNoOpWhenAccountsAlreadyExist() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        fixture.defaults.set("imap.legacy.com", forKey: SettingsKeys.emailImapHost)
        fixture.defaults.set("me@legacy.com", forKey: SettingsKeys.emailImapUsername)

        let store = EmailAccountStore(userDefaults: fixture.defaults)
        store.add(StoredEmailAccount(displayName: "Existing", imapHost: "imap.existing.com", imapUsername: "me@existing.com", smtpHost: "smtp.existing.com", smtpUsername: "me@existing.com", fromAddress: "me@existing.com"))

        store.migrateLegacyIfNeeded()

        // Only the manually-added account remains; legacy keys were not migrated.
        #expect(store.accounts.count == 1)
        #expect(store.accounts.first?.imapHost == "imap.existing.com")
    }

    @Test func isCompleteRequiresAllFields() {
        var account = StoredEmailAccount()
        #expect(!account.isComplete)

        account.imapHost = "imap.work.com"
        account.imapUsername = "me@work.com"
        account.smtpHost = "smtp.work.com"
        account.smtpUsername = "me@work.com"
        account.fromAddress = "me@work.com"
        #expect(account.isComplete)
    }

    @Test func effectiveDisplayNameFallsBackToUsername() {
        var account = StoredEmailAccount()
        account.displayName = ""
        account.imapUsername = "me@work.com"
        #expect(account.effectiveDisplayName == "me@work.com")

        account.displayName = "Work"
        #expect(account.effectiveDisplayName == "Work")
    }

    @Test func accountsProviderSnapshotsCurrentList() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let store = EmailAccountStore(userDefaults: fixture.defaults)
        let provider = store.accountsProvider()

        store.add(StoredEmailAccount(displayName: "A", imapHost: "a", imapUsername: "a", smtpHost: "a", smtpUsername: "a", fromAddress: "a"))
        store.add(StoredEmailAccount(displayName: "B", imapHost: "b", imapUsername: "b", smtpHost: "b", smtpUsername: "b", fromAddress: "b"))

        let snapshot = await provider()
        #expect(snapshot.count == 2)
        #expect(snapshot.map(\.displayName).sorted() == ["A", "B"])
    }

    // MARK: - Helpers

    private func makeFixture() throws -> UserDefaultsFixture {
        try UserDefaultsFixture()
    }
}
