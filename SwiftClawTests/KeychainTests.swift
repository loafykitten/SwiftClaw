import Foundation
import Testing
@testable import SwiftClaw

/// `Keychain` reports write failures, and the API-key migration only drops the
/// UserDefaults copy once the Keychain verifiably holds the secret.
struct KeychainTests {
    @Test func setReportsSuccessAndRoundTrips() {
        let key = "SwiftClawTests.keychain.\(UUID().uuidString)"
        defer { Keychain.delete(key) }

        #expect(Keychain.set("first", forKey: key))
        #expect(Keychain.string(forKey: key) == "first")
        #expect(Keychain.set("first", forKey: key))   // unchanged → still success
        #expect(Keychain.set("second", forKey: key))  // update path
        #expect(Keychain.string(forKey: key) == "second")
        #expect(Keychain.set("", forKey: key))        // empty deletes
        #expect(Keychain.string(forKey: key) == nil)
        #expect(Keychain.delete(key))                 // already gone → success
    }

    @Test func migrationKeepsUserDefaultsCopyWhenKeychainWriteFails() throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }
        let key = "SwiftClawTests.apiKey.\(UUID().uuidString)"
        fixture.defaults.set("sk-only-copy", forKey: key)

        Keychain.migrateAPIKeysFromUserDefaults(
            defaults: fixture.defaults,
            keys: [key],
            read: { _ in nil },
            write: { _, _ in false }
        )
        #expect(fixture.defaults.string(forKey: key) == "sk-only-copy")

        // A write that claims success but doesn't stick is also not trusted.
        Keychain.migrateAPIKeysFromUserDefaults(
            defaults: fixture.defaults,
            keys: [key],
            read: { _ in nil },
            write: { _, _ in true }
        )
        #expect(fixture.defaults.string(forKey: key) == "sk-only-copy")
    }

    @Test func migrationRemovesUserDefaultsCopyOnceStored() throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }
        let key = "SwiftClawTests.apiKey.\(UUID().uuidString)"
        fixture.defaults.set("sk-moved", forKey: key)
        var stored: [String: String] = [:]

        Keychain.migrateAPIKeysFromUserDefaults(
            defaults: fixture.defaults,
            keys: [key],
            read: { stored[$0] },
            write: { value, key in
                stored[key] = value
                return true
            }
        )

        #expect(stored[key] == "sk-moved")
        #expect(fixture.defaults.string(forKey: key) == nil)
    }

    @Test func migrationNeverOverwritesAnExistingKeychainValue() throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }
        let key = "SwiftClawTests.apiKey.\(UUID().uuidString)"
        fixture.defaults.set("sk-stale", forKey: key)
        var writes = 0

        Keychain.migrateAPIKeysFromUserDefaults(
            defaults: fixture.defaults,
            keys: [key],
            read: { _ in "sk-current" },
            write: { _, _ in
                writes += 1
                return true
            }
        )

        #expect(writes == 0)
        #expect(fixture.defaults.string(forKey: key) == nil)
    }

    // MARK: - KeychainEntry (what @KeychainStorage fields show)

    @Test func entryTracksSuccessfulWrites() {
        var entry = KeychainEntry(persisted: "sk-old")
        var written: [String] = []

        entry.update("sk-new") { written.append($0); return true }

        #expect(written == ["sk-new"])
        #expect(entry.entered == "sk-new")
        #expect(entry.persisted == "sk-new")
        #expect(!entry.isUnsaved)
        #expect(entry.saveFailureMessage == nil)
    }

    @Test func failedWriteKeepsEntryButMarksItUnsaved() throws {
        var entry = KeychainEntry(persisted: "sk-old")

        entry.update("sk-new") { _ in false }

        #expect(entry.entered == "sk-new")
        #expect(entry.persisted == "sk-old")
        #expect(entry.isUnsaved)
        let message = try #require(entry.saveFailureMessage)
        #expect(message.contains("previously saved key is still in use"))

        // The next edit retries; once a write lands the warning clears.
        entry.update("sk-newer") { _ in true }
        #expect(entry.persisted == "sk-newer")
        #expect(entry.saveFailureMessage == nil)
    }

    @Test func failureMessageDistinguishesMissingAndUndeletedKeys() throws {
        var firstKey = KeychainEntry(persisted: "")
        firstKey.update("sk-first") { _ in false }
        #expect(try #require(firstKey.saveFailureMessage).contains("no key is in use"))

        var cleared = KeychainEntry(persisted: "sk-old")
        cleared.update("") { _ in false }
        #expect(try #require(cleared.saveFailureMessage).contains("Couldn't remove"))
    }

    /// End to end against the real Keychain: a successful `Keychain.set`
    /// round-trips through the entry (unique test account, cleaned up).
    @Test func entryPersistsThroughTheKeychain() {
        let key = "SwiftClawTests.keychainEntry.\(UUID().uuidString)"
        defer { Keychain.delete(key) }
        var entry = KeychainEntry(persisted: Keychain.string(forKey: key) ?? "")

        entry.update("sk-live") { Keychain.set($0, forKey: key) }

        #expect(!entry.isUnsaved)
        #expect(Keychain.string(forKey: key) == "sk-live")
    }
}
