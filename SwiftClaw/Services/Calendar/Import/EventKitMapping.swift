import EventKit
import Foundation

/// Pure EventKit→SwiftClaw mapping. Everything here is testable without an
/// `EKEventStore` (`EKRecurrenceRule` and friends are plain constructible
/// objects); the store walking lives in `AppleCalendarImporter`.
nonisolated enum EventKitMapping {
    // MARK: - Recurrence

    /// Maps an `EKRecurrenceRule` onto our RRULE subset. Returns nil when the
    /// rule uses parts we don't support (daysOfTheYear, weeksOfTheYear) — the
    /// importer degrades those series to windowed one-offs instead of
    /// guessing.
    static func recurrenceRule(from ekRule: EKRecurrenceRule) -> RecurrenceRule? {
        guard ekRule.daysOfTheYear == nil, ekRule.weeksOfTheYear == nil else { return nil }

        let frequency: RecurrenceRule.Frequency
        switch ekRule.frequency {
        case .daily: frequency = .daily
        case .weekly: frequency = .weekly
        case .monthly: frequency = .monthly
        case .yearly: frequency = .yearly
        @unknown default: return nil
        }

        var daysOfWeek: [RecurrenceRule.DayOfWeek] = []
        for ekDay in ekRule.daysOfTheWeek ?? [] {
            guard let weekday = RecurrenceRule.Weekday(foundationWeekday: ekDay.dayOfTheWeek.rawValue) else {
                return nil
            }
            daysOfWeek.append(RecurrenceRule.DayOfWeek(
                weekday,
                ordinal: ekDay.weekNumber == 0 ? nil : ekDay.weekNumber
            ))
        }

        var end: RecurrenceRule.End?
        if let ekEnd = ekRule.recurrenceEnd {
            if let endDate = ekEnd.endDate {
                end = .untilDate(endDate)
            } else if ekEnd.occurrenceCount > 0 {
                end = .occurrenceCount(ekEnd.occurrenceCount)
            }
        }

        // EK's firstDayOfTheWeek: 0 = unspecified (RFC default Monday).
        let weekStart = RecurrenceRule.Weekday(foundationWeekday: ekRule.firstDayOfTheWeek) ?? .monday

        return RecurrenceRule(
            frequency: frequency,
            interval: max(1, ekRule.interval),
            daysOfWeek: daysOfWeek,
            daysOfMonth: (ekRule.daysOfTheMonth ?? []).map(\.intValue),
            monthsOfYear: (ekRule.monthsOfTheYear ?? []).map(\.intValue),
            setPositions: (ekRule.setPositions ?? []).map(\.intValue),
            end: end,
            weekStart: weekStart
        )
    }

    // MARK: - All-day normalization

    /// EventKit represents an all-day end as the last day's 23:59:59 (or, in
    /// some paths, an exclusive midnight). Normalize both to our exclusive
    /// form: the midnight after the last included day.
    static func normalizedAllDayEnd(_ end: Date, calendar: Calendar) -> Date {
        let midnight = calendar.startOfDay(for: end)
        if end == midnight {
            return end // already exclusive
        }
        return calendar.date(byAdding: .day, value: 1, to: midnight) ?? end
    }

    // MARK: - Alarms

    /// Relative offsets pass through; absolute-date alarms convert relative
    /// to the event start; proximity alarms are dropped.
    static func alarmOffsets(from ekAlarms: [EKAlarm]?, eventStart: Date) -> [TimeInterval] {
        (ekAlarms ?? []).compactMap { alarm in
            if let absolute = alarm.absoluteDate {
                return absolute.timeIntervalSince(eventStart)
            }
            return alarm.relativeOffset
        }
    }

    // MARK: - Deleted-occurrence reconstruction

    /// EventKit never reports occurrences the user deleted — they're simply
    /// absent from a windowed fetch. Recover them by diffing what our rule
    /// expansion expects against what EventKit actually returned; the missing
    /// starts become EXDATEs on the imported master.
    static func missingOccurrenceStarts(
        rule: RecurrenceRule,
        masterStart: Date,
        duration: TimeInterval,
        window: DateInterval,
        actualStarts: [Date],
        timeZone: TimeZone?
    ) -> [Date] {
        // The default occurrence cap (sized for UI windows) is too small for a
        // multi-year import range — a 4-year daily series alone is ~1,460
        // occurrences, and any deletion past the cap would go unrecovered.
        let expected = RecurrenceExpander.occurrenceStarts(
            rule: rule,
            eventStart: masterStart,
            duration: duration,
            window: window,
            timeZone: timeZone,
            cap: 10_000
        )
        let actualKeys = Set(actualStarts.map { Int64($0.timeIntervalSinceReferenceDate.rounded()) })
        return expected.filter { !actualKeys.contains(Int64($0.timeIntervalSinceReferenceDate.rounded())) }
    }

    // MARK: - Colors

    static func colorHex(from cgColor: CGColor?) -> String {
        guard let cgColor,
              let srgb = cgColor.converted(
                  to: CGColorSpace(name: CGColorSpace.sRGB)!,
                  intent: .defaultIntent,
                  options: nil
              ),
              let components = srgb.components,
              components.count >= 3
        else { return UserCalendar.defaultColorHex }
        let red = Int((components[0] * 255).rounded())
        let green = Int((components[1] * 255).rounded())
        let blue = Int((components[2] * 255).rounded())
        return String(format: "#%02X%02X%02X", min(max(red, 0), 255), min(max(green, 0), 255), min(max(blue, 0), 255))
    }
}
