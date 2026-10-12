import Foundation
@testable import SwiftClaw
import SwiftData
import Testing

@MainActor
struct ReminderCalendarItemBuilderTests {
    private nonisolated static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    // A fixed "now": 2026-06-10 12:00 UTC.
    private nonisolated static let now = date(2026, 6, 10, 12)
    // The whole of June 2026.
    private nonisolated static let window = DateInterval(start: date(2026, 6, 1), end: date(2026, 7, 1))

    private nonisolated static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private static func inMemoryContext() throws -> ModelContext {
        let schema = Schema([Reminder.self, ReminderList.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContext(ModelContainer(for: schema, configurations: [configuration]))
    }

    private static func items(
        _ reminders: [Reminder],
        window: DateInterval = window,
        now: Date = now
    ) -> [ReminderCalendarItem] {
        ReminderCalendarItemBuilder.items(from: reminders, in: window, now: now, calendar: calendar)
    }

    @Test func mapsPendingDatedRemindersOntoTheirDueDay() {
        let timed = Reminder(title: "Call", dueDate: Self.date(2026, 6, 14, 9), hasDueTime: true)
        let dateOnly = Reminder(title: "Pack", dueDate: Self.date(2026, 6, 20))

        let items = Self.items([timed, dateOnly])

        #expect(items.count == 2)
        #expect(items[0].day == Self.date(2026, 6, 14))
        #expect(items[0].hasDueTime)
        #expect(!items[0].isOverdue)
        #expect(items[0].colorHex == ReminderList.defaultColorHex)
        #expect(items[1].day == Self.date(2026, 6, 20))
        #expect(!items[1].hasDueTime)
    }

    @Test func excludesCompletedLogsUndatedAndOutOfWindow() {
        let completed = Reminder(title: "Done", dueDate: Self.date(2026, 6, 12), completedAt: Self.now)
        let log = Reminder(title: "History", dueDate: Self.date(2026, 6, 12))
        log.parentReminderID = UUID()
        let undated = Reminder(title: "Someday")
        let nextMonth = Reminder(title: "July", dueDate: Self.date(2026, 7, 3))
        let included = Reminder(title: "Real", dueDate: Self.date(2026, 6, 12))

        let items = Self.items([completed, log, undated, nextMonth, included])

        #expect(items.map(\.title) == ["Real"])
    }

    @Test func respectsListVisibilityAndColor() throws {
        let context = try Self.inMemoryContext()
        let hidden = ReminderList(name: "Hidden", isVisible: false)
        let visible = ReminderList(name: "Visible", colorHex: "#00FF00")
        context.insert(hidden)
        context.insert(visible)
        let onHidden = Reminder(title: "Hidden item", dueDate: Self.date(2026, 6, 12), list: hidden)
        let onVisible = Reminder(title: "Visible item", dueDate: Self.date(2026, 6, 12), list: visible)
        context.insert(onHidden)
        context.insert(onVisible)

        let items = Self.items([onHidden, onVisible])

        #expect(items.map(\.title) == ["Visible item"])
        #expect(items[0].colorHex == "#00FF00")
    }

    @Test func overdueRemindersSurfaceOnToday() {
        let pastDateOnly = Reminder(title: "Last week", dueDate: Self.date(2026, 6, 5))
        let pastTimed = Reminder(title: "Yesterday", dueDate: Self.date(2026, 6, 9, 15), hasDueTime: true)

        let items = Self.items([pastDateOnly, pastTimed])

        #expect(items.count == 2)
        #expect(items.allSatisfy { $0.day == Self.date(2026, 6, 10) })
        #expect(items.allSatisfy { $0.isOverdue })
        // The real due instant survives the roll-forward for labelling.
        #expect(items.map { $0.due } == [Self.date(2026, 6, 5), Self.date(2026, 6, 9, 15)])
    }

    @Test func overdueRemindersDropOutWhenTodayIsNotVisible() {
        let overdue = Reminder(title: "Old", dueDate: Self.date(2026, 6, 5))
        let julyWindow = DateInterval(start: Self.date(2026, 7, 1), end: Self.date(2026, 8, 1))

        #expect(Self.items([overdue], window: julyWindow).isEmpty)
    }

    @Test func timedEarlierTodayIsOverdueButDateOnlyTodayIsNot() {
        let earlierToday = Reminder(title: "Missed", dueDate: Self.date(2026, 6, 10, 9), hasDueTime: true)
        let todayDateOnly = Reminder(title: "Anytime", dueDate: Self.date(2026, 6, 10))

        let items = Self.items([earlierToday, todayDateOnly])

        #expect(items.count == 2)
        #expect(items.first { $0.title == "Missed" }?.isOverdue == true)
        #expect(items.first { $0.title == "Anytime" }?.isOverdue == false)
        #expect(items.allSatisfy { $0.day == Self.date(2026, 6, 10) })
    }

    @Test func sortsByDayThenDueInstantSoOverdueLeadsToday() {
        let laterToday = Reminder(title: "Later", dueDate: Self.date(2026, 6, 10, 18), hasDueTime: true)
        let overdue = Reminder(title: "Overdue", dueDate: Self.date(2026, 6, 5))
        let todayDateOnly = Reminder(title: "Anytime", dueDate: Self.date(2026, 6, 10))
        let nextWeek = Reminder(title: "Next week", dueDate: Self.date(2026, 6, 15))

        let items = Self.items([laterToday, overdue, todayDateOnly, nextWeek])

        #expect(items.map(\.title) == ["Overdue", "Anytime", "Later", "Next week"])
    }

    @Test func bucketsAcrossSpringForwardWithoutDayDrift() {
        // America/New_York springs forward on 2026-03-08; the 23-hour day
        // must not shift later reminders into the wrong bucket, and a
        // calendar-arithmetic window end must stay exclusive.
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = TimeZone(identifier: "America/New_York")!
        let windowStart = newYork.date(from: DateComponents(year: 2026, month: 3, day: 1))!
        let window = DateInterval(
            start: windowStart,
            end: newYork.date(byAdding: .day, value: 30, to: windowStart)!
        )
        let now = newYork.date(from: DateComponents(year: 2026, month: 3, day: 5, hour: 12))!

        let onTransitionDay = Reminder(
            title: "DST day",
            dueDate: CivilDay(year: 2026, month: 3, day: 8).canonicalDate
        )
        let afterTransition = Reminder(
            title: "After",
            dueDate: newYork.date(from: DateComponents(year: 2026, month: 3, day: 9, hour: 9))!,
            hasDueTime: true
        )
        let pastWindowEnd = Reminder(
            title: "Day 31",
            dueDate: newYork.date(from: DateComponents(year: 2026, month: 3, day: 31, hour: 9))!,
            hasDueTime: true
        )

        let items = ReminderCalendarItemBuilder.items(
            from: [onTransitionDay, afterTransition, pastWindowEnd],
            in: window,
            now: now,
            calendar: newYork
        )

        #expect(items.map { $0.title } == ["DST day", "After"])
        #expect(items[0].day == newYork.date(from: DateComponents(year: 2026, month: 3, day: 8))!)
        #expect(items[1].day == newYork.date(from: DateComponents(year: 2026, month: 3, day: 9))!)
    }

    @Test func windowStartIsInclusiveAndEndExclusive() {
        let atStart = Reminder(title: "First", dueDate: Self.date(2026, 6, 1))
        let atEnd = Reminder(title: "Past end", dueDate: Self.date(2026, 7, 1))

        #expect(Self.items([atStart, atEnd]).map(\.title) == ["First"])
    }
}
