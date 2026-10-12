import Foundation

/// The editor's working copy: the sheet binds to this value and applies it to
/// the store in one repository call on Save, so Cancel is a no-op and a
/// half-edited form never touches SwiftData.
nonisolated struct CalendarEventDraft {
    var title = ""
    var calendarID: UUID?
    var start: Date
    var end: Date
    var isAllDay = false
    var location = ""
    var urlString = ""
    var notes = ""
    var rule: RecurrenceRule?
    var alarms: [CalendarAlarmPayload] = []

    init(newAt start: Date, calendarID: UUID?, defaultAlarms: [CalendarAlarmPayload] = []) {
        self.start = start
        self.end = start.addingTimeInterval(3600)
        self.calendarID = calendarID
        self.alarms = defaultAlarms
    }

    /// Loads in local terms: an all-day event's canonical civil dates become
    /// local midnights in `calendar` (exclusive end), and so does its
    /// series' UNTIL, so the pickers show the stored days in any zone.
    init(from event: CalendarEvent, calendar: Calendar = .current) {
        title = event.title
        calendarID = event.calendar?.id
        let interval = event.displayInterval(calendar: calendar)
        start = interval.start
        end = interval.end
        isAllDay = event.isAllDay
        location = event.locationText ?? ""
        urlString = event.urlString ?? ""
        notes = event.notes ?? ""
        rule = event.recurrenceRuleString.flatMap(RecurrenceRule.init(rruleString:))
        if event.isAllDay {
            rule = rule?.localizingCivilUntil(to: calendar)
        }
        alarms = event.alarms
    }

    var isValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && end > start
    }

    /// Copies the draft onto a model row. Recurrence is skipped for override
    /// rows — a detached occurrence can't itself recur.
    @MainActor
    func apply(to event: CalendarEvent, in repository: CalendarRepository, calendar: Calendar = .current) {
        event.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let wasAllDay = event.isAllDay
        if isAllDay {
            // All-day events are whole civil days (canonical dates, exclusive
            // end day, no time zone), read from the local pickers in
            // `calendar`. Without this, a timed event toggled all-day would
            // keep its 09:00–10:00 clock times in the store.
            event.setAllDaySpan(localStart: start, localEnd: end, calendar: calendar)
        } else {
            event.startDate = start
            event.endDate = end
            if event.timeZoneIdentifier == nil {
                event.timeZoneIdentifier = TimeZone.current.identifier
            }
        }
        event.isAllDay = isAllDay
        event.locationText = location.isEmpty ? nil : location
        event.urlString = urlString.isEmpty ? nil : urlString
        event.notes = notes.isEmpty ? nil : notes
        event.alarms = alarms
        if !event.isOverride {
            let storedRule = isAllDay ? rule?.civilizingUntil(readingIn: calendar) : rule
            event.recurrenceRuleString = storedRule?.rruleString
            // Switching encodings must carry EXDATEs and override keys along.
            repository.reencodeOccurrenceKeys(of: event, wasAllDay: wasAllDay, calendar: calendar)
        }
        if let calendarID {
            event.calendar = repository.calendar(withID: calendarID)
        }
        repository.noteUpdated(event)
    }
}

/// What the editor sheet was opened for. Drives both the draft's initial
/// contents and what Save writes back.
nonisolated enum CalendarEditorRequest: Identifiable {
    /// Create a new event starting at the given time.
    case new(start: Date, isAllDay: Bool)
    /// Create a new timed event with both ends fixed (drag-to-create).
    case newTimed(start: Date, end: Date)
    /// Create a new event from a prefilled draft (natural-language quick
    /// entry) — the editor is the confirm-before-save step.
    case quickEntry(CalendarEventDraft)
    /// Edit a one-off event, a detached override, or a whole recurring series.
    case editEvent(id: UUID)
    /// Edit a single occurrence of a recurring master ("this event only"):
    /// Save detaches an override. `occurrenceStart` is the stored-encoding
    /// key (`EventOccurrence.occurrenceKey`), not the displayed start.
    case editOccurrence(masterID: UUID, occurrenceStart: Date)

    var id: String {
        switch self {
        case .new(let start, let isAllDay):
            "new-\(start.timeIntervalSinceReferenceDate)-\(isAllDay)"
        case .newTimed(let start, let end):
            "new-timed-\(start.timeIntervalSinceReferenceDate)-\(end.timeIntervalSinceReferenceDate)"
        case .quickEntry(let draft):
            "quick-entry-\(draft.title)-\(draft.start.timeIntervalSinceReferenceDate)"
        case .editEvent(let id):
            "event-\(id.uuidString)"
        case .editOccurrence(let masterID, let occurrenceStart):
            "occurrence-\(masterID.uuidString)-\(occurrenceStart.timeIntervalSinceReferenceDate)"
        }
    }
}
