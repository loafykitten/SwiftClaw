import Foundation

enum EmailDisplayDateFormatter {
    static func label(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            let elapsedSeconds = max(0, Int(now.timeIntervalSince(date)))
            guard elapsedSeconds >= 60 else {
                return "now"
            }

            let elapsedMinutes = elapsedSeconds / 60
            guard elapsedMinutes >= 60 else {
                return "\(elapsedMinutes)m ago"
            }

            return "\(elapsedMinutes / 60)h ago"
        }

        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday, \(date.formatted(date: .omitted, time: .shortened))"
        }

        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
