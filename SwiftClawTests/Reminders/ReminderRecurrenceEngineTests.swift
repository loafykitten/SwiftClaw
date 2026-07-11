import Foundation
@testable import SwiftClaw
import Testing

struct ReminderRecurrenceEngineTests {
    private static let utc = TimeZone(identifier: "UTC")!
    private static let newYork = TimeZone(identifier: "America/New_York")!

    private static func date(
        _ year: Int, _ month: Int, _ day: Int,
        _ hour: Int = 0, _ minute: Int = 0,
        tz: TimeZone = utc
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tz
        return calendar.date(
            from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
        )!
    }

    private static func calendar(tz: TimeZone = utc) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tz
        return calendar
    }

    @Test func weeklyFridayEarlyCompletionReturnsNextScheduledFriday() {
        let result = ReminderRecurrenceEngine.nextDueDate(
            afterScheduled: Self.date(2026, 6, 5, 9),
            ruleString: "FREQ=WEEKLY;BYDAY=FR",
            timeZone: Self.utc
        )
        #expect(result.nextDueDate == Self.date(2026, 6, 12, 9))
        #expect(result.updatedRuleString == "FREQ=WEEKLY;BYDAY=FR")
    }

    @Test func monthlyByMonthDaySkipsShortMonthsLikeCalendarExpander() {
        let result = ReminderRecurrenceEngine.nextDueDate(
            afterScheduled: Self.date(2026, 1, 31, 12),
            ruleString: "FREQ=MONTHLY;BYMONTHDAY=31",
            timeZone: Self.utc
        )
        #expect(result.nextDueDate == Self.date(2026, 3, 31, 12))
    }

    @Test func biweeklyRulePreservesPhaseFromScheduledOccurrence() {
        let result = ReminderRecurrenceEngine.nextDueDate(
            afterScheduled: Self.date(2026, 1, 2, 9),
            ruleString: "FREQ=WEEKLY;INTERVAL=2;BYDAY=FR",
            timeZone: Self.utc
        )
        #expect(result.nextDueDate == Self.date(2026, 1, 16, 9))
    }

    @Test func countOneExhaustsSeries() {
        let result = ReminderRecurrenceEngine.nextDueDate(
            afterScheduled: Self.date(2026, 6, 5, 9),
            ruleString: "FREQ=WEEKLY;BYDAY=FR;COUNT=1",
            timeZone: Self.utc
        )
        #expect(result.nextDueDate == nil)
        #expect(result.updatedRuleString == "FREQ=WEEKLY;BYDAY=FR;COUNT=1")
    }

    @Test func countDecrementsWhenAnotherOccurrenceExists() {
        let result = ReminderRecurrenceEngine.nextDueDate(
            afterScheduled: Self.date(2026, 6, 5, 9),
            ruleString: "FREQ=WEEKLY;BYDAY=FR;COUNT=3",
            timeZone: Self.utc
        )
        #expect(result.nextDueDate == Self.date(2026, 6, 12, 9))
        #expect(result.updatedRuleString == "FREQ=WEEKLY;BYDAY=FR;COUNT=2")
    }

    @Test func countTwoYieldsExactlyOneFinalOccurrence() {
        let result = ReminderRecurrenceEngine.nextDueDate(
            afterScheduled: Self.date(2026, 6, 5, 9),
            ruleString: "FREQ=WEEKLY;BYDAY=FR;COUNT=2",
            timeZone: Self.utc
        )
        #expect(result.nextDueDate == Self.date(2026, 6, 12, 9))
        #expect(result.updatedRuleString == "FREQ=WEEKLY;BYDAY=FR;COUNT=1")
    }

    @Test func untilInPastReturnsNil() {
        let result = ReminderRecurrenceEngine.nextDueDate(
            afterScheduled: Self.date(2026, 6, 5, 9),
            ruleString: "FREQ=WEEKLY;BYDAY=FR;UNTIL=20260604T090000Z",
            timeZone: Self.utc
        )
        #expect(result.nextDueDate == nil)
    }

    @Test func afterCompletionMonthEndUsesCalendarMath() {
        let next = ReminderRecurrenceEngine.nextDueDate(
            afterCompletion: Self.date(2026, 1, 31, 10),
            repeat: ReminderAfterCompletionRepeat(count: 1, unit: .month),
            hasDueTime: true,
            calendar: Self.calendar()
        )
        #expect(next == Self.date(2026, 2, 28, 10))
    }

    @Test func afterCompletionWeekAcrossDSTKeepsWallClock() {
        let calendar = Self.calendar(tz: Self.newYork)
        let next = ReminderRecurrenceEngine.nextDueDate(
            afterCompletion: Self.date(2026, 3, 7, 9, tz: Self.newYork),
            repeat: ReminderAfterCompletionRepeat(count: 1, unit: .week),
            hasDueTime: true,
            calendar: calendar
        )
        #expect(next == Self.date(2026, 3, 14, 9, tz: Self.newYork))
        #expect(calendar.component(.hour, from: next) == 9)
    }

    @Test func afterCompletionDateOnlyNormalizesToStartOfDay() {
        let next = ReminderRecurrenceEngine.nextDueDate(
            afterCompletion: Self.date(2026, 6, 5, 15),
            repeat: ReminderAfterCompletionRepeat(count: 1, unit: .day),
            hasDueTime: false,
            calendar: Self.calendar()
        )
        #expect(next == Self.date(2026, 6, 6))
    }
}
