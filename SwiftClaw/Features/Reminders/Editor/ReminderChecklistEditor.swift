import SwiftUI

/// Checklist section of the reminder editor: lightweight subtasks inside one
/// reminder (never independent rows — see `Reminder.checklistData`). Each item
/// is a done-toggle plus an inline text field; an empty trailing item is
/// pruned on save by the draft holding only what's typed.
struct ReminderChecklistEditor: View {
    @Binding var checklist: [ReminderChecklistItem]
    @FocusState private var focusedItemID: UUID?

    var body: some View {
        ForEach($checklist) { $item in
            HStack(spacing: 8) {
                Button {
                    item.isDone.toggle()
                } label: {
                    Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(item.isDone ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.isDone ? "Mark \(item.text) not done" : "Mark \(item.text) done")

                TextField("Step", text: $item.text)
                    .textFieldStyle(.plain)
                    .strikethrough(item.isDone, color: .secondary)
                    .foregroundStyle(item.isDone ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .focused($focusedItemID, equals: item.id)
                    .onSubmit { addItem(after: item) }

                Button {
                    checklist.removeAll { $0.id == item.id }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.quaternary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(item.text.isEmpty ? "step" : item.text)")
            }
        }

        Button {
            addItem(after: checklist.last)
        } label: {
            Label("Add Step", systemImage: "plus")
                .font(.subheadline)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
    }

    private func addItem(after item: ReminderChecklistItem?) {
        let new = ReminderChecklistItem(text: "")
        if let item, let index = checklist.firstIndex(where: { $0.id == item.id }) {
            checklist.insert(new, at: index + 1)
        } else {
            checklist.append(new)
        }
        focusedItemID = new.id
    }
}
