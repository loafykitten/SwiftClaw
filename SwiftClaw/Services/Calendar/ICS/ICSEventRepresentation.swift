import Foundation

/// The neutral shape one VEVENT round-trips through — both the parser's
/// output and the serializer's input. Keeping .ics parsing decoupled from the
/// SwiftData model means the serializer backend could be swapped (e.g. for
/// icalendar-kit) without touching import/export flows.
nonisolated struct ICSEventRepresentation: Sendable, Hashable {
    var uid: String
    var title: String = ""
    var start: Date
    var end: Date
    var isAllDay: Bool = false
    var timeZoneIdentifier: String?
    var location: String?
    var notes: String?
    var urlString: String?
    /// Raw RRULE value, if any.
    var rruleString: String?
    /// RECURRENCE-ID: when set, this VEVENT is a detached override of the
    /// series occurrence originally starting at this instant (the master is
    /// the VEVENT sharing the same UID with no RECURRENCE-ID).
    var recurrenceID: Date?
    var exceptionDates: [Date] = []
    /// VALARM display triggers as offsets from the event start (negative =
    /// before).
    var alarmOffsets: [TimeInterval] = []
}
