import Foundation
@testable import SwiftClaw
import SwiftData
import Testing

@MainActor
struct ReminderRepositoryTests {
    private static func inMemoryContainer() throws -> ModelContainer {
        let schema = Schema([Reminder.self, ReminderList.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    private static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    // MARK: - Lists

    @Test func defaultListSeedsRemindersOnFirstUse() throws {
        let repository = try ReminderRepository(modelContext: ModelContext(Self.inMemoryContainer()))
        #expect(repository.lists().isEmpty)
        let list = repository.defaultList()
        #expect(list.name == "Reminders")
        #expect(repository.lists().count == 1)
        #expect(repository.defaultList().id == list.id)
        #expect(repository.lists().count == 1)
    }

    @Test func preferredListLookupDoesNotCreateFallback() throws {
        let repository = try ReminderRepository(modelContext: ModelContext(Self.inMemoryContainer()))

        #expect(repository.preferredList() == nil)
        #expect(repository.lists().isEmpty)

        let personal = repository.createList(name: "Personal")
        let work = repository.createList(name: "Work")
        #expect(repository.preferredList(preferredID: work.id)?.id == work.id)
        #expect(repository.preferredList(preferredID: UUID())?.id == personal.id)
    }

    @Test func listCRUDAndPreferredDefault() throws {
        let repository = try ReminderRepository(modelContext: ModelContext(Self.inMemoryContainer()))
        _ = repository.createList(name: "Personal")
        let work = repository.createList(name: "Work", colorHex: "#00FF00")

        #expect(repository.defaultList(preferredID: work.id).id == work.id)
        repository.renameList(work, name: "Office")
        #expect(repository.list(withID: work.id)?.name == "Office")

        repository.deleteList(work)
        #expect(repository.list(withID: work.id) == nil)
        #expect(repository.lists().map(\.name) == ["Personal"])
    }

    // MARK: - Reminders

    @Test func reminderCRUDAndSmartViews() throws {
        let repository = try ReminderRepository(modelContext: ModelContext(Self.inMemoryContainer()))
        let list = repository.defaultList()
        let reminder = repository.insert(
            Reminder(title: "File taxes", dueDate: Self.date(2026, 4, 15), isFlagged: true),
            into: list
        )

        #expect(repository.reminder(withID: reminder.id)?.title == "File taxes")
        #expect(repository.pendingReminders().map(\.id) == [reminder.id])
        #expect(repository.reminders(in: list).map(\.id) == [reminder.id])

        reminder.title = "File tax extension"
        repository.noteUpdated(reminder)
        #expect(repository.reminder(withID: reminder.id)?.title == "File tax extension")

        repository.deleteReminder(reminder)
        #expect(repository.pendingReminders().isEmpty)
    }

    // MARK: - Completion

    @Test func completeAndUncompletePlainReminderRoundTrips() throws {
        let repository = try ReminderRepository(modelContext: ModelContext(Self.inMemoryContainer()))
        let reminder = repository.insert(Reminder(title: "Done once"))

        repository.complete(reminder, at: Self.date(2026, 6, 1, 12))
        #expect(reminder.completedAt == Self.date(2026, 6, 1, 12))
        #expect(repository.pendingReminders().isEmpty)

        repository.uncomplete(reminder)
        #expect(reminder.completedAt == nil)
        #expect(repository.pendingReminders().map(\.id) == [reminder.id])
    }

    @Test func fixedScheduleCompletionLogsAndAdvancesFromScheduledDate() throws {
        let repository = try ReminderRepository(modelContext: ModelContext(Self.inMemoryContainer()))
        let list = repository.defaultList()
        let master = repository.insert(
            Reminder(
                title: "Weekly report",
                notes: "Send before EOD",
                dueDate: Self.date(2026, 6, 5, 9),
                hasDueTime: true,
                timeZoneIdentifier: "UTC",
                priority: .high,
                isFlagged: true,
                recurrenceRuleString: "FREQ=WEEKLY;BYDAY=FR;COUNT=3"
            ),
            into: list
        )

        repository.complete(master, at: Self.date(2026, 6, 2, 10))

        let logs = repository.completionLog(of: master)
        #expect(logs.count == 1)
        #expect(logs.first?.title == "Weekly report")
        #expect(logs.first?.list?.id == list.id)
        #expect(logs.first?.priority == .high)
        #expect(logs.first?.isFlagged == true)
        #expect(logs.first?.notes == "Send before EOD")
        #expect(logs.first?.originalOccurrenceDate == Self.date(2026, 6, 5, 9))
        #expect(logs.first?.completedAt == Self.date(2026, 6, 2, 10))
        #expect(master.dueDate == Self.date(2026, 6, 12, 9))
        #expect(master.recurrenceRuleString == "FREQ=WEEKLY;BYDAY=FR;COUNT=2")
        #expect(master.completedAt == nil)
    }

    @Test func uncompleteRecurringLogRestoresMasterAndCount() throws {
        let repository = try ReminderRepository(modelContext: ModelContext(Self.inMemoryContainer()))
        let master = repository.insert(Reminder(
            title: "Weekly report",
            dueDate: Self.date(2026, 6, 5, 9),
            hasDueTime: true,
            timeZoneIdentifier: "UTC",
            recurrenceRuleString: "FREQ=WEEKLY;BYDAY=FR;COUNT=3"
        ))

        repository.complete(master, at: Self.date(2026, 6, 2, 10))
        let log = try #require(repository.completionLog(of: master).first)
        repository.uncomplete(log)

        #expect(master.dueDate == Self.date(2026, 6, 5, 9))
        #expect(master.recurrenceRuleString == "FREQ=WEEKLY;BYDAY=FR;COUNT=3")
        #expect(master.completedAt == nil)
        #expect(repository.completionLog(of: master).isEmpty)
    }

    @Test func skipOccurrenceAdvancesWithoutLogRow() throws {
        let repository = try ReminderRepository(modelContext: ModelContext(Self.inMemoryContainer()))
        let master = repository.insert(Reminder(
            title: "Weekly report",
            dueDate: Self.date(2026, 6, 5, 9),
            hasDueTime: true,
            timeZoneIdentifier: "UTC",
            recurrenceRuleString: "FREQ=WEEKLY;BYDAY=FR;COUNT=3"
        ))

        repository.skipOccurrence(of: master)

        #expect(master.dueDate == Self.date(2026, 6, 12, 9))
        #expect(master.recurrenceRuleString == "FREQ=WEEKLY;BYDAY=FR;COUNT=2")
        #expect(repository.completionLog(of: master).isEmpty)
    }

    @Test func afterCompletionRepeatAdvancesFromCompletionDate() throws {
        let repository = try ReminderRepository(modelContext: ModelContext(Self.inMemoryContainer()))
        let master = repository.insert(Reminder(
            title: "Water plants",
            dueDate: Self.date(2026, 6, 5, 9),
            hasDueTime: true
        ))
        master.afterCompletionRepeat = ReminderAfterCompletionRepeat(count: 2, unit: .day)
        repository.saveChanges()

        repository.complete(master, at: Self.date(2026, 6, 1, 11))

        #expect(master.dueDate == Self.date(2026, 6, 3, 11))
        #expect(master.completedAt == nil)
        #expect(repository.completionLog(of: master).count == 1)
    }

    @Test func countOneExhaustionAndUndo() throws {
        let repository = try ReminderRepository(modelContext: ModelContext(Self.inMemoryContainer()))
        let master = repository.insert(Reminder(
            title: "Final report",
            dueDate: Self.date(2026, 6, 5, 9),
            hasDueTime: true,
            timeZoneIdentifier: "UTC",
            recurrenceRuleString: "FREQ=WEEKLY;BYDAY=FR;COUNT=1"
        ))

        repository.complete(master, at: Self.date(2026, 6, 5, 10))
        let log = try #require(repository.completionLog(of: master).first)
        #expect(master.completedAt == Self.date(2026, 6, 5, 10))
        #expect(master.dueDate == Self.date(2026, 6, 5, 9))
        #expect(master.recurrenceRuleString == "FREQ=WEEKLY;BYDAY=FR;COUNT=1")

        repository.uncomplete(log)
        #expect(master.completedAt == nil)
        #expect(master.dueDate == Self.date(2026, 6, 5, 9))
        #expect(master.recurrenceRuleString == "FREQ=WEEKLY;BYDAY=FR;COUNT=1")
        #expect(repository.completionLog(of: master).isEmpty)
    }

    // MARK: - Import and dedup

    @Test func upsertImportedReminderIsIdempotent() throws {
        let repository = try ReminderRepository(modelContext: ModelContext(Self.inMemoryContainer()))
        let list = repository.defaultList()

        for title in ["First pass", "Second pass"] {
            repository.upsertImportedReminder(externalIdentifier: "ek-reminder-1") { reminder in
                reminder.title = title
                reminder.source = .appleImport
                reminder.list = list
            }
        }

        let reminders = repository.pendingReminders()
        #expect(reminders.count == 1)
        #expect(reminders.first?.title == "Second pass")
        #expect(reminders.first?.source == .appleImport)
    }

    @Test func dedupeCollapsesDuplicateListsAndRemindersAndSweepsOrphanLogs() throws {
        let context = try ModelContext(Self.inMemoryContainer())
        let repository = ReminderRepository(modelContext: context)

        let olderList = ReminderList(
            name: "Work",
            externalIdentifier: "list-dup",
            createdAt: Self.date(2026, 1, 1)
        )
        let newerList = ReminderList(
            name: "Work",
            externalIdentifier: "list-dup",
            createdAt: Self.date(2026, 2, 1)
        )
        context.insert(olderList)
        context.insert(newerList)

        let older = Reminder(title: "Duplicated", externalIdentifier: "rem-dup", list: newerList)
        older.createdAt = Self.date(2026, 1, 1)
        let newer = Reminder(title: "Duplicated", externalIdentifier: "rem-dup", list: newerList)
        newer.createdAt = Self.date(2026, 2, 1)
        let orphan = Reminder(title: "Orphan log", completedAt: Self.date(2026, 6, 1))
        orphan.parentReminderID = UUID()
        context.insert(older)
        context.insert(newer)
        context.insert(orphan)

        repository.dedupeAfterRemoteMerge()

        #expect(repository.lists().count == 1)
        #expect(repository.lists().first?.id == olderList.id)
        let remaining = try context.fetch(FetchDescriptor<Reminder>())
        #expect(remaining.count == 1)
        #expect(remaining.first?.id == older.id)
        #expect(remaining.first?.list?.id == olderList.id)
    }

    @Test func dedupeNeverMergesDistinctListsSharingOnlyAName() throws {
        let context = try ModelContext(Self.inMemoryContainer())
        let repository = ReminderRepository(modelContext: context)

        context.insert(ReminderList(name: "Groceries", createdAt: Self.date(2026, 1, 1)))
        context.insert(ReminderList(name: "Groceries", createdAt: Self.date(2026, 2, 1)))

        repository.dedupeAfterRemoteMerge()

        #expect(repository.lists().count == 2)
    }

    @Test func deleteReminderOnMasterRemovesLogs() throws {
        let repository = try ReminderRepository(modelContext: ModelContext(Self.inMemoryContainer()))
        let master = repository.insert(Reminder(
            title: "Weekly report",
            dueDate: Self.date(2026, 6, 5, 9),
            hasDueTime: true,
            timeZoneIdentifier: "UTC",
            recurrenceRuleString: "FREQ=WEEKLY;BYDAY=FR"
        ))
        repository.complete(master, at: Self.date(2026, 6, 5, 10))
        #expect(repository.completionLog(of: master).count == 1)

        repository.deleteReminder(master)
        #expect(repository.pendingReminders().isEmpty)
        #expect(repository.completionLog(of: master).isEmpty)
    }

    // MARK: - Review-fix regressions

    /// Undoing an old occurrence must not rewind the master: only the latest
    /// log restores state (older logs' circles are disabled in the UI, and
    /// the repository enforces the same rule).
    @Test func uncompletingAnOlderLogIsRejected() throws {
        let repository = try ReminderRepository(modelContext: ModelContext(Self.inMemoryContainer()))
        let master = repository.insert(Reminder(
            title: "Daily",
            dueDate: Self.date(2026, 6, 1, 9),
            hasDueTime: true,
            timeZoneIdentifier: "UTC",
            recurrenceRuleString: "FREQ=DAILY;COUNT=3"
        ))
        repository.complete(master, at: Self.date(2026, 6, 1, 10))
        repository.complete(master, at: Self.date(2026, 6, 2, 10))
        let logs = repository.completionLog(of: master)
        #expect(logs.count == 2)
        let ruleBefore = master.recurrenceRuleString
        let dueBefore = master.dueDate

        repository.uncomplete(logs[0]) // the older occurrence

        #expect(repository.completionLog(of: master).count == 2)
        #expect(master.dueDate == dueBefore)
        #expect(master.recurrenceRuleString == ruleBefore)

        // The latest log still undoes normally.
        repository.uncomplete(logs[1])
        #expect(repository.completionLog(of: master).count == 1)
        #expect(master.dueDate == logs[1].originalOccurrenceDate)
    }

    /// A stale completion (double-click: the second call carries the
    /// occurrence the row rendered before the first advanced it) is a no-op.
    @Test func completingWithStaleExpectedOccurrenceIsIgnored() throws {
        let repository = try ReminderRepository(modelContext: ModelContext(Self.inMemoryContainer()))
        let master = repository.insert(Reminder(
            title: "Water plants",
            dueDate: Self.date(2026, 6, 1, 9),
            hasDueTime: true,
            timeZoneIdentifier: "UTC",
            recurrenceRuleString: "FREQ=DAILY"
        ))
        let rendered = master.dueDate

        repository.complete(master, at: Self.date(2026, 6, 1, 10), expectedOccurrence: rendered)
        #expect(master.dueDate == Self.date(2026, 6, 2, 9))
        #expect(repository.completionLog(of: master).count == 1)

        // Second click, same rendered occurrence — must not consume Jun 2.
        repository.complete(master, at: Self.date(2026, 6, 1, 10), expectedOccurrence: rendered)
        #expect(master.dueDate == Self.date(2026, 6, 2, 9))
        #expect(repository.completionLog(of: master).count == 1)
    }

    /// Skipping the final COUNT occurrence retires the series instead of
    /// leaving it pending at the same due date forever.
    @Test func skippingTheFinalCountOccurrenceRetiresTheSeries() throws {
        let repository = try ReminderRepository(modelContext: ModelContext(Self.inMemoryContainer()))
        let master = repository.insert(Reminder(
            title: "Last one",
            dueDate: Self.date(2026, 6, 5, 9),
            hasDueTime: true,
            timeZoneIdentifier: "UTC",
            recurrenceRuleString: "FREQ=WEEKLY;COUNT=1"
        ))

        repository.skipOccurrence(of: master, at: Self.date(2026, 6, 4, 12))

        #expect(master.isCompleted)
        #expect(master.completedAt == Self.date(2026, 6, 4, 12))
        #expect(master.dueDate == Self.date(2026, 6, 5, 9))
        #expect(repository.completionLog(of: master).isEmpty)
    }

    /// The dedupe survivor is the earliest-created row even when a newer
    /// duplicate sorts first by manual order.
    @Test func dedupeKeepsEarliestCreatedReminderRegardlessOfSortOrder() throws {
        let repository = try ReminderRepository(modelContext: ModelContext(Self.inMemoryContainer()))
        let original = Reminder(title: "Original", externalIdentifier: "shared-id")
        original.createdAt = Self.date(2026, 1, 1)
        original.sortOrder = 5
        repository.insert(original)
        let duplicate = Reminder(title: "Duplicate", externalIdentifier: "shared-id")
        duplicate.createdAt = Self.date(2026, 3, 1)
        duplicate.sortOrder = 0 // sorts before the original
        repository.insert(duplicate)

        repository.dedupeAfterRemoteMerge()

        let survivors = repository.pendingReminders()
        #expect(survivors.map(\.title) == ["Original"])
    }
}
