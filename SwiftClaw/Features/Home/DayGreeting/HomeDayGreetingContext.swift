import Foundation

struct HomeDayGreetingContext: Sendable {
    let now: Date
    let timeZoneIdentifier: String
    let locationKey: HomeDayGreetingLocationKey
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
            locationKey: .unavailable(timeZoneIdentifier: timeZone.identifier),
            phase: HomeDayPhase.calculate(now: now, sunrise: nil, sunset: nil, calendar: calendar),
            sunrise: nil,
            sunset: nil,
            daylightSummary: "Sunrise and sunset unavailable",
            weatherSummary: "Weather unavailable"
        )
    }
}

struct HomeDayGreetingLocationKey: Hashable, Sendable {
    let latitudeBucket: Int?
    let longitudeBucket: Int?
    let timeZoneIdentifier: String

    static func approximate(
        latitude: Double,
        longitude: Double,
        timeZoneIdentifier: String
    ) -> HomeDayGreetingLocationKey {
        // Core Location is requested at three-kilometer accuracy. A 0.1-degree
        // bucket keeps harmless fixes from invalidating the content cache while
        // still changing the key when the user moves to a different area.
        HomeDayGreetingLocationKey(
            latitudeBucket: Int((latitude * 10).rounded()),
            longitudeBucket: Int((longitude * 10).rounded()),
            timeZoneIdentifier: timeZoneIdentifier
        )
    }

    static func unavailable(timeZoneIdentifier: String) -> HomeDayGreetingLocationKey {
        HomeDayGreetingLocationKey(
            latitudeBucket: nil,
            longitudeBucket: nil,
            timeZoneIdentifier: timeZoneIdentifier
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
