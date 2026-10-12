import EventKit
import Foundation
import os

/// Imports Apple Calendar (EventKit) data into SwiftClaw's own store.
/// Re-runnable: everything upserts by `calendarItemExternalIdentifier`, so a
/// second import updates rather than duplicates. Requires full calendar
/// access (`NSCalendarsFullAccessUsageDescription` + the calendars
/// entitlement).
@MainActor
final class AppleCalendarImporter {
    private static let logger = AppLog.make("calendar.import")

    struct Summary: Sendable {
        var calendarCount = 0
        var eventCount = 0
        var overrideCount = 0
        /// Series whose recurrence didn't fit our RRULE subset and were
        /// imported as individual occurrences instead.
        var degradedSeriesCount = 0
    }

    enum ImportError: LocalizedError {
        case accessDenied

        var errorDescription: String? {
            switch self {
            case .accessDenied:
                "SwiftClaw wasn't allowed to read your calendars. You can grant access in System Settings › Privacy & Security › Calendars."
            }
        }
    }

    /// Default import range: one year back, three years forward.
    nonisolated static func defaultRange(from now: Date = .now) -> DateInterval {
        DateInterval(
            start: now.addingTimeInterval(-365 * 24 * 3600),
            end: now.addingTimeInterval(3 * 365 * 24 * 3600)
        )
    }

    private let store = EKEventStore()

    func requestAccess() async throws {
        let granted = try await store.requestFullAccessToEvents()
        guard granted else { throw ImportError.accessDenied }
    }

    /// The user's event calendars, for the source picker.
    func availableCalendars() -> [(identifier: String, title: String, colorHex: String)] {
        store.calendars(for: .event).map {
            ($0.calendarIdentifier, $0.title, EventKitMapping.colorHex(from: $0.cgColor))
        }
    }

    /// Imports the selected source calendars over `range` as one
    /// transaction: a failed save throws and nothing is reported imported.
    @discardableResult
    func importCalendars(
        identifiers: Set<String>,
        range: DateInterval = AppleCalendarImporter.defaultRange(),
        repository: CalendarRepository
    ) throws -> Summary {
        let summary = try repository.performImport {
            var summary = Summary()
            let sourceCalendars = store.calendars(for: .event).filter {
                identifiers.contains($0.calendarIdentifier)
            }

            for source in sourceCalendars {
                let target = upsertCalendar(from: source, repository: repository)
                summary.calendarCount += 1
                importEvents(
                    from: source,
                    into: target,
                    range: range,
                    repository: repository,
                    summary: &summary
                )
            }
            repository.dedupeAfterRemoteMerge()
            return summary
        }
        Self.logger.info("""
            apple import: \(summary.calendarCount, privacy: .public) calendars, \
            \(summary.eventCount, privacy: .public) events, \
            \(summary.overrideCount, privacy: .public) overrides, \
            \(summary.degradedSeriesCount, privacy: .public) degraded series
            """)
        return summary
    }

    // MARK: - Calendars

    private func upsertCalendar(from source: EKCalendar, repository: CalendarRepository) -> UserCalendar {
        if let existing = repository.calendarMatching(externalIdentifier: source.calendarIdentifier) {
            existing.name = source.title
            existing.colorHex = EventKitMapping.colorHex(from: source.cgColor)
            repository.noteUpdated(existing)
            return existing
        }
        return repository.createCalendar(
            name: source.title,
            colorHex: EventKitMapping.colorHex(from: source.cgColor),
            externalIdentifier: source.calendarIdentifier
        )
    }

    // MARK: - Events

