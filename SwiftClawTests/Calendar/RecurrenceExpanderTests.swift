import Foundation
import Testing
@testable import SwiftClaw

struct RecurrenceExpanderTests {
    private static let utc = TimeZone(identifier: "UTC")!
    private static let losAngeles = TimeZone(identifier: "America/Los_Angeles")!

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

    private static func window(_ start: Date, _ end: Date) -> DateInterval {
        DateInterval(start: start, end: end)
    }

    private static func rule(_ rrule: String) -> RecurrenceRule {
        RecurrenceRule(rruleString: rrule)!
    }

    // MARK: - Basics

    @Test func dailyExpandsEveryDayInWindow() {
        let start = Self.date(2026, 6, 1, 9)
        let starts = RecurrenceExpander.occurrenceStarts(
            rule: Self.rule("FREQ=DAILY"),
            eventStart: start,
            duration: 3600,
            window: Self.window(Self.date(2026, 6, 1), Self.date(2026, 6, 5)),
            timeZone: Self.utc
        )
        #expect(starts == [
            Self.date(2026, 6, 1, 9), Self.date(2026, 6, 2, 9),
            Self.date(2026, 6, 3, 9), Self.date(2026, 6, 4, 9),
        ])
    }

    @Test func intervalSkipsPeriods() {
        let starts = RecurrenceExpander.occurrenceStarts(
            rule: Self.rule("FREQ=DAILY;INTERVAL=3"),
            eventStart: Self.date(2026, 6, 1, 9),
            duration: 3600,
            window: Self.window(Self.date(2026, 6, 1), Self.date(2026, 6, 10)),
            timeZone: Self.utc
        )
        #expect(starts == [Self.date(2026, 6, 1, 9), Self.date(2026, 6, 4, 9), Self.date(2026, 6, 7, 9)])
    }

    @Test func weeklyByDayGeneratesEachListedWeekday() {
        // 2026-06-01 is a Monday.
        let starts = RecurrenceExpander.occurrenceStarts(
            rule: Self.rule("FREQ=WEEKLY;BYDAY=MO,WE"),
            eventStart: Self.date(2026, 6, 1, 10),
            duration: 1800,
            window: Self.window(Self.date(2026, 6, 1), Self.date(2026, 6, 15)),
            timeZone: Self.utc
        )
        #expect(starts == [
            Self.date(2026, 6, 1, 10), Self.date(2026, 6, 3, 10),
            Self.date(2026, 6, 8, 10), Self.date(2026, 6, 10, 10),
        ])
    }

    @Test func eventStartIsAlwaysFirstOccurrenceEvenWhenOffPattern() {
        // Starts Wednesday but the rule says Mondays.
        let starts = RecurrenceExpander.occurrenceStarts(
            rule: Self.rule("FREQ=WEEKLY;BYDAY=MO"),
            eventStart: Self.date(2026, 6, 3, 9),
            duration: 3600,
            window: Self.window(Self.date(2026, 6, 1), Self.date(2026, 6, 16)),
            timeZone: Self.utc
        )
        #expect(starts == [
            Self.date(2026, 6, 3, 9),   // the start itself
            Self.date(2026, 6, 8, 9),
            Self.date(2026, 6, 15, 9),
        ])
    }

    // MARK: - DST

    @Test func weeklyKeepsWallClockAcrossSpringForward() {
        // US DST starts 2026-03-08. Weekly Monday 09:00 Pacific.
        let start = Self.date(2026, 3, 2, 9, tz: Self.losAngeles)
        let starts = RecurrenceExpander.occurrenceStarts(
            rule: Self.rule("FREQ=WEEKLY;BYDAY=MO"),
            eventStart: start,
            duration: 3600,
            window: Self.window(
                Self.date(2026, 3, 1, tz: Self.losAngeles),
                Self.date(2026, 3, 16, tz: Self.losAngeles)
            ),
            timeZone: Self.losAngeles
        )
        #expect(starts.count == 2)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.losAngeles
        for occurrence in starts {
            #expect(calendar.component(.hour, from: occurrence) == 9)
        }
        // Across the transition the UTC gap is an hour short of a full week.
        let gap = starts[1].timeIntervalSince(starts[0])
        #expect(gap == 7 * 24 * 3600 - 3600)
    }

    // MARK: - Monthly

    @Test func monthlyByMonthDaySkipsShortMonths() {
        let starts = RecurrenceExpander.occurrenceStarts(
            rule: Self.rule("FREQ=MONTHLY;BYMONTHDAY=31"),
            eventStart: Self.date(2026, 1, 31, 12),
            duration: 3600,
            window: Self.window(Self.date(2026, 1, 1), Self.date(2026, 6, 1)),
            timeZone: Self.utc
        )
        #expect(starts == [
            Self.date(2026, 1, 31, 12), Self.date(2026, 3, 31, 12), Self.date(2026, 5, 31, 12),
        ])
    }

    @Test func monthlyDefaultsToStartDayOfMonth() {
        let starts = RecurrenceExpander.occurrenceStarts(
            rule: Self.rule("FREQ=MONTHLY"),
            eventStart: Self.date(2026, 1, 15, 8),
            duration: 3600,
            window: Self.window(Self.date(2026, 1, 1), Self.date(2026, 4, 1)),
            timeZone: Self.utc
        )
        #expect(starts == [
            Self.date(2026, 1, 15, 8), Self.date(2026, 2, 15, 8), Self.date(2026, 3, 15, 8),
        ])
    }

    @Test func monthlyThirdTuesday() {
        // 3rd Tuesdays: Jan 20, Feb 17, Mar 17 in 2026.
        let starts = RecurrenceExpander.occurrenceStarts(
            rule: Self.rule("FREQ=MONTHLY;BYDAY=3TU"),
            eventStart: Self.date(2026, 1, 20, 14),
            duration: 3600,
            window: Self.window(Self.date(2026, 1, 1), Self.date(2026, 4, 1)),
            timeZone: Self.utc
        )
        #expect(starts == [
            Self.date(2026, 1, 20, 14), Self.date(2026, 2, 17, 14), Self.date(2026, 3, 17, 14),
        ])
    }

    @Test func monthlyLastFriday() {
        // Last Fridays: Jan 30, Feb 27, Mar 27 in 2026.
        let starts = RecurrenceExpander.occurrenceStarts(
            rule: Self.rule("FREQ=MONTHLY;BYDAY=-1FR"),
            eventStart: Self.date(2026, 1, 30, 17),
            duration: 3600,
            window: Self.window(Self.date(2026, 1, 1), Self.date(2026, 4, 1)),
            timeZone: Self.utc
        )
        #expect(starts == [
            Self.date(2026, 1, 30, 17), Self.date(2026, 2, 27, 17), Self.date(2026, 3, 27, 17),
        ])
    }

    @Test func setPositionSelectsLastWeekdayOfMonth() {
        // Last weekday: Jan 30 (Fri), Feb 27 (Fri), Mar 31 (Tue) in 2026.
        let starts = RecurrenceExpander.occurrenceStarts(
            rule: Self.rule("FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1"),
            eventStart: Self.date(2026, 1, 30, 9),
            duration: 3600,
            window: Self.window(Self.date(2026, 1, 1), Self.date(2026, 4, 1)),
            timeZone: Self.utc
        )
        #expect(starts == [
            Self.date(2026, 1, 30, 9), Self.date(2026, 2, 27, 9), Self.date(2026, 3, 31, 9),
        ])
    }

    // MARK: - Yearly

    @Test func yearlyOnLeapDayOnlyLandsOnLeapYears() {
        let starts = RecurrenceExpander.occurrenceStarts(
            rule: Self.rule("FREQ=YEARLY"),
            eventStart: Self.date(2024, 2, 29, 12),
            duration: 3600,
            window: Self.window(Self.date(2025, 1, 1), Self.date(2029, 1, 1)),
            timeZone: Self.utc
        )
        #expect(starts == [Self.date(2028, 2, 29, 12)])
    }

    @Test func yearlyByMonthRepeatsInEachListedMonth() {
        let starts = RecurrenceExpander.occurrenceStarts(
            rule: Self.rule("FREQ=YEARLY;BYMONTH=3,9"),
            eventStart: Self.date(2026, 3, 10, 10),
            duration: 3600,
            window: Self.window(Self.date(2026, 1, 1), Self.date(2027, 12, 31)),
            timeZone: Self.utc
        )
        #expect(starts == [
            Self.date(2026, 3, 10, 10), Self.date(2026, 9, 10, 10),
            Self.date(2027, 3, 10, 10), Self.date(2027, 9, 10, 10),
        ])
    }

    // MARK: - Ends and exceptions

    @Test func countBoundsTotalGeneratedInstances() {
        let starts = RecurrenceExpander.occurrenceStarts(
            rule: Self.rule("FREQ=DAILY;COUNT=5"),
            eventStart: Self.date(2026, 6, 1, 9),
            duration: 3600,
            window: Self.window(Self.date(2026, 5, 1), Self.date(2026, 7, 1)),
            timeZone: Self.utc
        )
        #expect(starts.count == 5)
        #expect(starts.last == Self.date(2026, 6, 5, 9))
    }

    @Test func exceptionDatesDoNotExtendACountedSeries() {
        // COUNT counts generated instances before EXDATE removal, so removing
        // one occurrence shrinks the visible set rather than shifting its end.
        let starts = RecurrenceExpander.occurrenceStarts(
            rule: Self.rule("FREQ=DAILY;COUNT=5"),
            eventStart: Self.date(2026, 6, 1, 9),
            duration: 3600,
            window: Self.window(Self.date(2026, 5, 1), Self.date(2026, 7, 1)),
            exceptionDates: [Self.date(2026, 6, 3, 9)],
            timeZone: Self.utc
        )
        #expect(starts == [
            Self.date(2026, 6, 1, 9), Self.date(2026, 6, 2, 9),
            Self.date(2026, 6, 4, 9), Self.date(2026, 6, 5, 9),
        ])
    }

    @Test func untilIsInclusive() {
        let starts = RecurrenceExpander.occurrenceStarts(
            rule: Self.rule("FREQ=WEEKLY;UNTIL=20260615T090000Z"),
            eventStart: Self.date(2026, 6, 1, 9),
            duration: 3600,
            window: Self.window(Self.date(2026, 5, 1), Self.date(2026, 8, 1)),
            timeZone: Self.utc
        )
        #expect(starts == [
            Self.date(2026, 6, 1, 9), Self.date(2026, 6, 8, 9), Self.date(2026, 6, 15, 9),
        ])
    }

    // MARK: - Window semantics

    @Test func occurrenceOverlappingWindowStartByDurationIsIncluded() {
        // 23:00–01:00 event: the June 1 23:00 instance spills into June 2.
        let starts = RecurrenceExpander.occurrenceStarts(
            rule: Self.rule("FREQ=DAILY"),
            eventStart: Self.date(2026, 6, 1, 23),
            duration: 2 * 3600,
            window: Self.window(Self.date(2026, 6, 2), Self.date(2026, 6, 3)),
            timeZone: Self.utc
        )
        #expect(starts == [Self.date(2026, 6, 1, 23), Self.date(2026, 6, 2, 23)])
    }

    @Test func fastForwardMatchesFullIterationForOldSeries() {
        // A years-old series windowed far in the future must produce dates on
        // the same 3-day lattice a from-the-start iteration would.
        let eventStart = Self.date(2020, 1, 1, 6)
        let starts = RecurrenceExpander.occurrenceStarts(
            rule: Self.rule("FREQ=DAILY;INTERVAL=3"),
            eventStart: eventStart,
            duration: 3600,
            window: Self.window(Self.date(2026, 6, 1), Self.date(2026, 6, 10)),
            timeZone: Self.utc
        )
        #expect(!starts.isEmpty)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.utc
        for occurrence in starts {
            let days = calendar.dateComponents([.day], from: eventStart, to: occurrence).day!
            #expect(days % 3 == 0)
            #expect(calendar.component(.hour, from: occurrence) == 6)
        }
    }

    @Test func emptyWindowBeforeSeriesYieldsNothing() {
        let starts = RecurrenceExpander.occurrenceStarts(
            rule: Self.rule("FREQ=DAILY"),
            eventStart: Self.date(2026, 6, 1, 9),
            duration: 3600,
            window: Self.window(Self.date(2026, 1, 1), Self.date(2026, 2, 1)),
            timeZone: Self.utc
        )
        #expect(starts.isEmpty)
    }

    @Test func expansionIsCappedForRunawayWindows() {
        let starts = RecurrenceExpander.occurrenceStarts(
            rule: Self.rule("FREQ=DAILY"),
            eventStart: Self.date(2020, 1, 1, 9),
            duration: 3600,
            window: Self.window(Self.date(2020, 1, 1), Self.date(2035, 1, 1)),
            timeZone: Self.utc
        )
        #expect(starts.count == RecurrenceExpander.occurrenceCap)
    }

    @Test func explicitCapOverridesTheDefault() {
        // Import reconciliation must enumerate multi-year windows fully — a
        // 4-year daily series (~1,461 occurrences) overflows the default cap.
        let starts = RecurrenceExpander.occurrenceStarts(
            rule: Self.rule("FREQ=DAILY"),
            eventStart: Self.date(2020, 1, 1, 9),
            duration: 3600,
            window: Self.window(Self.date(2020, 1, 1), Self.date(2024, 1, 1)),
            timeZone: Self.utc,
            cap: 10_000
        )
        #expect(starts.count == 1461) // 2020 is a leap year.
    }

    @Test func monthlyByMonthDayCombinedWithByDayIsALimit() {
        // RFC 5545 first-Monday idiom: BYDAY *limits* the BYMONTHDAY set.
        // June 2026: the 1st is a Monday; July 2026: the 6th; August: the 3rd.
        let starts = RecurrenceExpander.occurrenceStarts(
            rule: Self.rule("FREQ=MONTHLY;BYMONTHDAY=1,2,3,4,5,6,7;BYDAY=MO"),
            eventStart: Self.date(2026, 6, 1, 9),
            duration: 3600,
            window: Self.window(Self.date(2026, 6, 1), Self.date(2026, 9, 1)),
            timeZone: Self.utc
        )
        #expect(starts == [
            Self.date(2026, 6, 1, 9),
            Self.date(2026, 7, 6, 9),
            Self.date(2026, 8, 3, 9),
        ])
    }

    // MARK: - BY-part combinations (RFC 5545 §3.3.10)

    @Test func dailyByMonthDayLimitsToThatDay() {
        let starts = RecurrenceExpander.occurrenceStarts(
            rule: Self.rule("FREQ=DAILY;BYMONTHDAY=1"),
            eventStart: Self.date(2026, 6, 1, 9),
            duration: 3600,
            window: Self.window(Self.date(2026, 6, 1), Self.date(2026, 9, 2)),
            timeZone: Self.utc
        )
        #expect(starts == [
            Self.date(2026, 6, 1, 9), Self.date(2026, 7, 1, 9),
            Self.date(2026, 8, 1, 9), Self.date(2026, 9, 1, 9),
        ])
    }

    @Test func dailyNegativeByMonthDayCountsFromMonthEnd() {
        let starts = RecurrenceExpander.occurrenceStarts(
            rule: Self.rule("FREQ=DAILY;BYMONTHDAY=-1"),
            eventStart: Self.date(2026, 6, 30, 9),
            duration: 3600,
            window: Self.window(Self.date(2026, 6, 1), Self.date(2026, 9, 1)),
            timeZone: Self.utc
        )
        #expect(starts == [Self.date(2026, 6, 30, 9), Self.date(2026, 7, 31, 9), Self.date(2026, 8, 31, 9)])
    }

    /// YEARLY BYDAY without BYMONTH covers the whole year, not DTSTART's month.
    @Test func yearlyByDayWithoutByMonthSpansTheYear() {
        // 2026-01-05 is a Monday.
        let starts = RecurrenceExpander.occurrenceStarts(
            rule: Self.rule("FREQ=YEARLY;BYDAY=MO"),
            eventStart: Self.date(2026, 1, 5, 9),
            duration: 3600,
            window: Self.window(Self.date(2026, 3, 1), Self.date(2026, 4, 1)),
            timeZone: Self.utc
        )
        #expect(starts == [
            Self.date(2026, 3, 2, 9), Self.date(2026, 3, 9, 9), Self.date(2026, 3, 16, 9),
            Self.date(2026, 3, 23, 9), Self.date(2026, 3, 30, 9),
        ])
    }

    @Test func yearlyByDayOrdinalsCountWithinTheYear() {
        let twentieth = RecurrenceExpander.occurrenceStarts(
            rule: Self.rule("FREQ=YEARLY;BYDAY=20MO"),
            eventStart: Self.date(2026, 1, 5, 9),
            duration: 3600,
            window: Self.window(Self.date(2026, 1, 6), Self.date(2028, 1, 1)),
            timeZone: Self.utc
        )
        #expect(twentieth == [Self.date(2026, 5, 18, 9), Self.date(2027, 5, 17, 9)])

        let lastFriday = RecurrenceExpander.occurrenceStarts(
            rule: Self.rule("FREQ=YEARLY;BYDAY=-1FR"),
            eventStart: Self.date(2026, 1, 2, 9),
            duration: 3600,
            window: Self.window(Self.date(2026, 1, 3), Self.date(2027, 1, 1)),
            timeZone: Self.utc
        )
        #expect(lastFriday == [Self.date(2026, 12, 25, 9)])
    }

    @Test func yearlyByMonthDayWithoutByMonthCoversEveryMonth() {
        let starts = RecurrenceExpander.occurrenceStarts(
            rule: Self.rule("FREQ=YEARLY;BYMONTHDAY=15"),
            eventStart: Self.date(2026, 1, 15, 9),
            duration: 3600,
            window: Self.window(Self.date(2026, 1, 1), Self.date(2026, 4, 1)),
            timeZone: Self.utc
        )
        #expect(starts == [Self.date(2026, 1, 15, 9), Self.date(2026, 2, 15, 9), Self.date(2026, 3, 15, 9)])
    }

    /// A hand-built rule bypasses the parser's INTERVAL cap; period
    /// arithmetic must stop instead of trapping on overflow.
    @Test(arguments: RecurrenceRule.Frequency.allCases)
    func hugeIntervalEndsExpansionWithoutTrapping(frequency: RecurrenceRule.Frequency) {
        let start = Self.date(2026, 6, 1, 9)
        let starts = RecurrenceExpander.occurrenceStarts(
            rule: RecurrenceRule(frequency: frequency, interval: .max),
            eventStart: start,
            duration: 3600,
            window: Self.window(Self.date(2026, 1, 1), Self.date(2030, 1, 1)),
            timeZone: Self.utc
        )
        #expect(starts == [start])
    }
}
