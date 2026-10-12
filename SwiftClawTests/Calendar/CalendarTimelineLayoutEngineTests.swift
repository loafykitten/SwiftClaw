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

    // MARK: - DST days (wall-clock grid)

    private static var newYork: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    private static func newYorkDate(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        newYork.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    private static func newYorkOccurrence(start: Date, end: Date) -> EventOccurrence {
        EventOccurrence(
            eventID: UUID(),
            calendarID: nil,
            title: "Meeting",
            start: start,
            end: end,
            isAllDay: false,
            colorHex: "#0A84FF",
            source: .native,
            isOverride: false
        )
    }

    /// 2026-03-08 has 23 hours in New York; 09:00 must sit on the 09:00 row,
    /// not the 08:00 row elapsed time would give.
    @Test func springForwardDayPlacesEventsByWallClock() throws {
        let calendar = Self.newYork
        let day = try #require(calendar.dateInterval(of: .day, for: Self.newYorkDate(3, 8, 12)))
        let frames = CalendarTimelineLayoutEngine.frames(
            for: [Self.newYorkOccurrence(start: Self.newYorkDate(3, 8, 9), end: Self.newYorkDate(3, 8, 10))],
            day: day,
            calendar: calendar
        )
        let frame = try #require(frames.first)
        #expect(frame.startMinute == 540)
        #expect(frame.endMinute == 600)
    }

    /// 2026-11-01 has 25 hours; the last hour must still map inside the grid.
    @Test func fallBackDayKeepsTheLastHourOnTheGrid() throws {
        let calendar = Self.newYork
        let day = try #require(calendar.dateInterval(of: .day, for: Self.newYorkDate(11, 1, 12)))
        let frames = CalendarTimelineLayoutEngine.frames(
            for: [Self.newYorkOccurrence(start: Self.newYorkDate(11, 1, 23), end: day.end)],
            day: day,
            calendar: calendar
        )
        let frame = try #require(frames.first)
        #expect(frame.startMinute == 1380)
        #expect(frame.endMinute == 1440)
    }

    @Test func dragCreateMapsGridRowsToWallClockInstants() throws {
        let calendar = Self.newYork
        let dayStart = calendar.startOfDay(for: Self.newYorkDate(3, 8, 12))
        let nine = CalendarTimelineLayoutEngine.date(atWallClockMinute: 9 * 60, onDayStarting: dayStart, calendar: calendar)
        #expect(nine == Self.newYorkDate(3, 8, 9))
        let midnight = CalendarTimelineLayoutEngine.date(atWallClockMinute: 24 * 60, onDayStarting: dayStart, calendar: calendar)
        #expect(midnight == calendar.startOfDay(for: Self.newYorkDate(3, 9, 12)))
    }

    /// Dragging a 01:00 event down two rows on spring-forward day lands on
    /// the 03:00 row, not 04:00 (01:00 + two elapsed hours).
    @Test func dragMoveShiftsByWallClockRows() {
        let shifted = CalendarTimelineLayoutEngine.shiftingWallClock(
            Self.newYorkDate(3, 8, 1),
            byMinutes: 120,
            calendar: Self.newYork
        )
        #expect(shifted == Self.newYorkDate(3, 8, 3))
    }

    // MARK: - All-day spans across DST

    /// A one-day all-day event spans one calendar day on every occurrence,
    /// including the 23-hour spring-forward Sunday (seconds-based duration
    /// would end it at 01:00 Monday, into a second day cell).
    @MainActor
    @Test func allDayOccurrenceEndKeepsWholeDaysAcrossDST() {
        let calendar = Self.newYork
        let event = CalendarEvent(title: "Holiday")
        event.setAllDaySpan(from: CivilDay(year: 2026, month: 3, day: 1), dayCount: 1)
        let springForward = CivilDay(year: 2026, month: 3, day: 8).canonicalDate
        let shortDay = event.displayInterval(forStoredStart: springForward, calendar: calendar)
        #expect(shortDay.start == calendar.startOfDay(for: Self.newYorkDate(3, 8, 12)))
        #expect(shortDay.end == calendar.startOfDay(for: Self.newYorkDate(3, 9, 12)))
        #expect(shortDay.duration == 23 * 3600)

        // Created on the short day itself: still one day elsewhere.
        let shortDayEvent = CalendarEvent(title: "Holiday")
        shortDayEvent.setAllDaySpan(
            localStart: calendar.startOfDay(for: Self.newYorkDate(3, 8, 12)),
            localEnd: calendar.startOfDay(for: Self.newYorkDate(3, 9, 12)),
            calendar: calendar
        )
        #expect(shortDayEvent.allDayDayCount == 1)
        let normalDay = CivilDay(year: 2026, month: 3, day: 15).canonicalDate
        #expect(shortDayEvent.displayInterval(forStoredStart: normalDay, calendar: calendar).end
            == calendar.startOfDay(for: Self.newYorkDate(3, 16, 12)))

        // Timed events keep elapsed duration.
        let timed = CalendarEvent(
            title: "Call",
            startDate: Self.newYorkDate(3, 1, 9),
            endDate: Self.newYorkDate(3, 1, 10)
        )
        #expect(timed.occurrenceEnd(forStart: Self.newYorkDate(3, 8, 9))
            == Self.newYorkDate(3, 8, 10))
    }
}
