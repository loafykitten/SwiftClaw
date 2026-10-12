import SwiftUI
import SwiftData

/// The detail pane for one sidebar selection: pending reminders (manually
/// reorderable inside a user list), with completed items in a collapsible
/// trailing section so finished work stays reachable without crowding the
/// list. All writes go through `ReminderRepository`.
struct ReminderListDetailView: View {
    /// What the pane is showing.
    enum Selection: Hashable {
        case smart(ReminderSmartList)
        case list(UUID)

        func isAvailable(visibleListIDs: Set<UUID>) -> Bool {
            switch self {
            case .smart:
                true
            case .list(let id):
                visibleListIDs.contains(id)
            }
        }
    }

    let selection: Selection
    let pendingReminders: [Reminder]
    let lists: [ReminderList]
    let now: Date
    let onEdit: (Reminder) -> Void

    @Environment(\.modelContext) private var modelContext
    @Query private var completedReminders: [Reminder]
    @State private var isShowingCompleted = false
    @State private var deleteCandidate: Reminder?
    /// A row action (complete, undo, skip, delete) whose save failed.
    @State private var actionFailure: ActionFailure?
    /// Cached across minute ticks; refreshed from the store-change signal and
    /// whenever the selection-scoped history IDs change.
    @State private var latestLogIDs: Set<UUID> = []

    init(
        selection: Selection,
        pendingReminders: [Reminder],
        lists: [ReminderList],
        now: Date,
        onEdit: @escaping (Reminder) -> Void
    ) {
        self.selection = selection
        self.pendingReminders = pendingReminders
        self.lists = lists
        self.now = now
        self.onEdit = onEdit

        _completedReminders = Query(Self.completedHistoryDescriptor(for: selection))
    }

