import SwiftUI

/// Repeat section of the reminder editor. Reminders support two repeat
/// behaviors — a fixed schedule (RRULE, the calendar picker reused verbatim)
/// and "again N days/weeks/… after I complete it" — so the mode picker comes
/// first and each mode brings its own controls.
struct ReminderRepeatPicker: View {
    @Binding var repeatMode: ReminderDraft.RepeatMode
    @Binding var rule: RecurrenceRule?
    @Binding var afterCompletionRepeat: ReminderAfterCompletionRepeat
    let hasDueDate: Bool

    var body: some View {
        Picker("Repeat", selection: $repeatMode) {
            ForEach(ReminderDraft.RepeatMode.allCases) { mode in
                Text(mode.rawValue).tag(mode)
            }
        }
        .onChange(of: repeatMode) { _, mode in
            // Seed the schedule mode so its picker opens on a concrete rule.
            if mode == .schedule, rule == nil {
                rule = .weekly
            }
        }

        if repeatMode != .never, !hasDueDate {
            Text("Repeating needs a due date to count from.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        switch repeatMode {
        case .never:
            EmptyView()
        case .schedule:
            CalendarRecurrencePicker(rule: $rule)
        case .afterCompletion:
            Stepper(value: countBinding, in: 1...99) {
                LabeledContent("Repeat After", value: afterCompletionLabel)
            }
            .accessibilityLabel("Repeat \(afterCompletionLabel) after completion")
            Picker("Unit", selection: unitBinding) {
                ForEach(ReminderAfterCompletionRepeat.Unit.allCases, id: \.self) { unit in
                    Text(unitName(unit, plural: afterCompletionRepeat.count != 1)).tag(unit)
                }
            }
        }
    }

    private var countBinding: Binding<Int> {
        Binding(
            get: { afterCompletionRepeat.count },
            set: { afterCompletionRepeat.count = $0 }
        )
    }

    private var unitBinding: Binding<ReminderAfterCompletionRepeat.Unit> {
        Binding(
            get: { afterCompletionRepeat.unit },
            set: { afterCompletionRepeat.unit = $0 }
        )
    }

    private var afterCompletionLabel: String {
        let count = afterCompletionRepeat.count
        return "\(count) \(unitName(afterCompletionRepeat.unit, plural: count != 1))"
    }

    private func unitName(_ unit: ReminderAfterCompletionRepeat.Unit, plural: Bool) -> String {
        switch unit {
        case .day: plural ? "days" : "day"
        case .week: plural ? "weeks" : "week"
        case .month: plural ? "months" : "month"
        case .year: plural ? "years" : "year"
        }
    }
}
