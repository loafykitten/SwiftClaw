import Foundation
import Testing
@testable import SwiftClaw

/// Daily review times are wall-clock times, so they must hold on DST
/// transition days (minutes-after-midnight arithmetic drifted by an hour).
struct EmailReviewDailyScheduleTests {
    private static func chicagoCalendar() throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Chicago"))
        return calendar
    }

    private static func date(
        _ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0,
        in calendar: Calendar
    ) throws -> Date {
        try #require(calendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute
        )))
    }

    @Test(arguments: [(3, 8), (11, 1), (6, 15)])
    func nineAMStaysNineAMOnTransitionDays(month: Int, day: Int) throws {
        let calendar = try Self.chicagoCalendar()
        let noon = try Self.date(2026, month, day, in: calendar)
        let review = try #require(SettingsStorage.dailyReviewDate(
            minutesAfterMidnight: 9 * 60,
            onDayContaining: noon,
            calendar: calendar
        ))
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: review)
        #expect(components.year == 2026)
        #expect(components.month == month)
        #expect(components.day == day)
        #expect(components.hour == 9)
        #expect(components.minute == 0)
    }

    @Test func skippedSpringForwardTimeResolvesJustAfterTheGap() throws {
        let calendar = try Self.chicagoCalendar()
        let noon = try Self.date(2026, 3, 8, in: calendar)
        // 02:30 doesn't exist on 2026-03-08 in Chicago (02:00 → 03:00).
        let review = try #require(SettingsStorage.dailyReviewDate(
            minutesAfterMidnight: 2 * 60 + 30,
            onDayContaining: noon,
            calendar: calendar
        ))
        let components = calendar.dateComponents([.day, .hour], from: review)
        #expect(components.day == 8)
        #expect(components.hour == 3)
    }

    @Test func repeatedFallBackTimeUsesTheFirstPass() throws {
        let calendar = try Self.chicagoCalendar()
        let noon = try Self.date(2026, 11, 1, in: calendar)
        // 01:30 happens twice on 2026-11-01 in Chicago; take the CDT one.
        let review = try #require(SettingsStorage.dailyReviewDate(
            minutesAfterMidnight: 90,
            onDayContaining: noon,
            calendar: calendar
        ))
        let midnight = calendar.startOfDay(for: noon)
        #expect(review.timeIntervalSince(midnight) == 90 * 60)
    }

    @Test func nextDailyReviewOnSpringForwardDayIsNineLocal() throws {
        let calendar = try Self.chicagoCalendar()
        let now = try Self.date(2026, 3, 8, 7, 0, in: calendar)
        let lastCompleted = try Self.date(2026, 3, 7, 21, 0, in: calendar)
        let next = SettingsStorage.nextDailyEmailReviewDate(
            now: now,
            lastCompletedAt: lastCompleted,
            times: [9 * 60, 21 * 60],
            calendar: calendar
        )
        let nineAM = try Self.date(2026, 3, 8, 9, 0, in: calendar)
        #expect(next == nineAM)
    }
}