    private func importEvents(
        from source: EKCalendar,
        into target: UserCalendar,
        range: DateInterval,
        repository: CalendarRepository,
        summary: inout Summary
    ) {
        // EventKit predicates cap at 4 years; chunk the range.
        var occurrences: [EKEvent] = []
        var chunkStart = range.start
        let chunkLength: TimeInterval = 4 * 365 * 24 * 3600 - 24 * 3600
        while chunkStart < range.end {
            let chunkEnd = min(range.end, chunkStart.addingTimeInterval(chunkLength))
            let predicate = store.predicateForEvents(withStart: chunkStart, end: chunkEnd, calendars: [source])
            occurrences.append(contentsOf: store.events(matching: predicate))
            chunkStart = chunkEnd
        }

        let groups = Dictionary(grouping: occurrences) { $0.calendarItemExternalIdentifier ?? UUID().uuidString }
        for (externalIdentifier, group) in groups {
            guard let sample = group.first else { continue }
            // A detached instance belongs to a series even when it's the
            // only one in range; the one-off path would flatten the master.
            if sample.hasRecurrenceRules || sample.isDetached || group.count > 1 {
                importRecurringSeries(
                    externalIdentifier: externalIdentifier,
                    occurrences: group,
                    into: target,
                    range: range,
                    repository: repository,
                    summary: &summary
                )
            } else {
                upsertOneOff(sample, externalIdentifier: externalIdentifier, into: target, repository: repository)
                summary.eventCount += 1
            }
        }
    }

    private func upsertOneOff(
        _ ekEvent: EKEvent,
        externalIdentifier: String,
        into target: UserCalendar,
        repository: CalendarRepository
    ) {
        let event = repository.upsertImportedEvent(externalIdentifier: externalIdentifier) { event in
            apply(ekEvent, to: event, calendar: target)
        }
        // The series may have become a single event in Apple Calendar since
        // the last import; drop its old rule, EXDATEs, and overrides.
        repository.clearRecurrence(of: event)
    }

