import Foundation
import Testing
@testable import SwiftClaw

struct WorkspaceCalendarSummaryTests {
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    // A fixed "now": 2026-06-10 12:00 UTC.
    private static let now = makeDate(2026, 6, 10, 12)

    private static func makeDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private static func occurrence(
        _ title: String,
        start: Date,
        durationHours: Double = 1,
        isAllDay: Bool = false
    ) -> EventOccurrence {
        EventOccurrence(
            eventID: UUID(),
            calendarID: nil,
            title: title,
            start: start,
            end: start.addingTimeInterval(durationHours * 3600),
            isAllDay: isAllDay,
            colorHex: "#0A84FF",
            source: .native,
            isOverride: false
        )
    }

    @Test func countsTodayTomorrowAndWeek() {
        let summary = WorkspaceCalendarSummary(
            occurrences: [
                Self.occurrence("Ended this morning", start: Self.makeDate(2026, 6, 10, 8)),
                Self.occurrence("This afternoon", start: Self.makeDate(2026, 6, 10, 15)),
                Self.occurrence("All-day today", start: Self.makeDate(2026, 6, 10), durationHours: 24, isAllDay: true),
                Self.occurrence("Tomorrow", start: Self.makeDate(2026, 6, 11, 9)),
                Self.occurrence("Weekend", start: Self.makeDate(2026, 6, 13, 10)),
            ],
            now: Self.now,
            calendar: Self.calendar
        )
        // "Ended this morning" is done; the all-day event still counts.
        #expect(summary.todayRemainingCount == 2)
        #expect(summary.tomorrowCount == 1)
        #expect(summary.weekCount == 5)
    }

    @Test func nextEventSkipsAllDayAndEndedEvents() {
        let summary = WorkspaceCalendarSummary(
            occurrences: [
                Self.occurrence("All-day today", start: Self.makeDate(2026, 6, 10), durationHours: 24, isAllDay: true),
                Self.occurrence("Ended", start: Self.makeDate(2026, 6, 10, 8)),
                Self.occurrence("Up next", start: Self.makeDate(2026, 6, 10, 15)),
                Self.occurrence("Later", start: Self.makeDate(2026, 6, 11, 9)),
            ],
            now: Self.now,
            calendar: Self.calendar
        )
        #expect(summary.nextEvent?.title == "Up next")
    }

    @Test func inProgressEventIsStillNext() {
        let summary = WorkspaceCalendarSummary(
            occurrences: [
                Self.occurrence("Happening now", start: Self.makeDate(2026, 6, 10, 11), durationHours: 2),
            ],
            now: Self.now,
            calendar: Self.calendar
        )
        #expect(summary.nextEvent?.title == "Happening now")
    }

    @Test func emptyScheduleYieldsZeroes() {
        let summary = WorkspaceCalendarSummary(occurrences: [], now: Self.now, calendar: Self.calendar)
        #expect(summary.todayRemainingCount == 0)
        #expect(summary.tomorrowCount == 0)
        #expect(summary.weekCount == 0)
        #expect(summary.nextEvent == nil)
    }
}
