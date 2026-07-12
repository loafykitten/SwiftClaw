import SwiftUI
import SwiftData

/// Toolbar popover managing the user's reminder lists: visibility toggles,
/// inline rename, palette recolor, add, and delete (with its reminders).
/// Mirrors `CalendarListPopover`.
struct ReminderListPopover: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ReminderList.sortOrder) private var lists: [ReminderList]

    @State private var deleteCandidate: ReminderList?

    private var repository: ReminderRepository {
        ReminderRepository(modelContext: modelContext)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Lists")
                .font(.headline)

            ForEach(lists) { list in
                row(list)
            }

            Divider()

            Button {
                repository.createList(
                    name: String(localized: "New List"),
                    colorHex: CalendarPalette.presets[lists.count % CalendarPalette.presets.count].hex
                )
            } label: {
                Label("Add List", systemImage: "plus")
                    .font(.subheadline)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
        }
        .padding(14)
        .frame(minWidth: 260)
        .confirmationDialog(
            "Delete “\(deleteCandidate?.name ?? "")”?",
            isPresented: Binding(
                get: { deleteCandidate != nil },
                set: { if !$0 { deleteCandidate = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete List and Reminders", role: .destructive) {
                if let candidate = deleteCandidate {
                    repository.deleteList(candidate)
                }
                deleteCandidate = nil
            }
        } message: {
            Text("All reminders in this list will be deleted. This can't be undone.")
        }
    }

    private func row(_ list: ReminderList) -> some View {
        HStack(spacing: 8) {
            // Visibility checkbox drawn in the list's color.
            Button {
                list.isVisible.toggle()
                repository.noteUpdated(list)
            } label: {
                Image(systemName: list.isVisible ? "checkmark.circle.fill" : "circle")
                    .font(.body)
                    .foregroundStyle(Color(calendarHex: list.colorHex))
            }
            .buttonStyle(.plain)
            .help(list.isVisible ? "Hide list" : "Show list")
            .accessibilityLabel(list.isVisible ? "Hide \(list.name)" : "Show \(list.name)")

            TextField(
                "Name",
                text: Binding(
                    get: { list.name },
                    set: { list.name = $0 }
                )
            )
            .textFieldStyle(.plain)
            .onSubmit { repository.noteUpdated(list) }

            Menu {
                ForEach(CalendarPalette.presets) { preset in
                    Button {
                        list.colorHex = preset.hex
                        repository.noteUpdated(list)
                    } label: {
                        Label(preset.name, systemImage: "circle.fill")
                    }
                }
            } label: {
                Image(systemName: "paintpalette")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Change color of \(list.name)")

            Button {
                deleteCandidate = list
            } label: {
                Image(systemName: "trash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Delete list")
            .accessibilityLabel("Delete \(list.name)")
        }
    }
}
