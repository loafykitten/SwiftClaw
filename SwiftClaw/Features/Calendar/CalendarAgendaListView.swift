import SwiftUI

/// Agenda view: the coming weeks as a grouped list — the information-dense
/// "what's next" reading of the same occurrences the grids render.
struct CalendarAgendaListView: View {
    let occurrences: [EventOccurrence]
    let calendar: Calendar
    let onSelectOccurrence: (EventOccurrence) -> Void
    let onDeleteOccurrence: (EventOccurrence) -> Void
    var reminderItems: [ReminderCalendarItem] = []
    var onSelectReminder: (ReminderCalendarItem) -> Void = { _ in }
    var onCompleteReminder: (ReminderCalendarItem) -> Void = { _ in }

    private var groupedDays: [(day: Date, occurrences: [EventOccurrence], reminders: [ReminderCalendarItem])] {
        let occurrencesByDay = Dictionary(grouping: occurrences) { calendar.startOfDay(for: $0.start) }
        let remindersByDay = Dictionary(grouping: reminderItems, by: \.day)
        return Set(occurrencesByDay.keys).union(remindersByDay.keys)
            .sorted()
            .map { day in
                (
                    day: day,
                    occurrences: (occurrencesByDay[day] ?? []).sorted { $0.start < $1.start },
                    reminders: remindersByDay[day] ?? []
                )
            }
    }

    var body: some View {
        if occurrences.isEmpty && reminderItems.isEmpty {
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
                        ForEach(group.reminders) { item in
                            reminderRow(item)
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

    /// A reminder in the agenda: the leading circle completes it in place
    /// (the row is gone on the next render — done is done); the rest of the
    /// row opens it in Reminders.
    private func reminderRow(_ item: ReminderCalendarItem) -> some View {
        HStack(spacing: 10) {
            Button {
                onCompleteReminder(item)
            } label: {
                Image(systemName: "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(Color(calendarHex: item.colorHex))
            }
            .buttonStyle(.plain)
            .help("Mark Completed")
            .accessibilityLabel("Mark \(item.title) completed")

            Button {
                onSelectReminder(item)
            } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title.isEmpty ? "New Reminder" : item.title)
                            .font(.body)
                            .lineLimit(1)
                        Text(reminderTimeLabel(item))
                            .font(.caption)
                            .foregroundStyle(item.isOverdue ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                            .monospacedDigit()
                    }

                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
        .contextMenu {
            Button("Mark Completed") { onCompleteReminder(item) }
            Button("Open in Reminders") { onSelectReminder(item) }
        }
        .accessibilityElement(children: .contain)
    }

    private func reminderTimeLabel(_ item: ReminderCalendarItem) -> String {
        if item.isOverdue && !calendar.isDate(item.due, inSameDayAs: item.day) {
            return "Overdue — was due \(item.due.formatted(.dateTime.month(.abbreviated).day()))"
        }
        if item.hasDueTime {
            let time = item.due.formatted(date: .omitted, time: .shortened)
            return item.isOverdue ? "Overdue — was due \(time)" : "Due \(time)"
        }
        return "Any time"
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
