import Foundation
import Testing
import SwiftData
@testable import SwiftClaw

@MainActor
struct CalendarRepositoryTests {
    private static func inMemoryContainer() throws -> ModelContainer {
        let schema = Schema([CalendarEvent.self, UserCalendar.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    private static func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int = 0,
        timeZoneIdentifier: String = "UTC"
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier)!
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private static let june = DateInterval(start: date(2026, 6, 1), end: date(2026, 7, 1))

    // MARK: - Calendars

    @Test func defaultCalendarSeedsPersonalOnFirstUse() throws {
        let repository = CalendarRepository(modelContext: ModelContext(try Self.inMemoryContainer()))
        #expect(repository.calendars().isEmpty)
        let calendar = repository.defaultCalendar()
        #expect(calendar.name == "Personal")
        #expect(repository.calendars().count == 1)
        // Second call reuses, doesn't re-seed.
        #expect(repository.defaultCalendar().id == calendar.id)
        #expect(repository.calendars().count == 1)
    }

    @Test func defaultCalendarPrefersConfiguredID() throws {
        let repository = CalendarRepository(modelContext: ModelContext(try Self.inMemoryContainer()))
        _ = repository.createCalendar(name: "Personal")
        let work = repository.createCalendar(name: "Work")
        #expect(repository.defaultCalendar(preferredID: work.id).id == work.id)
    }

    // MARK: - Occurrences

    @Test func windowedOccurrencesIncludeOneOffsAndExpandedRecurrences() throws {
        let repository = CalendarRepository(modelContext: ModelContext(try Self.inMemoryContainer()))
        let calendar = repository.defaultCalendar()

        repository.insert(CalendarEvent(
            title: "Dentist",
            startDate: Self.date(2026, 6, 10, 15),
            endDate: Self.date(2026, 6, 10, 16),
            calendar: calendar
        ))
        let standup = CalendarEvent(
            title: "Standup",
            startDate: Self.date(2026, 6, 1, 9),
            endDate: Self.date(2026, 6, 1, 9).addingTimeInterval(900),
            timeZoneIdentifier: "UTC",
            recurrenceRuleString: "FREQ=WEEKLY;BYDAY=MO",
            calendar: calendar
        )
        repository.insert(standup)

        let occurrences = repository.occurrences(in: Self.june)
        let standups = occurrences.filter { $0.title == "Standup" }
        // Mondays in June 2026: 1, 8, 15, 22, 29.
        #expect(standups.count == 5)
        #expect(occurrences.contains { $0.title == "Dentist" })
        #expect(occurrences.first?.title == "Standup") // sorted by start
    }

    @Test func hiddenCalendarsAreExcludedFromOccurrences() throws {
        let repository = CalendarRepository(modelContext: ModelContext(try Self.inMemoryContainer()))
        let hidden = repository.createCalendar(name: "Hidden")
        hidden.isVisible = false
        repository.insert(CalendarEvent(
            title: "Secret",
            startDate: Self.date(2026, 6, 5, 10),
            endDate: Self.date(2026, 6, 5, 11),
            calendar: hidden
        ))
        #expect(repository.occurrences(in: Self.june).isEmpty)
        #expect(repository.occurrences(in: Self.june, visibleCalendarsOnly: false).count == 1)
    }

    @Test func unparseableRuleRendersMasterAsOneOff() throws {
        let repository = CalendarRepository(modelContext: ModelContext(try Self.inMemoryContainer()))
        let calendar = repository.defaultCalendar()
        repository.insert(CalendarEvent(
            title: "Exotic",
            startDate: Self.date(2026, 6, 5, 10),
            endDate: Self.date(2026, 6, 5, 11),
            recurrenceRuleString: "FREQ=DAILY;BYHOUR=9", // outside supported subset
            calendar: calendar
        ))
        let occurrences = repository.occurrences(in: Self.june)
        #expect(occurrences.count == 1)
        #expect(occurrences.first?.title == "Exotic")
    }

    // MARK: - Recurring edit semantics

    @Test func detachOccurrenceCreatesOverrideAndExcludesMasterInstance() throws {
        let repository = CalendarRepository(modelContext: ModelContext(try Self.inMemoryContainer()))
        let calendar = repository.defaultCalendar()
        let master = repository.insert(CalendarEvent(
            title: "Standup",
            startDate: Self.date(2026, 6, 1, 9),
            endDate: Self.date(2026, 6, 1, 10),
            timeZoneIdentifier: "UTC",
            recurrenceRuleString: "FREQ=WEEKLY;BYDAY=MO",
            calendar: calendar
        ))

        let override = repository.detachOccurrence(of: master, at: Self.date(2026, 6, 8, 9))
        override.title = "Standup (moved)"
        override.startDate = Self.date(2026, 6, 8, 14)
        override.endDate = Self.date(2026, 6, 8, 15)
        repository.noteUpdated(override)

        let occurrences = repository.occurrences(in: Self.june)
        let standups = occurrences.filter { $0.title == "Standup" }
        let moved = occurrences.filter { $0.title == "Standup (moved)" }
        #expect(standups.count == 4) // June 8 removed from the master
        #expect(moved.count == 1)
        #expect(moved.first?.isOverride == true)
        #expect(moved.first?.start == Self.date(2026, 6, 8, 14))
    }

    @Test func deleteOccurrenceRemovesSingleInstance() throws {
        let repository = CalendarRepository(modelContext: ModelContext(try Self.inMemoryContainer()))
        let master = repository.insert(CalendarEvent(
            title: "Standup",
            startDate: Self.date(2026, 6, 1, 9),
            endDate: Self.date(2026, 6, 1, 10),
            timeZoneIdentifier: "UTC",
            recurrenceRuleString: "FREQ=WEEKLY;BYDAY=MO",
            calendar: repository.defaultCalendar()
        ))
        repository.deleteOccurrence(of: master, at: Self.date(2026, 6, 15, 9))
        let starts = repository.occurrences(in: Self.june).map(\.start)
        #expect(!starts.contains(Self.date(2026, 6, 15, 9)))
        #expect(starts.count == 4)
    }

    @Test func deleteThisAndFutureCapsSeriesAndDropsLaterOverrides() throws {
        let repository = CalendarRepository(modelContext: ModelContext(try Self.inMemoryContainer()))
        let master = repository.insert(CalendarEvent(
            title: "Standup",
            startDate: Self.date(2026, 6, 1, 9),
            endDate: Self.date(2026, 6, 1, 10),
            timeZoneIdentifier: "UTC",
            recurrenceRuleString: "FREQ=WEEKLY;BYDAY=MO",
            calendar: repository.defaultCalendar()
        ))
        _ = repository.detachOccurrence(of: master, at: Self.date(2026, 6, 22, 9))

        repository.deleteThisAndFuture(of: master, from: Self.date(2026, 6, 15, 9))

        let occurrences = repository.occurrences(in: Self.june)
        #expect(occurrences.map(\.start) == [Self.date(2026, 6, 1, 9), Self.date(2026, 6, 8, 9)])
        #expect(repository.overrides(of: master).isEmpty)
        #expect(master.recurrenceEndDate != nil)
    }

    @Test func deleteEventSeriesRemovesMasterAndOverrides() throws {
        let repository = CalendarRepository(modelContext: ModelContext(try Self.inMemoryContainer()))
        let master = repository.insert(CalendarEvent(
            title: "Standup",
            startDate: Self.date(2026, 6, 1, 9),
            endDate: Self.date(2026, 6, 1, 10),
            timeZoneIdentifier: "UTC",
            recurrenceRuleString: "FREQ=WEEKLY;BYDAY=MO",
            calendar: repository.defaultCalendar()
        ))
        _ = repository.detachOccurrence(of: master, at: Self.date(2026, 6, 8, 9))
        repository.deleteEventSeries(master)
        #expect(repository.occurrences(in: Self.june).isEmpty)
    }

    @Test func countRecurrenceEndUsesCanonicalExpansionAcrossDST() throws {
        let repository = CalendarRepository(modelContext: ModelContext(try Self.inMemoryContainer()))
        let start = Self.date(2026, 3, 1, 9, timeZoneIdentifier: "America/Chicago")
        let event = repository.insert(CalendarEvent(
            title: "Sunday meeting",
            startDate: start,
            endDate: start.addingTimeInterval(3600),
            timeZoneIdentifier: "America/Chicago",
            recurrenceRuleString: "FREQ=WEEKLY;BYDAY=SU;COUNT=3",
            calendar: repository.defaultCalendar()
        ))

        let finalStart = Self.date(2026, 3, 15, 9, timeZoneIdentifier: "America/Chicago")
        #expect(event.recurrenceEndDate == finalStart)

        let finalDay = DateInterval(
            start: Self.date(2026, 3, 15, timeZoneIdentifier: "America/Chicago"),
            end: Self.date(2026, 3, 16, timeZoneIdentifier: "America/Chicago")
        )
        #expect(repository.occurrences(in: finalDay).map(\.start) == [finalStart])
        let later = DateInterval(
            start: Self.date(2026, 3, 16, timeZoneIdentifier: "America/Chicago"),
            end: Self.date(2026, 3, 17, timeZoneIdentifier: "America/Chicago")
        )
        #expect(repository.occurrences(in: later).isEmpty)
    }

    @Test func backfillPersistsCountEndDatesOnce() throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }
        let context = ModelContext(try Self.inMemoryContainer())
        let repository = CalendarRepository(modelContext: context)
        let event = CalendarEvent(
            title: "Legacy series",
            startDate: Self.date(2026, 6, 1, 9),
            endDate: Self.date(2026, 6, 1, 10),
            timeZoneIdentifier: "UTC",
            recurrenceRuleString: "FREQ=DAILY;COUNT=4",
            calendar: repository.defaultCalendar()
        )
        context.insert(event)
        try context.save()
        #expect(event.recurrenceEndDate == nil)

        #expect(repository.backfillRecurrenceEndDatesIfNeeded(userDefaults: fixture.defaults) == 1)
        #expect(event.recurrenceEndDate == Self.date(2026, 6, 4, 9))
        #expect(repository.backfillRecurrenceEndDatesIfNeeded(userDefaults: fixture.defaults) == 0)
    }

