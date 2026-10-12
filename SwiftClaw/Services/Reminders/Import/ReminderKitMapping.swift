import EventKit
import Foundation

/// Pure EventKit→SwiftClaw reminder mapping. Everything here is testable
/// without an `EKEventStore`; the store walking lives in
/// `AppleRemindersImporter`. Recurrence conversion reuses
/// `EventKitMapping.recurrenceRule(from:)` — reminder repeats are the same
/// `EKRecurrenceRule` objects calendar events carry.
nonisolated enum ReminderKitMapping {
    /// A Sendable value snapshot of one `EKReminder`. `EKReminder` itself
    /// isn't Sendable and `fetchReminders` completes on an arbitrary queue,
    /// so the importer converts inside the completion handler and only
    /// snapshots cross back to the main actor.
    struct Snapshot: Sendable {
        var externalIdentifier: String?
        /// Device-local EventKit identity used only when the cross-device
        /// external identifier is unavailable. Unlike a generated UUID, this
        /// remains stable across repeated imports on this Mac.
        var localIdentifier: String? = nil
        var title: String = ""
        var notes: String?
        var urlString: String?
        var dueDateComponents: DateComponents?
        /// RFC 5545 / EKReminder priority scale (0 none, 1 high … 9 low).
        var priorityRawValue: Int = 0
        var isCompleted: Bool = false
        var completedAt: Date?
        var recurrenceRule: RecurrenceRule?
        /// The reminder had a repeat rule that doesn't fit our RRULE subset;
        /// it imports as a one-off and the summary reports it.
        var hadUnmappableRecurrence: Bool = false
    }

    static func snapshot(from ekReminder: EKReminder) -> Snapshot {
        let ekRule = ekReminder.recurrenceRules?.first
        let mappedRule = ekRule.flatMap(EventKitMapping.recurrenceRule(from:))
        var snapshot = Snapshot(externalIdentifier: ekReminder.calendarItemExternalIdentifier)
        snapshot.localIdentifier = ekReminder.calendarItemIdentifier
        snapshot.title = ekReminder.title ?? ""
        snapshot.notes = ekReminder.notes
        snapshot.urlString = ekReminder.url?.absoluteString
        snapshot.dueDateComponents = ekReminder.dueDateComponents
        snapshot.priorityRawValue = clampedPriority(ekReminder.priority)
        snapshot.isCompleted = ekReminder.isCompleted
        snapshot.completedAt = ekReminder.completionDate
        snapshot.recurrenceRule = mappedRule
        snapshot.hadUnmappableRecurrence = ekRule != nil && mappedRule == nil
        return snapshot
    }

    // MARK: - Due dates

    struct ResolvedDueDate: Sendable, Hashable {
        var date: Date?
        var hasDueTime = false
        var timeZoneIdentifier: String?
    }

    /// `EKReminder.dueDateComponents` → our due-date triple. An hour present
    /// means a timed reminder (resolved in the components' zone, which is
    /// kept); otherwise the reminder is date-only and stores that civil day's
    /// canonical date (`CivilDay`) with no zone, the same as all-day
    /// calendar events, regardless of any zone the components carry.
    static func resolvedDueDate(from components: DateComponents?, now _: Date = .now) -> ResolvedDueDate {
        guard let components,
              let year = components.year, let month = components.month, let day = components.day
        else { return ResolvedDueDate() }

        var calendar = Calendar(identifier: .gregorian)
        guard let hour = components.hour else {
            let date = CivilDay(year: year, month: month, day: day).canonicalDate
            return ResolvedDueDate(date: date, hasDueTime: false, timeZoneIdentifier: nil)
        }

        calendar.timeZone = components.timeZone ?? .current
        let date = calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: components.minute ?? 0,
            second: components.second ?? 0
        ))
        return ResolvedDueDate(date: date, hasDueTime: true, timeZoneIdentifier: components.timeZone?.identifier)
    }

    // MARK: - Priority

    /// EKReminder priorities are already on the RFC 5545 scale; clamp
    /// defensively so a stray value can't leave the 0…9 range the model's
    /// bucketing accessor expects.
    static func clampedPriority(_ raw: Int) -> Int {
        min(max(raw, 0), 9)
    }
}