    private func importRecurringSeries(
        externalIdentifier: String,
        occurrences: [EKEvent],
        into target: UserCalendar,
        range: DateInterval,
        repository: CalendarRepository,
        summary: inout Summary
    ) {
        // The windowed fetch returns expanded occurrences; the true series
        // master (original DTSTART + rules) comes from the item lookup. The
        // lookup is unsorted and can also return detached instances or the
        // same server event from another calendar, so prefer a non-detached,
        // rule-carrying event from the source calendar.
        let lookupResults = store.calendarItems(withExternalIdentifier: externalIdentifier)
            .compactMap { $0 as? EKEvent }
        let sourceCalendarID = occurrences.first?.calendar?.calendarIdentifier
        let master = lookupResults.first {
            !$0.isDetached && $0.hasRecurrenceRules
                && (sourceCalendarID == nil || $0.calendar?.calendarIdentifier == sourceCalendarID)
        }
            ?? lookupResults.first { !$0.isDetached && $0.hasRecurrenceRules }
            ?? lookupResults.first

        let rule = master?.recurrenceRules?.first.flatMap(EventKitMapping.recurrenceRule(from:))
        guard let master, let rule else {
            // Unmappable (or unresolvable) series: degrade to the windowed
            // occurrences as standalone events, each with a synthesized
            // occurrence-scoped identity so re-imports stay idempotent.
            summary.degradedSeriesCount += 1
            for occurrence in occurrences {
                let occurrenceID = "\(externalIdentifier)@\(occurrence.startDate.timeIntervalSinceReferenceDate)"
                repository.upsertImportedEvent(externalIdentifier: occurrenceID) { event in
                    apply(occurrence, to: event, calendar: target)
                }
                summary.eventCount += 1
            }
            return
        }

        let masterRow = repository.upsertImportedEvent(externalIdentifier: externalIdentifier) { event in
            apply(master, to: event, calendar: target)
            event.recurrenceRuleString = rule.rruleString
        }
        summary.eventCount += 1

        // Detached occurrences (edited instances) become override rows.
        var detachedOriginalStarts: [Date] = []
        for occurrence in occurrences where occurrence.isDetached {
            // `startDate` is an IUO in EventKit; bind it before the nil-
            // coalescing so the result is non-optional.
            let occurrenceStart: Date = occurrence.startDate
            let originalStart = occurrence.occurrenceDate ?? occurrenceStart
            detachedOriginalStarts.append(originalStart)
            let overrideID = "\(externalIdentifier)@detached@\(originalStart.timeIntervalSinceReferenceDate)"
            repository.upsertImportedEvent(externalIdentifier: overrideID) { event in
                apply(occurrence, to: event, calendar: target)
                event.parentEventID = masterRow.id
                event.originalOccurrenceDate = originalStart
            }
            summary.overrideCount += 1
        }

        let actualStarts: [Date] = occurrences
            .filter { !$0.isDetached }
            .compactMap(\.startDate)

        // Drop override rows from an earlier import whose detached occurrence
        // no longer exists in EventKit (the edit was reverted or the instance
        // deleted) — otherwise the EXDATE rebuild below un-masks the master
        // occurrence and the stale override would render alongside it. Only
        // the fetched window is evidence: overrides it can't see stay.
        let currentOverrideIDs = Set(detachedOriginalStarts.map {
            "\(externalIdentifier)@detached@\($0.timeIntervalSinceReferenceDate)"
        })
        for override in repository.overrides(of: masterRow)
        where override.source == .appleImport
            && override.externalIdentifier?.hasPrefix("\(externalIdentifier)@detached@") == true
            && !currentOverrideIDs.contains(override.externalIdentifier ?? "")
            && EventKitMapping.isStaleImportedOverride(
                originalStart: override.originalOccurrenceDate ?? override.startDate,
                overrideStart: override.startDate,
                overrideDuration: override.duration,
                masterDuration: masterRow.duration,
                window: range,
                actualStarts: actualStarts
            ) {
            repository.deleteEventSeries(override)
        }

        // Occurrences the user deleted are simply absent from the fetch;
        // recover them (and mask the detached ones) as EXDATEs. EXDATEs
        // outside the fetched window are kept — this fetch can't speak for
        // them, and dropping them would resurrect deleted occurrences.
        let missing = EventKitMapping.missingOccurrenceStarts(
            rule: rule,
            masterStart: masterRow.startDate,
            duration: masterRow.duration,
            window: range,
            actualStarts: actualStarts,
            timeZone: masterRow.timeZone
        )
        masterRow.exceptionDates = EventKitMapping.reconciledExceptionDates(
            existing: masterRow.exceptionDates,
            missing: missing,
            detachedOriginalStarts: detachedOriginalStarts,
            duration: masterRow.duration,
            window: range
        )
        // The rebuild can un-mask an occurrence the user detached inside
        // SwiftClaw (EventKit still reports it); re-mask those native edits.
        repository.reconcileImportedOverrides(
            of: masterRow,
            importedIdentifierPrefix: "\(externalIdentifier)@detached@",
            keeping: currentOverrideIDs
        )
        repository.noteUpdated(masterRow)
    }

    /// Field-level EKEvent → CalendarEvent copy (everything but recurrence,
    /// which the series importer owns).
    private func apply(_ ekEvent: EKEvent, to event: CalendarEvent, calendar target: UserCalendar) {
        event.title = ekEvent.title ?? ""
        event.startDate = ekEvent.startDate
        event.isAllDay = ekEvent.isAllDay
        if ekEvent.isAllDay {
            event.timeZoneIdentifier = nil
            event.endDate = EventKitMapping.normalizedAllDayEnd(ekEvent.endDate, calendar: .current)
        } else {
            event.timeZoneIdentifier = ekEvent.timeZone?.identifier
            event.endDate = ekEvent.endDate
        }
        event.locationText = ekEvent.location
        event.notes = ekEvent.notes
        event.urlString = ekEvent.url?.absoluteString
        event.alarms = EventKitMapping
            .alarmOffsets(from: ekEvent.alarms, eventStart: ekEvent.startDate)
            .map(CalendarAlarmPayload.init(offsetSeconds:))
        event.source = .appleImport
        event.calendar = target
    }
}
