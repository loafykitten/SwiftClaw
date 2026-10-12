import Foundation
import os

/// Turns `CalendarEvent` rows into windowed `EventOccurrence` values: one-offs
/// and overrides pass through when they intersect the window; recurring
/// masters expand via `RecurrenceExpander`. Shared by `CalendarRepository`
/// (predicate-fetched rows) and the calendar views (`@Query` rows), so both
/// paths render identically.
@MainActor
enum CalendarOccurrenceBuilder {
    private static let logger = AppLog.make("calendar.occurrences")

    static func occurrences(
        from events: [CalendarEvent],
        in window: DateInterval,
        visibleCalendarsOnly: Bool = true
    ) -> [EventOccurrence] {
        var occurrences: [EventOccurrence] = []
        for event in events {
            if visibleCalendarsOnly && !(event.calendar?.isVisible ?? true) { continue }

            guard event.isRecurring else {
                if event.startDate < window.end && event.endDate > window.start {
                    occurrences.append(occurrence(for: event, start: event.startDate, end: event.endDate))
                }
                continue
            }
            guard let rule = event.recurrenceRuleString.flatMap(RecurrenceRule.init(rruleString:)) else {
                // Unparseable rule (imported beyond our subset): render the
                // master as a one-off rather than dropping it silently.
                Self.logger.warning("unparseable RRULE on event \(event.id, privacy: .public); rendering as one-off")
                if event.startDate < window.end && event.endDate > window.start {
                    occurrences.append(occurrence(for: event, start: event.startDate, end: event.endDate))
                }
                continue
            }
            let starts = RecurrenceExpander.occurrenceStarts(
                rule: rule,
                eventStart: event.startDate,
                duration: event.duration,
                window: window,
                exceptionDates: event.exceptionDates,
                timeZone: event.timeZone
            )
            for start in starts {
                // Calendar-day end for all-day series (see `occurrenceEnd`);
                // the expander's second-based window test can admit a day
                // that the DST-correct end no longer reaches.
                let end = event.occurrenceEnd(forStart: start)
                guard end > window.start else { continue }
                occurrences.append(occurrence(for: event, start: start, end: end))
            }
        }
        return occurrences.sorted { ($0.start, $0.title) < ($1.start, $1.title) }
    }

    private static func occurrence(for event: CalendarEvent, start: Date, end: Date) -> EventOccurrence {
        EventOccurrence(
            eventID: event.id,
            calendarID: event.calendar?.id,
            title: event.title,
            start: start,
            end: end,
            isAllDay: event.isAllDay,
            colorHex: event.calendar?.colorHex ?? UserCalendar.defaultColorHex,
            source: event.source,
            isOverride: event.isOverride
        )
    }
}
