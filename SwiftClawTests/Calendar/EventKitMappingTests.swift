import EventKit
import Foundation
import Testing
@testable import SwiftClaw

struct EventKitMappingTests {
    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0) -> Date {
        utcCalendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))!
    }

    // MARK: - Recurrence rules

    @Test func mapsBiweeklyByDayRule() throws {
        let ekRule = EKRecurrenceRule(
            recurrenceWith: .weekly,
            interval: 2,
            daysOfTheWeek: [EKRecurrenceDayOfWeek(.monday), EKRecurrenceDayOfWeek(.wednesday)],
            daysOfTheMonth: nil,
            monthsOfTheYear: nil,
            weeksOfTheYear: nil,
            daysOfTheYear: nil,
            setPositions: nil,
            end: nil
        )
        let rule = try #require(EventKitMapping.recurrenceRule(from: ekRule))
        #expect(rule.rruleString == "FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE")
    }

    @Test func mapsThirdTuesdayOrdinal() throws {
        let ekRule = EKRecurrenceRule(
            recurrenceWith: .monthly,
            interval: 1,
            daysOfTheWeek: [EKRecurrenceDayOfWeek(.tuesday, weekNumber: 3)],
            daysOfTheMonth: nil,
            monthsOfTheYear: nil,
            weeksOfTheYear: nil,
            daysOfTheYear: nil,
            setPositions: nil,
            end: nil
        )
        let rule = try #require(EventKitMapping.recurrenceRule(from: ekRule))
        #expect(rule.rruleString == "FREQ=MONTHLY;BYDAY=3TU")
    }

    @Test func mapsCountAndUntilEnds() throws {
        let counted = EKRecurrenceRule(
            recurrenceWith: .daily,
            interval: 1,
            end: EKRecurrenceEnd(occurrenceCount: 10)
        )
        let countedRule = try #require(EventKitMapping.recurrenceRule(from: counted))
        #expect(countedRule.end == .occurrenceCount(10))

        let until = EKRecurrenceRule(
            recurrenceWith: .daily,
            interval: 1,
            end: EKRecurrenceEnd(end: Self.date(2026, 12, 31, 23, 59, 59))
        )
        let untilRule = try #require(EventKitMapping.recurrenceRule(from: until))
        guard case .untilDate(let untilDate) = untilRule.end else {
            Issue.record("expected an UNTIL end")
            return
        }
        #expect(untilDate == Self.date(2026, 12, 31, 23, 59, 59))
    }

    @Test func rejectsDayOfYearRules() {
        let ekRule = EKRecurrenceRule(
            recurrenceWith: .yearly,
            interval: 1,
            daysOfTheWeek: nil,
            daysOfTheMonth: nil,
            monthsOfTheYear: nil,
            weeksOfTheYear: nil,
            daysOfTheYear: [100],
            setPositions: nil,
            end: nil
        )
        #expect(EventKitMapping.recurrenceRule(from: ekRule) == nil)
    }

    // MARK: - All-day normalization

    @Test func normalizesInclusiveAllDayEndToExclusiveMidnight() {
        let calendar = Self.utcCalendar
        let inclusive = Self.date(2026, 6, 11, 23, 59, 59)
        #expect(EventKitMapping.normalizedAllDayEnd(inclusive, calendar: calendar) == Self.date(2026, 6, 12))
        // Already-exclusive midnights pass through.
        let exclusive = Self.date(2026, 6, 12)
        #expect(EventKitMapping.normalizedAllDayEnd(exclusive, calendar: calendar) == exclusive)
    }

    // MARK: - Alarms

    @Test func mapsRelativeAndAbsoluteAlarms() {
        let eventStart = Self.date(2026, 6, 10, 15)
        let relative = EKAlarm(relativeOffset: -900)
        let absolute = EKAlarm(absoluteDate: Self.date(2026, 6, 10, 14))
        let offsets = EventKitMapping.alarmOffsets(from: [relative, absolute], eventStart: eventStart)
        #expect(offsets == [-900, -3600])
    }

    // MARK: - Deleted-occurrence recovery

    @Test func recoversDeletedOccurrencesAsMissingStarts() {
        let masterStart = Self.date(2026, 6, 1, 9)
        let window = DateInterval(start: Self.date(2026, 6, 1), end: Self.date(2026, 6, 30))
        // Mondays June 2026: 1, 8, 15, 22, 29 — the user deleted June 15.
        let actual = [
            Self.date(2026, 6, 1, 9), Self.date(2026, 6, 8, 9),
            Self.date(2026, 6, 22, 9), Self.date(2026, 6, 29, 9),
        ]
        let missing = EventKitMapping.missingOccurrenceStarts(
            rule: RecurrenceRule(rruleString: "FREQ=WEEKLY;BYDAY=MO")!,
            masterStart: masterStart,
            duration: 3600,
            window: window,
            actualStarts: actual,
            timeZone: TimeZone(identifier: "UTC")
        )
        #expect(missing == [Self.date(2026, 6, 15, 9)])
    }

    // MARK: - Colors

    @Test func convertsCGColorToHex() {
        let red = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        #expect(EventKitMapping.colorHex(from: red) == "#FF0000")
        #expect(EventKitMapping.colorHex(from: nil) == UserCalendar.defaultColorHex)
    }

    // MARK: - Windowed re-import reconciliation

    /// A second import over a later window must not resurrect occurrences
    /// deleted before that window: only EXDATEs inside the fetched window
    /// are rebuilt.
    @Test func reimportKeepsExceptionDatesOutsideTheFetchedWindow() {
        let earlyDeletion = Self.date(2025, 3, 3, 9)    // before the new window
        let staleInWindow = Self.date(2026, 6, 8, 9)    // restored in Apple Calendar
        let laterDeletion = Self.date(2031, 1, 6, 9)    // after the new window
        let window = DateInterval(start: Self.date(2026, 1, 1), end: Self.date(2027, 1, 1))

        let reconciled = EventKitMapping.reconciledExceptionDates(
            existing: [earlyDeletion, staleInWindow, laterDeletion],
            missing: [Self.date(2026, 6, 15, 9)],
            detachedOriginalStarts: [Self.date(2026, 6, 22, 9), Self.date(2026, 6, 15, 9)],
            duration: 3600,
            window: window
        )
        #expect(reconciled == [
            earlyDeletion, Self.date(2026, 6, 15, 9), Self.date(2026, 6, 22, 9), laterDeletion,
        ])
    }

    @Test func staleOverrideIsProvableOnlyInsideTheFetchedWindow() {
        let window = DateInterval(start: Self.date(2026, 1, 1), end: Self.date(2027, 1, 1))

        // Original outside the window: the fetch can't see it, keep.
        #expect(!EventKitMapping.isStaleImportedOverride(
            originalStart: Self.date(2025, 6, 2, 9),
            overrideStart: Self.date(2025, 6, 2, 11),
            overrideDuration: 3600,
            masterDuration: 3600,
            window: window,
            actualStarts: []
        ))
        // Reverted edit: the plain occurrence came back, drop.
        #expect(EventKitMapping.isStaleImportedOverride(
            originalStart: Self.date(2026, 6, 1, 9),
            overrideStart: Self.date(2026, 6, 1, 11),
            overrideDuration: 3600,
            masterDuration: 3600,
            window: window,
            actualStarts: [Self.date(2026, 6, 1, 9)]
        ))
        // Override sat in the window but wasn't returned: deleted, drop.
        #expect(EventKitMapping.isStaleImportedOverride(
            originalStart: Self.date(2026, 6, 1, 9),
            overrideStart: Self.date(2026, 6, 1, 11),
            overrideDuration: 3600,
            masterDuration: 3600,
            window: window,
            actualStarts: []
        ))
        // Moved out of the window: may still exist, keep.
        #expect(!EventKitMapping.isStaleImportedOverride(
            originalStart: Self.date(2026, 12, 31, 9),
            overrideStart: Self.date(2027, 2, 1, 9),
            overrideDuration: 3600,
            masterDuration: 3600,
            window: window,
            actualStarts: []
        ))
    }
}
