import Foundation
import SwiftData
import Testing
@testable import SwiftClaw

@MainActor
struct CalendarEventDraftTests {
    private static func makeRepository() throws -> CalendarRepository {
        let schema = Schema([CalendarEvent.self, UserCalendar.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        return CalendarRepository(modelContext: ModelContext(container))
    }

    @Test func allDayDraftNormalizesToWholeLocalDays() throws {
        let repository = try Self.makeRepository()
        let calendar = Calendar.current
        let nineAM = calendar.date(
            from: DateComponents(year: 2026, month: 7, day: 20, hour: 9)
        )!

        // A timed 09:00–10:00 draft toggled all-day must not keep its clock
        // times (or its zone) in the store.
        var draft = CalendarEventDraft(newAt: nineAM, calendarID: nil)
        draft.title = "Trip"
        draft.isAllDay = true

        let event = repository.insert(CalendarEvent())
        draft.apply(to: event, in: repository)

        // Stored as civil days (canonical dates), shown as local midnights.
        let dayStart = calendar.startOfDay(for: nineAM)
        #expect(event.startDate == CivilDay(year: 2026, month: 7, day: 20).canonicalDate)
        #expect(event.endDate == CivilDay(year: 2026, month: 7, day: 21).canonicalDate)
        #expect(event.displayInterval(calendar: calendar).start == dayStart)
        #expect(event.displayInterval(calendar: calendar).end == calendar.date(byAdding: .day, value: 1, to: dayStart))
        #expect(event.isAllDay)
        #expect(event.timeZoneIdentifier == nil)
    }

    @Test func multiDayAllDayDraftKeepsExclusiveEnd() throws {
        let repository = try Self.makeRepository()
        let calendar = Calendar.current
        let start = calendar.date(from: DateComponents(year: 2026, month: 7, day: 20, hour: 14))!
        let end = calendar.date(from: DateComponents(year: 2026, month: 7, day: 22, hour: 11))!

        var draft = CalendarEventDraft(newAt: start, calendarID: nil)
        draft.title = "Conference"
        draft.end = end
        draft.isAllDay = true

        let event = repository.insert(CalendarEvent())
        draft.apply(to: event, in: repository)

        // 20th 14:00 → 22nd 11:00 covers the 20th–22nd: exclusive end day is
        // the 23rd.
        #expect(event.startDate == CivilDay(year: 2026, month: 7, day: 20).canonicalDate)
        #expect(event.endDate == CivilDay(year: 2026, month: 7, day: 23).canonicalDate)
        #expect(event.allDayDayCount == 3)
        #expect(event.displayInterval(calendar: calendar).end == calendar.date(
            from: DateComponents(year: 2026, month: 7, day: 23)
        ))

        // Reopening the event loads the same local days back into the draft.
        let reloaded = CalendarEventDraft(from: event, calendar: calendar)
        #expect(reloaded.start == calendar.startOfDay(for: start))
        #expect(reloaded.end == calendar.date(from: DateComponents(year: 2026, month: 7, day: 23)))
    }

    @Test func timedDraftGetsCurrentZoneWhenUnset() throws {
        let repository = try Self.makeRepository()
        var draft = CalendarEventDraft(newAt: .now.addingTimeInterval(3600), calendarID: nil)
        draft.title = "Call"

        let event = repository.insert(CalendarEvent())
        draft.apply(to: event, in: repository)

        #expect(event.timeZoneIdentifier == TimeZone.current.identifier)
        #expect(!event.isAllDay)
    }
}
