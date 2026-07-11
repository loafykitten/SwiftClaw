import Foundation
import SwiftData
import os

/// Single mutation boundary for all Calendar/SwiftData writes (the Email
/// pattern — see `EmailRepository`). Also the identity authority: calendar
/// models live in the CloudKit-backed configuration, which forbids
/// `@Attribute(.unique)`, so `id` is not DB-enforced. Every lookup resolves
/// deterministically (earliest `createdAt` wins) and `dedupeAfterRemoteMerge`
/// collapses duplicates a CloudKit merge can produce.
@MainActor
final class CalendarRepository {
    private static let logger = AppLog.make("calendar.repository")

    let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - Calendars

    func calendars() -> [UserCalendar] {
        let descriptor = FetchDescriptor<UserCalendar>(
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.createdAt)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    func calendar(withID id: UUID) -> UserCalendar? {
        var descriptor = FetchDescriptor<UserCalendar>(
            predicate: #Predicate { $0.id == id },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor))?.first
    }

    @discardableResult
    func createCalendar(
        name: String,
        colorHex: String = UserCalendar.defaultColorHex,
        externalIdentifier: String? = nil
    ) -> UserCalendar {
        let calendar = UserCalendar(
            name: name,
            colorHex: colorHex,
            sortOrder: (calendars().map(\.sortOrder).max() ?? -1) + 1,
            externalIdentifier: externalIdentifier
        )
        modelContext.insert(calendar)
        save()
        return calendar
    }

    /// The calendar new events default into. Prefers the user's configured
    /// choice, falls back to the first calendar, creating "Personal" on first
    /// use so the app never has zero calendars once the feature is enabled.
    func defaultCalendar(preferredID: UUID? = nil) -> UserCalendar {
        if let preferredID, let preferred = calendar(withID: preferredID) {
            return preferred
        }
        if let first = calendars().first {
            return first
        }
        return createCalendar(name: String(localized: "Personal"))
    }

    func deleteCalendar(_ calendar: UserCalendar) {
        modelContext.delete(calendar)
        save()
    }

    /// Persist after in-place edits (rename, recolor, visibility toggle).
    func noteUpdated(_ calendar: UserCalendar) {
        save()
    }

    // MARK: - Events

    func event(withID id: UUID) -> CalendarEvent? {
        var descriptor = FetchDescriptor<CalendarEvent>(
            predicate: #Predicate { $0.id == id },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor))?.first
    }

    func events(withIDs ids: [UUID]) -> [CalendarEvent] {
        guard !ids.isEmpty else { return [] }
        let descriptor = FetchDescriptor<CalendarEvent>(
            predicate: #Predicate { ids.contains($0.id) }
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    func event(withExternalIdentifier externalIdentifier: String) -> CalendarEvent? {
        var descriptor = FetchDescriptor<CalendarEvent>(
            predicate: #Predicate { $0.externalIdentifier == externalIdentifier },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor))?.first
    }

    @discardableResult
    func insert(_ event: CalendarEvent) -> CalendarEvent {
        modelContext.insert(event)
        save()
        return event
    }

    /// Stamp + persist after in-place edits made by callers (the editor binds
    /// directly to the model).
    func noteUpdated(_ event: CalendarEvent) {
        event.modifiedAt = .now
        save()
    }

    /// Persists in-place mutations that don't change user-visible content
    /// (review stamps) — unlike `noteUpdated` it leaves `modifiedAt` alone.
    func saveChanges() {
        save()
    }

    // MARK: - Occurrences

    /// All occurrences intersecting `window` from visible (or all) calendars,
    /// sorted by start: one-offs and overrides as-is, recurring masters
    /// expanded via `RecurrenceExpander` with their overrides substituted.
    func occurrences(in window: DateInterval, visibleCalendarsOnly: Bool = true) -> [EventOccurrence] {
        let windowStart = window.start
        let windowEnd = window.end

        // One-offs and overrides intersecting the window.
        let plainPredicate = #Predicate<CalendarEvent> {
            $0.recurrenceRuleString == nil
                && $0.startDate < windowEnd
                && $0.endDate > windowStart
        }
        // Recurring masters whose series overlaps the window at all.
        // (nil recurrence end = infinite series, so it always qualifies.)
        let distantFuture = Date.distantFuture
        let recurringPredicate = #Predicate<CalendarEvent> {
            $0.recurrenceRuleString != nil
                && $0.startDate < windowEnd
                && ($0.recurrenceEndDate ?? distantFuture) > windowStart
        }

        let plain = (try? modelContext.fetch(FetchDescriptor(predicate: plainPredicate))) ?? []
        let recurring = (try? modelContext.fetch(FetchDescriptor(predicate: recurringPredicate))) ?? []
        return CalendarOccurrenceBuilder.occurrences(
            from: plain + recurring,
            in: window,
            visibleCalendarsOnly: visibleCalendarsOnly
        )
    }

    // MARK: - Recurring edit/delete semantics

    /// Detaches one occurrence of a recurring master for an independent edit:
    /// the occurrence joins the master's EXDATEs and a standalone override row
    /// (same fields, linked via `parentEventID`) is returned for the caller to
    /// mutate. EventKit's detached-occurrence shape, so imports map directly.
    @discardableResult
    func detachOccurrence(of master: CalendarEvent, at occurrenceStart: Date) -> CalendarEvent {
        let override = CalendarEvent(
            title: master.title,
            startDate: occurrenceStart,
            endDate: occurrenceStart.addingTimeInterval(master.duration),
            isAllDay: master.isAllDay,
            timeZoneIdentifier: master.timeZoneIdentifier,
            locationText: master.locationText,
            notes: master.notes,
            urlString: master.urlString,
            source: master.source,
            calendar: master.calendar
        )
        override.parentEventID = master.id
        override.originalOccurrenceDate = occurrenceStart
        override.alarmsData = master.alarmsData
        master.exceptionDates.append(occurrenceStart)
        master.modifiedAt = .now
        modelContext.insert(override)
        save()
        return override
    }

    /// Removes a single occurrence from a recurring master (EXDATE).
    func deleteOccurrence(of master: CalendarEvent, at occurrenceStart: Date) {
        master.exceptionDates.append(occurrenceStart)
        master.modifiedAt = .now
        save()
    }

    /// Ends a recurring master just before `occurrenceStart`; that occurrence
    /// and everything after (including now-orphaned overrides) is removed.
    func deleteThisAndFuture(of master: CalendarEvent, from occurrenceStart: Date) {
        guard var rule = master.recurrenceRuleString.flatMap(RecurrenceRule.init(rruleString:)) else {
            deleteEventSeries(master)
            return
        }
        let until = occurrenceStart.addingTimeInterval(-1)
        rule.end = .untilDate(until)
        master.recurrenceRuleString = rule.rruleString
        master.recurrenceEndDate = until
        master.modifiedAt = .now
        for override in overrides(of: master)
        where (override.originalOccurrenceDate ?? override.startDate) >= occurrenceStart {
            modelContext.delete(override)
        }
        save()
    }

    /// Deletes a master plus all of its detached overrides (or a one-off).
    func deleteEventSeries(_ event: CalendarEvent) {
        for override in overrides(of: event) {
            modelContext.delete(override)
        }
        modelContext.delete(event)
        save()
    }

    func overrides(of master: CalendarEvent) -> [CalendarEvent] {
        let masterID = master.id
        let descriptor = FetchDescriptor<CalendarEvent>(
            predicate: #Predicate { $0.parentEventID == masterID }
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    /// Re-derives `recurrenceEndDate` from the rule; call whenever the rule
    /// string is (re)assigned. COUNT ends can't be cheaply bounded without
    /// expansion, so they conservatively keep `nil` (always fetched) — COUNT
    /// series are finite anyway, so expansion stays cheap.
    func refreshRecurrenceEnd(of event: CalendarEvent) {
        guard let rule = event.recurrenceRuleString.flatMap(RecurrenceRule.init(rruleString:)) else {
            event.recurrenceEndDate = nil
            return
        }
        if case .untilDate(let until) = rule.end {
            event.recurrenceEndDate = until
        } else {
            event.recurrenceEndDate = nil
        }
    }

    // MARK: - Import support

    /// Upsert keyed on `externalIdentifier` — re-imports update in place
    /// instead of duplicating. Returns the persisted event.
    @discardableResult
    func upsertImportedEvent(
        externalIdentifier: String,
        apply: (CalendarEvent) -> Void
    ) -> CalendarEvent {
        let event: CalendarEvent
        if let existing = self.event(withExternalIdentifier: externalIdentifier) {
            event = existing
        } else {
            event = CalendarEvent(externalIdentifier: externalIdentifier)
            modelContext.insert(event)
        }
        apply(event)
        event.modifiedAt = .now
        refreshRecurrenceEnd(of: event)
        save()
        return event
    }

    func calendarMatching(externalIdentifier: String) -> UserCalendar? {
        var descriptor = FetchDescriptor<UserCalendar>(
            predicate: #Predicate { $0.externalIdentifier == externalIdentifier },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor))?.first
    }

    // MARK: - CloudKit dedup

    /// Collapses duplicates a CloudKit merge can introduce: rows sharing an
    /// `id` (same record inserted on two devices before first sync) or an
    /// `externalIdentifier` (the same import run on two devices). Keeps the
    /// earliest `createdAt`, re-points overrides at the survivor, and unions
    /// exception dates. Independently created native events are genuinely
    /// distinct and untouched. Also sweeps overrides whose master is gone.
    func dedupeAfterRemoteMerge() {
        dedupeCalendars()
        dedupeEvents()
        sweepOrphanedOverrides()
        save()
    }

    private func dedupeCalendars() {
        let all = calendars()
        var byKey: [String: UserCalendar] = [:]
        for calendar in all.sorted(by: { $0.createdAt < $1.createdAt }) {
            let key = calendar.externalIdentifier ?? calendar.id.uuidString
            if let survivor = byKey[key] {
                for event in calendar.events ?? [] {
                    event.calendar = survivor
                }
                modelContext.delete(calendar)
            } else {
                byKey[key] = calendar
            }
        }
    }

    private func dedupeEvents() {
        let descriptor = FetchDescriptor<CalendarEvent>(sortBy: [SortDescriptor(\.createdAt)])
        let all = (try? modelContext.fetch(descriptor)) ?? []
        var byKey: [String: CalendarEvent] = [:]
        var replacedIDs: [UUID: UUID] = [:]
        for event in all {
            let key = event.externalIdentifier ?? event.id.uuidString
            if let survivor = byKey[key] {
                survivor.exceptionDates = Array(Set(survivor.exceptionDates + event.exceptionDates)).sorted()
                replacedIDs[event.id] = survivor.id
                modelContext.delete(event)
            } else {
                byKey[key] = event
            }
        }
        guard !replacedIDs.isEmpty else { return }
        for event in all where event.parentEventID != nil {
            if let survivorID = replacedIDs[event.parentEventID!], event.isDeleted == false {
                event.parentEventID = survivorID
            }
        }
    }

    private func sweepOrphanedOverrides() {
        let descriptor = FetchDescriptor<CalendarEvent>(
            predicate: #Predicate { $0.parentEventID != nil }
        )
        let overrides = (try? modelContext.fetch(descriptor)) ?? []
        for override in overrides {
            if event(withID: override.parentEventID!) == nil {
                modelContext.delete(override)
            }
        }
    }

    // MARK: - Persistence

    private func save() {
        do {
            try modelContext.save()
            NotificationCenter.default.post(name: .calendarStoreDidChange, object: nil)
        } catch {
            Self.logger.error("save failed: \(String(describing: error))")
        }
    }
}

extension Notification.Name {
    /// Posted after every successful calendar-store save so interested
    /// services (the alert scheduler) can reconcile without polling.
    static let calendarStoreDidChange = Notification.Name("SwiftClaw.calendarStoreDidChange")
}
