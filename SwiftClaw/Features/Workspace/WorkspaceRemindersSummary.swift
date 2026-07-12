import Foundation

/// Stats for the Workspace reminders widget (mirrors
/// `WorkspaceCalendarSummary`'s role for the calendar widget). Pure logic over
/// fetched rows so tests pin `now` directly. Count semantics follow
/// `ReminderSmartList` where a smart list exists ("Today" includes overdue),
/// so the tile always agrees with the sidebar the user lands on.
nonisolated struct WorkspaceRemindersSummary: Equatable {
    struct NextReminder: Equatable {
        let title: String
        let due: Date
    }

    /// Pending and due before the end of today — overdue included, exactly
    /// like the Today smart list.
    let todayCount: Int
    /// Pending and fully past due: timed past their instant, date-only past
    /// their whole day.
    let overdueCount: Int
    /// Pending and due within the next seven days (from start of today).
    let weekCount: Int
    let flaggedCount: Int
    /// The next concrete deadline: soonest pending timed reminder still ahead
    /// (date-only reminders don't make useful countdowns).
    let nextReminder: NextReminder?

    init(reminders: [Reminder], now: Date, calendar: Calendar) {
        let pending = reminders.filter { !$0.isCompleted && !$0.isCompletionLog }
        let startOfToday = calendar.startOfDay(for: now)
        let endOfToday = calendar.dateInterval(of: .day, for: now)?.end
            ?? startOfToday.addingTimeInterval(24 * 3600)
        let endOfWeek = calendar.date(byAdding: .day, value: 7, to: startOfToday)
            ?? startOfToday.addingTimeInterval(7 * 24 * 3600)

        todayCount = pending.count { reminder in
            guard let due = reminder.dueDate else { return false }
            return due < endOfToday
        }
        overdueCount = pending.count { reminder in
            guard let due = reminder.dueDate else { return false }
            return reminder.hasDueTime ? due < now : due < startOfToday
        }
        weekCount = pending.count { reminder in
            guard let due = reminder.dueDate else { return false }
            return due >= startOfToday && due < endOfWeek
        }
        flaggedCount = pending.count(where: \.isFlagged)

        nextReminder = pending
            .compactMap { reminder -> NextReminder? in
                guard reminder.hasDueTime, let due = reminder.dueDate, due > now else { return nil }
                return NextReminder(title: reminder.title, due: due)
            }
            .min { ($0.due, $0.title) < ($1.due, $1.title) }
    }
}
