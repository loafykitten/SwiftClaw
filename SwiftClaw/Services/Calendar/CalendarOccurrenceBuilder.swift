import Foundation
import os

/// Turns `CalendarEvent` rows into windowed `EventOccurrence` values: one-offs
/// and overrides pass through when they intersect the window; recurring
/// masters expand via `RecurrenceExpander`. Shared by `CalendarRepository`
/// (predicate-fetched rows) and the calendar views (`@Query` rows), so both
/// paths render identically.
///
/// All-day rows store canonical civil dates (`CivilDay`); this is where they
/// become local intervals in `calendar`'s zone. All-day series expand in
/// canonical civil space against every civil day the window touches, then
/// each occurrence is tested against the window by its real local interval
/// (a day can run 23 or 25 hours, so no seconds-based duration is exact).
@MainActor
enum CalendarOccurrenceBuilder {
    private static let logger = AppLog.make("calendar.occurrences")

    static func occurrences(
        from events: [CalendarEvent],
        in window: DateInterval,
        visibleCalendarsOnly: Bool = true,
        calendar: Calendar = .current
    ) -> [EventOccurrence] {
        var occurrences: [EventOccurrence] = []
        func appendIfVisible(_ event: CalendarEvent, storedStart: Date) {
            let interval = event.displayInterval(forStoredStart: storedStart, calendar: calendar)
            guard interval.start < window.end, interval.end > window.start else { return }
            occurrences.append(occurrence(for: event, interval: interval, storedStart: storedStart))
        }

        for event in events {
            if visibleCalendarsOnly && !(event.calendar?.isVisible ?? true) { continue }

            guard event.isRecurring else {
                appendIfVisible(event, storedStart: event.startDate)
                continue
            }
            guard let rule = event.recurrenceRuleString.flatMap(RecurrenceRule.init(rruleString:)) else {
                // Unparseable rule (imported beyond our subset): render the
                // master as a one-off rather than dropping it silently.
                Self.logger.warning("unparseable RRULE on event \(event.id, privacy: .public); rendering as one-off")
                appendIfVisible(event, storedStart: event.startDate)
                continue
            }
            let starts = RecurrenceExpander.occurrenceStarts(
                rule: rule,
                eventStart: event.startDate,
                duration: event.duration,
                window: event.isAllDay ? CivilDay.canonicalWindow(covering: window, in: calendar) : window,
                exceptionDates: event.exceptionDates,
                timeZone: event.recurrenceTimeZone
            )
            for start in starts {
                appendIfVisible(event, storedStart: start)
            }
        }
        return occurrences.sorted { ($0.start, $0.title) < ($1.start, $1.title) }
    }

    private static func occurrence(
        for event: CalendarEvent,
        interval: DateInterval,
        storedStart: Date
    ) -> EventOccurrence {
        EventOccurrence(
            eventID: event.id,
            calendarID: event.calendar?.id,
            title: event.title,
            start: interval.start,
            end: interval.end,
            isAllDay: event.isAllDay,
            colorHex: event.calendar?.colorHex ?? UserCalendar.defaultColorHex,
            source: event.source,
            isOverride: event.isOverride,
            storedStart: storedStart
        )
    }
}
