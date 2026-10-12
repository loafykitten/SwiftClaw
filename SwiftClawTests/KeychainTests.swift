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
}
