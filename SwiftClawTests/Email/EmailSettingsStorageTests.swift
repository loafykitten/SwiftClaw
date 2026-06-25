import Foundation
import Testing
@testable import SwiftClaw

struct EmailSettingsStorageTests {
    @Test func emailDefaultsToOff() throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }

        #expect(!SettingsStorage.isEmailEnabled(userDefaults: fixture.defaults))
    }

    @Test func enablingEmailPersists() throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }

        fixture.defaults.set(true, forKey: SettingsKeys.emailEnabled)

        #expect(SettingsStorage.isEmailEnabled(userDefaults: fixture.defaults))
    }

    @Test func pollIntervalFallsBackToDefault() throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }

        #expect(
            SettingsStorage.loadEmailPollInterval(userDefaults: fixture.defaults)
                == SettingsStorage.defaultEmailPollIntervalSeconds
        )
    }

    @Test func pollIntervalClampsToLowerBound() throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }

        fixture.defaults.set(10, forKey: SettingsKeys.emailPollIntervalSeconds)

        #expect(
            SettingsStorage.loadEmailPollInterval(userDefaults: fixture.defaults)
                == SettingsStorage.emailPollIntervalSecondsRange.lowerBound
        )
    }

    @Test func pollIntervalClampsToUpperBound() throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }

        fixture.defaults.set(10_000_000, forKey: SettingsKeys.emailPollIntervalSeconds)

        #expect(
            SettingsStorage.loadEmailPollInterval(userDefaults: fixture.defaults)
                == SettingsStorage.emailPollIntervalSecondsRange.upperBound
        )
    }

    @Test func reviewIntervalClampsToRange() throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }

        fixture.defaults.set(1, forKey: SettingsKeys.emailReviewIntervalSeconds)

        #expect(
            SettingsStorage.loadEmailReviewInterval(userDefaults: fixture.defaults)
                == SettingsStorage.emailReviewIntervalSecondsRange.lowerBound
        )

        fixture.defaults.set(1_000_000, forKey: SettingsKeys.emailReviewIntervalSeconds)

        #expect(
            SettingsStorage.loadEmailReviewInterval(userDefaults: fixture.defaults)
                == SettingsStorage.emailReviewIntervalSecondsRange.upperBound
        )
    }
}

private struct UserDefaultsFixture {
    let suiteName: String
    let defaults: UserDefaults

    init() throws {
        suiteName = "SwiftClawTests-EmailStorage-\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}
