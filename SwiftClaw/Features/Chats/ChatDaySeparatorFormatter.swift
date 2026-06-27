import Foundation

enum ChatDaySeparatorFormatter {
    static func label(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return "Today"
        }

        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }

        return date.formatted(date: .abbreviated, time: .omitted)
    }

    /// Returns the `startOfDay` values at which a date separator should appear,
    /// in the order they're first encountered. A separator is inserted before
    /// the first message of each new calendar day; consecutive messages on the
    /// same day share a single separator.
    ///
    /// The result is ordered to match an ascending time-ordered input, so it
    /// can be consumed as a frontier while iterating messages.
    static func separatorDays(for dates: [Date], calendar: Calendar = .current) -> [Date] {
        var days: [Date] = []
        var previousDay: Date?

        for date in dates {
            let day = calendar.startOfDay(for: date)

            if day != previousDay {
                days.append(day)
                previousDay = day
            }
        }

        return days
    }
}

