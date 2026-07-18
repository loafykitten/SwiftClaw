import Foundation
import SwiftData
import Testing
@testable import SwiftClaw

struct ICSRoundTripTests {
    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        utcCalendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private static func roundTrip(_ event: ICSEventRepresentation) -> ICSEventRepresentation? {
        ICSParser.parse(ICSSerializer.serialize([event])).first
    }

    // MARK: - Round trips

    @Test func timedEventRoundTripsThroughUTC() throws {
        var event = ICSEventRepresentation(
            uid: "test-1",
            start: Self.date(2026, 6, 10, 15),
            end: Self.date(2026, 6, 10, 16, 30)
        )
        event.title = "Dentist"
        event.location = "12 Main St"
        event.notes = "Bring insurance card"
        event.urlString = "https://example.com"

        let parsed = try #require(Self.roundTrip(event))
        #expect(parsed.uid == "test-1")
        #expect(parsed.title == "Dentist")
        #expect(parsed.start == event.start)
        #expect(parsed.end == event.end)
        #expect(parsed.location == "12 Main St")
        #expect(parsed.notes == "Bring insurance card")
        #expect(parsed.urlString == "https://example.com")
        #expect(!parsed.isAllDay)
    }

    /// All-day starts are stored as *local* midnight (floating dates), so the
    /// fixture must be local midnight too — a UTC-midnight instant would
    /// legitimately serialize as the previous local day in negative-offset
    /// zones (and the next in positive ones).
    private static func localMidnight(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day))!
    }

    @Test func allDayEventRoundTripsWithExclusiveEnd() throws {
        var event = ICSEventRepresentation(
            uid: "test-2",
            start: Self.localMidnight(2026, 6, 10),
            end: Self.localMidnight(2026, 6, 11)
        )
        event.title = "Conference day"
        event.isAllDay = true

        let parsed = try #require(Self.roundTrip(event))
        #expect(parsed.isAllDay)
        #expect(parsed.title == "Conference day")
        #expect(parsed.start == event.start)
        #expect(parsed.end == event.end)
        let output = ICSSerializer.serialize([parsed])
        #expect(output.contains("DTSTART;VALUE=DATE:20260610"))
        #expect(output.contains("DTEND;VALUE=DATE:20260611"))
    }

    @Test func allDayExceptionsSerializeAsDateValues() throws {
        var event = ICSEventRepresentation(
            uid: "test-2b",
            start: Self.localMidnight(2026, 6, 10),
            end: Self.localMidnight(2026, 6, 11)
        )
        event.isAllDay = true
        event.rruleString = "FREQ=WEEKLY"
        event.exceptionDates = [Self.localMidnight(2026, 6, 24)]

        // RFC 5545 requires EXDATE to match DTSTART's value type; a UTC
        // date-time EXDATE against a VALUE=DATE start gets ignored by other
        // clients (restoring the deleted occurrence).
        let output = ICSSerializer.serialize([event])
        #expect(output.contains("EXDATE;VALUE=DATE:20260624"))

        let parsed = try #require(ICSParser.parse(output).first)
        #expect(parsed.exceptionDates == event.exceptionDates)
    }

    @Test func recurringEventKeepsZoneRuleAndExceptions() throws {
        var event = ICSEventRepresentation(
            uid: "test-3",
            start: Self.date(2026, 6, 1, 16), // 09:00 Pacific
            end: Self.date(2026, 6, 1, 17)
        )
        event.title = "Standup"
        event.timeZoneIdentifier = "America/Los_Angeles"
        event.rruleString = "FREQ=WEEKLY;BYDAY=MO"
        event.exceptionDates = [Self.date(2026, 6, 15, 16)]

        let parsed = try #require(Self.roundTrip(event))
        #expect(parsed.rruleString == "FREQ=WEEKLY;BYDAY=MO")
        #expect(parsed.timeZoneIdentifier == "America/Los_Angeles")
        #expect(parsed.start == event.start)
        #expect(parsed.exceptionDates == event.exceptionDates)
    }

    @Test func alarmsRoundTripAsRelativeTriggers() throws {
        var event = ICSEventRepresentation(
            uid: "test-4",
            start: Self.date(2026, 6, 10, 15),
            end: Self.date(2026, 6, 10, 16)
        )
        event.alarmOffsets = [-900, 0]

        let parsed = try #require(Self.roundTrip(event))
        #expect(parsed.alarmOffsets == [-900, 0])
    }

    @Test func specialCharactersSurviveEscaping() throws {
        var event = ICSEventRepresentation(
            uid: "test-5",
            start: Self.date(2026, 6, 10, 15),
            end: Self.date(2026, 6, 10, 16)
        )
        event.title = "Lunch; with Sam, maybe\nback by 2 \\ or so"

        let parsed = try #require(Self.roundTrip(event))
        #expect(parsed.title == event.title)
    }

    @Test func longLinesFoldAndUnfoldLosslessly() throws {
        var event = ICSEventRepresentation(
            uid: "test-6",
            start: Self.date(2026, 6, 10, 15),
            end: Self.date(2026, 6, 10, 16)
        )
        event.notes = String(repeating: "A rather long agenda item. ", count: 20)

        let serialized = ICSSerializer.serialize([event])
        for line in serialized.split(separator: "\r\n") {
            #expect(line.utf8.count <= 75)
        }
        let parsed = try #require(ICSParser.parse(serialized).first)
        #expect(parsed.notes == event.notes)
    }

    // MARK: - Tolerant parsing of foreign files

    @Test func parsesGoogleFlavoredFileSkippingUnknownComponents() throws {
        let googleish = """
        BEGIN:VCALENDAR\r
        PRODID:-//Google Inc//Google Calendar 70.9054//EN\r
        VERSION:2.0\r
        CALSCALE:GREGORIAN\r
        METHOD:PUBLISH\r
        X-WR-CALNAME:Team\r
        BEGIN:VTIMEZONE\r
        TZID:America/Los_Angeles\r
        BEGIN:DAYLIGHT\r
        TZOFFSETFROM:-0800\r
        TZOFFSETTO:-0700\r
        TZNAME:PDT\r
        DTSTART:19700308T020000\r
        RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=2SU\r
        END:DAYLIGHT\r
        END:VTIMEZONE\r
        BEGIN:VEVENT\r
        DTSTART;TZID=America/Los_Angeles:20260610T090000\r
        DTEND;TZID=America/Los_Angeles:20260610T093000\r
        DTSTAMP:20260601T120000Z\r
        UID:abc123@google.com\r
        CREATED:20260501T000000Z\r
        DESCRIPTION:Weekly sync\r
        LAST-MODIFIED:20260601T000000Z\r
        SEQUENCE:0\r
        STATUS:CONFIRMED\r
        SUMMARY:Team sync\r
        TRANSP:OPAQUE\r
        END:VEVENT\r
        BEGIN:VTODO\r
        UID:todo-1\r
        SUMMARY:Not an event\r
        END:VTODO\r
        END:VCALENDAR\r
        """
        let events = ICSParser.parse(googleish)
        #expect(events.count == 1)
        let event = try #require(events.first)
        #expect(event.uid == "abc123@google.com")
        #expect(event.title == "Team sync")
        #expect(event.timeZoneIdentifier == "America/Los_Angeles")
        // 09:00 PDT == 16:00 UTC.
        #expect(event.start == Self.date(2026, 6, 10, 16))
        #expect(event.end.timeIntervalSince(event.start) == 1800)
    }

    @Test func parsesRecurrenceIDIntoOverrideRepresentation() throws {
        let text = """
        BEGIN:VCALENDAR
        VERSION:2.0
        BEGIN:VEVENT
        UID:series-1
        DTSTART:20260601T150000Z
        DTEND:20260601T160000Z
        RRULE:FREQ=WEEKLY
        SUMMARY:Standup
        END:VEVENT
        BEGIN:VEVENT
        UID:series-1
        RECURRENCE-ID:20260608T150000Z
        DTSTART:20260608T170000Z
        DTEND:20260608T180000Z
        SUMMARY:Standup (moved)
        END:VEVENT
        END:VCALENDAR
        """
        let events = ICSParser.parse(text)
        #expect(events.count == 2)
        let master = try #require(events.first { $0.recurrenceID == nil })
        let override = try #require(events.first { $0.recurrenceID != nil })
        #expect(master.rruleString == "FREQ=WEEKLY")
        #expect(override.recurrenceID == Self.date(2026, 6, 8, 15))
        #expect(override.start == Self.date(2026, 6, 8, 17))
        #expect(override.title == "Standup (moved)")
    }

    @Test func resolvesDurationWhenDTENDIsAbsent() throws {
        let text = """
        BEGIN:VCALENDAR
        VERSION:2.0
        BEGIN:VEVENT
        UID:duration-1
        DTSTART:20260610T150000Z
        DURATION:PT1H30M
        SUMMARY:No DTEND
        END:VEVENT
        END:VCALENDAR
        """
        let event = try #require(ICSParser.parse(text).first)
        #expect(event.end.timeIntervalSince(event.start) == 5400)
    }

    // MARK: - Import (RECURRENCE-ID → override rows)

    @MainActor
    @Test func importMapsRecurrenceIDToDetachedOverride() throws {
        let schema = Schema([CalendarEvent.self, UserCalendar.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let repository = CalendarRepository(modelContext: ModelContext(container))
        let calendar = repository.defaultCalendar()

        // Override listed BEFORE the master to prove file order doesn't
        // matter — a UID-only upsert would have the two rows clobber each
        // other.
        let text = """
        BEGIN:VCALENDAR
        VERSION:2.0
        BEGIN:VEVENT
        UID:series-1
        RECURRENCE-ID:20260608T150000Z
        DTSTART:20260608T170000Z
        DTEND:20260608T180000Z
        SUMMARY:Standup (moved)
        END:VEVENT
        BEGIN:VEVENT
        UID:series-1
        DTSTART:20260601T150000Z
        DTEND:20260601T160000Z
        RRULE:FREQ=WEEKLY;COUNT=3
        SUMMARY:Standup
        END:VEVENT
        END:VCALENDAR
        """
        let count = ICSImporter.importEvents(from: text, into: calendar, repository: repository)
        #expect(count == 2)

        let master = try #require(repository.event(withExternalIdentifier: "series-1"))
        #expect(master.title == "Standup")
        #expect(master.recurrenceRuleString == "FREQ=WEEKLY;COUNT=3")
        #expect(master.recurrenceEndDate == Self.date(2026, 6, 15, 15))
        // The overridden occurrence is masked on the master…
        #expect(RecurrenceExpander.isException(Self.date(2026, 6, 8, 15), exceptionDates: master.exceptionDates))

        // …and lives on as a linked detached row.
        let overrides = repository.overrides(of: master)
        #expect(overrides.count == 1)
        let override = try #require(overrides.first)
        #expect(override.title == "Standup (moved)")
        #expect(override.originalOccurrenceDate == Self.date(2026, 6, 8, 15))
        #expect(override.startDate == Self.date(2026, 6, 8, 17))
        #expect(override.recurrenceRuleString == nil)

        // Re-import is idempotent: still one master + one override.
        _ = ICSImporter.importEvents(from: text, into: calendar, repository: repository)
        #expect(repository.overrides(of: master).count == 1)
        #expect(master.exceptionDates.count == 1)
    }

    // MARK: - Primitives

    @Test(arguments: [
        ("-PT15M", -900.0),
        ("PT0S", 0.0),
        ("PT1H30M", 5400.0),
        ("-P1D", -86400.0),
        ("P1DT2H", 93600.0),
        ("-P1W", -604800.0),
    ])
    func parsesDurations(_ input: String, _ expected: Double) {
        #expect(ICSParser.parseDuration(input) == expected)
    }

    @Test func rejectsMalformedDurations() {
        #expect(ICSParser.parseDuration("15M") == nil)
        #expect(ICSParser.parseDuration("PT") == 0)
        #expect(ICSParser.parseDuration("P1X") == nil)
    }

    @Test(arguments: [
        (0.0, "PT0S"),
        (-900.0, "-PT15M"),
        (5400.0, "PT1H30M"),
        (-86400.0, "-P1D"),
        (-90000.0, "-P1DT1H"),
    ])
    func serializesDurations(_ offset: Double, _ expected: String) {
        #expect(ICSSerializer.durationString(from: offset) == expected)
    }
}
