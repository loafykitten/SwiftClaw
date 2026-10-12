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

        try repository.deleteReminder(reminder)
        #expect(repository.pendingReminders().isEmpty)
    }

    @Test func pendingFetchAppliesWindowLimitAndKeepsOverdueAndUndated() throws {
        let repository = try ReminderRepository(modelContext: ModelContext(Self.inMemoryContainer()))
        let overdue = repository.insert(Reminder(title: "Overdue", dueDate: Self.date(2026, 6, 1)))
        let soon = repository.insert(Reminder(title: "Soon", dueDate: Self.date(2026, 6, 2)))
        _ = repository.insert(Reminder(title: "Far", dueDate: Self.date(2026, 7, 1)))
        let inbox = repository.insert(Reminder(title: "Inbox"))
        let completed = repository.insert(Reminder(title: "Completed", dueDate: Self.date(2026, 6, 2)))
        try repository.complete(completed)
        let log = Reminder(title: "History", dueDate: Self.date(2026, 6, 2), completedAt: .now)
        log.parentReminderID = UUID()
        repository.insert(log)

        let candidates = repository.pendingReminders(
            dueBefore: Self.date(2026, 6, 3),
            includeUndated: true
        )
        #expect(candidates.map(\.id) == [overdue.id, soon.id, inbox.id])
        #expect(repository.pendingReminders(
            dueBefore: Self.date(2026, 6, 3),
            includeUndated: true,
            limit: 2
        ).map(\.id) == [overdue.id, soon.id])
        #expect(repository.pendingReminders(
            dueBefore: Self.date(2026, 6, 3),
            includeUndated: false
        ).map(\.id) == [overdue.id, soon.id])
    }

    @Test func completedHistoryDescriptorsKeepOneOffsAndScopeLists() throws {
        let context = try ModelContext(Self.inMemoryContainer())
        let repository = ReminderRepository(modelContext: context)
        let firstList = repository.createList(name: "First")
        let secondList = repository.createList(name: "Second")
        let oneOff = repository.insert(Reminder(title: "Completed one-off"), into: firstList)
        try repository.complete(oneOff)
        let other = repository.insert(Reminder(title: "Other list"), into: secondList)
        try repository.complete(other)

        let listHistory = try context.fetch(ReminderListDetailView.completedHistoryDescriptor(
            for: .list(firstList.id)
        ))
        #expect(listHistory.map(\.id) == [oneOff.id])
        #expect(listHistory.first?.parentReminderID == nil)

        let completedHistory = try context.fetch(ReminderListDetailView.completedHistoryDescriptor(
            for: .smart(.completed)
        ))
        #expect(Set(completedHistory.map(\.id)) == Set([oneOff.id, other.id]))
    }

    // MARK: - Completion

    @Test func completeAndUncompletePlainReminderRoundTrips() throws {
        let repository = try ReminderRepository(modelContext: ModelContext(Self.inMemoryContainer()))
        let reminder = repository.insert(Reminder(title: "Done once"))

        try repository.complete(reminder, at: Self.date(2026, 6, 1, 12))
        #expect(reminder.completedAt == Self.date(2026, 6, 1, 12))
        #expect(repository.pendingReminders().isEmpty)

        try repository.uncomplete(reminder)
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

        try repository.complete(master, at: Self.date(2026, 6, 2, 10))

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

        try repository.complete(master, at: Self.date(2026, 6, 2, 10))
        let log = try #require(repository.completionLog(of: master).first)
        try repository.uncomplete(log)

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

        try repository.skipOccurrence(of: master)

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

        try repository.complete(master, at: Self.date(2026, 6, 1, 11))

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

        try repository.complete(master, at: Self.date(2026, 6, 5, 10))
        let log = try #require(repository.completionLog(of: master).first)
        #expect(master.completedAt == Self.date(2026, 6, 5, 10))
        #expect(master.dueDate == Self.date(2026, 6, 5, 9))
        #expect(master.recurrenceRuleString == "FREQ=WEEKLY;BYDAY=FR;COUNT=1")

        try repository.uncomplete(log)
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
        try repository.complete(master, at: Self.date(2026, 6, 5, 10))
        #expect(repository.completionLog(of: master).count == 1)

        try repository.deleteReminder(master)
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
        try repository.complete(master, at: Self.date(2026, 6, 1, 10))
        try repository.complete(master, at: Self.date(2026, 6, 2, 10))
        let logs = repository.completionLog(of: master)
        #expect(logs.count == 2)
        #expect(repository.latestCompletionLogIDs(for: [master.id]) == [logs[1].id])
        let ruleBefore = master.recurrenceRuleString
        let dueBefore = master.dueDate

        #expect(throws: ReminderRepository.UndoCompletionError.notLatestCompletion) {
            try repository.uncomplete(logs[0]) // the older occurrence
        }

        #expect(repository.completionLog(of: master).count == 2)
        #expect(master.dueDate == dueBefore)
        #expect(master.recurrenceRuleString == ruleBefore)

        // The latest log still undoes normally.
        try repository.uncomplete(logs[1])
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

        try repository.complete(master, at: Self.date(2026, 6, 1, 10), expectedOccurrence: rendered)
        #expect(master.dueDate == Self.date(2026, 6, 2, 9))
        #expect(repository.completionLog(of: master).count == 1)

        // Second click, same rendered occurrence — must not consume Jun 2.
        try repository.complete(master, at: Self.date(2026, 6, 1, 10), expectedOccurrence: rendered)
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

        try repository.skipOccurrence(of: master, at: Self.date(2026, 6, 4, 12))

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

    // MARK: - Undo after intervening changes

    /// Complete day 1 of a three-day series, skip day 2, then undo day 1:
    /// the skip left no log row, but rewinding would reinstate day 2 and
    /// lose day 3. The undo is refused and nothing changes.
    @Test func undoAfterASkipIsRejected() throws {
        let repository = try ReminderRepository(modelContext: ModelContext(Self.inMemoryContainer()))
        let master = repository.insert(Reminder(
            title: "Daily",
            dueDate: Self.date(2026, 6, 1, 9),
            hasDueTime: true,
            timeZoneIdentifier: "UTC",
            recurrenceRuleString: "FREQ=DAILY;COUNT=3"
        ))
        try repository.complete(master, at: Self.date(2026, 6, 1, 10))
        try repository.skipOccurrence(of: master, at: Self.date(2026, 6, 2, 10))
        #expect(master.dueDate == Self.date(2026, 6, 3, 9))
        #expect(master.recurrenceRuleString == "FREQ=DAILY;COUNT=1")

        let log = try #require(repository.completionLog(of: master).first)
        #expect(throws: ReminderRepository.UndoCompletionError.changedSinceCompletion) {
            try repository.uncomplete(log)
        }

        #expect(master.dueDate == Self.date(2026, 6, 3, 9))
        #expect(master.recurrenceRuleString == "FREQ=DAILY;COUNT=1")
        #expect(repository.completionLog(of: master).count == 1)
    }

    @Test func undoAfterARescheduleIsRejected() throws {
        let repository = try ReminderRepository(modelContext: ModelContext(Self.inMemoryContainer()))
        let master = repository.insert(Reminder(
            title: "Weekly report",
            dueDate: Self.date(2026, 6, 5, 9),
            hasDueTime: true,
            timeZoneIdentifier: "UTC",
            recurrenceRuleString: "FREQ=WEEKLY;BYDAY=FR"
        ))
        try repository.complete(master, at: Self.date(2026, 6, 5, 10))
        master.dueDate = Self.date(2026, 6, 20, 9) // user moved the next one
        repository.noteUpdated(master)

        let log = try #require(repository.completionLog(of: master).first)
        #expect(throws: ReminderRepository.UndoCompletionError.changedSinceCompletion) {
            try repository.uncomplete(log)
        }
        #expect(master.dueDate == Self.date(2026, 6, 20, 9))
    }

    @Test func afterCompletionUndoRestoresAndRejectsAfterASkip() throws {
        let repository = try ReminderRepository(modelContext: ModelContext(Self.inMemoryContainer()))
        let master = repository.insert(Reminder(
            title: "Water plants",
            dueDate: Self.date(2026, 6, 5, 9),
            hasDueTime: true,
            timeZoneIdentifier: "UTC"
        ))
        master.afterCompletionRepeat = ReminderAfterCompletionRepeat(count: 2, unit: .day)
        repository.saveChanges()

        // Unchanged since completion: undo restores the original due date.
        try repository.complete(master, at: Self.date(2026, 6, 1, 11))
        var log = try #require(repository.completionLog(of: master).first)
        try repository.uncomplete(log)
        #expect(master.dueDate == Self.date(2026, 6, 5, 9))
        #expect(repository.completionLog(of: master).isEmpty)

        // A skip after completing makes the undo incompatible.
        try repository.complete(master, at: Self.date(2026, 6, 1, 11))
        try repository.skipOccurrence(of: master)
        log = try #require(repository.completionLog(of: master).first)
        #expect(throws: ReminderRepository.UndoCompletionError.changedSinceCompletion) {
            try repository.uncomplete(log)
        }
        #expect(master.dueDate == Self.date(2026, 6, 5, 11))
    }

    /// Complete day 1 of `DAILY;COUNT=3`, then raise the remaining count
    /// from 2 to 10 without moving day 2. Replaying from the current rule
    /// would accept the undo and write COUNT=11; the recorded after-state
    /// shows the rule was edited, so the undo is refused.
    @Test func undoAfterACountEditIsRejected() throws {
        let repository = try ReminderRepository(modelContext: ModelContext(Self.inMemoryContainer()))
        let master = repository.insert(Reminder(
            title: "Daily",
            dueDate: Self.date(2026, 6, 1, 9),
            hasDueTime: true,
            timeZoneIdentifier: "UTC",
            recurrenceRuleString: "FREQ=DAILY;COUNT=3"
        ))
        try repository.complete(master, at: Self.date(2026, 6, 1, 10))
        #expect(master.recurrenceRuleString == "FREQ=DAILY;COUNT=2")
        master.recurrenceRuleString = "FREQ=DAILY;COUNT=10"
        repository.noteUpdated(master)

        let log = try #require(repository.completionLog(of: master).first)
        #expect(throws: ReminderRepository.UndoCompletionError.changedSinceCompletion) {
            try repository.uncomplete(log)
        }

        #expect(master.dueDate == Self.date(2026, 6, 2, 9))
        #expect(master.recurrenceRuleString == "FREQ=DAILY;COUNT=10")
        #expect(repository.completionLog(of: master).count == 1)
    }

    /// Edits that leave the schedule alone (a title change, an editor save
    /// that re-serializes the same rule) don't block undo, which restores
    /// the pre-completion state exactly.
    @Test func undoAfterANonScheduleEditRestoresTheRecordedState() throws {
        let repository = try ReminderRepository(modelContext: ModelContext(Self.inMemoryContainer()))
        let master = repository.insert(Reminder(
            title: "Daily",
            dueDate: Self.date(2026, 6, 1, 9),
            hasDueTime: true,
            timeZoneIdentifier: "UTC",
            recurrenceRuleString: "FREQ=DAILY;COUNT=3"
        ))
        try repository.complete(master, at: Self.date(2026, 6, 1, 10))
        let log = try #require(repository.completionLog(of: master).first)
        #expect(log.completionSnapshot?.before.recurrenceRuleString == "FREQ=DAILY;COUNT=3")
        #expect(log.completionSnapshot?.after.recurrenceRuleString == "FREQ=DAILY;COUNT=2")

        master.title = "Daily stretch"
        let rule = try #require(master.recurrenceRuleString.flatMap(RecurrenceRule.init(rruleString:)))
        master.recurrenceRuleString = rule.rruleString
        repository.noteUpdated(master)

        try repository.uncomplete(log)

        #expect(master.dueDate == Self.date(2026, 6, 1, 9))
        #expect(master.recurrenceRuleString == "FREQ=DAILY;COUNT=3")
        #expect(master.completedAt == nil)
        #expect(master.title == "Daily stretch")
        #expect(repository.completionLog(of: master).isEmpty)
    }

    /// Logs from before completions recorded a snapshot can't be undone
    /// safely, so undo refuses them instead of guessing.
    @Test func undoOfALogWithoutASnapshotIsRejected() throws {
        let repository = try ReminderRepository(modelContext: ModelContext(Self.inMemoryContainer()))
        let master = repository.insert(Reminder(
            title: "Daily",
            dueDate: Self.date(2026, 6, 1, 9),
            hasDueTime: true,
            timeZoneIdentifier: "UTC",
            recurrenceRuleString: "FREQ=DAILY;COUNT=3"
        ))
        try repository.complete(master, at: Self.date(2026, 6, 1, 10))
        let log = try #require(repository.completionLog(of: master).first)
        log.completionSnapshotData = nil
        repository.saveChanges()

        #expect(throws: ReminderRepository.UndoCompletionError.notRecorded) {
            try repository.uncomplete(log)
        }
        #expect(master.dueDate == Self.date(2026, 6, 2, 9))
        #expect(repository.completionLog(of: master).count == 1)
    }

    // MARK: - Single-mutation save failures

    /// A failed completion throws and rolls back only itself: no log row,
    /// the master keeps its occurrence and COUNT, and edits another writer
    /// left pending on the shared context were saved rather than discarded.
    @Test func failedCompletionThrowsAndRollsBackOnlyTheCompletion() throws {
        let container = try Self.inMemoryContainer()
        let saves = ScriptedSaves()
        let repository = ReminderRepository(modelContext: ModelContext(container)) { try saves.persist($0) }
        let master = repository.insert(Reminder(
            title: "Daily",
            dueDate: Self.date(2026, 6, 1, 9),
            hasDueTime: true,
            timeZoneIdentifier: "UTC",
            recurrenceRuleString: "FREQ=DAILY;COUNT=3"
        ))
        let other = repository.insert(Reminder(title: "Other"))
        other.title = "Other, renamed" // unsaved work from elsewhere

        // The pending-changes save succeeds; the completion's own commit fails.
        saves.outcomes = [true, false]
        #expect(throws: ReminderRepository.SaveError.self) {
            try repository.complete(master, at: Self.date(2026, 6, 1, 10))
        }

        #expect(master.dueDate == Self.date(2026, 6, 1, 9))
        #expect(master.recurrenceRuleString == "FREQ=DAILY;COUNT=3")
        #expect(repository.completionLog(of: master).isEmpty)
        #expect(other.title == "Other, renamed")
        let fresh = ModelContext(container)
        let masterID = master.id
        let storedMaster = try fresh.fetch(FetchDescriptor<Reminder>(predicate: #Predicate { $0.id == masterID }))
        #expect(storedMaster.first?.recurrenceRuleString == "FREQ=DAILY;COUNT=3")
        #expect(try fresh.fetchCount(FetchDescriptor<Reminder>()) == 2)
        let otherID = other.id
        let storedOther = try fresh.fetch(FetchDescriptor<Reminder>(predicate: #Predicate { $0.id == otherID }))
        #expect(storedOther.first?.title == "Other, renamed")

        // A retry goes through normally.
        try repository.complete(master, at: Self.date(2026, 6, 1, 10))
        #expect(master.dueDate == Self.date(2026, 6, 2, 9))
        #expect(repository.completionLog(of: master).count == 1)
    }

    @Test func failedSkipUndoAndDeleteThrowAndChangeNothing() throws {
        let container = try Self.inMemoryContainer()
        let saves = ScriptedSaves()
        let repository = ReminderRepository(modelContext: ModelContext(container)) { try saves.persist($0) }
        let master = repository.insert(Reminder(
            title: "Daily",
            dueDate: Self.date(2026, 6, 1, 9),
            hasDueTime: true,
            timeZoneIdentifier: "UTC",
            recurrenceRuleString: "FREQ=DAILY;COUNT=3"
        ))
        try repository.complete(master, at: Self.date(2026, 6, 1, 10))
        let log = try #require(repository.completionLog(of: master).first)

        saves.outcomes = [false]
        #expect(throws: ReminderRepository.SaveError.self) {
            try repository.skipOccurrence(of: master)
        }
        #expect(master.dueDate == Self.date(2026, 6, 2, 9))
        #expect(master.recurrenceRuleString == "FREQ=DAILY;COUNT=2")

        saves.outcomes = [false]
        #expect(throws: ReminderRepository.SaveError.self) {
            try repository.uncomplete(log)
        }
        #expect(master.dueDate == Self.date(2026, 6, 2, 9))
        #expect(repository.completionLog(of: master).count == 1)

        saves.outcomes = [false]
        #expect(throws: ReminderRepository.SaveError.self) {
            try repository.deleteReminder(master)
        }
        #expect(repository.reminder(withID: master.id) != nil)
        #expect(repository.completionLog(of: master).count == 1)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<Reminder>()) == 2)
    }
}
