import Foundation

/// The editor's working copy: the sheet binds to this value and applies it to
/// the store in one repository call on Save, so Cancel is a no-op and a
/// half-edited form never touches SwiftData (the `CalendarEventDraft` pattern).
nonisolated struct ReminderDraft {
    /// How the due date is expressed. `date` reminders are civil days (the
    /// draft holds local start-of-day; the store, a canonical civil date);
    /// `dateTime` pins an instant.
    enum DueDateMode: String, CaseIterable, Identifiable {
        case none = "None"
        case date = "On a Day"
        case dateTime = "At a Time"

        var id: String { rawValue }
    }

    /// Which repeat behavior is active. The two recurrence encodings are
    /// mutually exclusive on the model; the mode makes that a structural
    /// impossibility in the editor rather than a validation rule.
    enum RepeatMode: String, CaseIterable, Identifiable {
        case never = "Never"
        case schedule = "On a Schedule"
        case afterCompletion = "After Completion"

        var id: String { rawValue }
    }

    var title = ""
    var notes = ""
    var urlString = ""
    var listID: UUID?
    var dueDateMode: DueDateMode = .none
    /// The working due value; only meaningful when `dueDateMode != .none`.
    var dueDate: Date = .now
    var priority: ReminderPriority = .none
    var isFlagged = false
    var checklist: [ReminderChecklistItem] = []
    var repeatMode: RepeatMode = .never
    var rule: RecurrenceRule?
    var afterCompletionRepeat = ReminderAfterCompletionRepeat(count: 1, unit: .day)

    init(newAt dueDate: Date? = nil, listID: UUID?) {
        self.listID = listID
        if let dueDate {
            self.dueDate = dueDate
            dueDateMode = .date
        }
    }

    /// Loads in local terms: a date-only due day (stored as a canonical civil
    /// date) becomes its local start of day in `calendar`, and so does its
    /// series' UNTIL, so the pickers show the stored dates in any zone.
    init(from reminder: Reminder, calendar: Calendar = .current) {
        title = reminder.title
        notes = reminder.notes ?? ""
        urlString = reminder.urlString ?? ""
        listID = reminder.list?.id
        if let due = reminder.localDueDate(calendar: calendar) {
            dueDate = due
            dueDateMode = reminder.hasDueTime ? .dateTime : .date
        }
        priority = reminder.priority
        isFlagged = reminder.isFlagged
        checklist = reminder.checklist
        rule = reminder.recurrenceRuleString.flatMap(RecurrenceRule.init(rruleString:))
        if reminder.dueDate != nil, !reminder.hasDueTime {
            rule = rule?.localizingCivilUntil(to: calendar)
        }
        if let afterCompletion = reminder.afterCompletionRepeat {
            afterCompletionRepeat = afterCompletion
            repeatMode = .afterCompletion
        } else if rule != nil {
            repeatMode = .schedule
        }
    }

    var hasDueDate: Bool { dueDateMode != .none }

    /// A repeat without a due date has no anchor to advance from, so Save
    /// stays disabled until one is picked.
    var isValid: Bool {
        let hasTitle = !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let repeatIsAnchored = repeatMode == .never || hasDueDate
        return hasTitle && repeatIsAnchored
    }

    /// Copies the draft onto a model row. Never called on completion-log rows
    /// (they're history, not editable reminders).
    /// Date-only values go back to canonical civil dates, read in `calendar`.
    @MainActor
    func apply(to reminder: Reminder, in repository: ReminderRepository, calendar: Calendar = .current) {
        reminder.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        reminder.notes = notes.isEmpty ? nil : notes
        reminder.urlString = urlString.isEmpty ? nil : urlString
        reminder.priority = priority
        reminder.isFlagged = isFlagged
        reminder.checklist = checklist

        switch dueDateMode {
        case .none:
            reminder.dueDate = nil
            reminder.hasDueTime = false
            reminder.timeZoneIdentifier = nil
        case .date:
            // Date-only reminders are civil days (no zone), the all-day
            // calendar event convention: July 10 stays July 10 everywhere.
            reminder.setDueDay(CivilDay(containing: dueDate, in: calendar))
        case .dateTime:
            reminder.dueDate = dueDate
            reminder.hasDueTime = true
            if reminder.timeZoneIdentifier == nil {
                reminder.timeZoneIdentifier = TimeZone.current.identifier
            }
        }

        switch repeatMode {
        case .never:
            reminder.recurrenceRuleString = nil
            reminder.afterCompletionRepeat = nil
        case .schedule:
            let storedRule = dueDateMode == .date ? rule?.civilizingUntil(readingIn: calendar) : rule
            reminder.recurrenceRuleString = storedRule?.rruleString
            reminder.afterCompletionRepeat = nil
        case .afterCompletion:
            reminder.recurrenceRuleString = nil
            reminder.afterCompletionRepeat = afterCompletionRepeat
        }
        repository.refreshRecurrenceEnd(of: reminder)

        if let listID {
            reminder.list = repository.list(withID: listID)
        }
        repository.noteUpdated(reminder)
    }
}

/// What the editor sheet was opened for. Drives the draft's initial contents
/// and what Save writes back.
nonisolated enum ReminderEditorRequest: Identifiable {
    /// Create a new reminder, optionally pre-dated (from a list that implies
    /// one, e.g. Today) and pre-assigned to a list.
    case new(dueDate: Date?, listID: UUID?)
    /// Create from a prefilled draft (natural-language quick entry) — the
    /// editor is the confirm-before-save step.
    case quickEntry(ReminderDraft)
    /// Edit an existing reminder (a one-off or a whole recurring series —
    /// roll-forward recurrence has no per-occurrence edits).
    case edit(id: UUID)

    var id: String {
        switch self {
        case .new(let dueDate, let listID):
            "new-\(dueDate?.timeIntervalSinceReferenceDate ?? 0)-\(listID?.uuidString ?? "none")"
        case .quickEntry(let draft):
            "quick-entry-\(draft.title)-\(draft.dueDate.timeIntervalSinceReferenceDate)"
        case .edit(let id):
            "edit-\(id.uuidString)"
        }
    }
}
