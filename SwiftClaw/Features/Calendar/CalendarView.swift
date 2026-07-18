import SwiftUI
import SwiftData

/// The calendar's root view: month / week / day / agenda over the same
/// windowed occurrences, with toolbar navigation and ⌘-key shortcuts
/// (⌘1–4 views, ⌘T today, ⌘⇧←/→ previous/next period, ⌘N new event).
struct CalendarView: View {
    enum DisplayMode: String, CaseIterable, Identifiable {
        case month = "Month"
        case week = "Week"
        case day = "Day"
        case agenda = "Agenda"

        var id: String { rawValue }
    }

    @Environment(\.modelContext) private var modelContext

    @State private var displayMode: DisplayMode = .month
    @State private var anchorDate: Date = .now
    @State private var editorRequest: CalendarEditorRequest?
    @AppStorage(SettingsKeys.calendarHasCompletedOnboarding) private var hasCompletedOnboarding = false
    @AppStorage(SettingsKeys.calendarOverlayEnabled) private var isOverlayEnabled = SettingsStorage.defaultCalendarOverlayEnabled
    @AppStorage(SettingsKeys.remindersEnabled) private var isRemindersEnabled = SettingsStorage.defaultRemindersEnabled
    @AppStorage(SettingsKeys.remindersShowInCalendar)
    private var isShowingReminders = SettingsStorage.defaultRemindersShowInCalendar
    @State private var isShowingOnboarding = false
    @State private var quickEntryText = ""
    @State private var isParsingQuickEntry = false
    @State private var quickEntryService = CalendarQuickEntryService()
    @State private var isShowingCalendarList = false
    /// A tapped recurring occurrence awaiting an edit-scope choice.
    @State private var scopePromptOccurrence: EventOccurrence?
    /// A recurring occurrence awaiting a delete-scope choice.
    @State private var deletePromptOccurrence: EventOccurrence?

    private var calendar: Calendar { Calendar.current }

    private var repository: CalendarRepository {
        CalendarRepository(modelContext: modelContext)
    }

