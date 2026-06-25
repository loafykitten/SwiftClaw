import Foundation
import Testing
import SwiftData
@testable import SwiftClaw

/// Regression coverage for the testConnection credential path on
/// `SwiftMailClient`. Without password overrides the add-account sheet's
/// "Test Connection" button stayed permanently disabled because
/// `isConfigured` read the password from the Keychain — which is only
/// written on confirm — so `testConnection()`'s `guard isConfigured` threw
/// `.notConfigured` before reaching the network.
@MainActor
struct SwiftMailClientTests {
    @Test func isConfiguredFalseWithoutKeychainOrOverrides() {
        let accountID = UUID()
        defer {
            Keychain.delete(EmailAccountKeychainKeys.imapPassword(for: accountID))
            Keychain.delete(EmailAccountKeychainKeys.smtpPassword(for: accountID))
        }

        let account = Self.completeAccount(id: accountID)
        let client = SwiftMailClient(account: account)
        #expect(!client.isConfigured)
    }

    @Test func passwordOverridesMakeIsConfiguredTrueWithoutKeychain() {
        let accountID = UUID()
        defer {
            Keychain.delete(EmailAccountKeychainKeys.imapPassword(for: accountID))
            Keychain.delete(EmailAccountKeychainKeys.smtpPassword(for: accountID))
        }
        // Confirm the Keychain really is empty for this account — overrides
        // must be the only credential source.
        #expect(Keychain.string(forKey: EmailAccountKeychainKeys.imapPassword(for: accountID)) == nil)
        #expect(Keychain.string(forKey: EmailAccountKeychainKeys.smtpPassword(for: accountID)) == nil)

        let account = Self.completeAccount(id: accountID)
        let client = SwiftMailClient(
            account: account,
            imapPasswordOverride: "override-imap",
            smtpPasswordOverride: "override-smtp"
        )
        #expect(client.isConfigured)
    }

    @Test func keychainPasswordsAlsoSatisfyIsConfigured() {
        let accountID = UUID()
        Keychain.set("real-imap", forKey: EmailAccountKeychainKeys.imapPassword(for: accountID))
        Keychain.set("real-smtp", forKey: EmailAccountKeychainKeys.smtpPassword(for: accountID))
        defer {
            Keychain.delete(EmailAccountKeychainKeys.imapPassword(for: accountID))
            Keychain.delete(EmailAccountKeychainKeys.smtpPassword(for: accountID))
        }

        let account = Self.completeAccount(id: accountID)
        let client = SwiftMailClient(account: account) // no overrides → Keychain path
        #expect(client.isConfigured)
    }

    @Test func incompleteAccountIsNeverConfigured_evenWithOverrides() {
        var account = StoredEmailAccount(id: UUID())
        account.imapHost = "imap.example.com"
        // smtpHost missing → isComplete is false → overrides can't help.
        let client = SwiftMailClient(
            account: account,
            imapPasswordOverride: "irrelevant",
            smtpPasswordOverride: "irrelevant"
        )
        #expect(!client.isConfigured)
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
}
