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
    let reminders: [Reminder]
    let lists: [ReminderList]
    let now: Date
    let onEdit: (Reminder) -> Void

    @Environment(\.modelContext) private var modelContext
    @State private var isShowingCompleted = false
    @State private var deleteCandidate: Reminder?

    private var repository: ReminderRepository {
        ReminderRepository(modelContext: modelContext)
    }

    private var selectedList: ReminderList? {
        guard case .list(let id) = selection else { return nil }
        return lists.first { $0.id == id }
    }

    /// Pending rows for the current selection, in manual order.
    private var pendingRows: [Reminder] {
        switch selection {
        case .smart(let smart):
            smart == .completed ? [] : smart.filter(reminders, now: now)
        case .list(let id):
            reminders.filter {
                $0.list?.id == id && !$0.isCompleted && !$0.isCompletionLog
            }
        }
    }

    /// Completed rows shown in the trailing section: completion history for
    /// the selection (log rows and completed one-offs).
    private var completedRows: [Reminder] {
        let completed: [Reminder]
        switch selection {
        case .smart(let smart):
            guard smart == .completed else { return [] }
            completed = reminders.filter(\.isCompleted)
        case .list(let id):
            completed = reminders.filter { $0.list?.id == id && $0.isCompleted }
        }
        return completed.sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
    }

    private var showsCompletedSection: Bool {
        if case .smart(.completed) = selection { return false }
        return !completedRows.isEmpty
    }

    var body: some View {
        List {
            if case .smart(.completed) = selection {
                completedContent
            } else {
                pendingContent
                if showsCompletedSection {
                    Section {
                        if isShowingCompleted {
                            rows(completedRows)
                        }
                    } header: {
                        completedHeader
                    }
                }
            }
        }
        .listStyle(.inset)
        .overlay {
            if pendingRows.isEmpty, completedRows.isEmpty {
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
            repository.deleteReminder(candidate)
        }
    }

    @ViewBuilder
    private var pendingContent: some View {
        if case .list = selection {
            // Manual ordering only makes sense inside one list — smart views
            // interleave many lists and sort by relevance instead.
            rows(pendingRows)
                .onMove(perform: moveRows)
        } else {
            rows(sortedForSmartView(pendingRows))
        }
    }

    @ViewBuilder
    private var completedContent: some View {
        if completedRows.isEmpty {
            EmptyView()
        } else {
            rows(completedRows)
        }
    }

    private func rows(_ rows: [Reminder]) -> some ForEachView {
        ForEach(rows) { reminder in
            ReminderRowView(
                reminder: reminder,
                now: now,
                onToggleCompletion: { toggleCompletion(reminder) }
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
                            repository.skipOccurrence(of: reminder)
                        }
                    }
                }
                Button("Delete", role: .destructive) {
                    requestDelete(reminder)
                }
            }
        }
    }

    private var completedHeader: some View {
        Button {
            withAnimation { isShowingCompleted.toggle() }
        } label: {
            HStack(spacing: 4) {
                Text("Completed (\(completedRows.count))")
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .rotationEffect(.degrees(isShowingCompleted ? 90 : 0))
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            isShowingCompleted
                ? "Hide \(completedRows.count) completed reminders"
                : "Show \(completedRows.count) completed reminders"
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

    private func toggleCompletion(_ reminder: Reminder) {
        if reminder.isCompleted {
            repository.uncomplete(reminder)
        } else {
            repository.complete(reminder)
        }
    }

    private func requestDelete(_ reminder: Reminder) {
        if reminder.isCompletionLog || (!reminder.isRecurring && reminder.isCompleted) {
            // History/one-off cleanup — low stakes, no dialog.
            repository.deleteReminder(reminder)
        } else {
            deleteCandidate = reminder
        }
    }

    private func moveRows(from source: IndexSet, to destination: Int) {
        guard case .list = selection else { return }
        var ordered = pendingRows
        ordered.move(fromOffsets: source, toOffset: destination)
        for (index, reminder) in ordered.enumerated() where reminder.sortOrder != index {
            reminder.sortOrder = index
        }
        repository.saveChanges()
    }

    /// Smart views interleave lists: soonest due first, then flagged, then
    /// title — a stable, explainable order.
    private func sortedForSmartView(_ rows: [Reminder]) -> [Reminder] {
        rows.sorted {
            let lhs = $0.dueDate ?? .distantFuture
            let rhs = $1.dueDate ?? .distantFuture
            if lhs != rhs { return lhs < rhs }
            if $0.isFlagged != $1.isFlagged { return $0.isFlagged }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
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
}

private typealias ForEachView = DynamicViewContent & View
