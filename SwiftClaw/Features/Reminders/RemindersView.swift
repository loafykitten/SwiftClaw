import SwiftUI
import SwiftData

/// The Reminders root view: a sidebar of smart views + user lists beside the
/// selected list's reminders. Deliberately calm — one sidebar, one detail
/// pane, one editor sheet; no boards, no badges competing for attention.
/// ⌘N creates a reminder in the current context.
struct RemindersView: View {
    /// Reminder routed in from a notification tap; the view selects the pane
    /// containing it and reports back so the router clears the focus.
    var focusReminderID: UUID?
    var onFocusHandled: () -> Void = {}

    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<Reminder> {
        $0.completedAt == nil && $0.parentReminderID == nil
    })
    private var pendingReminders: [Reminder]
    @Query(sort: \ReminderList.sortOrder) private var lists: [ReminderList]

    @State private var selection: ReminderListDetailView.Selection? = .smart(.today)
    @State private var editorRequest: ReminderEditorRequest?
    @State private var isShowingListPopover = false
    @AppStorage(SettingsKeys.remindersHasCompletedOnboarding) private var hasCompletedOnboarding = false
    @State private var isShowingOnboarding = false
    @State private var quickEntryText = ""
    @State private var isParsingQuickEntry = false
    @State private var quickEntryService = ReminderQuickEntryService()

    private var repository: ReminderRepository {
        ReminderRepository(modelContext: modelContext)
    }

    var body: some View {
        VStack(spacing: 0) {
            quickEntryBar
            Divider()
            // Minute ticks keep Today membership and overdue styling honest
            // while the window sits open (matching CalendarView) — a store
            // write is not required for time to pass.
            TimelineView(.everyMinute) { timeline in
                panes(now: timeline.date)
            }
        }
        .toolbar { toolbarContent }
        .background { shortcutButtons }
        .sheet(item: $editorRequest) { request in
            ReminderEditorSheet(request: request)
        }
        .sheet(isPresented: $isShowingOnboarding) {
            RemindersOnboardingSheet()
        }
        .onAppear {
            normalizeSelection()
            applyPendingFocus()
            if !hasCompletedOnboarding {
                isShowingOnboarding = true
            }
        }
        .onChange(of: focusReminderID) { _, _ in
            applyPendingFocus()
        }
        .onChange(of: visibleLists.map(\.id)) { _, _ in
            normalizeSelection()
        }
    }

    private func panes(now: Date) -> some View {
        let visiblePending = pendingReminders.filter(\.isInVisibleList)
        let sidebarSnapshot = SidebarSnapshot(reminders: visiblePending, now: now)
        return HStack(spacing: 0) {
            sidebar(snapshot: sidebarSnapshot)
                .frame(width: 210)
            Divider()
            detail(now: now, visiblePending: visiblePending)
        }
    }

    // MARK: - Sidebar

    private func sidebar(snapshot: SidebarSnapshot) -> some View {
        List(selection: $selection) {
            Section {
                ForEach(ReminderSmartList.allCases) { smart in
                    smartRow(smart, count: snapshot.smartCounts[smart] ?? 0)
                        .tag(ReminderListDetailView.Selection.smart(smart))
                }
            }

            Section("My Lists") {
                ForEach(visibleLists) { list in
                    listRow(list, count: snapshot.listCounts[list.id] ?? 0)
                        .tag(ReminderListDetailView.Selection.list(list.id))
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func smartRow(_ smart: ReminderSmartList, count: Int) -> some View {
        Label {
            HStack {
                Text(smart.rawValue)
                Spacer(minLength: 4)
                if smart != .completed, count > 0 {
                    Text("\(count)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: smart.systemImage)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            smart == .completed ? smart.rawValue : "\(smart.rawValue), \(count) pending"
        )
        .accessibilityAddTraits(selection == .smart(smart) ? .isSelected : [])
    }

    private func listRow(_ list: ReminderList, count: Int) -> some View {
        Label {
            HStack {
                Text(list.name)
                Spacer(minLength: 4)
                if count > 0 {
                    Text("\(count)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: "circle.fill")
                .foregroundStyle(Color(calendarHex: list.colorHex))
                .font(.caption)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(list.name), \(count) pending")
        .accessibilityAddTraits(selection == .list(list.id) ? .isSelected : [])
    }

    // MARK: - Detail

    @ViewBuilder
    private func detail(now: Date, visiblePending: [Reminder]) -> some View {
        if let selection {
            VStack(alignment: .leading, spacing: 0) {
                Text(detailTitle(for: selection))
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(detailTitleColor(for: selection))
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 6)
                    .accessibilityAddTraits(.isHeader)

                ReminderListDetailView(
                    selection: selection,
                    pendingReminders: visiblePending,
                    lists: lists,
                    now: now,
                    onEdit: { editorRequest = .edit(id: $0.id) }
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ContentUnavailableView(
                "Select a list",
                systemImage: "checklist",
                description: Text("Choose a smart view or list from the sidebar.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Quick entry

    /// Natural-language quick entry: type a phrase, ⏎, review the parsed
    /// draft in the editor, save. Parsing failures fall back to a blank
    /// editor carrying the phrase as the title — typing is never lost.
    /// Lives in a slim bar above the panes, not the toolbar — a text field
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
                TextField("New reminder in plain words — “Email Priya tomorrow 9am”", text: $quickEntryText)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .onSubmit(submitQuickEntry)
                    .disabled(isParsingQuickEntry)
                    .accessibilityLabel("New reminder in plain words")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.quaternary.opacity(0.5), in: Capsule())
            .frame(maxWidth: 460)
            .help("The model fills in the reminder for you to confirm before saving.")

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private func submitQuickEntry() {
        let phrase = quickEntryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty, !isParsingQuickEntry else { return }
        isParsingQuickEntry = true
        let listOptions = visibleLists.map { (id: $0.id, name: $0.name) }
        let contextListID: UUID? = switch selection {
        case .list(let id): id
        default: nil
        }
        Task {
            defer { isParsingQuickEntry = false }
            do {
                var draft = try await quickEntryService.draft(from: phrase, lists: listOptions)
                // An unmatched list inherits the open list; the editor applies
                // the default when that's nil too.
                if draft.listID == nil {
                    draft.listID = contextListID
                }
                quickEntryText = ""
                editorRequest = .quickEntry(draft)
            } catch {
                // Fall back to the manual editor with the phrase preserved.
                var draft = ReminderDraft(newAt: nil, listID: contextListID)
                draft.title = phrase
                quickEntryText = ""
                editorRequest = .quickEntry(draft)
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                isShowingListPopover.toggle()
            } label: {
                Image(systemName: "square.stack.3d.up")
            }
            .help("Manage lists")
            .accessibilityLabel("Manage Lists")
            .popover(isPresented: $isShowingListPopover) {
                ReminderListPopover()
            }

            Button {
                editorRequest = newReminderRequest
            } label: {
                Image(systemName: "plus")
            }
            .help("New Reminder")
            .accessibilityLabel("New Reminder")
        }
    }

    /// Hidden buttons carrying the keyboard shortcuts.
    private var shortcutButtons: some View {
        Button("") { editorRequest = newReminderRequest }
            .keyboardShortcut("n", modifiers: .command)
            .opacity(0)
            .accessibilityHidden(true)
    }

    // MARK: - Derived

    private var visibleLists: [ReminderList] {
        lists.filter(\.isVisible)
    }

    /// A new reminder inherits the current context: today's date in Today,
    /// the open list in a list view.
    private var newReminderRequest: ReminderEditorRequest {
        switch selection {
        case .smart(.today):
            .new(dueDate: Calendar.current.startOfDay(for: .now), listID: nil)
        case .list(let id):
            .new(dueDate: nil, listID: id)
        default:
            .new(dueDate: nil, listID: nil)
        }
    }

    private func detailTitle(for selection: ReminderListDetailView.Selection) -> String {
        switch selection {
        case .smart(let smart):
            smart.rawValue
        case .list(let id):
            lists.first { $0.id == id }?.name ?? String(localized: "Reminders")
        }
    }

    private func detailTitleColor(for selection: ReminderListDetailView.Selection) -> Color {
        switch selection {
        case .smart:
            .primary
        case .list(let id):
            lists.first { $0.id == id }.map { Color(calendarHex: $0.colorHex) } ?? .primary
        }
    }

    private func normalizeSelection() {
        let visibleIDs = Set(visibleLists.map(\.id))
        if selection?.isAvailable(visibleListIDs: visibleIDs) != true {
            selection = .smart(.today)
        }
    }

    /// Selects the pane holding the notification-tapped reminder: its list
    /// when visible, otherwise its editor directly — no smart view is
    /// guaranteed to contain a hidden-list reminder (its due date may have
    /// rolled past Today). Always reports the focus handled so a stale ID
    /// can't re-trigger later.
    private func applyPendingFocus() {
        guard let focusReminderID else { return }
        defer { onFocusHandled() }
        // Unfiltered lookup: hidden-list reminders still fire alerts.
        guard let reminder = repository.reminder(withID: focusReminderID),
              !reminder.isCompletionLog
        else { return }
        if let list = reminder.list, list.isVisible {
            selection = .list(list.id)
        } else {
            editorRequest = .edit(id: reminder.id)
        }
    }

    private struct SidebarSnapshot {
        var smartCounts: [ReminderSmartList: Int] = [:]
        var listCounts: [UUID: Int] = [:]

        init(reminders: [Reminder], now: Date) {
            for reminder in reminders {
                if let listID = reminder.list?.id {
                    listCounts[listID, default: 0] += 1
                }
                for smart in ReminderSmartList.allCases where smart != .completed {
                    if smart.contains(reminder, now: now) {
                        smartCounts[smart, default: 0] += 1
                    }
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        RemindersView()
    }
    .modelContainer(for: [Reminder.self, ReminderList.self], inMemory: true)
}
