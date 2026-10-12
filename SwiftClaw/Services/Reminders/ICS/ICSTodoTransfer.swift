import Foundation

extension ICSTodoRepresentation {
    /// Export mapping. The UID prefers the reminder's original external
    /// identity so an export→import round trip (or a re-import into another
    /// SwiftClaw) dedups instead of duplicating.
    @MainActor
    init(reminder: Reminder) {
        self.init(uid: reminder.externalIdentifier ?? "\(ReminderRepository.nativeExportUIDPrefix)\(reminder.id.uuidString)")
        title = reminder.title
        notes = reminder.notes
        urlString = reminder.urlString
        due = reminder.dueDate
        isDateOnly = reminder.dueDate != nil && !reminder.hasDueTime
        timeZoneIdentifier = reminder.timeZoneIdentifier
        priority = reminder.priorityRawValue
        isFlagged = reminder.isFlagged
        completedAt = reminder.completedAt
        isCompleted = reminder.completedAt != nil
        rruleString = reminder.recurrenceRuleString
        afterCompletionRepeat = reminder.afterCompletionRepeat
        checklist = reminder.checklist
    }
}

/// Applies parsed VTODOs to the store. Import is idempotent: rows are
/// upserted by UID (`externalIdentifier`, or a native row's exported
/// `swiftclaw-<id>`), so re-importing the same file — or your own export —
/// updates rather than duplicates. All .ics to-do usage funnels through here
/// (the `ICSImporter` pattern) so the backend stays swappable. A failed save
/// throws `ReminderRepository.ImportSaveError` with the committed count.
@MainActor
enum ICSTodoImporter {
    @discardableResult
    static func importTodos(
        from text: String,
        into list: ReminderList,
        repository: ReminderRepository
    ) throws -> Int {
        try importTodos(ICSParser.parseTodos(text), into: list, repository: repository)
    }

    @discardableResult
    static func importTodos(
        _ parsed: [ICSTodoRepresentation],
        into list: ReminderList,
        repository: ReminderRepository
    ) throws -> Int {
        var remaining = parsed[...]
        let identities = parsed.map {
            ReminderRepository.ImportedReminderIdentity(externalIdentifier: $0.uid)
        }
        try repository.upsertImportedReminders(identities) { _, reminder in
            apply(remaining.removeFirst(), to: reminder, list: list)
        }
        return parsed.count
    }

    private static func apply(
        _ representation: ICSTodoRepresentation,
        to reminder: Reminder,
        list: ReminderList
    ) {
        reminder.title = representation.title
        reminder.notes = representation.notes
        reminder.urlString = representation.urlString
        reminder.dueDate = representation.due
        reminder.hasDueTime = representation.due != nil && !representation.isDateOnly
        reminder.timeZoneIdentifier = representation.isDateOnly ? nil : representation.timeZoneIdentifier
        reminder.priorityRawValue = min(max(representation.priority, 0), 9)
        reminder.isFlagged = representation.isFlagged
        reminder.completedAt = representation.completedAt
            ?? (representation.isCompleted ? (reminder.completedAt ?? .now) : nil)
        reminder.checklist = representation.checklist

        // Repeats need a due-date anchor, and a foreign RRULE outside our
        // subset degrades to a one-off rather than storing a string the
        // engine can't advance. The modes stay mutually exclusive.
        let rule = representation.rruleString.flatMap(RecurrenceRule.init(rruleString:))
        if representation.due != nil, let rule {
            reminder.recurrenceRuleString = rule.rruleString
            reminder.afterCompletionRepeat = nil
        } else if representation.due != nil, let repeatAfter = representation.afterCompletionRepeat {
            reminder.recurrenceRuleString = nil
            reminder.afterCompletionRepeat = repeatAfter
        } else {
            reminder.recurrenceRuleString = nil
            reminder.afterCompletionRepeat = nil
        }

        // A native row matched by its exported UID has no external identity:
        // it's the user's own reminder coming home, so it keeps its
        // provenance and list.
        if reminder.externalIdentifier != nil {
            reminder.source = .icsImport
            reminder.list = list
        }
    }

    @MainActor
    static func exportText(for reminders: [Reminder], listName: String?) -> String {
        ICSSerializer.serialize(
            todos: reminders.map(ICSTodoRepresentation.init(reminder:)),
            listName: listName
        )
    }
}
