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

    @Test func reviewIntervalUpperBoundIsTwentyFourHours() throws {
        #expect(SettingsStorage.emailReviewIntervalSecondsRange.upperBound == 86_400)
    }

    @Test func reviewFetchDefaultsUseConfiguredValues() throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }

        fixture.defaults.set(25, forKey: SettingsKeys.emailReviewMaxThreads)
        fixture.defaults.set(true, forKey: SettingsKeys.emailReviewDefaultMaxAgeEnabled)
        fixture.defaults.set(14, forKey: SettingsKeys.emailReviewDefaultMaxAgeDays)
        fixture.defaults.set(false, forKey: SettingsKeys.emailReviewDefaultIncludeRead)
        fixture.defaults.set(true, forKey: SettingsKeys.emailReviewDefaultIncludeArchived)

        let defaults = SettingsStorage.loadEmailReviewFetchDefaults(userDefaults: fixture.defaults)

        #expect(defaults.limit == 25)
        #expect(defaults.maxAgeDays == 14)
        #expect(defaults.includeFlagged)
        #expect(defaults.includeNotated)
        #expect(!defaults.includeRead)
        #expect(defaults.includeUnread)
        #expect(defaults.includeArchived)
        #expect(!defaults.includeTrashed)
    }

    @Test func reviewFetchDefaultsDisableMaxAgeByDefault() throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }

        let defaults = SettingsStorage.loadEmailReviewFetchDefaults(userDefaults: fixture.defaults)

        #expect(defaults.maxAgeDays == nil)
    }

    @Test func intervalReviewScheduleFirstRunUsesDefaultDelay() throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }

        let now = Date(timeIntervalSince1970: 1_800_000)
        let expectedDelay = TimeInterval(max(
            SettingsStorage.emailReviewFirstRunMinimumDelaySeconds,
            SettingsStorage.defaultEmailReviewIntervalSeconds / 4
        ))

        let next = SettingsStorage.nextEmailReviewDate(
            now: now,
            lastCompletedAt: nil,
            userDefaults: fixture.defaults
        )

        #expect(next == now.addingTimeInterval(expectedDelay))
    }

    @Test func intervalReviewScheduleRunsOverdueReviewImmediately() throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }

        fixture.defaults.set(EmailReviewScheduleMode.interval.rawValue, forKey: SettingsKeys.emailReviewScheduleMode)
        let now = Date(timeIntervalSince1970: 1_800_000)
        let lastCompletedAt = now.addingTimeInterval(-TimeInterval(SettingsStorage.defaultEmailReviewIntervalSeconds * 2))

        let next = SettingsStorage.nextEmailReviewDate(
            now: now,
            lastCompletedAt: lastCompletedAt,
            userDefaults: fixture.defaults
        )

        #expect(next <= now)
    }

    @Test func dailyReviewScheduleRunsMissedLocalTimeImmediately() throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }

        fixture.defaults.set(EmailReviewScheduleMode.daily.rawValue, forKey: SettingsKeys.emailReviewScheduleMode)
        SettingsStorage.saveEmailReviewDailyTimes([8 * 60], userDefaults: fixture.defaults)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 6, day: 25, hour: 9)))
        let yesterday = try #require(calendar.date(from: DateComponents(year: 2026, month: 6, day: 24, hour: 12)))

        let next = SettingsStorage.nextEmailReviewDate(
            now: now,
            lastCompletedAt: yesterday,
            userDefaults: fixture.defaults,
            calendar: calendar
        )

        #expect(next == now)
    }

    @Test func dailyReviewScheduleDelaysFirstMissedLocalTimeSoSyncCanLand() throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }

        fixture.defaults.set(EmailReviewScheduleMode.daily.rawValue, forKey: SettingsKeys.emailReviewScheduleMode)
        SettingsStorage.saveEmailReviewDailyTimes([8 * 60], userDefaults: fixture.defaults)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 6, day: 25, hour: 9)))

        let next = SettingsStorage.nextEmailReviewDate(
            now: now,
            lastCompletedAt: nil,
            userDefaults: fixture.defaults,
            calendar: calendar
        )

        #expect(next == now.addingTimeInterval(TimeInterval(SettingsStorage.emailReviewFirstRunMinimumDelaySeconds)))
    }

    @Test func dailyReviewScheduleWaitsForNextConfiguredLocalTime() throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }

        fixture.defaults.set(EmailReviewScheduleMode.daily.rawValue, forKey: SettingsKeys.emailReviewScheduleMode)
        SettingsStorage.saveEmailReviewDailyTimes([8 * 60, 17 * 60], userDefaults: fixture.defaults)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 6, day: 25, hour: 9)))
        let completed = try #require(calendar.date(from: DateComponents(year: 2026, month: 6, day: 25, hour: 8, minute: 5)))
        let expected = try #require(calendar.date(from: DateComponents(year: 2026, month: 6, day: 25, hour: 17)))

        let next = SettingsStorage.nextEmailReviewDate(
            now: now,
            lastCompletedAt: completed,
            userDefaults: fixture.defaults,
            calendar: calendar
        )

        #expect(next == expected)
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
