import Foundation
@testable import SwiftClaw
import SwiftData
import Testing

struct ICSTodoRoundTripTests {
    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        utcCalendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    /// Date-only dues are stored as *local* midnight (floating dates), so
    /// fixtures must be local midnight too.
    private static func localMidnight(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private static func roundTrip(_ todo: ICSTodoRepresentation) -> ICSTodoRepresentation? {
        ICSParser.parseTodos(ICSSerializer.serialize(todos: [todo])).first
    }

    // MARK: - Round trips

    @Test func timedTodoRoundTripsThroughUTC() throws {
        var todo = ICSTodoRepresentation(uid: "todo-1")
        todo.title = "Send recap"
        todo.notes = "Include the, budget; table"
        todo.urlString = "https://example.com"
        todo.due = Self.date(2026, 7, 20, 15, 30)
        todo.priority = 1

        let parsed = try #require(Self.roundTrip(todo))
        #expect(parsed.uid == "todo-1")
        #expect(parsed.title == "Send recap")
        #expect(parsed.notes == "Include the, budget; table")
        #expect(parsed.urlString == "https://example.com")
        #expect(parsed.due == todo.due)
        #expect(!parsed.isDateOnly)
        #expect(parsed.priority == 1)
        #expect(!parsed.isCompleted)
        #expect(parsed.completedAt == nil)
    }

    @Test func dateOnlyDueRoundTripsAsFloatingDate() throws {
        var todo = ICSTodoRepresentation(uid: "todo-2")
        todo.title = "Trash day"
        todo.due = Self.localMidnight(2026, 7, 10)
        todo.isDateOnly = true

        let output = ICSSerializer.serialize(todos: [todo])
        #expect(output.contains("DUE;VALUE=DATE:20260710"))

        let parsed = try #require(ICSParser.parseTodos(output).first)
        #expect(parsed.due == todo.due)
        #expect(parsed.isDateOnly)
        #expect(parsed.timeZoneIdentifier == nil)
    }

    @Test func completedTodoRoundTripsStatusAndTimestamp() throws {
        var todo = ICSTodoRepresentation(uid: "todo-3")
        todo.title = "Done thing"
        todo.completedAt = Self.date(2026, 7, 8, 18, 45)
        todo.isCompleted = true

        let output = ICSSerializer.serialize(todos: [todo])
        #expect(output.contains("STATUS:COMPLETED"))
        #expect(output.contains("COMPLETED:20260708T184500Z"))

        let parsed = try #require(ICSParser.parseTodos(output).first)
        #expect(parsed.isCompleted)
        #expect(parsed.completedAt == todo.completedAt)
    }

    @Test func statusOnlyCompletionParsesAsCompleted() throws {
        let text = [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "BEGIN:VTODO",
            "UID:todo-status",
            "SUMMARY:Marked done elsewhere",
            "STATUS:COMPLETED",
            "END:VTODO",
            "END:VCALENDAR",
        ].joined(separator: "\r\n")

        let parsed = try #require(ICSParser.parseTodos(text).first)
        #expect(parsed.isCompleted)
        #expect(parsed.completedAt == nil)
    }

    @Test func impossibleDueDatesAreRejected() {
        let dateOnly = [
            "BEGIN:VTODO",
            "UID:bad-day",
            "DUE;VALUE=DATE:20260230",
            "END:VTODO",
        ].joined(separator: "\r\n")
        let timed = [
            "BEGIN:VTODO",
            "UID:bad-time",
            "DUE:20260711T256000Z",
            "END:VTODO",
        ].joined(separator: "\r\n")

        #expect(ICSParser.parseTodos(dateOnly).first?.due == nil)
        #expect(ICSParser.parseTodos(timed).first?.due == nil)
    }

    /// A wall-clock time inside a DST spring-forward gap is legitimate in
    /// real-world files and must normalize (to the shifted instant), not be
    /// rejected like an impossible date — rejection would silently drop
    /// whole VEVENTs/VTODOs and EXDATEs on import.
    @Test func dstGapTimesNormalizeInsteadOfBeingRejected() throws {
        // 2026-03-08 02:30 does not exist in America/New_York (02:00 → 03:00).
        let text = [
            "BEGIN:VTODO",
            "UID:dst-gap",
            "DUE;TZID=America/New_York:20260308T023000",
            "SUMMARY:Gap time",
            "END:VTODO",
        ].joined(separator: "\r\n")

        let parsed = try #require(ICSParser.parseTodos(text).first)
        let due = try #require(parsed.due)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let components = calendar.dateComponents([.year, .month, .day, .hour], from: due)
        #expect(components.year == 2026)
        #expect(components.month == 3)
        #expect(components.day == 8)
        #expect(components.hour == 3) // sprung forward, same day
    }

    @Test func recurringTimedTodoKeepsZoneAndRule() throws {
        var todo = ICSTodoRepresentation(uid: "todo-4")
        todo.title = "Weekly review"
        todo.due = Self.date(2026, 7, 6, 16) // 09:00 Pacific
        todo.timeZoneIdentifier = "America/Los_Angeles"
        todo.rruleString = "FREQ=WEEKLY;BYDAY=MO"

        let output = ICSSerializer.serialize(todos: [todo])
        #expect(output.contains("DUE;TZID=America/Los_Angeles:20260706T090000"))

        let parsed = try #require(ICSParser.parseTodos(output).first)
        #expect(parsed.due == todo.due)
        #expect(parsed.timeZoneIdentifier == "America/Los_Angeles")
        #expect(parsed.rruleString == "FREQ=WEEKLY;BYDAY=MO")
    }

    @Test func checklistAndFlagRoundTrip() throws {
        var todo = ICSTodoRepresentation(uid: "todo-5")
        todo.title = "Groceries"
        todo.isFlagged = true
        todo.checklist = [
            ReminderChecklistItem(text: "Milk, whole; 2 gallons"),
            ReminderChecklistItem(text: "Eggs", isDone: true),
        ]

        let parsed = try #require(Self.roundTrip(todo))
        #expect(parsed.isFlagged)
        #expect(parsed.checklist == todo.checklist)
    }

    @Test func afterCompletionRepeatRoundTrips() throws {
        var todo = ICSTodoRepresentation(uid: "todo-6")
        todo.title = "Change air filter"
        todo.due = Self.localMidnight(2026, 8, 1)
        todo.isDateOnly = true
        todo.afterCompletionRepeat = ReminderAfterCompletionRepeat(count: 3, unit: .month)

        let output = ICSSerializer.serialize(todos: [todo])
        #expect(output.contains("X-SWIFTCLAW-REPEAT-AFTER:3 month"))

        let parsed = try #require(ICSParser.parseTodos(output).first)
        #expect(parsed.afterCompletionRepeat == ReminderAfterCompletionRepeat(count: 3, unit: .month))
        #expect(parsed.rruleString == nil)
    }

    /// A timed after-completion repeat does zone-sensitive month/DST math, so
    /// its stored zone must survive export like an RRULE's does (UTC export
    /// would drop `timeZoneIdentifier` on re-import).
    @Test func timedAfterCompletionRepeatKeepsZone() throws {
        var todo = ICSTodoRepresentation(uid: "todo-7")
        todo.title = "Rebalance portfolio"
        todo.due = Self.date(2026, 7, 6, 16) // 09:00 Pacific
        todo.timeZoneIdentifier = "America/Los_Angeles"
        todo.afterCompletionRepeat = ReminderAfterCompletionRepeat(count: 1, unit: .month)

        let output = ICSSerializer.serialize(todos: [todo])
        #expect(output.contains("DUE;TZID=America/Los_Angeles:20260706T090000"))

        let parsed = try #require(ICSParser.parseTodos(output).first)
        #expect(parsed.due == todo.due)
        #expect(parsed.timeZoneIdentifier == "America/Los_Angeles")
        #expect(parsed.afterCompletionRepeat == ReminderAfterCompletionRepeat(count: 1, unit: .month))
    }

    // MARK: - Mixed files

    /// One file carrying both VEVENTs and VTODOs: each walk finds only its
    /// own components, and neither misreads the other's properties.
    @Test func mixedFileParsesEventsAndTodosIndependently() throws {
        let text = [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "BEGIN:VEVENT",
            "UID:event-1",
            "DTSTART:20260710T150000Z",
            "DTEND:20260710T160000Z",
            "SUMMARY:Kickoff meeting",
            "END:VEVENT",
            "BEGIN:VTODO",
            "UID:todo-1",
            "DUE:20260711T090000Z",
            "SUMMARY:Send recap",
            "PRIORITY:5",
            "END:VTODO",
            "END:VCALENDAR",
        ].joined(separator: "\r\n")

        let events = ICSParser.parse(text)
        #expect(events.count == 1)
        #expect(events.first?.uid == "event-1")
        #expect(events.first?.title == "Kickoff meeting")
        #expect(events.first?.start == Self.date(2026, 7, 10, 15))

        let todos = ICSParser.parseTodos(text)
        #expect(todos.count == 1)
        #expect(todos.first?.uid == "todo-1")
        #expect(todos.first?.title == "Send recap")
        #expect(todos.first?.due == Self.date(2026, 7, 11, 9))
        #expect(todos.first?.priority == 5)
    }

    // MARK: - Import

    @MainActor
    @Test func importingTwiceUpdatesInsteadOfDuplicating() throws {
        let schema = Schema([Reminder.self, ReminderList.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let repository = ReminderRepository(modelContext: ModelContext(container))
        let list = repository.createList(name: "Imported")

        var todo = ICSTodoRepresentation(uid: "todo-import")
        todo.title = "Water plants"
        todo.due = Self.localMidnight(2026, 7, 12)
        todo.isDateOnly = true
        let first = ICSSerializer.serialize(todos: [todo])
        #expect(ICSTodoImporter.importTodos(from: first, into: list, repository: repository) == 1)

        todo.title = "Water the plants"
        let second = ICSSerializer.serialize(todos: [todo])
        #expect(ICSTodoImporter.importTodos(from: second, into: list, repository: repository) == 1)

        let reminders = repository.reminders(in: list)
        #expect(reminders.count == 1)
        let reminder = try #require(reminders.first)
        #expect(reminder.title == "Water the plants")
        #expect(reminder.externalIdentifier == "todo-import")
        #expect(reminder.source == .icsImport)
        #expect(!reminder.hasDueTime)
        #expect(reminder.timeZoneIdentifier == nil)
    }

    @MainActor
    @Test func statusOnlyCompletionKeepsFirstImportedTimestamp() throws {
        let schema = Schema([Reminder.self, ReminderList.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let repository = ReminderRepository(modelContext: ModelContext(container))
        let list = repository.createList(name: "Imported")
        let text = [
            "BEGIN:VTODO",
            "UID:todo-stable-completion",
            "STATUS:COMPLETED",
            "END:VTODO",
        ].joined(separator: "\r\n")

        ICSTodoImporter.importTodos(from: text, into: list, repository: repository)
        let reminder = try #require(repository.reminder(withExternalIdentifier: "todo-stable-completion"))
        let firstCompletion = try #require(reminder.completedAt)
        reminder.completedAt = firstCompletion.addingTimeInterval(-3600)
        repository.noteUpdated(reminder)

        ICSTodoImporter.importTodos(from: text, into: list, repository: repository)
        #expect(reminder.completedAt == firstCompletion.addingTimeInterval(-3600))
    }

    /// A foreign RRULE outside our subset degrades to a one-off instead of
    /// storing a string the recurrence engine can't advance.
    @MainActor
    @Test func importDegradesUnsupportedRulesToOneOffs() throws {
        let schema = Schema([Reminder.self, ReminderList.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let repository = ReminderRepository(modelContext: ModelContext(container))
        let list = repository.createList(name: "Imported")

        let text = [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "BEGIN:VTODO",
            "UID:todo-weird",
            "DUE:20260711T090000Z",
            "SUMMARY:Odd repeat",
            "RRULE:FREQ=SECONDLY;INTERVAL=90",
            "END:VTODO",
            "END:VCALENDAR",
        ].joined(separator: "\r\n")

        #expect(ICSTodoImporter.importTodos(from: text, into: list, repository: repository) == 1)
        let reminder = try #require(repository.reminder(withExternalIdentifier: "todo-weird"))
        #expect(reminder.recurrenceRuleString == nil)
        #expect(reminder.dueDate == Self.date(2026, 7, 11, 9))
    }

    /// Export from one SwiftClaw, import into another (twice): the UID
    /// becomes the destination's external identifier, so the transfer keeps
    /// every field and re-imports dedupe.
    @MainActor
    @Test func exportImportRoundTripKeepsFieldsAndDedupes() throws {
        let schema = Schema([Reminder.self, ReminderList.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let source = try ModelContainer(for: schema, configurations: [configuration])
        let sourceRepository = ReminderRepository(modelContext: ModelContext(source))
        let sourceList = sourceRepository.createList(name: "Chores")

        let reminder = Reminder(
            title: "Change air filter",
            dueDate: Self.localMidnight(2026, 8, 1),
            hasDueTime: false,
            priority: .medium,
            isFlagged: true
        )
        reminder.checklist = [ReminderChecklistItem(text: "Buy filter")]
        reminder.afterCompletionRepeat = ReminderAfterCompletionRepeat(count: 3, unit: .month)
        sourceRepository.insert(reminder, into: sourceList)

        let text = ICSTodoImporter.exportText(for: [reminder], listName: sourceList.name)

        let destinationConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let destination = try ModelContainer(for: schema, configurations: [destinationConfiguration])
        let repository = ReminderRepository(modelContext: ModelContext(destination))
        let list = repository.createList(name: "Chores")
        #expect(ICSTodoImporter.importTodos(from: text, into: list, repository: repository) == 1)
        #expect(ICSTodoImporter.importTodos(from: text, into: list, repository: repository) == 1)

        let rows = repository.reminders(in: list)
        #expect(rows.count == 1)
        let roundTripped = try #require(rows.first)
        #expect(roundTripped.externalIdentifier == "swiftclaw-\(reminder.id.uuidString)")
        #expect(roundTripped.title == "Change air filter")
        #expect(roundTripped.priority == .medium)
        #expect(roundTripped.isFlagged)
        #expect(roundTripped.checklist.map(\.text) == ["Buy filter"])
        #expect(roundTripped.afterCompletionRepeat == ReminderAfterCompletionRepeat(count: 3, unit: .month))
        #expect(roundTripped.dueDate == Self.localMidnight(2026, 8, 1))
        #expect(!roundTripped.hasDueTime)
    }
}
