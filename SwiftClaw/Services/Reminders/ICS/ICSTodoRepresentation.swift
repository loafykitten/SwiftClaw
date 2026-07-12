import Foundation

/// The neutral shape one VTODO round-trips through — both the parser's
/// output and the serializer's input, mirroring `ICSEventRepresentation`.
/// Checklists, the flag, and after-completion repeats have no RFC 5545 home,
/// so they travel as `X-SWIFTCLAW-*` properties (foreign clients ignore
/// them; a SwiftClaw→SwiftClaw round trip keeps them).
nonisolated struct ICSTodoRepresentation: Sendable, Hashable {
    var uid: String
    var title: String = ""
    var notes: String?
    var urlString: String?
    /// DUE. Nil = no due date (an inbox item).
    var due: Date?
    /// DUE;VALUE=DATE — a floating local day (stored as local midnight),
    /// mirroring all-day event semantics.
    var isDateOnly: Bool = false
    var timeZoneIdentifier: String?
    /// RFC 5545 / EKReminder scale: 0 none, 1 high … 9 low.
    var priority: Int = 0
    var isFlagged: Bool = false
    /// COMPLETED timestamp when present. A VTODO can also be marked done via
    /// STATUS:COMPLETED alone — see `isCompleted`.
    var completedAt: Date?
    /// True when STATUS:COMPLETED or a COMPLETED timestamp was seen; the
    /// importer falls back to "now" when only the status carried it.
    var isCompleted: Bool = false
    /// Raw RRULE value for a fixed-schedule repeat, if any.
    var rruleString: String?
    /// After-completion repeat (X-SWIFTCLAW-REPEAT-AFTER); mutually exclusive
    /// with `rruleString`.
    var afterCompletionRepeat: ReminderAfterCompletionRepeat?
    var checklist: [ReminderChecklistItem] = []
}
