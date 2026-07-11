import Foundation

/// Pure roll-forward math for Reminder recurrence. Fixed-schedule rules reuse
/// the Calendar RRULE parser/expander and advance from the scheduled due date;
/// after-completion repeats advance from the actual completion date.
nonisolated enum ReminderRecurrenceEngine {
    /// Returns the next fixed-schedule due date after `scheduled`, plus an
    /// updated RRULE string when COUNT must be decremented. COUNT represents
    /// remaining scheduled occurrences, including `scheduled`.
    static func nextDueDate(
        afterScheduled scheduled: Date,
        ruleString: String,
        timeZone: TimeZone
    ) -> (nextDueDate: Date?, updatedRuleString: String) {
        guard let rule = RecurrenceRule(rruleString: ruleString) else {
            return (nil, ruleString)
        }

        let updatedRuleString: String
        if case let .occurrenceCount(count) = rule.end {
            guard count > 1 else {
                return (nil, rule.rruleString)
            }
            var decremented = rule
            decremented.end = .occurrenceCount(count - 1)
            updatedRuleString = decremented.rruleString
        } else {
            updatedRuleString = ruleString
        }

        let searchEnd = Calendar(identifier: .gregorian).date(
            byAdding: .year,
            value: 100,
            to: scheduled
        ) ?? scheduled.addingTimeInterval(100 * 366 * 24 * 3600)

        // Expand with the ORIGINAL rule: the expander's COUNT budget includes
        // the anchor occurrence, so expanding with the decremented rule would
        // end a COUNT=2 series one occurrence early.
        let occurrences = RecurrenceExpander.occurrenceStarts(
            rule: rule,
            eventStart: scheduled,
            duration: 1,
            window: DateInterval(start: scheduled, end: searchEnd),
            timeZone: timeZone,
            cap: 2
        )
        return (occurrences.first { $0 > scheduled }, updatedRuleString)
    }

    /// Returns the next due date for completion-based repeats. Units are
    /// calendar components, not seconds, so month-end and DST behavior follows
    /// the provided calendar.
    static func nextDueDate(
        afterCompletion completedAt: Date,
        repeat repeatRule: ReminderAfterCompletionRepeat,
        hasDueTime: Bool,
        calendar: Calendar
    ) -> Date {
        let component: Calendar.Component = switch repeatRule.unit {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        case .year: .year
        }
        let advanced = calendar.date(
            byAdding: component,
            value: max(1, repeatRule.count),
            to: completedAt
        ) ?? completedAt
        guard !hasDueTime else { return advanced }
        return calendar.startOfDay(for: advanced)
    }
}
