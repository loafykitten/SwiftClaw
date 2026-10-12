import Foundation
@testable import SwiftClaw
import SwiftData
import Testing

/// Exercises the importer's store-application step (`importSnapshots`) — the
/// part that doesn't need an `EKEventStore` — for idempotency and the
/// degrade rules.
@MainActor
struct AppleRemindersImporterTests {
    private static func inMemoryContainer() throws -> ModelContainer {
        let schema = Schema([Reminder.self, ReminderList.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    private static func snapshot(
        externalIdentifier: String,
        title: String,
        due: DateComponents? = nil
    ) -> ReminderKitMapping.Snapshot {
        var snapshot = ReminderKitMapping.Snapshot(externalIdentifier: externalIdentifier)
        snapshot.title = title
        snapshot.dueDateComponents = due
        return snapshot
    }

    @Test func importingTwiceUpdatesInsteadOfDuplicating() throws {
        let repository = try ReminderRepository(modelContext: ModelContext(Self.inMemoryContainer()))
        let list = repository.createList(name: "Imported")
        var summary = AppleRemindersImporter.Summary()

        let first = [
            Self.snapshot(externalIdentifier: "ek-1", title: "Water plants"),
            Self.snapshot(externalIdentifier: "ek-2", title: "File taxes"),
        ]
        try AppleRemindersImporter.importSnapshots(first, into: list, repository: repository, summary: &summary)
        #expect(repository.reminders(in: list).count == 2)

        let second = [
            Self.snapshot(externalIdentifier: "ek-1", title: "Water the plants"),
            Self.snapshot(externalIdentifier: "ek-2", title: "File taxes"),
        ]
        try AppleRemindersImporter.importSnapshots(second, into: list, repository: repository, summary: &summary)

        let reminders = repository.reminders(in: list)
        #expect(reminders.count == 2)
        #expect(repository.reminder(withExternalIdentifier: "ek-1")?.title == "Water the plants")
        #expect(reminders.allSatisfy { $0.source == .appleImport })
    }

    @Test func duplicateIdentityWithinOneBatchUpdatesOneRow() throws {
        let repository = try ReminderRepository(modelContext: ModelContext(Self.inMemoryContainer()))
        let list = repository.createList(name: "Imported")
        var summary = AppleRemindersImporter.Summary()

        try AppleRemindersImporter.importSnapshots([
            Self.snapshot(externalIdentifier: "ek-same", title: "First"),
            Self.snapshot(externalIdentifier: "ek-same", title: "Last"),
        ], into: list, repository: repository, summary: &summary)

        let reminders = repository.reminders(in: list)
        #expect(reminders.count == 1)
        #expect(reminders.first?.title == "Last")
        #expect(summary.reminderCount == 2)
    }

    @Test func largeBatchCommitsAcrossChunkBoundary() throws {
        let repository = try ReminderRepository(modelContext: ModelContext(Self.inMemoryContainer()))
        let list = repository.createList(name: "Imported")
        var summary = AppleRemindersImporter.Summary()
        let snapshots = (0 ... 400).map {
            Self.snapshot(externalIdentifier: "ek-\($0)", title: "Reminder \($0)")
        }

        try AppleRemindersImporter.importSnapshots(
            snapshots,
            into: list,
            repository: repository,
            summary: &summary
        )

        #expect(repository.reminders(in: list).count == 401)
        #expect(summary.reminderCount == 401)
    }

    @Test func dueDateMappingFlowsThroughToTheModel() throws {
        let repository = try ReminderRepository(modelContext: ModelContext(Self.inMemoryContainer()))
        let list = repository.createList(name: "Imported")
        var summary = AppleRemindersImporter.Summary()

        var timed = DateComponents(year: 2026, month: 8, day: 3, hour: 14, minute: 0)
        timed.timeZone = TimeZone(identifier: "America/Chicago")
        let snapshots = [
            Self.snapshot(externalIdentifier: "ek-timed", title: "Call bank", due: timed),
            Self.snapshot(externalIdentifier: "ek-day", title: "Trash day", due: DateComponents(year: 2026, month: 8, day: 4)),
        ]
        try AppleRemindersImporter.importSnapshots(snapshots, into: list, repository: repository, summary: &summary)

        let timedReminder = try #require(repository.reminder(withExternalIdentifier: "ek-timed"))
        #expect(timedReminder.hasDueTime)
        #expect(timedReminder.timeZoneIdentifier == "America/Chicago")

        let dayReminder = try #require(repository.reminder(withExternalIdentifier: "ek-day"))
        #expect(!dayReminder.hasDueTime)
        #expect(dayReminder.timeZoneIdentifier == nil)
        #expect(dayReminder.dueDate == Calendar.current.date(from: DateComponents(year: 2026, month: 8, day: 4)))
    }

    @Test func completedWithoutTimestampStillImportsAsCompleted() throws {
        let repository = try ReminderRepository(modelContext: ModelContext(Self.inMemoryContainer()))
        let list = repository.createList(name: "Imported")
        var summary = AppleRemindersImporter.Summary()

        var snapshot = Self.snapshot(externalIdentifier: "ek-done", title: "Done thing")
        snapshot.isCompleted = true
        try AppleRemindersImporter.importSnapshots([snapshot], into: list, repository: repository, summary: &summary)

        let reminder = try #require(repository.reminder(withExternalIdentifier: "ek-done"))
        #expect(reminder.isCompleted)
        #expect(reminder.completedAt != nil)
    }

    @Test func completedWithoutTimestampKeepsFirstImportedCompletionDate() throws {
        let repository = try ReminderRepository(modelContext: ModelContext(Self.inMemoryContainer()))
        let list = repository.createList(name: "Imported")
        var summary = AppleRemindersImporter.Summary()

        var snapshot = Self.snapshot(externalIdentifier: "ek-done-stable", title: "Done thing")
        snapshot.isCompleted = true
        try AppleRemindersImporter.importSnapshots([snapshot], into: list, repository: repository, summary: &summary)

        let reminder = try #require(repository.reminder(withExternalIdentifier: "ek-done-stable"))
        let firstCompletion = try #require(reminder.completedAt)
        reminder.completedAt = firstCompletion.addingTimeInterval(-3600)
        repository.noteUpdated(reminder)

        try AppleRemindersImporter.importSnapshots([snapshot], into: list, repository: repository, summary: &summary)
        #expect(reminder.completedAt == firstCompletion.addingTimeInterval(-3600))
    }

    @Test func localIdentifierMakesMissingExternalIdentifierIdempotent() throws {
        let repository = try ReminderRepository(modelContext: ModelContext(Self.inMemoryContainer()))
        let list = repository.createList(name: "Imported")
        var summary = AppleRemindersImporter.Summary()

        var snapshot = ReminderKitMapping.Snapshot(externalIdentifier: nil)
        snapshot.localIdentifier = "ek-local-1"
        snapshot.title = "Local identity"
        try AppleRemindersImporter.importSnapshots([snapshot], into: list, repository: repository, summary: &summary)
        snapshot.title = "Updated local identity"
        try AppleRemindersImporter.importSnapshots([snapshot], into: list, repository: repository, summary: &summary)

        let reminders = repository.reminders(in: list)
        #expect(reminders.count == 1)
        #expect(reminders.first?.externalIdentifier == "ek-local-1")
        #expect(reminders.first?.title == "Updated local identity")
    }

    @Test func gainingExternalIdentifierMigratesLocallyIdentifiedReminder() throws {
        let repository = try ReminderRepository(modelContext: ModelContext(Self.inMemoryContainer()))
        let list = repository.createList(name: "Imported")
        var summary = AppleRemindersImporter.Summary()

        var snapshot = ReminderKitMapping.Snapshot(externalIdentifier: nil)
        snapshot.localIdentifier = "ek-local-transition"
        snapshot.title = "Before external ID"
        try AppleRemindersImporter.importSnapshots([snapshot], into: list, repository: repository, summary: &summary)

        snapshot.externalIdentifier = "ek-external-transition"
        snapshot.title = "After external ID"
        try AppleRemindersImporter.importSnapshots([snapshot], into: list, repository: repository, summary: &summary)

        let reminders = repository.reminders(in: list)
        #expect(reminders.count == 1)
        #expect(reminders.first?.externalIdentifier == "ek-external-transition")
        #expect(reminders.first?.title == "After external ID")
        #expect(repository.reminder(withExternalIdentifier: "ek-local-transition") == nil)
    }

    @Test func recurrenceWithoutDueDateDegradesToOneOff() throws {
        let repository = try ReminderRepository(modelContext: ModelContext(Self.inMemoryContainer()))
        let list = repository.createList(name: "Imported")
        var summary = AppleRemindersImporter.Summary()

        var snapshot = Self.snapshot(externalIdentifier: "ek-anchorless", title: "Repeat with no due")
        snapshot.recurrenceRule = RecurrenceRule(rruleString: "FREQ=WEEKLY")
        try AppleRemindersImporter.importSnapshots([snapshot], into: list, repository: repository, summary: &summary)

        let reminder = try #require(repository.reminder(withExternalIdentifier: "ek-anchorless"))
        #expect(reminder.recurrenceRuleString == nil)
        #expect(summary.degradedRuleCount == 1)
    }

    @Test func appleReimportClearsLocalAfterCompletionRepeat() throws {
        let repository = try ReminderRepository(modelContext: ModelContext(Self.inMemoryContainer()))
        let list = repository.createList(name: "Imported")
        var summary = AppleRemindersImporter.Summary()

        let initial = Self.snapshot(externalIdentifier: "ek-repeat", title: "Weekly task")
        try AppleRemindersImporter.importSnapshots([initial], into: list, repository: repository, summary: &summary)
        let reminder = try #require(repository.reminder(withExternalIdentifier: "ek-repeat"))
        reminder.afterCompletionRepeat = ReminderAfterCompletionRepeat(count: 2, unit: .week)
        repository.noteUpdated(reminder)

        var repeated = Self.snapshot(
            externalIdentifier: "ek-repeat",
            title: "Weekly task",
            due: DateComponents(year: 2026, month: 8, day: 4)
        )
        repeated.recurrenceRule = RecurrenceRule(rruleString: "FREQ=WEEKLY")
        try AppleRemindersImporter.importSnapshots([repeated], into: list, repository: repository, summary: &summary)

        #expect(reminder.recurrenceRuleString == "FREQ=WEEKLY")
        #expect(reminder.afterCompletionRepeat == nil)
    }

    @Test func nonRecurringAppleReimportPreservesLocalAfterCompletionRepeat() throws {
        let repository = try ReminderRepository(modelContext: ModelContext(Self.inMemoryContainer()))
        let list = repository.createList(name: "Imported")
        var summary = AppleRemindersImporter.Summary()

        let snapshot = Self.snapshot(
            externalIdentifier: "ek-local-repeat",
            title: "Water plants",
            due: DateComponents(year: 2026, month: 8, day: 4)
        )
        try AppleRemindersImporter.importSnapshots([snapshot], into: list, repository: repository, summary: &summary)
        let reminder = try #require(repository.reminder(withExternalIdentifier: "ek-local-repeat"))
        reminder.afterCompletionRepeat = ReminderAfterCompletionRepeat(count: 2, unit: .week)
        repository.noteUpdated(reminder)

        try AppleRemindersImporter.importSnapshots([snapshot], into: list, repository: repository, summary: &summary)

        #expect(reminder.recurrenceRuleString == nil)
        #expect(reminder.afterCompletionRepeat == ReminderAfterCompletionRepeat(count: 2, unit: .week))
    }

    @Test func unmappableRecurrenceCountsAsDegraded() throws {
        let repository = try ReminderRepository(modelContext: ModelContext(Self.inMemoryContainer()))
        let list = repository.createList(name: "Imported")
        var summary = AppleRemindersImporter.Summary()

        var snapshot = Self.snapshot(
            externalIdentifier: "ek-weird",
            title: "Weird repeat",
            due: DateComponents(year: 2026, month: 8, day: 4)
        )
        snapshot.hadUnmappableRecurrence = true
        try AppleRemindersImporter.importSnapshots([snapshot], into: list, repository: repository, summary: &summary)

        let reminder = try #require(repository.reminder(withExternalIdentifier: "ek-weird"))
        #expect(reminder.recurrenceRuleString == nil)
        #expect(summary.degradedRuleCount == 1)
    }

    /// Checklists are local-only (EventKit has no subtask API), so a
    /// re-import must not wipe one the user built after the first import.
    @Test func reimportPreservesLocalChecklist() throws {
        let repository = try ReminderRepository(modelContext: ModelContext(Self.inMemoryContainer()))
        let list = repository.createList(name: "Imported")
        var summary = AppleRemindersImporter.Summary()

        let snapshot = Self.snapshot(externalIdentifier: "ek-groceries", title: "Groceries")
        try AppleRemindersImporter.importSnapshots([snapshot], into: list, repository: repository, summary: &summary)

        let reminder = try #require(repository.reminder(withExternalIdentifier: "ek-groceries"))
        reminder.checklist = [ReminderChecklistItem(text: "Milk"), ReminderChecklistItem(text: "Eggs", isDone: true)]
        repository.noteUpdated(reminder)

        try AppleRemindersImporter.importSnapshots([snapshot], into: list, repository: repository, summary: &summary)
        let reimported = try #require(repository.reminder(withExternalIdentifier: "ek-groceries"))
        #expect(reimported.checklist.map(\.text) == ["Milk", "Eggs"])
    }
}
