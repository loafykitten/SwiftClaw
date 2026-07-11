import SwiftUI

/// Agenda view: the coming weeks as a grouped list — the information-dense
/// "what's next" reading of the same occurrences the grids render.
struct CalendarAgendaListView: View {
    let occurrences: [EventOccurrence]
    let calendar: Calendar
    let onSelectOccurrence: (EventOccurrence) -> Void
    let onDeleteOccurrence: (EventOccurrence) -> Void

    private var groupedDays: [(day: Date, occurrences: [EventOccurrence])] {
        Dictionary(grouping: occurrences) { calendar.startOfDay(for: $0.start) }
            .sorted { $0.key < $1.key }
            .map { (day: $0.key, occurrences: $0.value.sorted { $0.start < $1.start }) }
    }

    var body: some View {
        if occurrences.isEmpty {
            ContentUnavailableView(
                "No Upcoming Events",
                systemImage: "calendar",
                description: Text("Events in the weeks ahead will show up here.")
            )
        } else {
            List {
                ForEach(groupedDays, id: \.day) { group in
                    Section {
                        ForEach(group.occurrences) { occurrence in
                            row(occurrence)
                        }
                    } header: {
                        Text(sectionTitle(for: group.day))
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private func row(_ occurrence: EventOccurrence) -> some View {
        Button {
            onSelectOccurrence(occurrence)
        } label: {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(calendarHex: occurrence.colorHex))
                    .frame(width: 4, height: 30)

                VStack(alignment: .leading, spacing: 1) {
                    Text(occurrence.title.isEmpty ? "New Event" : occurrence.title)
                        .font(.body)
                        .lineLimit(1)
                    Text(timeLabel(occurrence))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Edit") { onSelectOccurrence(occurrence) }
            Button("Delete", role: .destructive) { onDeleteOccurrence(occurrence) }
        }
    }

    private func timeLabel(_ occurrence: EventOccurrence) -> String {
        if occurrence.isAllDay {
            return "All day"
        }
        let start = occurrence.start.formatted(date: .omitted, time: .shortened)
        let end = occurrence.end.formatted(date: .omitted, time: .shortened)
        return "\(start) – \(end)"
    }

    private func sectionTitle(for day: Date) -> String {
        if calendar.isDateInToday(day) {
            "Today — \(day.formatted(.dateTime.weekday(.wide).month().day()))"
        } else if calendar.isDateInTomorrow(day) {
            "Tomorrow — \(day.formatted(.dateTime.weekday(.wide).month().day()))"
        } else {
            day.formatted(.dateTime.weekday(.wide).month().day())
        }
    }
}
