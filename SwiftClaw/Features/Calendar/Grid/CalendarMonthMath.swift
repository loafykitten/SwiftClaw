import Foundation

/// Pure month-grid math: the full weeks covering a month, honoring the
/// calendar's `firstWeekday`, as flat rows of 7 days. Leading/trailing cells
/// from adjacent months are marked so the grid can dim them.
nonisolated enum CalendarMonthMath {
    struct Day: Hashable, Identifiable {
        let date: Date
        let isInMonth: Bool
        let isToday: Bool

        var id: Date { date }
    }

    /// 7-aligned day cells (5 or 6 weeks) covering the month containing
    /// `monthAnchor`. `today` marks the current-day cell explicitly so tests
    /// pin it.
    static func gridDays(
        forMonthContaining monthAnchor: Date,
        today: Date,
        calendar: Calendar
    ) -> [Day] {
        guard let month = calendar.dateInterval(of: .month, for: monthAnchor),
              let firstWeek = calendar.dateInterval(of: .weekOfYear, for: month.start)
        else { return [] }

        var days: [Day] = []
        var cursor = firstWeek.start
        // Walk whole weeks until the week containing the month's last day is
        // emitted. (`month.end` is the next month's first instant.)
        while cursor < month.end || days.count % 7 != 0 {
            // Half-open on purpose: `DateInterval.contains` includes the end
            // boundary, which would count the next month's first midnight.
            days.append(Day(
                date: cursor,
                isInMonth: cursor >= month.start && cursor < month.end,
                isToday: calendar.isDate(cursor, inSameDayAs: today)
            ))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return days
    }

    /// The midnights of every day `[start, end)` touches, so a multi-day
    /// event lands in each month cell it spans rather than only its first.
    /// An end exactly on midnight (exclusive all-day form) does not add that
    /// day; capped defensively for degenerate year-long spans.
    static func coveredDayStarts(
        from start: Date,
        to end: Date,
        calendar: Calendar
    ) -> [Date] {
        var days: [Date] = []
        var cursor = calendar.startOfDay(for: start)
        while cursor < end && days.count < 366 {
            days.append(cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        // Zero-duration edge (imported instantaneous events): still show it
        // on its start day.
        return days.isEmpty ? [calendar.startOfDay(for: start)] : days
    }

    /// The weekday symbols in grid order (respecting `firstWeekday`), for the
    /// header row.
    static func orderedWeekdaySymbols(calendar: Calendar) -> [String] {
        let symbols = calendar.veryShortWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }
}
