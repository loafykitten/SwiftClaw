import Foundation

struct HomeDayGreetingContext: Sendable {
    let now: Date
    let timeZoneIdentifier: String
    let phase: HomeDayPhase
    let sunrise: Date?
    let sunset: Date?
    let daylightSummary: String
    let weatherSummary: String

    static func localOnly(now: Date = Date()) -> HomeDayGreetingContext {
        let timeZone = TimeZone.current
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        return HomeDayGreetingContext(
            now: now,
            timeZoneIdentifier: timeZone.identifier,
            phase: HomeDayPhase.calculate(now: now, sunrise: nil, sunset: nil, calendar: calendar),
            sunrise: nil,
            sunset: nil,
            daylightSummary: "Sunrise and sunset unavailable",
            weatherSummary: "Weather unavailable"
        )
    }
}

enum HomeDaylightSummary {
    static func describe(now: Date, sunrise: Date?, sunset: Date?) -> String {
        guard let sunrise, let sunset else {
            return "Sunrise and sunset unavailable"
        }

        if now < sunrise {
            return "Sunrise in \(shortDuration(from: now, to: sunrise))"
        }

        if now <= sunset {
            return "\(shortDuration(from: now, to: sunset)) of daylight left"
        }

        return "Sunset was \(shortDuration(from: sunset, to: now)) ago"
    }

    private static func shortDuration(from start: Date, to end: Date) -> String {
        let totalMinutes = max(0, Int(end.timeIntervalSince(start) / 60))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60

        if hours > 0, minutes > 0 {
            return "\(hours)h \(minutes)m"
        }

        if hours > 0 {
            return "\(hours)h"
        }

        return "\(minutes)m"
    }
}
