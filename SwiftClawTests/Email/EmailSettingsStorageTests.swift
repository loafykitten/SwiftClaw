import Foundation
import Testing
@testable import SwiftClaw

struct EmailSettingsStorageTests {
    @Test func emailEnablementDefaultsOffAndReadsTheStoredChoice() throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }

        #expect(!SettingsStorage.isEmailEnabled(userDefaults: fixture.defaults))
        fixture.defaults.set(true, forKey: SettingsKeys.emailEnabled)
        #expect(SettingsStorage.isEmailEnabled(userDefaults: fixture.defaults))
    }

    @Test func intervalLoadersUseDefaultsAndClampPersistedPollValues() throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }

        #expect(
            SettingsStorage.loadEmailPollInterval(userDefaults: fixture.defaults)
                == SettingsStorage.defaultEmailPollIntervalSeconds
        )
        #expect(
            SettingsStorage.loadEmailReviewInterval(userDefaults: fixture.defaults)
                == SettingsStorage.defaultEmailReviewIntervalSeconds
        )

        fixture.defaults.set(10, forKey: SettingsKeys.emailPollIntervalSeconds)
        #expect(
            SettingsStorage.loadEmailPollInterval(userDefaults: fixture.defaults)
                == SettingsStorage.emailPollIntervalSecondsRange.lowerBound
        )

        fixture.defaults.set(10_000_000, forKey: SettingsKeys.emailPollIntervalSeconds)
        #expect(
            SettingsStorage.loadEmailPollInterval(userDefaults: fixture.defaults)
                == SettingsStorage.emailPollIntervalSecondsRange.upperBound
        )
    }

    @Test(arguments: [
        (1, 300),
        (420, 300),
        (5_400, 3_600),
        (1_000_000, 86_400),
    ])
    func reviewIntervalLoadsTheNearestOfferedValue(_ stored: Int, _ expected: Int) throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }

        fixture.defaults.set(stored, forKey: SettingsKeys.emailReviewIntervalSeconds)
        #expect(SettingsStorage.loadEmailReviewInterval(userDefaults: fixture.defaults) == expected)
    }

    @Test(arguments: [
        (1, 60),
        (90, 60),
        (250, 300),
        (1_000_000, 3_600),
    ])
    func syncPickerUsesTheNearestOfferedValue(_ stored: Int, _ expected: Int) {
        #expect(SettingsStorage.nearestEmailSyncIntervalSeconds(stored) == expected)
    }

    @Test func intervalOptionLabelsUseMinutesAndHours() {
        #expect(EmailReviewIntervalOption.minutes45.displayName == "45 min")
        #expect(EmailReviewIntervalOption.hour24.displayName == "24 hr")
        #expect(EmailSyncIntervalOption.minute1.displayName == "1 min")
        #expect(EmailSyncIntervalOption.hour1.displayName == "1 hr")
    }

    @Test func reviewFetchDefaultsCanBeOverridden() throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }

        #expect(SettingsStorage.loadEmailReviewFetchDefaults(userDefaults: fixture.defaults).maxAgeDays == nil)

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

    @Test func reviewSlideActionUsesDefaultStoredAndFallbackValues() throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }

        #expect(
            SettingsStorage.loadEmailReviewSlideAction(userDefaults: fixture.defaults)
                == .review
        )

        fixture.defaults.set(EmailReviewSlideAction.delete.rawValue, forKey: SettingsKeys.emailReviewSlideAction)
        #expect(
            SettingsStorage.loadEmailReviewSlideAction(userDefaults: fixture.defaults)
                == .delete
        )

        fixture.defaults.set("archive", forKey: SettingsKeys.emailReviewSlideAction)
        #expect(
            SettingsStorage.loadEmailReviewSlideAction(userDefaults: fixture.defaults)
                == SettingsStorage.defaultEmailReviewSlideAction
        )
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
