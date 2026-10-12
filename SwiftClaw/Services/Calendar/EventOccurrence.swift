import Foundation

/// A single rendered instance of an event — the value type every calendar
/// view consumes. One-off events yield one occurrence; recurring events yield
/// one per expansion within the visible window (`RecurrenceExpander`).
/// Occurrences are never persisted.
nonisolated struct EventOccurrence: Identifiable, Sendable, Hashable {
    /// The master (or override) `CalendarEvent.id` this occurrence renders.
    let eventID: UUID
    let calendarID: UUID?
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let colorHex: String
    let source: CalendarEventSource
    /// True when this occurrence comes from a detached "this event only"
    /// override rather than the recurring master.
    let isOverride: Bool
    /// The occurrence start in the event row's stored encoding, which is what
    /// EXDATEs, detached overrides, and `CalendarRepository`'s occurrence
    /// APIs key on. It differs from `start` for all-day events: their rows
    /// store canonical civil dates (`CivilDay`), while `start` is local
    /// midnight in the viewer's zone. Nil = same as `start`.
    var storedStart: Date? = nil

    /// The key to hand back to the repository for this occurrence.
    var occurrenceKey: Date {
        storedStart ?? start
    }

    /// Stable per-instance identity: the same event contributes many
    /// occurrences, so the id folds in the start instant.
    var id: String {
        "\(eventID.uuidString)@\(start.timeIntervalSinceReferenceDate)"
    }
}
