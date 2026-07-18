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
        let startOfToday = calendar.startOfDay(for: now)
        let endOfToday = calendar.dateInterval(of: .day, for: now)?.end
            ?? startOfToday.addingTimeInterval(24 * 3600)
        let endOfWeek = calendar.date(byAdding: .day, value: 7, to: startOfToday)
            ?? startOfToday.addingTimeInterval(7 * 24 * 3600)
        var todayCount = 0
        var overdueCount = 0
        var weekCount = 0
        var flaggedCount = 0
        var nextReminder: NextReminder?

        // Hidden lists are excluded everywhere outside their own list view,
        // matching the calendar chips.
        for reminder in reminders {
            guard !reminder.isCompleted,
                  !reminder.isCompletionLog,
                  reminder.isInVisibleList else { continue }

            if reminder.isFlagged {
                flaggedCount += 1
            }
            if reminder.isOverdue(now: now, calendar: calendar) {
                overdueCount += 1
            }
            guard let due = reminder.dueDate else { continue }

            if due < endOfToday {
                todayCount += 1
            }
            if due >= startOfToday, due < endOfWeek {
                weekCount += 1
            }
            if reminder.hasDueTime, due > now {
                let candidate = NextReminder(title: reminder.title, due: due)
                if let current = nextReminder {
                    if (candidate.due, candidate.title) < (current.due, current.title) {
                        nextReminder = candidate
                    }
                } else {
                    nextReminder = candidate
                }
            }
        }

        self.todayCount = todayCount
        self.overdueCount = overdueCount
        self.weekCount = weekCount
        self.flaggedCount = flaggedCount
        self.nextReminder = nextReminder
    }
}
