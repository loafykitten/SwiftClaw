import SwiftUI

/// Recurrence section of the event editor: a preset menu covering the common
/// cases, expanding into a compact custom builder (frequency, interval,
/// weekday toggles, end condition) when "Custom" is selected.
struct CalendarRecurrencePicker: View {
    @Binding var rule: RecurrenceRule?

    private enum Preset: String, CaseIterable, Identifiable {
        case never = "Never"
        case daily = "Every Day"
        case weekdays = "Every Weekday"
        case weekly = "Every Week"
        case biweekly = "Every 2 Weeks"
        case monthly = "Every Month"
        case yearly = "Every Year"
        case custom = "Custom"

        var id: String { rawValue }

        var rule: RecurrenceRule? {
            switch self {
            case .never: nil
            case .daily: .daily
            case .weekdays: .weekdays
            case .weekly: .weekly
            case .biweekly: .biweekly
            case .monthly: .monthly
            case .yearly: .yearly
            case .custom: nil
            }
        }

        static func matching(_ rule: RecurrenceRule?) -> Preset {
            guard let rule else { return .never }
            // Ends don't disqualify a preset shape; compare the core pattern.
            var core = rule
            core.end = nil
            return allCases.first { $0 != .custom && $0.rule == core } ?? .custom
        }
    }

    private enum EndChoice: String, CaseIterable, Identifiable {
        case never = "Never"
        case onDate = "On Date"
        case afterCount = "After"

        var id: String { rawValue }
    }

    @State private var preset: Preset = .never
    @State private var endChoice: EndChoice = .never
    @State private var endDate: Date = .now
    @State private var endCount = 10

    var body: some View {
        Picker("Repeat", selection: $preset) {
            ForEach(Preset.allCases) { preset in
                Text(preset.rawValue).tag(preset)
            }
        }
        .onAppear(perform: syncFromRule)
        .onChange(of: preset) { _, newPreset in
            switch newPreset {
            case .never:
                rule = nil
            case .custom:
                // Seed the builder from whatever was selected before.
                if rule == nil { rule = .weekly }
            default:
                var newRule = newPreset.rule
                newRule?.end = rule?.end
                rule = newRule
            }
        }

        if preset == .custom, rule != nil {
            customBuilder
        }

        if preset != .never {
            endPicker
        }
    }

    // MARK: - Custom pattern

    @ViewBuilder
    private var customBuilder: some View {
        Picker("Frequency", selection: frequencyBinding) {
            Text("Daily").tag(RecurrenceRule.Frequency.daily)
            Text("Weekly").tag(RecurrenceRule.Frequency.weekly)
            Text("Monthly").tag(RecurrenceRule.Frequency.monthly)
            Text("Yearly").tag(RecurrenceRule.Frequency.yearly)
        }

        Stepper(value: intervalBinding, in: 1...99) {
            LabeledContent("Every", value: intervalLabel)
        }

        if frequencyBinding.wrappedValue == .weekly {
            weekdayToggles
        }
    }

    private var weekdayToggles: some View {
        HStack(spacing: 6) {
            ForEach(RecurrenceRule.Weekday.allCases, id: \.self) { weekday in
                let isOn = selectedWeekdays.contains(weekday)
                Button {
                    toggleWeekday(weekday)
                } label: {
                    Text(weekday.rfcToken.capitalized)
                        .font(.caption.weight(isOn ? .semibold : .regular))
                        .frame(minWidth: 30)
                        .padding(.vertical, 5)
                        .background(
                            isOn ? AnyShapeStyle(.tint.opacity(0.25)) : AnyShapeStyle(.quaternary.opacity(0.5)),
                            in: .rect(cornerRadius: 6)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - End condition

    @ViewBuilder
    private var endPicker: some View {
        Picker("End Repeat", selection: $endChoice) {
            ForEach(EndChoice.allCases) { choice in
                Text(choice.rawValue).tag(choice)
            }
        }
        .onChange(of: endChoice) { _, choice in
            switch choice {
            case .never: rule?.end = nil
            case .onDate: rule?.end = .untilDate(endDate)
            case .afterCount: rule?.end = .occurrenceCount(endCount)
            }
        }

        switch endChoice {
        case .onDate:
            DatePicker("End Date", selection: $endDate, displayedComponents: .date)
                .onChange(of: endDate) { _, date in
                    rule?.end = .untilDate(date)
                }
        case .afterCount:
            Stepper(value: $endCount, in: 1...999) {
                LabeledContent("Occurrences", value: "\(endCount)")
            }
            .onChange(of: endCount) { _, count in
                rule?.end = .occurrenceCount(count)
            }
        case .never:
            EmptyView()
        }
    }

    // MARK: - State plumbing

    private var frequencyBinding: Binding<RecurrenceRule.Frequency> {
        Binding(
            get: { rule?.frequency ?? .weekly },
            set: { frequency in
                var updated = rule ?? .weekly
                updated.frequency = frequency
                if frequency != .weekly {
                    updated.daysOfWeek = []
                }
                rule = updated
            }
        )
    }

    private var intervalBinding: Binding<Int> {
        Binding(
            get: { rule?.interval ?? 1 },
            set: { interval in
                var updated = rule ?? .weekly
                updated.interval = interval
                rule = updated
            }
        )
    }

    private var intervalLabel: String {
        let interval = rule?.interval ?? 1
        let unit = switch rule?.frequency ?? .weekly {
        case .daily: interval == 1 ? "day" : "days"
        case .weekly: interval == 1 ? "week" : "weeks"
        case .monthly: interval == 1 ? "month" : "months"
        case .yearly: interval == 1 ? "year" : "years"
        }
        return "\(interval) \(unit)"
    }

    private var selectedWeekdays: Set<RecurrenceRule.Weekday> {
        Set((rule?.daysOfWeek ?? []).map(\.weekday))
    }

    private func toggleWeekday(_ weekday: RecurrenceRule.Weekday) {
        var updated = rule ?? .weekly
        var days = Set(updated.daysOfWeek.map(\.weekday))
        if days.contains(weekday) {
            days.remove(weekday)
        } else {
            days.insert(weekday)
        }
        updated.daysOfWeek = days.sorted().map { RecurrenceRule.DayOfWeek($0) }
        rule = updated
    }

    /// Seeds the picker's local state from the bound rule when the sheet opens.
    private func syncFromRule() {
        preset = Preset.matching(rule)
        switch rule?.end {
        case .untilDate(let date):
            endChoice = .onDate
            endDate = date
        case .occurrenceCount(let count):
            endChoice = .afterCount
            endCount = count
        case nil:
            endChoice = .never
        }
    }
}