    static func completedHistoryDescriptor(for selection: Selection) -> FetchDescriptor<Reminder> {
        switch selection {
        case .smart(.completed):
            return FetchDescriptor(
                predicate: #Predicate { $0.completedAt != nil },
                sortBy: [SortDescriptor(\.completedAt, order: .reverse)]
            )
        case .list(let listID):
            return FetchDescriptor(
                predicate: #Predicate {
                    $0.completedAt != nil && $0.list?.id == listID
                },
                sortBy: [SortDescriptor(\.completedAt, order: .reverse)]
            )
        default:
            return FetchDescriptor(
                predicate: #Predicate {
                    $0.completedAt != nil && $0.completedAt == nil
                }
            )
        }
    }

    private var repository: ReminderRepository {
        ReminderRepository(modelContext: modelContext)
    }

    private var selectedList: ReminderList? {
        guard case .list(let id) = selection else { return nil }
        return lists.first { $0.id == id }
    }

    var body: some View {
        let snapshot = RowSnapshot(
            selection: selection,
            pendingReminders: pendingReminders,
            completedReminders: completedReminders,
            now: now
        )
        List {
            if case .smart(.completed) = selection {
                completedContent(rows: snapshot.completedRows)
            } else {
                pendingContent(rows: snapshot.pendingRows)
                if snapshot.showsCompletedSection {
                    Section {
                        if isShowingCompleted {
                            rows(snapshot.completedRows)
                        }
                    } header: {
                        completedHeader(count: snapshot.completedRows.count)
                    }
                }
            }
        }
        .listStyle(.inset)
        .overlay {
            if snapshot.pendingRows.isEmpty, snapshot.completedRows.isEmpty {
                emptyState
            }
        }
        .confirmingAction(
            item: $deleteCandidate,
            copy: ConfirmationDialogCopy(
                title: "Delete “\(deleteCandidate?.title ?? "")”?",
                actionTitle: deleteCandidate?.isRecurring == true
                    ? "Delete Reminder and History"
                    : "Delete Reminder",
                message: deleteCandidate?.isRecurring == true
                    ? "This repeating reminder and its completion history will be deleted."
                    : "This reminder will be deleted."
            )
        ) { candidate in
            delete(candidate)
        }
        .actionFailureAlert($actionFailure)
        .onAppear {
            refreshLatestLogIDs(in: snapshot.completedRows)
        }
        .onChange(of: snapshot.completedRows.map(\.id)) { _, _ in
            refreshLatestLogIDs(in: snapshot.completedRows)
        }
        .onReceive(NotificationCenter.default.publisher(for: .reminderStoreDidChange)) { _ in
            refreshLatestLogIDs(in: snapshot.completedRows)
        }
    }

    @ViewBuilder
    private func pendingContent(rows pendingRows: [Reminder]) -> some View {
        if case .list = selection {
            // Manual ordering only makes sense inside one list — smart views
            // interleave many lists and sort by relevance instead.
            rows(pendingRows)
                .onMove { source, destination in
                    moveRows(pendingRows, from: source, to: destination)
                }
        } else {
            rows(pendingRows)
        }
    }

    @ViewBuilder
    private func completedContent(rows completedRows: [Reminder]) -> some View {
        if completedRows.isEmpty {
            EmptyView()
        } else {
            rows(completedRows)
        }
    }

    private func rows(_ rows: [Reminder]) -> some ForEachView {
        ForEach(rows) { reminder in
            // Snapshot the rendered occurrence: a second click before the row
            // re-renders must not complete the next occurrence too.
            let renderedOccurrence = reminder.dueDate
            ReminderRowView(
                reminder: reminder,
                now: now,
                // Only the newest log per master can be uncompleted — undoing
                // an older occurrence would rewind the series' state.
                isToggleEnabled: !reminder.isCompletionLog || latestLogIDs.contains(reminder.id),
                onToggleCompletion: { toggleCompletion(reminder, renderedOccurrence: renderedOccurrence) }
            )
            .onTapGesture {
                guard !reminder.isCompletionLog else { return }
                onEdit(reminder)
            }
            .contextMenu {
                if !reminder.isCompletionLog {
                    Button("Edit") { onEdit(reminder) }
                    if reminder.isRecurring, !reminder.isCompleted {
                        Button("Skip This Occurrence") {
                            perform(String(localized: "Couldn't Skip Reminder")) {
                                try repository.skipOccurrence(of: reminder)
                            }
                        }
                    }
                }
                Button("Delete", role: .destructive) {
                    requestDelete(reminder)
                }
            }
        }
    }

    private func completedHeader(count: Int) -> some View {
        Button {
            withAnimation { isShowingCompleted.toggle() }
        } label: {
            HStack(spacing: 4) {
                Text("Completed (\(count))")
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .rotationEffect(.degrees(isShowingCompleted ? 90 : 0))
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            isShowingCompleted
                ? "Hide \(count) completed reminders"
                : "Show \(count) completed reminders"
        )
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(emptyTitle, systemImage: emptyIcon)
        } description: {
            Text(emptyMessage)
        }
    }

    // MARK: - Actions

    private func refreshLatestLogIDs(in rows: [Reminder]) {
        let parentIDs = Set(rows.compactMap(\.parentReminderID))
        latestLogIDs = repository.latestCompletionLogIDs(for: parentIDs)
    }

    /// Runs one repository mutation, surfacing a failure in the alert.
    private func perform(_ failureTitle: String, _ action: () throws -> Void) {
        do {
            try action()
        } catch {
            actionFailure = ActionFailure(title: failureTitle, error: error)
        }
    }

    private func toggleCompletion(_ reminder: Reminder, renderedOccurrence: Date?) {
        if reminder.isCompleted {
            perform(String(localized: "Couldn't Undo Completion")) {
                try repository.uncomplete(reminder)
            }
        } else {
            perform(String(localized: "Couldn't Complete Reminder")) {
                try repository.complete(reminder, expectedOccurrence: renderedOccurrence)
            }
        }
    }

    private func requestDelete(_ reminder: Reminder) {
        if reminder.isCompletionLog || (!reminder.isRecurring && reminder.isCompleted) {
            // History/one-off cleanup — low stakes, no dialog.
            delete(reminder)
        } else {
            deleteCandidate = reminder
        }
    }

    private func delete(_ reminder: Reminder) {
        perform(String(localized: "Couldn't Delete Reminder")) {
            try repository.deleteReminder(reminder)
        }
    }

    private func moveRows(_ pendingRows: [Reminder], from source: IndexSet, to destination: Int) {
        guard case .list = selection else { return }
        var ordered = pendingRows
        ordered.move(fromOffsets: source, toOffset: destination)
        for (index, reminder) in ordered.enumerated() where reminder.sortOrder != index {
            reminder.sortOrder = index
        }
        repository.saveChanges()
    }

    // MARK: - Empty-state copy

    private var emptyTitle: String {
        switch selection {
        case .smart(.today): String(localized: "Nothing due today")
        case .smart(.scheduled): String(localized: "Nothing scheduled")
        case .smart(.inbox): String(localized: "Inbox is clear")
        case .smart(.flagged): String(localized: "No flagged reminders")
        case .smart(.completed): String(localized: "Nothing completed yet")
        case .list: String(localized: "No reminders")
        }
    }

    private var emptyIcon: String {
        switch selection {
        case .smart(let smart): smart.systemImage
        case .list: "checklist"
        }
    }

    private var emptyMessage: String {
        switch selection {
        case .smart(.completed):
            String(localized: "Reminders you complete will appear here.")
        default:
            String(localized: "Add a reminder with the + button.")
        }
    }

    private struct RowSnapshot {
        let pendingRows: [Reminder]
        let completedRows: [Reminder]
        let showsCompletedSection: Bool

        init(
            selection: Selection,
            pendingReminders: [Reminder],
            completedReminders: [Reminder],
            now: Date
        ) {
            switch selection {
            case .smart(.completed):
                pendingRows = []
                completedRows = completedReminders.filter(\.isInVisibleList)
                showsCompletedSection = false
            case .smart(let smart):
                pendingRows = smart.filter(pendingReminders, now: now).sorted(by: Self.smartOrder)
                completedRows = []
                showsCompletedSection = false
            case .list(let id):
                // sortOrder is what moveRows writes; without sorting here the
                // manual order would never display.
                pendingRows = pendingReminders.filter { $0.list?.id == id }.sorted {
                    $0.sortOrder != $1.sortOrder
                        ? $0.sortOrder < $1.sortOrder
                        : $0.createdAt < $1.createdAt
                }
                completedRows = completedReminders
                showsCompletedSection = !completedRows.isEmpty
            }
        }

        /// Smart views interleave lists: soonest due first, then flagged, then
        /// title — a stable, explainable order.
        private static func smartOrder(_ lhs: Reminder, _ rhs: Reminder) -> Bool {
            let lhsDue = lhs.localDueDate() ?? .distantFuture
            let rhsDue = rhs.localDueDate() ?? .distantFuture
            if lhsDue != rhsDue { return lhsDue < rhsDue }
            if lhs.isFlagged != rhs.isFlagged { return lhs.isFlagged }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }
}

private typealias ForEachView = DynamicViewContent & View
