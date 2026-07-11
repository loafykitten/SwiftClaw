import Foundation
import Testing
@testable import SwiftClaw

struct CalendarTimelineLayoutEngineTests {
    private static let utc = TimeZone(identifier: "UTC")!

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar
    }

    private static let dayStart = makeDate(2026, 6, 10)
    private static let day = DateInterval(start: dayStart, duration: 24 * 3600)

    private static func makeDate(_ year: Int, _ month: Int, _ dayOfMonth: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: dayOfMonth, hour: hour, minute: minute))!
    }

    private static func occurrence(_ title: String, _ startHour: Int, _ startMinute: Int, durationMinutes: Double, isAllDay: Bool = false) -> EventOccurrence {
        let start = makeDate(2026, 6, 10, startHour, startMinute)
        return EventOccurrence(
            eventID: UUID(),
            calendarID: nil,
            title: title,
            start: start,
            end: start.addingTimeInterval(durationMinutes * 60),
            isAllDay: isAllDay,
            colorHex: "#0A84FF",
            source: .native,
            isOverride: false
        )
    }

    private static func frames(_ occurrences: [EventOccurrence]) -> [CalendarTimelineLayoutEngine.Frame] {
        CalendarTimelineLayoutEngine.frames(for: occurrences, day: day, calendar: calendar)
    }

    @Test func nonOverlappingEventsGetFullWidth() {
        let frames = Self.frames([
            Self.occurrence("A", 9, 0, durationMinutes: 60),
            Self.occurrence("B", 10, 0, durationMinutes: 60),
        ])
        #expect(frames.count == 2)
        #expect(frames.allSatisfy { $0.columnCount == 1 && $0.columnIndex == 0 })
        #expect(frames[0].startMinute == 9 * 60)
        #expect(frames[0].endMinute == 10 * 60)
    }

    @Test func twoWayOverlapSplitsIntoTwoColumns() {
        let frames = Self.frames([
            Self.occurrence("A", 9, 0, durationMinutes: 90),
            Self.occurrence("B", 9, 30, durationMinutes: 60),
        ])
        #expect(frames.count == 2)
        #expect(frames.allSatisfy { $0.columnCount == 2 })
        #expect(frames.map(\.columnIndex).sorted() == [0, 1])
    }

    @Test func threeWayOverlapUsesThreeColumns() {
        let frames = Self.frames([
            Self.occurrence("A", 9, 0, durationMinutes: 120),
            Self.occurrence("B", 9, 15, durationMinutes: 90),
            Self.occurrence("C", 9, 30, durationMinutes: 60),
        ])
        #expect(frames.allSatisfy { $0.columnCount == 3 })
        #expect(frames.map(\.columnIndex).sorted() == [0, 1, 2])
    }

    @Test func columnIsReusedAfterOccupantEnds() {
        // A(9-10) and B(9-11) overlap; C(10-11) fits back into A's column,
        // and the cluster keeps 2 columns overall.
        let frames = Self.frames([
            Self.occurrence("A", 9, 0, durationMinutes: 60),
            Self.occurrence("B", 9, 0, durationMinutes: 120),
            Self.occurrence("C", 10, 0, durationMinutes: 60),
        ])
        let byTitle = Dictionary(uniqueKeysWithValues: frames.map { ($0.occurrence.title, $0) })
        #expect(byTitle["A"]?.columnIndex == 0)
        #expect(byTitle["B"]?.columnIndex == 1)
        #expect(byTitle["C"]?.columnIndex == 0)
        #expect(frames.allSatisfy { $0.columnCount == 2 })
    }

    @Test func separateClustersDoNotShareColumnCounts() {
        // Morning pair overlaps; the afternoon single must be full-width.
        let frames = Self.frames([
            Self.occurrence("A", 9, 0, durationMinutes: 60),
            Self.occurrence("B", 9, 30, durationMinutes: 60),
            Self.occurrence("C", 15, 0, durationMinutes: 60),
        ])
        let byTitle = Dictionary(uniqueKeysWithValues: frames.map { ($0.occurrence.title, $0) })
        #expect(byTitle["A"]?.columnCount == 2)
        #expect(byTitle["C"]?.columnCount == 1)
    }

    @Test func allDayEventsAreExcluded() {
        let frames = Self.frames([
            Self.occurrence("All day", 0, 0, durationMinutes: 24 * 60, isAllDay: true),
            Self.occurrence("Timed", 9, 0, durationMinutes: 60),
        ])
        #expect(frames.count == 1)
        #expect(frames[0].occurrence.title == "Timed")
    }

    @Test func shortEventsArePaddedToMinimumSlot() {
        let frames = Self.frames([Self.occurrence("Blip", 9, 0, durationMinutes: 1)])
        #expect(frames[0].endMinute - frames[0].startMinute == CalendarTimelineLayoutEngine.minimumSlotMinutes)
    }

    @Test func paddedDurationDrivesOverlapPacking() {
        // 1-minute event pads to 15; an event starting 5 minutes later must
        // land in a second column, not on top of it.
        let frames = Self.frames([
            Self.occurrence("Blip", 9, 0, durationMinutes: 1),
            Self.occurrence("Next", 9, 5, durationMinutes: 30),
        ])
        #expect(frames.allSatisfy { $0.columnCount == 2 })
    }

    @Test func multiDaySpillClampsToDayBounds() {
        // Event 22:00 yesterday → 02:00 today renders as 00:00–02:00 today.
        let start = Self.makeDate(2026, 6, 9, 22, 0)
        let spill = EventOccurrence(
            eventID: UUID(),
            calendarID: nil,
            title: "Overnight",
            start: start,
            end: start.addingTimeInterval(4 * 3600),
            isAllDay: false,
            colorHex: "#0A84FF",
            source: .native,
            isOverride: false
        )
        let frames = Self.frames([spill])
        #expect(frames.count == 1)
        #expect(frames[0].startMinute == 0)
        #expect(frames[0].endMinute == 120)
    }

    @Test func eventsOutsideTheDayAreDropped() {
        let frames = Self.frames([
            Self.occurrence("In", 9, 0, durationMinutes: 60),
            EventOccurrence(
                eventID: UUID(),
                calendarID: nil,
                title: "Out",
                start: Self.makeDate(2026, 6, 11, 9, 0),
                end: Self.makeDate(2026, 6, 11, 10, 0),
                isAllDay: false,
                colorHex: "#0A84FF",
                source: .native,
                isOverride: false
            ),
        ])
        #expect(frames.count == 1)
        #expect(frames[0].occurrence.title == "In")
    }
}
