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
    /// Timed events: UTC instants, with `timeZoneIdentifier` recording the
    /// zone the event was created in so recurrence math and display anchor
    /// to it. All-day events: canonical civil dates (`CivilDay`, midnight
    /// UTC of each day) with an exclusive end day and a nil zone. The same
    /// encoding applies to an all-day master's EXDATEs, its overrides'
    /// `originalOccurrenceDate`, and its RRULE UNTIL. Read them through
    /// `displayInterval(calendar:)`, never as instants.
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
    /// How this row stores all-day values: `CivilDay.encodingVersion` for
    /// canonical civil dates; nil for a legacy row (local-midnight instants)
    /// the startup migration hasn't converted yet.
    var dateEncodingVersion: Int? = nil
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
        dateEncodingVersion = CivilDay.encodingVersion
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

    // MARK: - All-day civil dates

    /// The zone recurrence expands in: canonical civil space for all-day
    /// series (whole-day steps, immune to DST and zone changes), otherwise
    /// the event's own zone (nil = the current zone).
    var recurrenceTimeZone: TimeZone? {
        isAllDay ? CivilDay.canonicalTimeZone : timeZone
    }

    /// Civil days an all-day event spans (at least one). Exact, because both
    /// stored ends are canonical civil dates.
    var allDayDayCount: Int {
        max(1, CivilDay(canonical: startDate).days(until: CivilDay(canonical: endDate)))
    }

    /// Stores an all-day span: `dayCount` civil days from `firstDay`.
    func setAllDaySpan(from firstDay: CivilDay, dayCount: Int) {
        isAllDay = true
        startDate = firstDay.canonicalDate
        endDate = firstDay.adding(days: max(1, dayCount)).canonicalDate
        timeZoneIdentifier = nil
    }

    /// Stores an all-day span from local instants (editors, EventKit): the
    /// day containing `localStart` through the day before the exclusive end
    /// (an inclusive 23:59:59 end rounds up to the next midnight), read in
    /// `calendar`'s zone. Always at least one day.
    func setAllDaySpan(localStart: Date, localEnd: Date, calendar: Calendar = .current) {
        let firstDay = CivilDay(containing: localStart, in: calendar)
        let exclusiveEnd = EventKitMapping.normalizedAllDayEnd(max(localEnd, localStart), calendar: calendar)
        let endDay = CivilDay(containing: exclusiveEnd, in: calendar)
        setAllDaySpan(from: firstDay, dayCount: firstDay.days(until: endDay))
    }

    /// The row's own interval as shown in `calendar`'s zone.
    func displayInterval(calendar: Calendar = .current) -> DateInterval {
        displayInterval(forStoredStart: startDate, calendar: calendar)
    }

    /// The displayed interval of the occurrence whose stored start (the
    /// master's encoding, which the expander and EXDATEs use) is `start`.
    /// All-day occurrences run local midnight to local midnight in
    /// `calendar`, however long those days are; timed ones keep their
    /// elapsed duration.
    func displayInterval(forStoredStart start: Date, calendar: Calendar = .current) -> DateInterval {
        guard isAllDay else {
            return DateInterval(start: start, duration: max(0, duration))
        }
        let firstDay = CivilDay(canonical: start)
        let localStart = firstDay.startDate(in: calendar)
        let localEnd = firstDay.adding(days: allDayDayCount).startDate(in: calendar)
        return DateInterval(start: localStart, end: max(localStart, localEnd))
    }

    /// Stored end of the occurrence starting at stored `start`. Timed events
    /// keep their elapsed duration; all-day events keep their day count.
    func occurrenceEnd(forStart start: Date) -> Date {
        guard isAllDay else { return start.addingTimeInterval(duration) }
        return CivilDay(canonical: start).adding(days: allDayDayCount).canonicalDate
    }

    /// The stored-encoding key for a displayed occurrence start: the
    /// canonical date of its local day for all-day events, the instant
    /// itself otherwise.
    func storedDate(forDisplayed date: Date, calendar: Calendar = .current) -> Date {
        isAllDay ? CivilDay.canonicalDate(forLocal: date, in: calendar) : date
    }

    /// The window store fetches over `startDate`/`endDate`/`recurrenceEndDate`
    /// use: the visible one widened by `CivilDay.storagePadding`, because
    /// all-day rows store canonical dates up to a day from their local
    /// instants. `CalendarOccurrenceBuilder` applies the exact test after.
    static func storeFetchWindow(for window: DateInterval) -> DateInterval {
        DateInterval(
            start: window.start.addingTimeInterval(-CivilDay.storagePadding),
            end: window.end.addingTimeInterval(CivilDay.storagePadding)
        )
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