    var body: some View {
        let window = visibleInterval
        VStack(spacing: 0) {
            quickEntryBar
            Divider()
            // Minute ticks keep time-derived state honest while the window
            // sits open: reminder chips cross into overdue (and roll forward
            // at midnight) without waiting for a store change to re-render.
            TimelineView(.everyMinute) { timeline in
                CalendarWindowContent(
                    window: window,
                    displayMode: displayMode,
                    monthAnchor: anchorDate,
                    timelineDays: timelineDays,
                    calendar: calendar,
                    now: timeline.date,
                    isOverlayEnabled: isOverlayEnabled,
                    showsReminders: isRemindersEnabled && isShowingReminders,
                    onSelectDay: { day in
                        anchorDate = day
                        displayMode = .day
                    },
                    onCreateAllDay: { day in
                        editorRequest = .new(start: day, isAllDay: true)
                    },
                    onSelectOccurrence: requestEdit,
                    onDeleteOccurrence: requestDelete,
                    onCreateTimed: { start, end in
                        editorRequest = .newTimed(start: start, end: end)
                    },
                    onMove: moveOccurrence,
                    onResize: resizeOccurrence,
                    onSelectReminder: openReminder,
                    onCompleteReminder: completeReminder
                )
                // SwiftData query predicates are fixed at initialization.
                .id(CalendarVisibleWindowID(window: window))
            }
        }
            .toolbar { toolbarContent }
            .navigationSubtitle(periodTitle)
            .background { shortcutButtons }
            .sheet(item: $editorRequest) { request in
                CalendarEventEditorSheet(request: request)
            }
            .sheet(isPresented: $isShowingOnboarding) {
                CalendarOnboardingSheet()
            }
            .onAppear {
                if !hasCompletedOnboarding {
                    isShowingOnboarding = true
                }
                if isOverlayEnabled {
                    Task { await CalendarOverlayProvider.shared.activate() }
                }
            }
            .onChange(of: isOverlayEnabled) { _, enabled in
                if enabled {
                    Task { await CalendarOverlayProvider.shared.activate() }
                } else {
                    CalendarOverlayProvider.shared.deactivate()
                }
            }
            .confirmationDialog(
                "This is a repeating event.",
                isPresented: Binding(
                    get: { scopePromptOccurrence != nil },
                    set: { if !$0 { scopePromptOccurrence = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let occurrence = scopePromptOccurrence {
                    Button("Edit This Event") {
                        editorRequest = .editOccurrence(
                            masterID: occurrence.eventID,
                            occurrenceStart: occurrence.start
                        )
                        scopePromptOccurrence = nil
                    }
                    Button("Edit All Events") {
                        editorRequest = .editEvent(id: occurrence.eventID)
                        scopePromptOccurrence = nil
                    }
                }
            }
            .confirmationDialog(
                "Delete this repeating event?",
                isPresented: Binding(
                    get: { deletePromptOccurrence != nil },
                    set: { if !$0 { deletePromptOccurrence = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let occurrence = deletePromptOccurrence {
                    Button("Delete This Event", role: .destructive) {
                        if let master = repository.event(withID: occurrence.eventID) {
                            repository.deleteOccurrence(of: master, at: occurrence.start)
                        }
                        deletePromptOccurrence = nil
                    }
                    Button("Delete This and Future Events", role: .destructive) {
                        if let master = repository.event(withID: occurrence.eventID) {
                            repository.deleteThisAndFuture(of: master, from: occurrence.start)
                        }
                        deletePromptOccurrence = nil
                    }
                    Button("Delete All Events", role: .destructive) {
                        if let master = repository.event(withID: occurrence.eventID) {
                            repository.deleteEventSeries(master)
                        }
                        deletePromptOccurrence = nil
                    }
                }
            }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Picker("View", selection: $displayMode) {
                ForEach(DisplayMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Button("Today") { anchorDate = .now }
                .disabled(isShowingToday)

            Button {
                step(-1)
            } label: {
                Image(systemName: "chevron.left")
            }
            .help("Previous \(periodUnitName)")

            Button {
                step(1)
            } label: {
                Image(systemName: "chevron.right")
            }
            .help("Next \(periodUnitName)")

            Button {
                isShowingCalendarList.toggle()
            } label: {
                Image(systemName: "square.stack.3d.up")
            }
            .help("Calendars")
            .popover(isPresented: $isShowingCalendarList) {
                CalendarListPopover()
            }

            Button {
                editorRequest = .new(start: defaultNewEventStart, isAllDay: false)
            } label: {
                Image(systemName: "plus")
            }
            .help("New Event")
        }
    }

    /// Natural-language quick entry: type a phrase, ⏎, review the parsed
    /// draft in the editor, save. Parsing failures fall back to a blank
    /// editor carrying the phrase as the title — typing is never lost.
    /// Lives in a slim bar above the grid, not the toolbar — a text field
    /// wide enough to type in would push every toolbar control into the
    /// overflow menu at normal window widths.
    private var quickEntryBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                if isParsingQuickEntry {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: "sparkles")
                        .font(.caption)
                        .foregroundStyle(.tint)
                }
                TextField("New event in plain words — “Lunch with Sam tomorrow 1pm”", text: $quickEntryText)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .onSubmit(submitQuickEntry)
                    .disabled(isParsingQuickEntry)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.quaternary.opacity(0.5), in: Capsule())
            .frame(maxWidth: 460)
            .help("The model fills in the event for you to confirm before saving.")

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private func submitQuickEntry() {
        let phrase = quickEntryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty, !isParsingQuickEntry else { return }
        isParsingQuickEntry = true
        let defaultCalendarID = repository.defaultCalendar(
            preferredID: SettingsStorage.loadCalendarDefaultCalendarID()
        ).id
        Task {
            defer { isParsingQuickEntry = false }
            do {
                let draft = try await quickEntryService.draft(from: phrase, calendarID: defaultCalendarID)
                quickEntryText = ""
                editorRequest = .quickEntry(draft)
            } catch {
                // Fall back to the manual editor with the phrase preserved.
                var draft = CalendarEventDraft(newAt: defaultNewEventStart, calendarID: defaultCalendarID)
                draft.title = phrase
                quickEntryText = ""
                editorRequest = .quickEntry(draft)
            }
        }
    }

    /// Hidden buttons carrying the keyboard shortcuts.
    private var shortcutButtons: some View {
        Group {
            Button("") { displayMode = .month }.keyboardShortcut("1", modifiers: .command)
            Button("") { displayMode = .week }.keyboardShortcut("2", modifiers: .command)
            Button("") { displayMode = .day }.keyboardShortcut("3", modifiers: .command)
            Button("") { displayMode = .agenda }.keyboardShortcut("4", modifiers: .command)
            Button("") { anchorDate = .now }.keyboardShortcut("t", modifiers: .command)
            Button("") { step(-1) }.keyboardShortcut(.leftArrow, modifiers: [.command, .shift])
            Button("") { step(1) }.keyboardShortcut(.rightArrow, modifiers: [.command, .shift])
            Button("") {
                editorRequest = .new(start: defaultNewEventStart, isAllDay: false)
            }
            .keyboardShortcut("n", modifiers: .command)
        }
        .opacity(0)
        .accessibilityHidden(true)
    }

    // MARK: - Window math

    private var visibleInterval: DateInterval {
        switch displayMode {
        case .month:
            // Include the leading/trailing adjacent-month days the grid shows.
            guard let month = calendar.dateInterval(of: .month, for: anchorDate),
                  let firstWeek = calendar.dateInterval(of: .weekOfYear, for: month.start),
                  let lastWeek = calendar.dateInterval(of: .weekOfYear, for: month.end - 1)
            else { return DateInterval(start: anchorDate, duration: 31 * 24 * 3600) }
            return DateInterval(start: firstWeek.start, end: lastWeek.end)
        case .week:
            return calendar.dateInterval(of: .weekOfYear, for: anchorDate)
                ?? DateInterval(start: anchorDate, duration: 7 * 24 * 3600)
        case .day:
            return calendar.dateInterval(of: .day, for: anchorDate)
                ?? DateInterval(start: anchorDate, duration: 24 * 3600)
        case .agenda:
            // Calendar-day arithmetic: a fixed 30 × 24h duration would end
            // mid-morning after a DST transition and leak a 31st day.
            let start = calendar.startOfDay(for: anchorDate)
            let end = calendar.date(byAdding: .day, value: 30, to: start)
                ?? start.addingTimeInterval(30 * 24 * 3600)
            return DateInterval(start: start, end: end)
        }
    }

    private var timelineDays: [Date] {
        switch displayMode {
        case .day:
            return [calendar.startOfDay(for: anchorDate)]
        default:
            let interval = visibleInterval
            var days: [Date] = []
            var cursor = interval.start
            while cursor < interval.end {
                days.append(cursor)
                guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
                cursor = next
            }
            return days
        }
    }

    private var periodTitle: String {
        switch displayMode {
        case .month:
            anchorDate.formatted(.dateTime.month(.wide).year())
        case .week:
            visibleInterval.start.formatted(.dateTime.month(.abbreviated).day())
                + " – "
                + (visibleInterval.end - 1).formatted(.dateTime.month(.abbreviated).day())
        case .day:
            anchorDate.formatted(.dateTime.weekday(.wide).month(.wide).day().year())
        case .agenda:
            "Next 30 days"
        }
    }

    private var periodUnitName: String {
        switch displayMode {
        case .month: "month"
        case .week: "week"
        case .day: "day"
        case .agenda: "week"
        }
    }

    private var isShowingToday: Bool {
        visibleInterval.contains(.now)
    }

    private var defaultNewEventStart: Date {
        // Next full hour on the anchored day (today's hour if anchored today).
        let base = calendar.isDateInToday(anchorDate) ? Date.now : anchorDate
        let hour = calendar.component(.hour, from: base)
        let day = calendar.startOfDay(for: base)
        return day.addingTimeInterval(TimeInterval(min(hour + 1, 23) * 3600))
    }

    private func step(_ direction: Int) {
        let component: Calendar.Component = switch displayMode {
        case .month: .month
        case .week: .weekOfYear
        case .day: .day
        case .agenda: .weekOfYear
        }
        if let next = calendar.date(byAdding: component, value: direction, to: anchorDate) {
            anchorDate = next
        }
    }

    // MARK: - Actions

    private func requestEdit(_ occurrence: EventOccurrence) {
        guard occurrence.source != .appleOverlay else { return } // read-only
        if repository.event(withID: occurrence.eventID)?.isRecurring == true {
            scopePromptOccurrence = occurrence
        } else {
            editorRequest = .editEvent(id: occurrence.eventID)
        }
    }

    private func requestDelete(_ occurrence: EventOccurrence) {
        guard occurrence.source != .appleOverlay else { return } // read-only
        if repository.event(withID: occurrence.eventID)?.isRecurring == true {
            deletePromptOccurrence = occurrence
        } else if let event = repository.event(withID: occurrence.eventID) {
            repository.deleteEventSeries(event)
        }
    }

    private func moveOccurrence(_ occurrence: EventOccurrence, to newStart: Date) {
        guard let event = repository.event(withID: occurrence.eventID) else { return }
        let duration = event.duration
        event.startDate = newStart
        event.endDate = newStart.addingTimeInterval(duration)
        repository.noteUpdated(event)
    }

    private func resizeOccurrence(_ occurrence: EventOccurrence, to newEnd: Date) {
        guard let event = repository.event(withID: occurrence.eventID), newEnd > event.startDate else { return }
        event.endDate = newEnd
        repository.noteUpdated(event)
    }

    // Reminder chips are a window into another feature: opening routes to the
    // Reminders view (their editor lives there), completing goes through the
    // reminder repository so recurrence rolls forward exactly as it would
    // from a Reminders row.

    private func openReminder(_ item: ReminderCalendarItem) {
        AppRouter.shared.showReminders(focusing: item.reminderID)
    }

    private func completeReminder(_ item: ReminderCalendarItem) {
        let reminderRepository = ReminderRepository(modelContext: modelContext)
        guard let reminder = reminderRepository.reminder(withID: item.reminderID) else { return }
        // The chip's dueDate is the occurrence it rendered; a stale
        // double-click must not consume the next occurrence too.
        reminderRepository.complete(reminder, expectedOccurrence: item.due)
    }
}

private struct CalendarVisibleWindowID: Hashable {
    let start: Date
    let end: Date

    init(window: DateInterval) {
        start = window.start
        end = window.end
    }
}

/// Owns the fixed-at-init SwiftData predicates for one visible window.
private struct CalendarWindowContent: View {
    let window: DateInterval
    let displayMode: CalendarView.DisplayMode
    let monthAnchor: Date
    let timelineDays: [Date]
    let calendar: Calendar
    let now: Date
    let isOverlayEnabled: Bool
    let showsReminders: Bool
    let onSelectDay: (Date) -> Void
    let onCreateAllDay: (Date) -> Void
    let onSelectOccurrence: (EventOccurrence) -> Void
    let onDeleteOccurrence: (EventOccurrence) -> Void
    let onCreateTimed: (Date, Date) -> Void
    let onMove: (EventOccurrence, Date) -> Void
    let onResize: (EventOccurrence, Date) -> Void
    let onSelectReminder: (ReminderCalendarItem) -> Void
    let onCompleteReminder: (ReminderCalendarItem) -> Void

    @Query private var plainEvents: [CalendarEvent]
    @Query private var recurringEvents: [CalendarEvent]
    /// Masters and one-offs only — completion-log history grows unbounded.
    @Query private var reminders: [Reminder]
    @State private var occurrenceCache = CalendarOccurrenceCache()

    init(
        window: DateInterval,
        displayMode: CalendarView.DisplayMode,
        monthAnchor: Date,
        timelineDays: [Date],
        calendar: Calendar,
        now: Date,
        isOverlayEnabled: Bool,
        showsReminders: Bool,
        onSelectDay: @escaping (Date) -> Void,
        onCreateAllDay: @escaping (Date) -> Void,
        onSelectOccurrence: @escaping (EventOccurrence) -> Void,
        onDeleteOccurrence: @escaping (EventOccurrence) -> Void,
        onCreateTimed: @escaping (Date, Date) -> Void,
        onMove: @escaping (EventOccurrence, Date) -> Void,
        onResize: @escaping (EventOccurrence, Date) -> Void,
        onSelectReminder: @escaping (ReminderCalendarItem) -> Void,
        onCompleteReminder: @escaping (ReminderCalendarItem) -> Void
    ) {
        self.window = window
        self.displayMode = displayMode
        self.monthAnchor = monthAnchor
        self.timelineDays = timelineDays
        self.calendar = calendar
        self.now = now
        self.isOverlayEnabled = isOverlayEnabled
        self.showsReminders = showsReminders
        self.onSelectDay = onSelectDay
        self.onCreateAllDay = onCreateAllDay
        self.onSelectOccurrence = onSelectOccurrence
        self.onDeleteOccurrence = onDeleteOccurrence
        self.onCreateTimed = onCreateTimed
        self.onMove = onMove
        self.onResize = onResize
        self.onSelectReminder = onSelectReminder
        self.onCompleteReminder = onCompleteReminder

        let windowStart = window.start
        let windowEnd = window.end
        let distantFuture = Date.distantFuture
        _plainEvents = Query(filter: #Predicate<CalendarEvent> {
            $0.recurrenceRuleString == nil
                && $0.startDate < windowEnd
                && $0.endDate > windowStart
        })
        _recurringEvents = Query(filter: #Predicate<CalendarEvent> {
            $0.recurrenceRuleString != nil
                && $0.startDate < windowEnd
                && ($0.recurrenceEndDate ?? distantFuture) >= windowStart
        })
        _reminders = Query(filter: #Predicate<Reminder> {
            $0.parentReminderID == nil
                && $0.completedAt == nil
                && ($0.dueDate ?? distantFuture) < windowEnd
        })
    }

    var body: some View {
        // Observation of the version refreshes this child after EventKit
        // changes; the provider serves the matching interval from its cache.
        let overlayVersion = isOverlayEnabled
            ? CalendarOverlayProvider.shared.changeVersion
            : 0
        let overlay = isOverlayEnabled
            ? CalendarOverlayProvider.shared.occurrences(in: window)
            : []
        let _ = overlayVersion
        let occurrences = occurrenceCache.occurrences(
            from: plainEvents + recurringEvents,
            overlay: overlay,
            in: window
        )
        let reminderItems = showsReminders
            ? ReminderCalendarItemBuilder.items(
                from: reminders,
                in: window,
                now: now,
                calendar: calendar
            )
            : []
        let recurringEventIDs = Set(recurringEvents.map(\.id))
            .union(overlay.map(\.eventID))

        switch displayMode {
        case .month:
            CalendarMonthGridView(
                monthAnchor: monthAnchor,
                occurrences: occurrences,
                calendar: calendar,
                onSelectDay: onSelectDay,
                onCreate: onCreateAllDay,
                onSelectOccurrence: onSelectOccurrence,
                onDeleteOccurrence: onDeleteOccurrence,
                reminderItems: reminderItems,
                onSelectReminder: onSelectReminder,
                onCompleteReminder: onCompleteReminder
            )
        case .week, .day:
            CalendarTimelineView(
                days: timelineDays,
                occurrences: occurrences,
                calendar: calendar,
                recurringEventIDs: recurringEventIDs,
                onSelectOccurrence: onSelectOccurrence,
                onDeleteOccurrence: onDeleteOccurrence,
                onCreate: onCreateTimed,
                onMove: onMove,
                onResize: onResize,
                reminderItems: reminderItems,
                onSelectReminder: onSelectReminder,
                onCompleteReminder: onCompleteReminder
            )
        case .agenda:
            CalendarAgendaListView(
                occurrences: occurrences,
                calendar: calendar,
                onSelectOccurrence: onSelectOccurrence,
                onDeleteOccurrence: onDeleteOccurrence,
                reminderItems: reminderItems,
                onSelectReminder: onSelectReminder,
                onCompleteReminder: onCompleteReminder
            )
        }
    }
}

@MainActor
private final class CalendarOccurrenceCache {
    private struct Key: Equatable {
        let window: DateInterval
        let events: [EventContent]
        let overlay: [EventOccurrence]
    }

    private struct EventContent: Equatable {
        let id: UUID
        let title: String
        let startDate: Date
        let endDate: Date
        let isAllDay: Bool
        let timeZoneIdentifier: String?
        let recurrenceRuleString: String?
        let recurrenceEndDate: Date?
        let exceptionDatesData: Data?
        let parentEventID: UUID?
        let sourceRawValue: String
        let createdAt: Date
        let calendarID: UUID?
        let calendarIsVisible: Bool?
        let calendarColorHex: String?

        init(event: CalendarEvent) {
            id = event.id
            title = event.title
            startDate = event.startDate
            endDate = event.endDate
            isAllDay = event.isAllDay
            timeZoneIdentifier = event.timeZoneIdentifier
            recurrenceRuleString = event.recurrenceRuleString
            recurrenceEndDate = event.recurrenceEndDate
            exceptionDatesData = event.exceptionDatesData
            parentEventID = event.parentEventID
            sourceRawValue = event.sourceRawValue
            createdAt = event.createdAt
            calendarID = event.calendar?.id
            calendarIsVisible = event.calendar?.isVisible
            calendarColorHex = event.calendar?.colorHex
        }
    }

    private var key: Key?
    private var value: [EventOccurrence] = []

    /// Expansion invalidates only when the visible interval or rendered row
    /// content changes; minute ticks and unrelated review stamps reuse it.
    func occurrences(
        from events: [CalendarEvent],
        overlay: [EventOccurrence],
        in window: DateInterval
    ) -> [EventOccurrence] {
        let nextKey = Key(
            window: window,
            events: events.map(EventContent.init),
            overlay: overlay
        )
        guard key != nextKey else { return value }

        key = nextKey
        value = (CalendarOccurrenceBuilder.occurrences(from: events, in: window) + overlay)
            .sorted { ($0.start, $0.title) < ($1.start, $1.title) }
        return value
    }
}

#Preview {
    NavigationStack {
        CalendarView()
    }
    .modelContainer(for: [CalendarEvent.self, UserCalendar.self, Reminder.self, ReminderList.self], inMemory: true)
}