    @Test func countFinalOccurrenceAtWindowStartRemainsVisible() throws {
        let repository = CalendarRepository(modelContext: ModelContext(try Self.inMemoryContainer()))
        let event = repository.insert(CalendarEvent(
            title: "Three-day series",
            startDate: Self.date(2026, 6, 1),
            endDate: Self.date(2026, 6, 2),
            isAllDay: true,
            recurrenceRuleString: "FREQ=DAILY;COUNT=3",
            calendar: repository.defaultCalendar()
        ))
        let finalStart = Self.date(2026, 6, 3)
        #expect(event.recurrenceEndDate == finalStart)

        let finalDay = DateInterval(start: finalStart, end: Self.date(2026, 6, 4))
        #expect(repository.occurrences(in: finalDay).map(\.start) == [finalStart])
    }

    // MARK: - Import support

    @Test func upsertImportedEventIsIdempotent() throws {
        let repository = CalendarRepository(modelContext: ModelContext(try Self.inMemoryContainer()))
        let calendar = repository.defaultCalendar()

        for title in ["First pass", "Second pass"] {
            repository.upsertImportedEvent(externalIdentifier: "ek-abc-123") { event in
                event.title = title
                event.startDate = Self.date(2026, 6, 10, 15)
                event.endDate = Self.date(2026, 6, 10, 16)
                event.source = .appleImport
                event.calendar = calendar
            }
        }

        let occurrences = repository.occurrences(in: Self.june)
        #expect(occurrences.count == 1)
        #expect(occurrences.first?.title == "Second pass")
        #expect(occurrences.first?.source == .appleImport)
    }

