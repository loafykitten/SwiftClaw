import SwiftUI
import SwiftData

/// The Reminders root view: a sidebar of smart views + user lists beside the
/// selected list's reminders. Deliberately calm — one sidebar, one detail
/// pane, one editor sheet; no boards, no badges competing for attention.
/// ⌘N creates a reminder in the current context.
struct RemindersView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var reminders: [Reminder]
    @Query(sort: \ReminderList.sortOrder) private var lists: [ReminderList]

    @State private var selection: ReminderListDetailView.Selection? = .smart(.today)
    @State private var editorRequest: ReminderEditorRequest?
    @State private var isShowingListPopover = false
    /// Re-evaluated on save/appear so "Today" boundaries stay honest in a
    /// long-lived window.
    @State private var now: Date = .now

    private var repository: ReminderRepository {
        ReminderRepository(modelContext: modelContext)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 210)
            Divider()
            detail
        }
        .toolbar { toolbarContent }
        .background { shortcutButtons }
        .sheet(item: $editorRequest) { request in
            ReminderEditorSheet(request: request)
        }
        .onAppear {
            now = .now
            normalizeSelection()
        }
        .onChange(of: visibleLists.map(\.id)) { _, _ in
            normalizeSelection()
        }
        .onReceive(NotificationCenter.default.publisher(for: .reminderStoreDidChange)) { _ in
            now = .now
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            Section {
                ForEach(ReminderSmartList.allCases) { smart in
                    smartRow(smart)
                        .tag(ReminderListDetailView.Selection.smart(smart))
                }
            }

            Section("My Lists") {
                ForEach(visibleLists) { list in
                    listRow(list)
                        .tag(ReminderListDetailView.Selection.list(list.id))
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func smartRow(_ smart: ReminderSmartList) -> some View {
        Label {
            HStack {
                Text(smart.rawValue)
                Spacer(minLength: 4)
                if smart != .completed {
                    let count = smart.filter(activeReminders, now: now).count
                    if count > 0 {
                        Text("\(count)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } icon: {
            Image(systemName: smart.systemImage)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(smartAccessibilityLabel(smart))
        .accessibilityAddTraits(selection == .smart(smart) ? .isSelected : [])
    }

    private func listRow(_ list: ReminderList) -> some View {
        Label {
            HStack {
                Text(list.name)
                Spacer(minLength: 4)
                let count = pendingCount(in: list)
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
        .accessibilityLabel("\(list.name), \(pendingCount(in: list)) pending")
        .accessibilityAddTraits(selection == .list(list.id) ? .isSelected : [])
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
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
                    reminders: reminders,
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

    /// Rows that can appear in pending views (masters and one-offs).
    private var activeReminders: [Reminder] {
        reminders.filter { !$0.isCompletionLog }
    }

    private var visibleLists: [ReminderList] {
        lists.filter(\.isVisible)
    }

    private func pendingCount(in list: ReminderList) -> Int {
        activeReminders.count { $0.list?.id == list.id && !$0.isCompleted }
    }

    /// A new reminder inherits the current context: today's date in Today,
    /// the open list in a list view.
    private var newReminderRequest: ReminderEditorRequest {
        switch selection {
        case .smart(.today):
            .new(dueDate: Calendar.current.startOfDay(for: now), listID: nil)
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

    private func smartAccessibilityLabel(_ smart: ReminderSmartList) -> String {
        guard smart != .completed else { return smart.rawValue }
        let count = smart.filter(activeReminders, now: now).count
        return "\(smart.rawValue), \(count) pending"
    }

    private func normalizeSelection() {
        let visibleIDs = Set(visibleLists.map(\.id))
        if selection?.isAvailable(visibleListIDs: visibleIDs) != true {
            selection = .smart(.today)
        }
    }
}

#Preview {
    NavigationStack {
        RemindersView()
    }
    .modelContainer(for: [Reminder.self, ReminderList.self], inMemory: true)
}
