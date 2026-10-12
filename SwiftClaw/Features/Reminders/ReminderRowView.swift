import SwiftUI

/// One reminder in a list: completion circle, title, due/priority/repeat
/// metadata. The circle is the row's primary action and stays a generous
/// target; completing is always reversible, so no confirmation stands between
/// the tap and the checkmark.
struct ReminderRowView: View {
    let reminder: Reminder
    let now: Date
    /// False only for non-latest completion logs, whose undo the repository
    /// rejects (it would rewind the master's series state).
    var isToggleEnabled: Bool = true
    let onToggleCompletion: () -> Void

    private var isOverdue: Bool {
        reminder.isOverdue(now: now)
    }

    private var listColor: Color {
        Color(calendarHex: reminder.list?.colorHex ?? ReminderList.defaultColorHex)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            completionCircle

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    priorityMark
                    Text(reminder.title)
                        .strikethrough(reminder.isCompleted, color: .secondary)
                        .foregroundStyle(reminder.isCompleted ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                        .lineLimit(2)
                }
                metadataLine
            }

            Spacer(minLength: 0)

            if reminder.isFlagged {
                Image(systemName: "flag.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Flagged")
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var completionCircle: some View {
        Button(action: onToggleCompletion) {
            Image(systemName: reminder.isCompleted ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(reminder.isCompleted ? AnyShapeStyle(listColor) : AnyShapeStyle(.secondary))
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isToggleEnabled)
        .accessibilityLabel(toggleLabel)
        .help(toggleLabel)
    }

    private var toggleLabel: String {
        guard isToggleEnabled else {
            return String(localized: "Undo the most recent completion first")
        }
        return reminder.isCompleted
            ? String(localized: "Mark incomplete")
            : String(localized: "Complete")
    }

    @ViewBuilder
    private var priorityMark: some View {
        switch reminder.priority {
        case .none:
            EmptyView()
        case .low, .medium, .high:
            Text(String(repeating: "!", count: priorityBangs))
                .font(.body.weight(.semibold))
                .foregroundStyle(.tint)
                .accessibilityHidden(true) // spoken via the combined label
        }
    }

    private var priorityBangs: Int {
        switch reminder.priority {
        case .high: 3
        case .medium: 2
        case .low: 1
        case .none: 0
        }
    }

    @ViewBuilder
    private var metadataLine: some View {
        HStack(spacing: 6) {
            if let dueText {
                Text(dueText)
                    .foregroundStyle(isOverdue ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            }
            if reminder.recurrenceRuleString != nil || reminder.afterCompletionRepeat != nil {
                Image(systemName: "repeat")
                    .accessibilityLabel("Repeats")
            }
            // Bound once: `checklist` JSON-decodes its blob on every access.
            let checklist = reminder.checklist
            if !checklist.isEmpty {
                let done = checklist.count(where: \.isDone)
                Text("\(done) of \(checklist.count)")
                    .monospacedDigit()
                    .accessibilityLabel("\(done) of \(checklist.count) steps done")
            }
            if reminder.notes?.isEmpty == false {
                Image(systemName: "note.text")
                    .accessibilityLabel("Has notes")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var dueText: String? {
        guard let dueDate = reminder.localDueDate() else { return nil }
        if reminder.hasDueTime {
            if Calendar.current.isDate(dueDate, inSameDayAs: now) {
                return dueDate.formatted(date: .omitted, time: .shortened)
            }
            return dueDate.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        }
        if Calendar.current.isDate(dueDate, inSameDayAs: now) {
            return String(localized: "Today")
        }
        return dueDate.formatted(.dateTime.month(.abbreviated).day())
    }

    private var accessibilitySummary: String {
        var parts: [String] = [reminder.title]
        if reminder.isCompleted {
            parts.append(String(localized: "completed"))
        } else if let dueText {
            parts.append(isOverdue ? String(localized: "overdue, \(dueText)") : String(localized: "due \(dueText)"))
        }
        switch reminder.priority {
        case .high: parts.append(String(localized: "high priority"))
        case .medium: parts.append(String(localized: "medium priority"))
        case .low: parts.append(String(localized: "low priority"))
        case .none: break
        }
        return parts.joined(separator: ", ")
    }
}
