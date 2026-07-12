import Foundation
import Testing
@testable import SwiftClaw

struct WorkspaceRemindersSummaryTests {
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    // A fixed "now": 2026-06-10 12:00 UTC.
    private static let now = date(2026, 6, 10, 12)

    private static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private static func summary(_ reminders: [Reminder]) -> WorkspaceRemindersSummary {
        WorkspaceRemindersSummary(reminders: reminders, now: now, calendar: calendar)
    }

    @Test func countsTodayOverdueWeekAndFlagged() {
        let overdueYesterday = Reminder(title: "Yesterday", dueDate: Self.date(2026, 6, 9, 9), hasDueTime: true)
        let overdueEarlierToday = Reminder(title: "Missed", dueDate: Self.date(2026, 6, 10, 10), hasDueTime: true)
        let todayDateOnly = Reminder(title: "Anytime", dueDate: Self.date(2026, 6, 10))
        let laterToday = Reminder(title: "Later", dueDate: Self.date(2026, 6, 10, 18), hasDueTime: true)
        let thisWeek = Reminder(title: "Sunday", dueDate: Self.date(2026, 6, 14, 9), hasDueTime: true)
        let beyondWeek = Reminder(title: "Too far", dueDate: Self.date(2026, 6, 17, 9), hasDueTime: true)
        let flaggedUndated = Reminder(title: "Flagged", isFlagged: true)
        let completedToday = Reminder(
            title: "Done",
            dueDate: Self.date(2026, 6, 10, 8),
            hasDueTime: true,
            completedAt: Self.date(2026, 6, 10, 8)
        )
        let completionLog = Reminder(title: "History", dueDate: Self.date(2026, 6, 10))
        completionLog.parentReminderID = UUID()

        let summary = Self.summary([
            overdueYesterday, overdueEarlierToday, todayDateOnly, laterToday,
            thisWeek, beyondWeek, flaggedUndated, completedToday, completionLog,
        ])

        // Today matches the Today smart list: everything due before the end
        // of today, overdue included.
        #expect(summary.todayCount == 4)
        #expect(summary.overdueCount == 2)
        // The week window starts at today's start, so yesterday's miss is out
        // but earlier today is in; June 17 sits past the 7-day boundary.
        #expect(summary.weekCount == 4)
        #expect(summary.flaggedCount == 1)
    }

    @Test func nextReminderIsSoonestUpcomingTimedDeadline() {
        let dateOnlyToday = Reminder(title: "Anytime", dueDate: Self.date(2026, 6, 10))
        let past = Reminder(title: "Missed", dueDate: Self.date(2026, 6, 10, 9), hasDueTime: true)
        let upNext = Reminder(title: "Up next", dueDate: Self.date(2026, 6, 10, 15), hasDueTime: true)
        let later = Reminder(title: "Later", dueDate: Self.date(2026, 6, 12, 9), hasDueTime: true)

        let summary = Self.summary([dateOnlyToday, past, upNext, later])

        #expect(summary.nextReminder == .init(title: "Up next", due: Self.date(2026, 6, 10, 15)))
    }

    @Test func completedRemindersNeverBecomeNext() {
        let completed = Reminder(
            title: "Done early",
            dueDate: Self.date(2026, 6, 10, 15),
            hasDueTime: true,
            completedAt: Self.now
        )

        #expect(Self.summary([completed]).nextReminder == nil)
    }

    @Test func emptyStoreYieldsZeroes() {
        let summary = Self.summary([])
        #expect(summary.todayCount == 0)
        #expect(summary.overdueCount == 0)
        #expect(summary.weekCount == 0)
        #expect(summary.flaggedCount == 0)
        #expect(summary.nextReminder == nil)
    }
}
