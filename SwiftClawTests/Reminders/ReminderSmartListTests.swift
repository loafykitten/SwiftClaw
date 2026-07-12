import Foundation
@testable import SwiftClaw
import Testing

@MainActor
struct ReminderSmartListTests {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    /// Noon on a fixed day so "today" boundaries are deterministic.
    private static let now = date(2026, 6, 10, 12)

    @Test func todayIncludesOverdueAndDueTodayIncludingDateOnly() {
        let overdue = Reminder(title: "Overdue", dueDate: Self.date(2026, 6, 1, 9), hasDueTime: true)
        let dueTodayTimed = Reminder(title: "Timed", dueDate: Self.date(2026, 6, 10, 18), hasDueTime: true)
        let dueTodayDateOnly = Reminder(title: "Date-only", dueDate: Self.date(2026, 6, 10))
        let tomorrow = Reminder(title: "Tomorrow", dueDate: Self.date(2026, 6, 11))
        let inboxItem = Reminder(title: "No date")

        let today = ReminderSmartList.today
        #expect(today.contains(overdue, now: Self.now, calendar: Self.calendar))
        #expect(today.contains(dueTodayTimed, now: Self.now, calendar: Self.calendar))
        #expect(today.contains(dueTodayDateOnly, now: Self.now, calendar: Self.calendar))
        #expect(!today.contains(tomorrow, now: Self.now, calendar: Self.calendar))
        #expect(!today.contains(inboxItem, now: Self.now, calendar: Self.calendar))
    }

    @Test func scheduledExcludesUndatedAndCompleted() {
        let dated = Reminder(title: "Dated", dueDate: Self.date(2026, 7, 1))
        let undated = Reminder(title: "Undated")
        let done = Reminder(title: "Done", dueDate: Self.date(2026, 7, 1), completedAt: Self.now)

        let scheduled = ReminderSmartList.scheduled
        #expect(scheduled.contains(dated, now: Self.now, calendar: Self.calendar))
        #expect(!scheduled.contains(undated, now: Self.now, calendar: Self.calendar))
        #expect(!scheduled.contains(done, now: Self.now, calendar: Self.calendar))
    }

    @Test func inboxIsPendingWithoutDueDate() {
        let undated = Reminder(title: "Undated")
        let dated = Reminder(title: "Dated", dueDate: Self.date(2026, 7, 1))

        #expect(ReminderSmartList.inbox.contains(undated, now: Self.now, calendar: Self.calendar))
        #expect(!ReminderSmartList.inbox.contains(dated, now: Self.now, calendar: Self.calendar))
    }

    @Test func completedIncludesLogRowsAndCompletedOneOffs() {
        let doneOneOff = Reminder(title: "Done", completedAt: Self.now)
        let log = Reminder(title: "Weekly done", completedAt: Self.now)
        log.parentReminderID = UUID()
        let pending = Reminder(title: "Pending")

        let completed = ReminderSmartList.completed
        #expect(completed.contains(doneOneOff, now: Self.now, calendar: Self.calendar))
        #expect(completed.contains(log, now: Self.now, calendar: Self.calendar))
        #expect(!completed.contains(pending, now: Self.now, calendar: Self.calendar))
    }

    @Test func logRowsNeverSurfaceInPendingViews() {
        // A pathological log row without completedAt still must not surface.
        let strayLog = Reminder(title: "Stray log", dueDate: Self.date(2026, 6, 10))
        strayLog.parentReminderID = UUID()

        for smart in ReminderSmartList.allCases where smart != .completed {
            #expect(!smart.contains(strayLog, now: Self.now, calendar: Self.calendar))
        }
    }

    @Test func flaggedIsPendingOnly() {
        let flagged = Reminder(title: "Flagged", isFlagged: true)
        let flaggedDone = Reminder(title: "Flagged done", isFlagged: true, completedAt: Self.now)

        #expect(ReminderSmartList.flagged.contains(flagged, now: Self.now, calendar: Self.calendar))
        #expect(!ReminderSmartList.flagged.contains(flaggedDone, now: Self.now, calendar: Self.calendar))
    }

    @Test func listSelectionAvailabilityTracksVisibleLists() {
        let visibleID = UUID()
        let hiddenID = UUID()
        let visibleIDs: Set<UUID> = [visibleID]

        #expect(ReminderListDetailView.Selection.smart(.today).isAvailable(visibleListIDs: visibleIDs))
        #expect(ReminderListDetailView.Selection.list(visibleID).isAvailable(visibleListIDs: visibleIDs))
        #expect(!ReminderListDetailView.Selection.list(hiddenID).isAvailable(visibleListIDs: visibleIDs))
    }
}
