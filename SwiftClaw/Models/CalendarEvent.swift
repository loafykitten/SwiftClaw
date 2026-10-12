import Foundation
import SwiftData

/// A calendar event master record. Recurring events store one row plus an
/// RFC 5545 RRULE string; occurrences are expanded on the fly per visible
/// window by `RecurrenceExpander` and are never persisted. "Edit this event
/// only" detaches an override row (`parentEventID` + `originalOccurrenceDate`)
/// and adds the occurrence to the master's exception dates — the same shape
/// EventKit uses, which keeps import mapping direct.
///
/// Lives in the CloudKit-backed "calendar" model configuration, which forbids
/// `@Attribute(.unique)` and requires every property to be optional or carry a
/// default (see docs/conventions/MODELS.md). Identity is app-level: `id`, with
/// `CalendarRepository` resolving lookups deterministically and collapsing
/// remote-merge duplicates by `externalIdentifier`.
@Model
final class CalendarEvent {
    var id: UUID = UUID()
    var title: String = ""
    /// UTC instants. `timeZoneIdentifier` records the zone the event was
    /// created in so recurrence math and display anchor to it; nil floats the
    /// event in the viewer's local zone (used for all-day events).
    var startDate: Date = Date.now
    var endDate: Date = Date.now.addingTimeInterval(3600)
    var isAllDay: Bool = false
    var timeZoneIdentifier: String? = nil
    var locationText: String? = nil
    var notes: String? = nil
    var urlString: String? = nil
    /// RFC 5545 RRULE value (e.g. "FREQ=WEEKLY;BYDAY=MO,WE"). Nil = one-off.
    var recurrenceRuleString: String? = nil
    /// Derived from the rule's UNTIL/COUNT whenever the rule is saved; nil for
    /// an infinite recurrence. Denormalized so windowed fetch predicates can
    /// exclude recurrences that ended before the window.
    var recurrenceEndDate: Date? = nil
    /// JSON `[Date]` — occurrence starts removed from the recurrence (EXDATE).
    var exceptionDatesData: Data? = nil
    /// Detached "this event only" override: the master this row replaces one
    /// occurrence of, and which occurrence. Resolved by `id`, not a
    /// relationship, so the master's cascade delete doesn't strand overrides
    /// mid-merge — the repository sweeps orphans instead.
    var parentEventID: UUID? = nil
    var originalOccurrenceDate: Date? = nil
    /// JSON `[CalendarAlarmPayload]` — relative alert offsets.
    var alarmsData: Data? = nil
    /// EventKit `calendarItemExternalIdentifier` or .ics UID; the upsert key
    /// that makes re-imports idempotent.
    var externalIdentifier: String? = nil
    var sourceRawValue: String = CalendarEventSource.native.rawValue
    var createdAt: Date = Date.now
    var modifiedAt: Date = Date.now
    /// Last time a calendar-review pass included this event. Mirrors
    /// `EmailThread.lastReviewedAt` suppression.
    var lastReviewedAt: Date? = nil
    var calendar: UserCalendar? = nil

    init(
        id: UUID = UUID(),
        title: String = "",
        startDate: Date = .now,
        endDate: Date = Date.now.addingTimeInterval(3600),
        isAllDay: Bool = false,
        timeZoneIdentifier: String? = nil,
        locationText: String? = nil,
        notes: String? = nil,
        urlString: String? = nil,
        recurrenceRuleString: String? = nil,
        recurrenceEndDate: Date? = nil,
        externalIdentifier: String? = nil,
        source: CalendarEventSource = .native,
        calendar: UserCalendar? = nil
    ) {
        self.id = id
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.isAllDay = isAllDay
        self.timeZoneIdentifier = timeZoneIdentifier
        self.locationText = locationText
        self.notes = notes
        self.urlString = urlString
        self.recurrenceRuleString = recurrenceRuleString
        self.recurrenceEndDate = recurrenceEndDate
        self.externalIdentifier = externalIdentifier
        self.sourceRawValue = source.rawValue
        self.calendar = calendar
    }

    var source: CalendarEventSource {
        get { CalendarEventSource(rawValue: sourceRawValue) ?? .native }
        set { sourceRawValue = newValue.rawValue }
    }

    var isRecurring: Bool {
        recurrenceRuleString != nil
    }

    var isOverride: Bool {
        parentEventID != nil
    }

    var duration: TimeInterval {
        endDate.timeIntervalSince(startDate)
    }

    var timeZone: TimeZone? {
        timeZoneIdentifier.flatMap(TimeZone.init(identifier:))
    }

    /// Whole local days an all-day event spans (at least one). Counted by
    /// calendar days, not seconds: a one-day event created on a 23- or
    /// 25-hour DST day still spans exactly one day.
    func allDaySpan(calendar: Calendar = .current) -> Int {
        let firstDay = calendar.startOfDay(for: startDate)
        let exclusiveEnd = EventKitMapping.normalizedAllDayEnd(max(endDate, startDate), calendar: calendar)
        let days = calendar.dateComponents([.day], from: firstDay, to: exclusiveEnd).day ?? 1
        return max(1, days)
    }

    /// End of this event's occurrence starting at `start`. Timed events keep
    /// their elapsed duration; all-day events keep their day count, so an
    /// occurrence on a DST-transition day still ends at the next local
    /// midnight instead of an hour into the following day.
    func occurrenceEnd(forStart start: Date, calendar: Calendar = .current) -> Date {
        guard isAllDay else { return start.addingTimeInterval(duration) }
        return calendar.date(byAdding: .day, value: allDaySpan(calendar: calendar), to: start)
            ?? start.addingTimeInterval(duration)
    }

    var url: URL? {
        urlString.flatMap(URL.init(string:))
    }

    var exceptionDates: [Date] {
        get { Self.decodeJSON([Date].self, from: exceptionDatesData) ?? [] }
        set { exceptionDatesData = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue) }
    }

    var alarms: [CalendarAlarmPayload] {
        get { Self.decodeJSON([CalendarAlarmPayload].self, from: alarmsData) ?? [] }
        set { alarmsData = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue) }
    }

    private static func decodeJSON<T: Decodable>(_ type: T.Type, from data: Data?) -> T? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

nonisolated enum CalendarEventSource: String, Codable, Sendable, Hashable {
    case native
    case appleImport
    case icsImport
    /// Display-only occurrences read live from Apple Calendar (never stored
    /// as `CalendarEvent` rows — only `EventOccurrence` values carry this).
    case appleOverlay
}

/// A relative alert on an event: fires `offsetSeconds` from the occurrence
/// start (negative = before, the common case).
nonisolated struct CalendarAlarmPayload: Codable, Sendable, Hashable {
    var offsetSeconds: TimeInterval

    init(offsetSeconds: TimeInterval) {
        self.offsetSeconds = offsetSeconds
    }
}