    // MARK: - Dedup

    @Test func dedupeCollapsesEventsSharingExternalIdentifier() throws {
        let context = ModelContext(try Self.inMemoryContainer())
        let repository = CalendarRepository(modelContext: context)
        let calendar = repository.defaultCalendar()

        // Simulate a CloudKit merge delivering the same imported event twice.
        let older = CalendarEvent(
            title: "Duplicated",
            startDate: Self.date(2026, 6, 10, 15),
            endDate: Self.date(2026, 6, 10, 16),
            externalIdentifier: "ek-dup",
            calendar: calendar
        )
        older.createdAt = Self.date(2026, 1, 1)
        let newer = CalendarEvent(
            title: "Duplicated",
            startDate: Self.date(2026, 6, 10, 15),
            endDate: Self.date(2026, 6, 10, 16),
            externalIdentifier: "ek-dup",
            calendar: calendar
        )
        newer.createdAt = Self.date(2026, 2, 1)
        context.insert(older)
        context.insert(newer)

        repository.dedupeAfterRemoteMerge()

        let remaining = try context.fetch(FetchDescriptor<CalendarEvent>())
        #expect(remaining.count == 1)
        #expect(remaining.first?.id == older.id)
    }

    @Test func dedupeSweepsOverridesWhoseMasterIsGone() throws {
        let context = ModelContext(try Self.inMemoryContainer())
        let repository = CalendarRepository(modelContext: context)
        let orphan = CalendarEvent(
            title: "Orphan override",
            startDate: Self.date(2026, 6, 8, 9),
            endDate: Self.date(2026, 6, 8, 10),
            calendar: repository.defaultCalendar()
        )
        orphan.parentEventID = UUID() // master never synced / deleted remotely
        context.insert(orphan)

        repository.dedupeAfterRemoteMerge()
        #expect(try context.fetch(FetchDescriptor<CalendarEvent>()).isEmpty)
    }
}
