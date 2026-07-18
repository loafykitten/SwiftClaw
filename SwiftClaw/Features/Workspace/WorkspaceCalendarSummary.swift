import Foundation

/// Stats for the Workspace calendar widget, computed from the occurrences of
/// the next seven days (mirrors `WorkspaceEmailSummary`'s role for the email
/// widget). Pure so tests pin `now` directly.
nonisolated struct WorkspaceCalendarSummary: Equatable {
    struct NextEvent: Equatable {
        let title: String
        let start: Date
        let isAllDay: Bool
    }

    let todayRemainingCount: Int
    let tomorrowCount: Int
    let weekCount: Int
    let nextEvent: NextEvent?

    /// `occurrences` should cover `[startOfDay(now), startOfDay(now) + 7d)`.
    init(occurrences: [EventOccurrence], now: Date, calendar: Calendar) {
        todayRemainingCount = occurrences.count { occurrence in
            calendar.isDate(occurrence.start, inSameDayAs: now)
                && (occurrence.isAllDay || occurrence.end > now)
        }
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now
        tomorrowCount = occurrences.count { calendar.isDate($0.start, inSameDayAs: tomorrow) }
        weekCount = occurrences.count

        // The next concrete thing on the schedule: soonest timed event that
        // hasn't ended (all-day events don't make useful countdowns). The
        // occurrence builder supplies start/title ordering.
        nextEvent = occurrences
            .first { !$0.isAllDay && $0.end > now }
            .map { NextEvent(title: $0.title, start: $0.start, isAllDay: $0.isAllDay) }
    }
}
