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

        let dayStart = calendar.startOfDay(for: nineAM)
        #expect(event.startDate == dayStart)
        #expect(event.endDate == calendar.date(byAdding: .day, value: 1, to: dayStart))
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

        // 20th 14:00 → 22nd 11:00 covers the 20th–22nd: exclusive end is the
        // 23rd's midnight.
        #expect(event.startDate == calendar.startOfDay(for: start))
        #expect(event.endDate == calendar.date(
            from: DateComponents(year: 2026, month: 7, day: 23)
        ))
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
