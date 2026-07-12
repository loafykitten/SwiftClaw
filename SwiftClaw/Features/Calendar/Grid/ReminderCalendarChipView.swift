import SwiftUI

/// The compact reminder pill the calendar views render next to event chips —
/// a list-colored open circle marks it as a to-do rather than an event, and
/// overdue items show their real due date in red.
struct ReminderCalendarChipView: View {
    let item: ReminderCalendarItem
    var showsTime = false

    private var color: Color {
        Color(calendarHex: item.colorHex)
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "circle")
                .font(.caption2.weight(.medium))
                .foregroundStyle(color)

            Text(item.title.isEmpty ? "New Reminder" : item.title)
                .font(.caption)
                .lineLimit(1)

            if let detail = dueDetail {
                Spacer(minLength: 2)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(item.isOverdue ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .layoutPriority(1)
            }
        }
        .padding(.horizontal, 3)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Hug the text vertically, like `CalendarEventChipView` — a tall
        // month cell would otherwise stretch the chip through the whole cell.
        .fixedSize(horizontal: false, vertical: true)
        .background(color.opacity(0.14), in: .rect(cornerRadius: 4))
        .contentShape(.rect(cornerRadius: 4))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    /// A rolled-forward overdue chip always names its real due day; otherwise
    /// the time only appears where the layout asked for it.
    private var dueDetail: String? {
        if item.isOverdue && !Calendar.current.isDate(item.due, inSameDayAs: item.day) {
            return item.due.formatted(.dateTime.month(.abbreviated).day())
        }
        if item.hasDueTime && (showsTime || item.isOverdue) {
            return item.due.formatted(date: .omitted, time: .shortened)
        }
        return nil
    }

    private var accessibilitySummary: String {
        var parts = ["Reminder: \(item.title)"]
        if item.isOverdue {
            parts.append("overdue")
        }
        if item.hasDueTime {
            parts.append("due \(item.due.formatted(date: .abbreviated, time: .shortened))")
        } else {
            parts.append("due \(item.due.formatted(date: .abbreviated, time: .omitted))")
        }
        return parts.joined(separator: ", ")
    }
}
