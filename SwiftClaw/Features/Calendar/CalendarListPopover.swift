import SwiftUI
import SwiftData

/// Toolbar popover managing the user's calendars: visibility toggles, inline
/// rename, palette recolor, add, and delete (with its events).
struct CalendarListPopover: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \UserCalendar.sortOrder) private var calendars: [UserCalendar]

    @State private var deleteCandidate: UserCalendar?

    private var repository: CalendarRepository {
        CalendarRepository(modelContext: modelContext)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Calendars")
                .font(.headline)

            ForEach(calendars) { calendar in
                row(calendar)
            }

            Divider()

            Button {
                repository.createCalendar(
                    name: String(localized: "New Calendar"),
                    colorHex: CalendarPalette.presets[calendars.count % CalendarPalette.presets.count].hex
                )
            } label: {
                Label("Add Calendar", systemImage: "plus")
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
            Button("Delete Calendar and Events", role: .destructive) {
                if let candidate = deleteCandidate {
                    repository.deleteCalendar(candidate)
                }
                deleteCandidate = nil
            }
        } message: {
            Text("All events in this calendar will be deleted. This can't be undone.")
        }
    }

    private func row(_ calendar: UserCalendar) -> some View {
        HStack(spacing: 8) {
            // Visibility checkbox drawn in the calendar's color.
            Button {
                calendar.isVisible.toggle()
                repository.noteUpdated(calendar)
            } label: {
                Image(systemName: calendar.isVisible ? "checkmark.circle.fill" : "circle")
                    .font(.body)
                    .foregroundStyle(Color(calendarHex: calendar.colorHex))
            }
            .buttonStyle(.plain)
            .help(calendar.isVisible ? "Hide calendar" : "Show calendar")

            TextField(
                "Name",
                text: Binding(
                    get: { calendar.name },
                    set: { calendar.name = $0 }
                )
            )
            .textFieldStyle(.plain)
            .onSubmit { repository.noteUpdated(calendar) }

            Menu {
                ForEach(CalendarPalette.presets) { preset in
                    Button {
                        calendar.colorHex = preset.hex
                        repository.noteUpdated(calendar)
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

            Button {
                deleteCandidate = calendar
            } label: {
                Image(systemName: "trash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Delete calendar")
        }
    }
}
