import Foundation
import SwiftData
import Testing
@testable import SwiftClaw

/// All-day events and date-only reminders are civil dates: stored as
/// canonical `CivilDay` instants and rendered in whatever zone the viewer is
/// in. Every test injects its zone through a `Calendar` instead of mutating
/// the process default.
@MainActor
struct CivilDateTests {
    private static func calendar(_ identifier: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier)!
        return calendar
    }

    private static let chicago = calendar("America/Chicago")
    private static let losAngeles = calendar("America/Los_Angeles")
    private static let tokyo = calendar("Asia/Tokyo")
    private static let newYork = calendar("America/New_York")

    private static func date(
        _ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0,
        in calendar: Calendar
    ) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private static func day(_ year: Int, _ month: Int, _ day: Int) -> CivilDay {
        CivilDay(year: year, month: month, day: day)
    }

    private static func calendarRepository() throws -> CalendarRepository {
        let schema = Schema([CalendarEvent.self, UserCalendar.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        return CalendarRepository(modelContext: ModelContext(container))
    }

    private static func reminderRepository() throws -> ReminderRepository {
        let schema = Schema([Reminder.self, ReminderList.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        return ReminderRepository(modelContext: ModelContext(container))
    }

    /// Civil days an occurrence covers in `calendar`.
    private static func days(of occurrence: EventOccurrence, in calendar: Calendar) -> [CivilDay] {
        let first = CivilDay(containing: occurrence.start, in: calendar)
        let count = first.days(until: CivilDay(containing: occurrence.end, in: calendar))
        return (0..<count).map { first.adding(days: $0) }
    }

    // MARK: - CivilDay

    @Test func canonicalEncodingRoundTripsAndRejectsImpossibleDates() {
        let july10 = Self.day(2026, 7, 10)
        #expect(CivilDay(canonical: july10.canonicalDate) == july10)
        #expect(july10.canonicalDate == Self.date(2026, 7, 10, in: Self.calendar("UTC")))
        #expect(CivilDay(isoDatePrefix: "2026-07-10T00:00:00-05:00") == july10)
        #expect(CivilDay(isoDatePrefix: "2026-02-30") == nil)
        #expect(july10.adding(.month, value: 1) == Self.day(2026, 8, 10))
        #expect(Self.day(2026, 1, 31).adding(.month, value: 1) == Self.day(2026, 2, 28))
        #expect(Self.day(2026, 3, 1).days(until: Self.day(2026, 3, 15)) == 14)
    }

    // MARK: - All-day events across zones

    /// July 10 made in Chicago is July 10 in Los Angeles and Tokyo, and stays
    /// one day long. Local-midnight storage showed it on July 9 from 22:00 in
    /// LA, spilling into a second day.
    @Test func allDayEventKeepsItsDayAfterMovingFromChicagoToLAAndTokyo() throws {
        let event = CalendarEvent(title: "Holiday")
        event.setAllDaySpan(
            localStart: Self.date(2026, 7, 10, 9, in: Self.chicago),
            localEnd: Self.date(2026, 7, 10, 10, in: Self.chicago),
            calendar: Self.chicago
        )
        #expect(event.allDayDayCount == 1)

        for zone in [Self.chicago, Self.losAngeles, Self.tokyo] {
            let interval = event.displayInterval(calendar: zone)
            #expect(interval.start == Self.date(2026, 7, 10, in: zone))
            #expect(interval.end == Self.date(2026, 7, 11, in: zone))

            let month = DateInterval(start: Self.date(2026, 7, 1, in: zone), end: Self.date(2026, 8, 1, in: zone))
            let occurrences = CalendarOccurrenceBuilder.occurrences(from: [event], in: month, calendar: zone)
            #expect(occurrences.count == 1)
            #expect(occurrences.flatMap { Self.days(of: $0, in: zone) } == [Self.day(2026, 7, 10)])
        }

        // A window on July 9 in LA (where the old encoding leaked) is empty.
        let july9LA = DateInterval(start: Self.date(2026, 7, 9, in: Self.losAngeles), duration: 24 * 3600)
        #expect(CalendarOccurrenceBuilder.occurrences(from: [event], in: july9LA, calendar: Self.losAngeles).isEmpty)
    }

    @Test func multiDayAllDayEventSpansTheSameDaysInEveryZone() throws {
        let repository = try Self.calendarRepository()
        let event = CalendarEvent(title: "Conference", calendar: repository.defaultCalendar())
        event.setAllDaySpan(from: Self.day(2026, 7, 20), dayCount: 3)
        repository.insert(event)

        for zone in [Self.chicago, Self.losAngeles, Self.tokyo] {
            let week = DateInterval(start: Self.date(2026, 7, 19, in: zone), end: Self.date(2026, 7, 26, in: zone))
            let occurrences = repository.occurrences(in: week, calendar: zone)
            #expect(occurrences.count == 1)
            let occurrence = try #require(occurrences.first)
            #expect(Self.days(of: occurrence, in: zone) == [
                Self.day(2026, 7, 20), Self.day(2026, 7, 21), Self.day(2026, 7, 22),
            ])
            // The editor shows the same days back.
            let draft = CalendarEventDraft(from: event, calendar: zone)
            #expect(draft.start == Self.date(2026, 7, 20, in: zone))
            #expect(draft.end == Self.date(2026, 7, 23, in: zone))
        }
    }

    // MARK: - Recurring all-day series

    /// A weekly all-day series expands by civil weeks: across New York's
    /// spring-forward (a 23-hour March 8) each occurrence still starts at
    /// local midnight and covers exactly its own day.
    @Test func recurringAllDaySeriesKeepsWholeDaysAcrossDST() throws {
        let event = CalendarEvent(title: "Recycling", recurrenceRuleString: "FREQ=WEEKLY")
        event.setAllDaySpan(from: Self.day(2026, 3, 1), dayCount: 1)
        let march = DateInterval(start: Self.date(2026, 3, 1, in: Self.newYork), end: Self.date(2026, 4, 1, in: Self.newYork))

        let occurrences = CalendarOccurrenceBuilder.occurrences(from: [event], in: march, calendar: Self.newYork)
        #expect(occurrences.map { CivilDay(containing: $0.start, in: Self.newYork) } == [
            Self.day(2026, 3, 1), Self.day(2026, 3, 8), Self.day(2026, 3, 15),
            Self.day(2026, 3, 22), Self.day(2026, 3, 29),
        ])
        for occurrence in occurrences {
            #expect(Self.newYork.startOfDay(for: occurrence.start) == occurrence.start)
            #expect(Self.days(of: occurrence, in: Self.newYork).count == 1)
            #expect(occurrence.occurrenceKey == CivilDay(containing: occurrence.start, in: Self.newYork).canonicalDate)
        }
        let springForward = try #require(occurrences.first {
            CivilDay(containing: $0.start, in: Self.newYork) == Self.day(2026, 3, 8)
        })
        #expect(springForward.end.timeIntervalSince(springForward.start) == 23 * 3600)
    }

    /// The same series viewed after flying to Tokyo lands on the same civil
    /// days; EXDATEs and UNTIL, being civil too, still apply.
    @Test func recurringAllDaySeriesSurvivesATimeZoneChange() {
        let event = CalendarEvent(title: "Standup day", recurrenceRuleString: "FREQ=DAILY")
        event.setAllDaySpan(from: Self.day(2026, 7, 6), dayCount: 1)
        var rule = RecurrenceRule(rruleString: "FREQ=DAILY")!
        rule.end = .untilDate(Self.day(2026, 7, 10).canonicalEndOfDay)
        event.recurrenceRuleString = rule.rruleString
        event.exceptionDates = [Self.day(2026, 7, 8).canonicalDate]

        let expected = [Self.day(2026, 7, 6), Self.day(2026, 7, 7), Self.day(2026, 7, 9), Self.day(2026, 7, 10)]
        for zone in [Self.chicago, Self.tokyo, Self.losAngeles] {
            let window = DateInterval(start: Self.date(2026, 7, 1, in: zone), end: Self.date(2026, 7, 31, in: zone))
            let occurrences = CalendarOccurrenceBuilder.occurrences(from: [event], in: window, calendar: zone)
            #expect(occurrences.map { CivilDay(containing: $0.start, in: zone) } == expected)
        }
    }

    /// Finding B: a one-day daily series created on the 23-hour
    /// spring-forward day must still show up in a 23:30 window on a normal
    /// 24-hour day; its seconds-based duration (23 h) would end it at 23:00.
    @Test func springForwardSeriesAppearsInALateEveningWindow() throws {
        let repository = try Self.calendarRepository()
        let event = CalendarEvent(
            title: "Daily",
            recurrenceRuleString: "FREQ=DAILY",
            calendar: repository.defaultCalendar()
        )
        event.setAllDaySpan(
            localStart: Self.date(2026, 3, 8, in: Self.newYork),
            localEnd: Self.date(2026, 3, 9, in: Self.newYork),
            calendar: Self.newYork
        )
        repository.insert(event)
        #expect(event.allDayDayCount == 1)

        let lateEvening = DateInterval(
            start: Self.date(2026, 3, 10, 23, 30, in: Self.newYork),
            end: Self.date(2026, 3, 11, in: Self.newYork)
        )
        let viaBuilder = CalendarOccurrenceBuilder.occurrences(from: [event], in: lateEvening, calendar: Self.newYork)
        let viaRepository = repository.occurrences(in: lateEvening, calendar: Self.newYork)
        for occurrences in [viaBuilder, viaRepository] {
            #expect(occurrences.count == 1)
            #expect(occurrences.first?.start == Self.date(2026, 3, 10, in: Self.newYork))
            #expect(occurrences.first?.end == Self.date(2026, 3, 11, in: Self.newYork))
        }
    }

    // MARK: - Alerts

    @Test func allDayAlarmsFireAtLocalWallClockTime() {
        let occurrence = EventOccurrence(
            eventID: UUID(),
            calendarID: nil,
            title: "Holiday",
            start: Self.date(2026, 3, 8, in: Self.newYork),
            end: Self.date(2026, 3, 9, in: Self.newYork),
            isAllDay: true,
            colorHex: "#0A84FF",
            source: .native,
            isOverride: false
        )
        // "9:00 the morning of" on the 23-hour day stays 9:00, not 10:00.
        #expect(CalendarAlertScheduler.fireDate(for: occurrence, offsetSeconds: 9 * 3600, calendar: Self.newYork)
            == Self.date(2026, 3, 8, 9, in: Self.newYork))
        // "-15 h" = 9:00 the day before.
        #expect(CalendarAlertScheduler.fireDate(for: occurrence, offsetSeconds: -15 * 3600, calendar: Self.newYork)
            == Self.date(2026, 3, 7, 9, in: Self.newYork))

        // The same civil day rendered in Tokyo fires at 9:00 Tokyo.
        let event = CalendarEvent(title: "Holiday")
        event.setAllDaySpan(from: Self.day(2026, 3, 8), dayCount: 1)
        let tokyoInterval = event.displayInterval(calendar: Self.tokyo)
        let tokyoOccurrence = EventOccurrence(
            eventID: event.id, calendarID: nil, title: "Holiday",
            start: tokyoInterval.start, end: tokyoInterval.end, isAllDay: true,
            colorHex: "#0A84FF", source: .native, isOverride: false
        )
        #expect(CalendarAlertScheduler.fireDate(for: tokyoOccurrence, offsetSeconds: 9 * 3600, calendar: Self.tokyo)
            == Self.date(2026, 3, 8, 9, in: Self.tokyo))
    }

    @Test func dateOnlyReminderAlertFiresOnItsDayInTheCurrentZone() throws {
        let reminder = Reminder(title: "Trash day")
        reminder.setDueDay(Self.day(2026, 7, 10))
        for zone in [Self.chicago, Self.tokyo] {
            let due = try #require(reminder.localDueDate(calendar: zone))
            let fire = ReminderAlertScheduler.fireDate(
                forDueDate: due,
                hasDueTime: false,
                allDayAlertMinutes: 9 * 60,
                calendar: zone
            )
            #expect(fire == Self.date(2026, 7, 10, 9, in: zone))
        }
    }

    // MARK: - Date-only reminders

    @Test func dateOnlyReminderKeepsItsDayAfterAZoneChange() throws {
        let repository = try Self.reminderRepository()
        var draft = ReminderDraft(listID: nil)
        draft.title = "File taxes"
        draft.dueDateMode = .date
        draft.dueDate = Self.date(2026, 7, 10, 23, in: Self.chicago)
        let reminder = Reminder()
        draft.apply(to: reminder, in: repository, calendar: Self.chicago)

        #expect(reminder.dueDay == Self.day(2026, 7, 10))
        for zone in [Self.chicago, Self.losAngeles, Self.tokyo] {
            #expect(reminder.localDueDate(calendar: zone) == Self.date(2026, 7, 10, in: zone))
            #expect(ReminderDraft(from: reminder, calendar: zone).dueDate == Self.date(2026, 7, 10, in: zone))
            // Not overdue until July 10 has passed where the viewer is.
            #expect(!reminder.isOverdue(now: Self.date(2026, 7, 10, 23, 59, in: zone), calendar: zone))
            #expect(reminder.isOverdue(now: Self.date(2026, 7, 11, 0, 1, in: zone), calendar: zone))
        }
    }

    /// Smart lists and the Workspace tile bucket a date-only reminder by its
    /// civil day in the viewer's zone, not by the stored instant.
    @Test func smartListsBucketDateOnlyRemindersAfterAZoneChange() {
        let reminder = Reminder(title: "Pay rent")
        reminder.setDueDay(Self.day(2026, 7, 10))

        for zone in [Self.losAngeles, Self.tokyo] {
            let dayBefore = Self.date(2026, 7, 9, 20, in: zone)
            let sameDay = Self.date(2026, 7, 10, 8, in: zone)
            let dayAfter = Self.date(2026, 7, 11, 8, in: zone)

            #expect(!ReminderSmartList.today.contains(reminder, now: dayBefore, calendar: zone))
            #expect(ReminderSmartList.scheduled.contains(reminder, now: dayBefore, calendar: zone))
            #expect(ReminderSmartList.today.contains(reminder, now: sameDay, calendar: zone))
            // Today includes overdue.
            #expect(ReminderSmartList.today.contains(reminder, now: dayAfter, calendar: zone))

            let onTheDay = WorkspaceRemindersSummary(reminders: [reminder], now: sameDay, calendar: zone)
            #expect(onTheDay.todayCount == 1)
            #expect(onTheDay.overdueCount == 0)
            let afterward = WorkspaceRemindersSummary(reminders: [reminder], now: dayAfter, calendar: zone)
            #expect(afterward.overdueCount == 1)

            let window = DateInterval(start: Self.date(2026, 7, 1, in: zone), end: Self.date(2026, 8, 1, in: zone))
            let items = ReminderCalendarItemBuilder.items(from: [reminder], in: window, now: dayBefore, calendar: zone)
            #expect(items.map(\.day) == [Self.date(2026, 7, 10, in: zone)])
            #expect(items.first?.storedDueDate == reminder.dueDate)
        }
    }

    @Test func pendingRemindersHorizonUsesTheLocalDueDay() throws {
        let repository = try Self.reminderRepository()
        let reminder = Reminder(title: "Tokyo errand")
        reminder.setDueDay(Self.day(2026, 7, 10))
        repository.insert(reminder)

        // In Tokyo, July 10 starts at 15:00Z on July 9: a horizon at 16:00Z
        // July 9 includes it, though the stored canonical instant is later.
        let horizon = Self.date(2026, 7, 10, 1, in: Self.tokyo)
        #expect(repository.pendingReminders(dueBefore: horizon, calendar: Self.tokyo).map(\.title) == ["Tokyo errand"])
        // In LA the day hasn't begun at that instant.
        #expect(repository.pendingReminders(dueBefore: horizon, calendar: Self.losAngeles).isEmpty)
    }

    /// Fixed-schedule date-only repeats advance by civil days, so a weekly
    /// reminder crossing DST keeps its weekday and stays a civil date.
    @Test func dateOnlyRecurringReminderAdvancesByCivilDays() throws {
        let repository = try Self.reminderRepository()
        let reminder = Reminder(title: "Recycling", recurrenceRuleString: "FREQ=WEEKLY")
        reminder.setDueDay(Self.day(2026, 3, 5))
        repository.insert(reminder)

        repository.complete(reminder, at: Self.date(2026, 3, 5, 18, in: Self.newYork))
        #expect(reminder.dueDay == Self.day(2026, 3, 12))
        repository.complete(reminder, at: Self.date(2026, 3, 12, 18, in: Self.newYork))
        #expect(reminder.dueDay == Self.day(2026, 3, 19))
        // The log rows remember the civil occurrence they completed.
        let logs = repository.completionLog(of: reminder)
        #expect(Set(logs.compactMap(\.originalOccurrenceDate)) == [
            Self.day(2026, 3, 5).canonicalDate, Self.day(2026, 3, 12).canonicalDate,
        ])
    }

    /// After-completion date-only repeats step from the day you completed it
    /// where you were: 23:30 on July 10 in LA is already July 11 in UTC.
    @Test func afterCompletionDateOnlyRepeatStepsFromTheLocalCompletionDay() {
        let next = ReminderRecurrenceEngine.nextDueDate(
            afterCompletion: Self.date(2026, 7, 10, 23, 30, in: Self.losAngeles),
            repeat: ReminderAfterCompletionRepeat(count: 1, unit: .day),
            hasDueTime: false,
            calendar: Self.losAngeles
        )
        #expect(next == Self.day(2026, 7, 11).canonicalDate)
    }

    // MARK: - Migration

    @Test func calendarMigrationConvertsLegacyRowsOnce() throws {
        let repository = try Self.calendarRepository()
        let userCalendar = repository.defaultCalendar()
        let chicago = Self.chicago
        let legacyJuly17 = Self.date(2026, 7, 17, in: chicago)
        let legacyJuly24 = Self.date(2026, 7, 24, in: chicago)

        let master = CalendarEvent(
            title: "Weekly holiday",
            startDate: Self.date(2026, 7, 10, in: chicago),
            endDate: Self.date(2026, 7, 11, in: chicago),
            isAllDay: true,
            recurrenceRuleString: "FREQ=WEEKLY;UNTIL=20260807T050000Z",
            calendar: userCalendar
        )
        master.exceptionDates = [legacyJuly17, legacyJuly24]
        master.dateEncodingVersion = nil
        repository.insert(master)

        let override = CalendarEvent(
            title: "Moved",
            startDate: Self.date(2026, 7, 25, in: chicago),
            endDate: Self.date(2026, 7, 26, in: chicago),
            isAllDay: true,
            externalIdentifier: "uid@detached@\(legacyJuly24.timeIntervalSinceReferenceDate)",
            source: .icsImport,
            calendar: userCalendar
        )
        override.parentEventID = master.id
        override.originalOccurrenceDate = legacyJuly24
        override.dateEncodingVersion = nil
        repository.insert(override)

        let timedStart = Self.date(2026, 7, 10, 9, in: chicago)
        let timed = CalendarEvent(
            title: "Call",
            startDate: timedStart,
            endDate: timedStart.addingTimeInterval(3600),
            timeZoneIdentifier: "America/Chicago",
            calendar: userCalendar
        )
        timed.dateEncodingVersion = nil
        repository.insert(timed)

        #expect(repository.migrateAllDayDatesToCivilEncodingIfNeeded(calendar: chicago) == 2)

        #expect(master.startDate == Self.day(2026, 7, 10).canonicalDate)
        #expect(master.endDate == Self.day(2026, 7, 11).canonicalDate)
        #expect(master.exceptionDates == [Self.day(2026, 7, 17).canonicalDate, Self.day(2026, 7, 24).canonicalDate])
        let until = try #require(master.recurrenceRuleString.flatMap(RecurrenceRule.init(rruleString:))?.end)
        #expect(until == .untilDate(Self.day(2026, 8, 7).canonicalEndOfDay))
        #expect(override.originalOccurrenceDate == Self.day(2026, 7, 24).canonicalDate)
        #expect(override.externalIdentifier
            == "uid@detached@\(Self.day(2026, 7, 24).canonicalDate.timeIntervalSinceReferenceDate)")
        #expect(override.startDate == Self.day(2026, 7, 25).canonicalDate)
        #expect(timed.startDate == timedStart)
        #expect([master, override, timed].allSatisfy { $0.dateEncodingVersion == CivilDay.encodingVersion })

        // Idempotent: a second run (even from another zone) converts nothing.
        #expect(repository.migrateAllDayDatesToCivilEncodingIfNeeded(calendar: Self.tokyo) == 0)
        #expect(master.startDate == Self.day(2026, 7, 10).canonicalDate)
        #expect(master.exceptionDates.count == 2)
        #expect(override.originalOccurrenceDate == Self.day(2026, 7, 24).canonicalDate)

        // And the converted series renders July 10, (24 moved to) 25, 31,
        // and August 7 in LA.
        let july = DateInterval(start: Self.date(2026, 7, 1, in: Self.losAngeles), end: Self.date(2026, 8, 15, in: Self.losAngeles))
        let days = repository.occurrences(in: july, calendar: Self.losAngeles)
            .filter(\.isAllDay)
            .map { CivilDay(containing: $0.start, in: Self.losAngeles) }
        #expect(days == [
            Self.day(2026, 7, 10), Self.day(2026, 7, 25), Self.day(2026, 7, 31), Self.day(2026, 8, 7),
        ])
    }

    @Test func reminderMigrationConvertsLegacyRowsOnce() throws {
        let repository = try Self.reminderRepository()
        let chicago = Self.chicago

        let dateOnly = Reminder(
            title: "Trash day",
            dueDate: Self.date(2026, 7, 10, in: chicago),
            recurrenceRuleString: "FREQ=WEEKLY;UNTIL=20260807T050000Z"
        )
        dateOnly.dateEncodingVersion = nil
        repository.insert(dateOnly)

        let log = Reminder(title: "Trash day", dueDate: Self.date(2026, 7, 3, in: chicago), completedAt: .now)
        log.parentReminderID = dateOnly.id
        log.originalOccurrenceDate = Self.date(2026, 7, 3, in: chicago)
        log.dateEncodingVersion = nil
        repository.insert(log)

        let timedDue = Self.date(2026, 7, 10, 9, in: chicago)
        let timed = Reminder(title: "Call", dueDate: timedDue, hasDueTime: true, timeZoneIdentifier: "America/Chicago")
        timed.dateEncodingVersion = nil
        repository.insert(timed)

        #expect(repository.migrateDateOnlyDueDatesToCivilEncodingIfNeeded(calendar: chicago) == 2)
        #expect(dateOnly.dueDay == Self.day(2026, 7, 10))
        #expect(log.originalOccurrenceDate == Self.day(2026, 7, 3).canonicalDate)
        #expect(dateOnly.recurrenceEndDate == Self.day(2026, 8, 7).canonicalEndOfDay)
        #expect(timed.dueDate == timedDue)

        #expect(repository.migrateDateOnlyDueDatesToCivilEncodingIfNeeded(calendar: Self.tokyo) == 0)
        #expect(dateOnly.dueDay == Self.day(2026, 7, 10))
        #expect(log.dueDay == Self.day(2026, 7, 3))
    }

    // MARK: - .ics VALUE=DATE

    @Test func allDayICSRoundTripKeepsCivilDatesAndDateUntil() throws {
        let repository = try Self.calendarRepository()
        let event = CalendarEvent(title: "Retreat", calendar: repository.defaultCalendar())
        event.setAllDaySpan(from: Self.day(2026, 7, 10), dayCount: 2)
        var rule = RecurrenceRule(rruleString: "FREQ=WEEKLY")!
        rule.end = .untilDate(Self.day(2026, 8, 7).canonicalEndOfDay)
        event.recurrenceRuleString = rule.rruleString
        event.exceptionDates = [Self.day(2026, 7, 17).canonicalDate]
        repository.insert(event)

        let text = ICSImporter.exportText(for: [event], calendarName: nil)
        #expect(text.contains("DTSTART;VALUE=DATE:20260710"))
        #expect(text.contains("DTEND;VALUE=DATE:20260712"))
        #expect(text.contains("EXDATE;VALUE=DATE:20260717"))
        #expect(text.contains("UNTIL=20260807"))
        #expect(!text.contains("UNTIL=20260807T"))

        let parsed = try #require(ICSParser.parse(text).first)
        #expect(parsed.isAllDay)
        #expect(parsed.start == event.startDate)
        #expect(parsed.end == event.endDate)
        #expect(parsed.exceptionDates == event.exceptionDates)
        let parsedUntil = parsed.rruleString.flatMap(RecurrenceRule.init(rruleString:))?.end
        #expect(parsedUntil == .untilDate(Self.day(2026, 8, 7).canonicalEndOfDay))

        // Importing a foreign file puts the dates on the same days anywhere.
        let foreign = """
        BEGIN:VCALENDAR
        VERSION:2.0
        BEGIN:VEVENT
        UID:foreign-1
        DTSTART;VALUE=DATE:20261231
        DTEND;VALUE=DATE:20270101
        SUMMARY:New Year's Eve
        END:VEVENT
        END:VCALENDAR
        """
        try ICSImporter.importEvents(from: foreign, into: repository.defaultCalendar(), repository: repository)
        let imported = try #require(repository.event(withExternalIdentifier: "foreign-1"))
        for zone in [Self.losAngeles, Self.tokyo] {
            #expect(imported.displayInterval(calendar: zone).start == Self.date(2026, 12, 31, in: zone))
            #expect(imported.displayInterval(calendar: zone).end == Self.date(2027, 1, 1, in: zone))
        }
    }

    @Test func allDayICSWithStrayDateTimeValuesMapsOntoCivilDays() throws {
        let text = """
        BEGIN:VCALENDAR
        VERSION:2.0
        BEGIN:VEVENT
        UID:mixed-1
        DTSTART;VALUE=DATE:20260710
        DTEND;TZID=Asia/Tokyo:20260711T000000
        RRULE:FREQ=DAILY;COUNT=5
        EXDATE;TZID=Asia/Tokyo:20260712T000000
        SUMMARY:Mixed
        END:VEVENT
        END:VCALENDAR
        """
        let parsed = try #require(ICSParser.parse(text).first)
        #expect(parsed.start == Self.day(2026, 7, 10).canonicalDate)
        #expect(parsed.end == Self.day(2026, 7, 11).canonicalDate)
        #expect(parsed.exceptionDates == [Self.day(2026, 7, 12).canonicalDate])
    }

    @Test func dateOnlyTodoICSRoundTripKeepsItsCivilDay() throws {
        let reminder = Reminder(title: "Renew passport", recurrenceRuleString: nil)
        reminder.setDueDay(Self.day(2026, 7, 10))
        var rule = RecurrenceRule(rruleString: "FREQ=MONTHLY")!
        rule.end = .untilDate(Self.day(2026, 12, 10).canonicalEndOfDay)
        reminder.recurrenceRuleString = rule.rruleString

        let text = ICSSerializer.serialize(todos: [ICSTodoRepresentation(reminder: reminder)])
        #expect(text.contains("DUE;VALUE=DATE:20260710"))
        #expect(text.contains("UNTIL=20261210"))
        #expect(!text.contains("UNTIL=20261210T"))

        let parsed = try #require(ICSParser.parseTodos(text).first)
        #expect(parsed.isDateOnly)
        #expect(parsed.due == reminder.dueDate)
        let parsedUntil = parsed.rruleString.flatMap(RecurrenceRule.init(rruleString:))?.end
        #expect(parsedUntil == .untilDate(Self.day(2026, 12, 10).canonicalEndOfDay))
    }

    // MARK: - Editors and quick entry

    @Test func allDayDraftSavesUntilAsACivilDay() throws {
        let repository = try Self.calendarRepository()
        var draft = CalendarEventDraft(newAt: Self.date(2026, 7, 10, in: Self.tokyo), calendarID: nil)
        draft.title = "Retreat"
        draft.isAllDay = true
        var rule = RecurrenceRule(rruleString: "FREQ=WEEKLY")!
        // The picker hands back a local instant on the chosen end day.
        rule.end = .untilDate(Self.date(2026, 8, 7, 8, in: Self.tokyo))
        draft.rule = rule

        let event = repository.insert(CalendarEvent())
        draft.apply(to: event, in: repository, calendar: Self.tokyo)
        #expect(event.startDate == Self.day(2026, 7, 10).canonicalDate)
        let storedUntil = event.recurrenceRuleString.flatMap(RecurrenceRule.init(rruleString:))?.end
        #expect(storedUntil == .untilDate(Self.day(2026, 8, 7).canonicalEndOfDay))

        // Reopened in LA, the picker shows August 7 again.
        let reloaded = CalendarEventDraft(from: event, calendar: Self.losAngeles)
        guard case .untilDate(let localUntil) = reloaded.rule?.end else {
            Issue.record("UNTIL lost on reload")
            return
        }
        #expect(CivilDay(containing: localUntil, in: Self.losAngeles) == Self.day(2026, 8, 7))
    }

    // MARK: - Review follow-ups

    /// Civil days are Gregorian even when the user's calendar isn't: a
    /// Buddhist-calendar device must not migrate July 10, 2026 into 2569.
    @Test func civilDaysIgnoreANonGregorianUserCalendar() throws {
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = TimeZone(identifier: "Asia/Bangkok")!
        let localMidnight = Self.date(2026, 7, 10, in: Self.calendar("Asia/Bangkok"))
        #expect(CivilDay(containing: localMidnight, in: buddhist) == Self.day(2026, 7, 10))
        #expect(Self.day(2026, 7, 10).startDate(in: buddhist) == localMidnight)

        let repository = try Self.calendarRepository()
        let legacy = CalendarEvent(
            title: "Holiday",
            startDate: localMidnight,
            endDate: localMidnight.addingTimeInterval(24 * 3600),
            isAllDay: true,
            calendar: repository.defaultCalendar()
        )
        legacy.dateEncodingVersion = nil
        repository.insert(legacy)
        repository.migrateAllDayDatesToCivilEncodingIfNeeded(calendar: buddhist)
        #expect(legacy.startDate == Self.day(2026, 7, 10).canonicalDate)
        #expect(legacy.allDayDayCount == 1)
    }

    /// An all-day override of a *timed* master keys its RECURRENCE-ID as the
    /// master's instant; a timed override of an all-day master keys it as
    /// the civil day.
    @Test func icsOverrideRecurrenceIDsFollowTheMastersEncoding() throws {
        let repository = try Self.calendarRepository()
        let text = """
        BEGIN:VCALENDAR
        VERSION:2.0
        BEGIN:VEVENT
        UID:timed-master
        DTSTART:20260710T090000Z
        DTEND:20260710T100000Z
        RRULE:FREQ=DAILY;COUNT=5
        SUMMARY:Timed
        END:VEVENT
        BEGIN:VEVENT
        UID:timed-master
        RECURRENCE-ID:20260711T090000Z
        DTSTART;VALUE=DATE:20260711
        DTEND;VALUE=DATE:20260712
        SUMMARY:Became all-day
        END:VEVENT
        BEGIN:VEVENT
        UID:allday-master
        DTSTART;VALUE=DATE:20260710
        DTEND;VALUE=DATE:20260711
        RRULE:FREQ=DAILY;COUNT=5
        SUMMARY:All-day
        END:VEVENT
        BEGIN:VEVENT
        UID:allday-master
        RECURRENCE-ID;TZID=Asia/Tokyo:20260712T000000
        DTSTART:20260712T060000Z
        DTEND:20260712T070000Z
        SUMMARY:Became timed
        END:VEVENT
        END:VCALENDAR
        """
        try ICSImporter.importEvents(from: text, into: repository.defaultCalendar(), repository: repository)

        let timedMaster = try #require(repository.event(withExternalIdentifier: "timed-master"))
        #expect(timedMaster.exceptionDates == [Self.date(2026, 7, 11, 9, in: Self.calendar("UTC"))])
        let allDayMaster = try #require(repository.event(withExternalIdentifier: "allday-master"))
        #expect(allDayMaster.exceptionDates == [Self.day(2026, 7, 12).canonicalDate])
        let timedOverride = try #require(repository.overrides(of: allDayMaster).first)
        #expect(timedOverride.originalOccurrenceDate == Self.day(2026, 7, 12).canonicalDate)
        #expect(!timedOverride.isAllDay)
    }

    /// A DATE-TIME UNTIL on a UTC day boundary reads the same in every zone.
    @Test func importedUTCBoundaryUntilIsZoneIndependent() {
        for zone in [Self.losAngeles, Self.tokyo] {
            let civil = RecurrenceRule.civilRuleString(fromImported: "FREQ=DAILY;UNTIL=20260712T000000Z", readingIn: zone)
            #expect(RecurrenceRule(rruleString: civil)?.end == .untilDate(Self.day(2026, 7, 12).canonicalEndOfDay))
        }
        // A local instant still reads in the importing zone.
        let local = RecurrenceRule.civilRuleString(fromImported: "FREQ=DAILY;UNTIL=20260712T050000Z", readingIn: Self.chicago)
        #expect(RecurrenceRule(rruleString: local)?.end == .untilDate(Self.day(2026, 7, 12).canonicalEndOfDay))
        // A DATE UNTIL passes through verbatim.
        #expect(RecurrenceRule.civilRuleString(fromImported: "FREQ=DAILY;UNTIL=20260712", readingIn: Self.tokyo)
            == "FREQ=DAILY;UNTIL=20260712")
    }

    @Test func absurdAllDayAlarmOffsetsDoNotTrap() {
        let day = Self.day(2026, 7, 10)
        #expect(day.wallClockDate(offsetSeconds: 1e25, in: Self.tokyo) > Self.date(2100, 1, 1, in: Self.tokyo))
        #expect(day.wallClockDate(offsetSeconds: .infinity, in: Self.tokyo) == .distantFuture)
    }

    /// Toggling a recurring series between timed and all-day carries its
    /// EXDATEs and override keys into the new encoding.
    @Test func togglingAllDayReencodesExceptionAndOverrideKeys() throws {
        let repository = try Self.calendarRepository()
        let chicago = Self.chicago
        let master = CalendarEvent(
            title: "Series",
            startDate: Self.date(2026, 7, 10, 9, in: chicago),
            endDate: Self.date(2026, 7, 10, 10, in: chicago),
            timeZoneIdentifier: "America/Chicago",
            recurrenceRuleString: "FREQ=DAILY",
            calendar: repository.defaultCalendar()
        )
        master.exceptionDates = [Self.date(2026, 7, 12, 9, in: chicago)]
        repository.insert(master)
        let override = repository.detachOccurrence(of: master, at: Self.date(2026, 7, 13, 9, in: chicago))

        var draft = CalendarEventDraft(from: master, calendar: chicago)
        draft.isAllDay = true
        draft.apply(to: master, in: repository, calendar: chicago)
        #expect(master.exceptionDates.contains(Self.day(2026, 7, 12).canonicalDate))
        #expect(master.exceptionDates.contains(Self.day(2026, 7, 13).canonicalDate))
        #expect(override.originalOccurrenceDate == Self.day(2026, 7, 13).canonicalDate)
        let july = DateInterval(start: Self.date(2026, 7, 10, in: chicago), end: Self.date(2026, 7, 15, in: chicago))
        let shown = repository.occurrences(in: july, calendar: chicago)
            .filter { $0.eventID == master.id }
            .map { CivilDay(containing: $0.start, in: chicago) }
        #expect(shown == [Self.day(2026, 7, 10), Self.day(2026, 7, 11), Self.day(2026, 7, 14)])

        // And back to timed: keys land on the same days at the start time.
        var timedDraft = CalendarEventDraft(from: master, calendar: chicago)
        timedDraft.isAllDay = false
        timedDraft.start = Self.date(2026, 7, 10, 9, in: chicago)
        timedDraft.end = Self.date(2026, 7, 10, 10, in: chicago)
        timedDraft.apply(to: master, in: repository, calendar: chicago)
        #expect(master.exceptionDates.contains(Self.date(2026, 7, 12, 9, in: chicago)))
        #expect(override.originalOccurrenceDate == Self.date(2026, 7, 13, 9, in: chicago))
    }

    /// A timed override of an all-day series is judged against the fetch in
    /// its own encoding: moved to the evening before the window, it wasn't
    /// fetched and must not be called stale.
    @Test func staleOverrideCheckUsesTheOverridesOwnWindow() {
        let la = Self.losAngeles
        let range = DateInterval(start: Self.date(2026, 7, 10, in: la), end: Self.date(2026, 7, 13, in: la))
        let overrideStart = Self.date(2026, 7, 9, 20, in: la)
        let stale = EventKitMapping.isStaleImportedOverride(
            originalStart: Self.day(2026, 7, 10).canonicalDate,
            overrideStart: overrideStart,
            overrideDuration: 3600,
            masterDuration: 86400,
            window: CivilDay.canonicalWindow(covering: range, in: la),
            overrideWindow: range,
            actualStarts: []
        )
        #expect(!stale)
    }

    /// Files exported before the migration still name migrated rows by
    /// their legacy local-midnight key.
    @Test func legacyAllDayIdentifiersStillResolveAfterMigration() throws {
        let repository = try Self.calendarRepository()
        let current = Calendar.current
        let legacyMidnight = Self.date(2026, 7, 24, in: current)
        let legacyID = "uid@detached@\(legacyMidnight.timeIntervalSinceReferenceDate)"
        let master = CalendarEvent(
            title: "Series",
            startDate: Self.date(2026, 7, 10, in: current),
            endDate: Self.date(2026, 7, 11, in: current),
            isAllDay: true,
            recurrenceRuleString: "FREQ=WEEKLY",
            externalIdentifier: "uid",
            source: .icsImport,
            calendar: repository.defaultCalendar()
        )
        master.dateEncodingVersion = nil
        repository.insert(master)
        let override = CalendarEvent(
            title: "Moved",
            startDate: Self.date(2026, 7, 25, in: current),
            endDate: Self.date(2026, 7, 26, in: current),
            isAllDay: true,
            externalIdentifier: legacyID,
            source: .icsImport,
            calendar: repository.defaultCalendar()
        )
        override.parentEventID = master.id
        override.originalOccurrenceDate = legacyMidnight
        override.dateEncodingVersion = nil
        repository.insert(override)

        repository.migrateAllDayDatesToCivilEncodingIfNeeded(calendar: current)
        #expect(repository.event(withExternalIdentifier: legacyID)?.id == override.id)
    }

    /// Re-importing a series that switched from all-day to timed carries a
    /// native "this event only" edit's key along, so it stays masked.
    @Test func reimportThatChangesAllDayStateKeepsNativeOverridesMasked() throws {
        let repository = try Self.calendarRepository()
        let userCalendar = repository.defaultCalendar()
        let zone = TimeZone.current.identifier
        let allDay = """
        BEGIN:VCALENDAR
        VERSION:2.0
        BEGIN:VEVENT
        UID:series-1
        DTSTART;VALUE=DATE:20260710
        DTEND;VALUE=DATE:20260711
        RRULE:FREQ=DAILY;COUNT=5
        SUMMARY:Series
        END:VEVENT
        END:VCALENDAR
        """
        try ICSImporter.importEvents(from: allDay, into: userCalendar, repository: repository)
        let master = try #require(repository.event(withExternalIdentifier: "series-1"))
        let detached = repository.detachOccurrence(of: master, at: Self.day(2026, 7, 12).canonicalDate)
        detached.title = "Edited"
        repository.noteUpdated(detached)

        let timed = """
        BEGIN:VCALENDAR
        VERSION:2.0
        BEGIN:VEVENT
        UID:series-1
        DTSTART;TZID=\(zone):20260710T000000
        DTEND;TZID=\(zone):20260710T010000
        RRULE:FREQ=DAILY;COUNT=5
        SUMMARY:Series
        END:VEVENT
        END:VCALENDAR
        """
        try ICSImporter.importEvents(from: timed, into: userCalendar, repository: repository)
        #expect(!master.isAllDay)
        let july12 = Self.date(2026, 7, 12, in: Calendar.current)
        #expect(detached.originalOccurrenceDate == july12)
        let day = DateInterval(start: july12, duration: 3600)
        let shown = repository.occurrences(in: day).filter { $0.eventID == master.id }
        #expect(shown.isEmpty)
    }

    @Test func quickEntryAllDayUsesTheWrittenCivilDate() {
        let range = CalendarQuickEntryService.allDayRange(start: "2026-07-10T00:00:00+09:00", end: nil)
        #expect(range?.first == Self.day(2026, 7, 10))
        #expect(range?.count == 1)
        let trip = CalendarQuickEntryService.allDayRange(start: "2026-07-10", end: "2026-07-12T23:59:59-05:00")
        #expect(trip?.first == Self.day(2026, 7, 10))
        #expect(trip?.count == 3)
        let exclusive = CalendarQuickEntryService.allDayRange(start: "2026-07-10", end: "2026-07-12T00:00:00Z")
        #expect(exclusive?.count == 2)
    }
}
