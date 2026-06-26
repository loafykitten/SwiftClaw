import Foundation
import Testing
@testable import SwiftClaw

@Suite(.serialized)
struct EmailDisplayDateFormatterTests {
    @Test func previousCalendarDayUsesYesterdayLabel() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 6, day: 25, hour: 9)))
        let date = try #require(calendar.date(from: DateComponents(year: 2026, month: 6, day: 24, hour: 23, minute: 30)))

        let previousTZ = getenv("TZ").map { String(cString: $0) }
        setenv("TZ", "UTC", 1)
        tzset()
        NSTimeZone.resetSystemTimeZone()
        defer {
            if let previousTZ {
                setenv("TZ", previousTZ, 1)
            } else {
                unsetenv("TZ")
            }
            tzset()
            NSTimeZone.resetSystemTimeZone()
        }

        let label = EmailDisplayDateFormatter.label(for: date, now: now, calendar: calendar)
        let normalizedLabel = label.replacingOccurrences(of: "\u{202F}", with: " ")

        #expect(normalizedLabel == "Yesterday, 11:30 PM")
    }

    @Test func sameDayUnderMinuteUsesNow() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 6, day: 25, hour: 9)))
        let date = now.addingTimeInterval(-30)

        let label = EmailDisplayDateFormatter.label(for: date, now: now, calendar: calendar)

        #expect(label == "now")
    }

    @Test func sameDayRecentMailUsesMinutesAgo() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 6, day: 25, hour: 9)))
        let date = now.addingTimeInterval(-120)

        let label = EmailDisplayDateFormatter.label(for: date, now: now, calendar: calendar)

        #expect(label == "2m ago")
    }

    @Test func sameDayOlderMailUsesHoursAgo() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 6, day: 25, hour: 9)))
        let date = now.addingTimeInterval(-7_200)

        let label = EmailDisplayDateFormatter.label(for: date, now: now, calendar: calendar)

        #expect(label == "2h ago")
    }

    @Test func twoDaysAgoFallsBackToNormalDateLabel() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 6, day: 25, hour: 9)))
        let date = try #require(calendar.date(from: DateComponents(year: 2026, month: 6, day: 23, hour: 13)))

        let label = EmailDisplayDateFormatter.label(for: date, now: now, calendar: calendar)

        #expect(label == date.formatted(date: .abbreviated, time: .shortened))
    }
}
