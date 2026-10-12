import SwiftUI
import SwiftData

/// The reminder editor sheet, used for creation and edits
/// (`ReminderEditorRequest`). Binds to a `ReminderDraft` and writes back
/// through `ReminderRepository` only on Save.
struct ReminderEditorSheet: View {
    let request: ReminderEditorRequest

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \ReminderList.sortOrder) private var lists: [ReminderList]

    @State private var draft = ReminderDraft(listID: nil)
    @State private var hasLoaded = false
    /// Set when Save couldn't commit; the sheet stays open with the draft.
    @State private var saveErrorMessage: String?

    private var repository: ReminderRepository {
        ReminderRepository(modelContext: modelContext)
    }

    private var sheetTitle: String {
        switch request {
        case .new, .quickEntry: "New Reminder"
        case .edit: "Edit Reminder"
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
                    Picker("List", selection: $draft.listID) {
                        ForEach(lists) { list in
                            Label {
                                Text(list.name)
                            } icon: {
                                Image(systemName: "circle.fill")
                                    .foregroundStyle(Color(calendarHex: list.colorHex))
                            }
                            .tag(Optional(list.id))
                        }
                    }
                }

                Section {
                    Picker("Due", selection: $draft.dueDateMode) {
                        ForEach(ReminderDraft.DueDateMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel("Due date")

                    if draft.dueDateMode != .none {
                        DatePicker(
                            "Due Date",
                            selection: $draft.dueDate,
                            displayedComponents: draft.dueDateMode == .dateTime
                                ? [.date, .hourAndMinute]
                                : [.date]
                        )
                    }
                }

                Section {
                    ReminderRepeatPicker(
                        repeatMode: $draft.repeatMode,
                        rule: $draft.rule,
                        afterCompletionRepeat: $draft.afterCompletionRepeat,
                        hasDueDate: draft.hasDueDate
                    )
                }

                Section {
                    Picker("Priority", selection: $draft.priority) {
                        Text("None").tag(ReminderPriority.none)
                        Text("Low").tag(ReminderPriority.low)
                        Text("Medium").tag(ReminderPriority.medium)
                        Text("High").tag(ReminderPriority.high)
                    }
                    Toggle("Flagged", isOn: $draft.isFlagged)
                }

                Section("Checklist") {
                    ReminderChecklistEditor(checklist: $draft.checklist)
                }

                Section {
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
        .frame(minWidth: 420, minHeight: 540)
        #endif
        .onAppear(perform: loadDraft)
    }

    private func loadDraft() {
        guard !hasLoaded else { return }
        hasLoaded = true
        let defaultListID = repository.preferredList(
            preferredID: SettingsStorage.loadRemindersDefaultListID()
        )?.id
        switch request {
        case .new(let dueDate, let listID):
            draft = ReminderDraft(newAt: dueDate, listID: listID ?? defaultListID)
        case .quickEntry(let prefilled):
            var draft = prefilled
            if draft.listID == nil {
                draft.listID = defaultListID
            }
            self.draft = draft
        case .edit(let id):
            if let reminder = repository.reminder(withID: id) {
                draft = ReminderDraft(from: reminder)
            }
        }
    }

    /// One transaction: the sheet dismisses only once the change is on disk.
    /// A failed save rolls back and keeps the draft open to retry or cancel.
    private func save() {
        let repository = repository
        var savedDraft = draft
        // Empty checklist steps are typing debris, not content.
        savedDraft.checklist.removeAll { $0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        do {
            try repository.performTransaction {
                if savedDraft.listID.flatMap({ repository.list(withID: $0) }) == nil {
                    savedDraft.listID = repository.defaultList(
                        preferredID: SettingsStorage.loadRemindersDefaultListID()
                    ).id
                }
                switch request {
                case .new, .quickEntry:
                    let reminder = Reminder()
                    savedDraft.apply(to: reminder, in: repository)
                    repository.insert(reminder)
                case .edit(let id):
                    if let reminder = repository.reminder(withID: id) {
                        savedDraft.apply(to: reminder, in: repository)
                    }
                }
            }
        } catch {
            saveErrorMessage = error.localizedDescription
            return
        }
        dismiss()
    }
}
