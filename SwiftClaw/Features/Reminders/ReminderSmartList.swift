import Foundation

/// The built-in views in the Reminders sidebar. Membership is pure logic over
/// fetched rows so the sidebar counts and the detail pane always agree (and
/// tests can pin the boundaries — "today" includes overdue, date-only
/// reminders are due at start-of-day, completion logs only ever surface in
/// Completed).
nonisolated enum ReminderSmartList: String, CaseIterable, Identifiable {
    case today = "Today"
    case scheduled = "Scheduled"
    case inbox = "Inbox"
    case flagged = "Flagged"
    case completed = "Completed"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .today: "star"
        case .scheduled: "calendar"
        case .inbox: "tray"
        case .flagged: "flag"
        case .completed: "checkmark.circle"
        }
    }

    /// Whether `reminder` belongs to this view at `now`. Completion-log rows
    /// belong only to Completed; masters and one-offs everywhere else.
    func contains(_ reminder: Reminder, now: Date, calendar: Calendar = .current) -> Bool {
        switch self {
        case .completed:
            return reminder.isCompleted
        case .today:
            guard isPending(reminder), let dueDate = reminder.dueDate else { return false }
            guard let endOfToday = calendar.dateInterval(of: .day, for: now)?.end else { return false }
            return dueDate < endOfToday
        case .scheduled:
            return isPending(reminder) && reminder.dueDate != nil
        case .inbox:
            return isPending(reminder) && reminder.dueDate == nil
        case .flagged:
            return isPending(reminder) && reminder.isFlagged
        }
    }

    func filter(_ reminders: [Reminder], now: Date, calendar: Calendar = .current) -> [Reminder] {
        reminders.filter { contains($0, now: now, calendar: calendar) }
    }

    private func isPending(_ reminder: Reminder) -> Bool {
        !reminder.isCompleted && !reminder.isCompletionLog
    }
}
