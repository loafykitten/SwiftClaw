import Foundation

/// A reminder rendered in the calendar views — the reminders-side parallel of
/// `EventOccurrence`, deliberately its own type: reminders have no duration,
/// complete rather than delete, and never drag. One item per pending master —
/// `dueDate` is always the next pending occurrence, so a recurring reminder
/// contributes a single chip, never an expansion. Items are never persisted.
nonisolated struct ReminderCalendarItem: Identifiable, Sendable, Hashable {
    /// The `Reminder.id` this item renders.
    let reminderID: UUID
    let title: String
    /// Start of the day cell the item renders in: the due day, except overdue
    /// reminders surface on today (matching the Today smart list — a chip on
    /// a past page nobody revisits helps no one).
    let day: Date
    /// The actual due moment in the viewer's zone (local start of the civil
    /// due day when `hasDueTime` is false).
    let due: Date
    /// The reminder's stored `dueDate` this item rendered: the
    /// `expectedOccurrence` to complete with.
    let storedDueDate: Date
    let hasDueTime: Bool
    let isOverdue: Bool
    let colorHex: String

    var id: String { "reminder-\(reminderID.uuidString)" }
}

/// Turns `Reminder` rows into windowed `ReminderCalendarItem`s — the
/// reminders-side counterpart of `CalendarOccurrenceBuilder`. Only pending
/// masters on visible lists with a due date qualify.
@MainActor
enum ReminderCalendarItemBuilder {
    static func items(
        from reminders: [Reminder],
        in window: DateInterval,
        now: Date,
        calendar: Calendar
    ) -> [ReminderCalendarItem] {
        let startOfToday = calendar.startOfDay(for: now)
        var items: [ReminderCalendarItem] = []
        for reminder in reminders {
            guard !reminder.isCompleted, !reminder.isCompletionLog,
                  reminder.list?.isVisible ?? true,
                  let storedDueDate = reminder.dueDate,
                  let due = reminder.localDueDate(calendar: calendar)
            else { continue }

            let dueDay = calendar.startOfDay(for: due)
            let isOverdue = reminder.isOverdue(now: now, calendar: calendar)
            let day = max(dueDay, startOfToday)
            guard day >= window.start && day < window.end else { continue }

            items.append(
                ReminderCalendarItem(
                    reminderID: reminder.id,
                    title: reminder.title,
                    day: day,
                    due: due,
                    storedDueDate: storedDueDate,
                    hasDueTime: reminder.hasDueTime,
                    isOverdue: isOverdue,
                    colorHex: reminder.list?.colorHex ?? ReminderList.defaultColorHex
                )
            )
        }
        // Within a day, older due instants first — rolled-forward overdue
        // items lead today's cell.
        return items.sorted { ($0.day, $0.due, $0.title) < ($1.day, $1.due, $1.title) }
    }
}
