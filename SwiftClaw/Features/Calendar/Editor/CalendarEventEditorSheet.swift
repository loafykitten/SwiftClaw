import SwiftUI
import SwiftData

/// The event editor sheet, used for creation and every edit scope
/// (`CalendarEditorRequest`). Binds to a `CalendarEventDraft` and writes back
/// through `CalendarRepository` only on Save.
struct CalendarEventEditorSheet: View {
    let request: CalendarEditorRequest

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \UserCalendar.sortOrder) private var calendars: [UserCalendar]

    @State private var draft = CalendarEventDraft(newAt: .now, calendarID: nil)
    @State private var hasLoaded = false
    @State private var allowsRecurrence: Bool

    init(request: CalendarEditorRequest) {
        self.request = request
        if case .editOccurrence = request {
            _allowsRecurrence = State(initialValue: false)
        } else {
            _allowsRecurrence = State(initialValue: true)
        }
    }

    private var repository: CalendarRepository {
        CalendarRepository(modelContext: modelContext)
    }

    private var sheetTitle: String {
        switch request {
        case .new, .newTimed, .quickEntry: "New Event"
        case .editEvent: "Edit Event"
        case .editOccurrence: "Edit This Event"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: sheetTitle) {
                dismiss()
            }

            Form {
                Section {
                    TextField("Title", text: $draft.title)
                    Picker("Calendar", selection: $draft.calendarID) {
                        ForEach(calendars) { calendar in
                            Label {
                                Text(calendar.name)
                            } icon: {
                                Image(systemName: "circle.fill")
                                    .foregroundStyle(Color(calendarHex: calendar.colorHex))
                            }
                            .tag(Optional(calendar.id))
                        }
                    }
                }

                Section {
                    Toggle("All Day", isOn: $draft.isAllDay)
                    DatePicker(
                        "Starts",
                        selection: startBinding,
                        displayedComponents: draft.isAllDay ? [.date] : [.date, .hourAndMinute]
                    )
                    DatePicker(
                        "Ends",
                        selection: $draft.end,
                        in: draft.start...,
                        displayedComponents: draft.isAllDay ? [.date] : [.date, .hourAndMinute]
                    )
                }

                Section {
                    if allowsRecurrence {
                        CalendarRecurrencePicker(rule: $draft.rule)
                    }
                    CalendarAlertPicker(alarms: $draft.alarms)
                }

                Section {
                    TextField("Location", text: $draft.location)
                    TextField("URL", text: $draft.urlString)
                    TextField("Notes", text: $draft.notes, axis: .vertical)
                        .lineLimit(3...8)
                }
            }
            .formStyle(.grouped)

            SheetFooter(confirmTitle: "Save", isDisabled: !draft.isValid) {
                save()
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 520)
        #endif
        .onAppear(perform: loadDraft)
    }

    /// Moving the start keeps the duration pinned (the way every calendar
    /// editor behaves). A binding rather than `onChange` so programmatic draft
    /// loads don't shift the already-correct end.
    private var startBinding: Binding<Date> {
        Binding(
            get: { draft.start },
            set: { newStart in
                let delta = newStart.timeIntervalSince(draft.start)
                draft.start = newStart
                draft.end = draft.end.addingTimeInterval(delta)
            }
        )
    }

    private func loadDraft() {
        guard !hasLoaded else { return }
        hasLoaded = true
        switch request {
        case .new(let start, let isAllDay):
            var draft = CalendarEventDraft(newAt: start, calendarID: repository.defaultCalendar(preferredID: SettingsStorage.loadCalendarDefaultCalendarID()).id)
            draft.isAllDay = isAllDay
            self.draft = draft
        case .newTimed(let start, let end):
            var draft = CalendarEventDraft(newAt: start, calendarID: repository.defaultCalendar(preferredID: SettingsStorage.loadCalendarDefaultCalendarID()).id)
            draft.end = end
            self.draft = draft
        case .quickEntry(let prefilled):
            var draft = prefilled
            if draft.calendarID == nil {
                draft.calendarID = repository.defaultCalendar(
                    preferredID: SettingsStorage.loadCalendarDefaultCalendarID()
                ).id
            }
            self.draft = draft
        case .editEvent(let id):
            if let event = repository.event(withID: id) {
                allowsRecurrence = !event.isOverride
                draft = CalendarEventDraft(from: event)
            }
        case .editOccurrence(let masterID, let occurrenceStart):
            if let master = repository.event(withID: masterID) {
                var draft = CalendarEventDraft(from: master)
                draft.start = occurrenceStart
                draft.end = occurrenceStart.addingTimeInterval(master.duration)
                draft.rule = nil
                self.draft = draft
            }
        }
    }

    private func save() {
        switch request {
        case .new, .newTimed, .quickEntry:
            let event = CalendarEvent()
            event.timeZoneIdentifier = draft.isAllDay ? nil : TimeZone.current.identifier
            draft.apply(to: event, in: repository)
            repository.insert(event)
        case .editEvent(let id):
            if let event = repository.event(withID: id) {
                draft.apply(to: event, in: repository)
            }
        case .editOccurrence(let masterID, let occurrenceStart):
            if let master = repository.event(withID: masterID) {
                let override = repository.detachOccurrence(of: master, at: occurrenceStart)
                draft.apply(to: override, in: repository)
            }
        }
        dismiss()
    }
}
