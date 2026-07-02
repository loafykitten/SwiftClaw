import Foundation

enum AppDateFormatting {
    static let shortDateTime = Date.FormatStyle(date: .abbreviated, time: .shortened)
    static let longDateTime = Date.FormatStyle(date: .complete, time: .standard)
    static let iso8601 = Date.ISO8601FormatStyle()
}

extension Date {
    var appShortDateTimeString: String {
        formatted(AppDateFormatting.shortDateTime)
    }

    var appLongDateTimeString: String {
        formatted(AppDateFormatting.longDateTime)
    }

    var appISO8601String: String {
        formatted(AppDateFormatting.iso8601)
    }
}
