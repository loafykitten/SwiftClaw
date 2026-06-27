import Foundation
import Testing
@testable import SwiftClaw

@Suite(.serialized)
struct ChatDaySeparatorFormatterTests {
    @Test func todayUsesTodayLabel() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 6, day: 27, hour: 9)))
        let date = try #require(calendar.date(from: DateComponents(year: 2026, month: 6, day: 27, hour: 0, minute: 5)))

        let label = ChatDaySeparatorFormatter.label(for: date, now: now, calendar: calendar)

        #expect(label == "Today")
    }

    @Test func previousCalendarDayUsesYesterdayLabel() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 6, day: 27, hour: 9)))
        let date = try #require(calendar.date(from: DateComponents(year: 2026, month: 6, day: 26, hour: 23, minute: 30)))

        let label = ChatDaySeparatorFormatter.label(for: date, now: now, calendar: calendar)

        #expect(label == "Yesterday")
    }

    @Test func twoDaysAgoFallsBackToShortDate() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 6, day: 27, hour: 9)))
        let date = try #require(calendar.date(from: DateComponents(year: 2026, month: 6, day: 25, hour: 13)))

        let label = ChatDaySeparatorFormatter.label(for: date, now: now, calendar: calendar)

        #expect(label == date.formatted(date: .abbreviated, time: .omitted))
    }

    @Test func separatorDaysEmptyWhenNoMessages() {
        #expect(ChatDaySeparatorFormatter.separatorDays(for: []).isEmpty)
    }

    @Test func separatorDaysInsertsOneEntryForSameDayMessages() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))

        let day = try #require(calendar.date(from: DateComponents(year: 2026, month: 6, day: 27)))
        let dates = [
            day.addingTimeInterval(3_600),
            day.addingTimeInterval(7_200),
            day.addingTimeInterval(10_800)
        ]

        let days = ChatDaySeparatorFormatter.separatorDays(for: dates, calendar: calendar)

        #expect(days == [calendar.startOfDay(for: day)])
    }

    @Test func separatorDaysInsertsOneEntryPerNewDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))

        let day1 = try #require(calendar.date(from: DateComponents(year: 2026, month: 6, day: 25, hour: 22)))
        let day2 = try #require(calendar.date(from: DateComponents(year: 2026, month: 6, day: 26, hour: 1)))
        let day3 = try #require(calendar.date(from: DateComponents(year: 2026, month: 6, day: 27, hour: 6)))

        let days = ChatDaySeparatorFormatter.separatorDays(for: [day1, day2, day3], calendar: calendar)

        #expect(days == [
            calendar.startOfDay(for: day1),
            calendar.startOfDay(for: day2),
            calendar.startOfDay(for: day3)
        ])
    }

    @Test func separatorDaysFollowsFirstAppearanceOrder() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))

        let day1 = try #require(calendar.date(from: DateComponents(year: 2026, month: 6, day: 25, hour: 12)))
        let day2 = try #require(calendar.date(from: DateComponents(year: 2026, month: 6, day: 26, hour: 12)))

        let days = ChatDaySeparatorFormatter.separatorDays(for: [day2, day1], calendar: calendar)

        // The frontier follows first-appearance order, mirroring how the
        // transcript iterates visible messages (which are sorted ascending by
        // createdAt). A day that reappears later does not introduce a second
        // separator.
        #expect(days == [
            calendar.startOfDay(for: day2),
            calendar.startOfDay(for: day1)
        ])
    }
}
