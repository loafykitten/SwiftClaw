import Foundation
import Testing
@testable import SwiftClaw

struct CalendarMonthMathTests {
    private static func calendar(firstWeekday: Int = 1, timeZone: String = "UTC") -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone)!
        calendar.firstWeekday = firstWeekday
        return calendar
    }

    private static func date(_ year: Int, _ month: Int, _ day: Int, calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    @Test func gridCoversFullWeeksAroundTheMonth() {
        let calendar = Self.calendar() // Sunday-first
        // June 2026: June 1 is a Monday, June 30 a Tuesday → grid runs
        // Sun May 31 through Sat Jul 4 = 35 cells.
        let days = CalendarMonthMath.gridDays(
            forMonthContaining: Self.date(2026, 6, 15, calendar: calendar),
            today: Self.date(2026, 6, 15, calendar: calendar),
            calendar: calendar
        )
        #expect(days.count == 35)
        #expect(days.first?.date == Self.date(2026, 5, 31, calendar: calendar))
        #expect(days.last?.date == Self.date(2026, 7, 4, calendar: calendar))
        #expect(days.count(where: \.isInMonth) == 30)
    }

    @Test func gridRespectsMondayFirstWeekday() {
        let calendar = Self.calendar(firstWeekday: 2)
        // Monday-first June 2026 grid starts on June 1 itself (a Monday).
        let days = CalendarMonthMath.gridDays(
            forMonthContaining: Self.date(2026, 6, 15, calendar: calendar),
            today: Self.date(2026, 6, 15, calendar: calendar),
            calendar: calendar
        )
        #expect(days.first?.date == Self.date(2026, 6, 1, calendar: calendar))
        #expect(days.count == 35)
    }

    @Test func sixWeekMonthProduces42Cells() {
        let calendar = Self.calendar() // Sunday-first
        // August 2026: Aug 1 is a Saturday, Aug 31 a Monday → 6 rows.
        let days = CalendarMonthMath.gridDays(
            forMonthContaining: Self.date(2026, 8, 10, calendar: calendar),
            today: Self.date(2026, 8, 10, calendar: calendar),
            calendar: calendar
        )
        #expect(days.count == 42)
    }

    @Test func leapFebruaryStaysAligned() {
        let calendar = Self.calendar()
        let days = CalendarMonthMath.gridDays(
            forMonthContaining: Self.date(2028, 2, 10, calendar: calendar),
            today: Self.date(2026, 6, 15, calendar: calendar),
            calendar: calendar
        )
        #expect(days.count % 7 == 0)
        #expect(days.count(where: \.isInMonth) == 29)
        #expect(days.allSatisfy { !$0.isToday })
    }

    @Test func todayIsMarked() {
        let calendar = Self.calendar()
        let today = Self.date(2026, 6, 15, calendar: calendar)
        let days = CalendarMonthMath.gridDays(
            forMonthContaining: today,
            today: today,
            calendar: calendar
        )
        #expect(days.count(where: \.isToday) == 1)
        #expect(days.first(where: \.isToday)?.date == today)
    }

    @Test func coveredDayStartsSpansEveryTouchedDay() {
        let calendar = Self.calendar()
        // Three-day all-day span (exclusive end): 10th, 11th, 12th — the
        // midnight end must NOT add the 13th.
        let days = CalendarMonthMath.coveredDayStarts(
            from: Self.date(2026, 6, 10, calendar: calendar),
            to: Self.date(2026, 6, 13, calendar: calendar),
            calendar: calendar
        )
        #expect(days == [
            Self.date(2026, 6, 10, calendar: calendar),
            Self.date(2026, 6, 11, calendar: calendar),
            Self.date(2026, 6, 12, calendar: calendar),
        ])
    }

    @Test func coveredDayStartsIncludesPartialLastDay() {
        let calendar = Self.calendar()
        // Timed event 22:00 June 10 → 02:00 June 11 touches both days.
        let start = calendar.date(
            from: DateComponents(year: 2026, month: 6, day: 10, hour: 22)
        )!
        let days = CalendarMonthMath.coveredDayStarts(
            from: start,
            to: start.addingTimeInterval(4 * 3600),
            calendar: calendar
        )
        #expect(days == [
            Self.date(2026, 6, 10, calendar: calendar),
            Self.date(2026, 6, 11, calendar: calendar),
        ])
    }

    @Test func coveredDayStartsHandlesZeroDuration() {
        let calendar = Self.calendar()
        let start = Self.date(2026, 6, 10, calendar: calendar)
        #expect(CalendarMonthMath.coveredDayStarts(from: start, to: start, calendar: calendar) == [start])
    }

    @Test func weekdaySymbolsRotateWithFirstWeekday() {
        let sundayFirst = CalendarMonthMath.orderedWeekdaySymbols(calendar: Self.calendar(firstWeekday: 1))
        let mondayFirst = CalendarMonthMath.orderedWeekdaySymbols(calendar: Self.calendar(firstWeekday: 2))
        #expect(sundayFirst.count == 7)
        #expect(mondayFirst.first == sundayFirst[1])
        #expect(mondayFirst.last == sundayFirst.first)
    }
}
