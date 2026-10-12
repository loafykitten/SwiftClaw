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

    /// UID prefix native rows export under (they have no external identity).
    nonisolated static let nativeExportUIDPrefix = "swiftclaw-"

    /// Imports preload external identities once so a large calendar produces
    /// one fetch.
    private var importedEventsByExternalIdentifier: [String: CalendarEvent]?
    /// Inside `performTransaction`, saves are deferred to one commit at the
    /// end (one save and one store-change notification).
    private var isDeferringSaves = false
    private var deferredSaveNeeded = false
    /// Performs the actual store write. A seam so tests can inject a
    /// persistence failure; production always calls `ModelContext.save()`.
    private let persist: @MainActor (ModelContext) throws -> Void

    /// A save that failed. The write was rolled back, so the rows on screen
    /// match the store again and the user can simply retry.
    struct SaveError: LocalizedError {
        let underlying: any Error

        var errorDescription: String? {
            String(localized: "SwiftClaw couldn't save this change, so nothing was changed. Try again.")
        }
    }

    init(
        modelContext: ModelContext,
        persist: @escaping @MainActor (ModelContext) throws -> Void = { try $0.save() }
    ) {
        self.modelContext = modelContext
        self.persist = persist
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
        if let event = exactEvent(withExternalIdentifier: externalIdentifier) {
            return event
        }
        // Files written before civil dates key all-day occurrences by their
        // local-midnight instant ("…@<seconds>"); the migration re-keyed
        // those rows to the canonical date, so try that spelling too.
        guard let alias = Self.civilAlias(ofLegacyIdentifier: externalIdentifier),
              let event = exactEvent(withExternalIdentifier: alias)
        else { return nil }
        return event
    }

    /// "<prefix>@<local midnight>" → "<prefix>@<canonical civil date>", or
    /// nil when the suffix isn't a local-midnight instant.
    private static func civilAlias(ofLegacyIdentifier identifier: String) -> String? {
        guard let separator = identifier.lastIndex(of: "@"),
              let seconds = Double(identifier[identifier.index(after: separator)...])
        else { return nil }
        let instant = Date(timeIntervalSinceReferenceDate: seconds)
        guard Calendar.current.startOfDay(for: instant) == instant else { return nil }
        let canonical = CivilDay.canonicalDate(forLocal: instant)
        guard canonical != instant else { return nil }
        return "\(identifier[..<separator])@\(canonical.timeIntervalSinceReferenceDate)"
    }

    private func exactEvent(withExternalIdentifier externalIdentifier: String) -> CalendarEvent? {
        if let importedEventsByExternalIdentifier {
            return importedEventsByExternalIdentifier[externalIdentifier]
                ?? nativeEvent(forExportedUID: externalIdentifier)
        }
        if let native = nativeEvent(forExportedUID: externalIdentifier) {
            return native
        }
        var descriptor = FetchDescriptor<CalendarEvent>(
            predicate: #Predicate { $0.externalIdentifier == externalIdentifier },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor))?.first
    }

    @discardableResult
    func insert(_ event: CalendarEvent) -> CalendarEvent {
        refreshRecurrenceEnd(of: event)
        modelContext.insert(event)
        save()
        return event
    }

    /// Stamp + persist after in-place edits made by callers (the editor binds
    /// directly to the model).
    func noteUpdated(_ event: CalendarEvent) {
        event.modifiedAt = .now
        refreshRecurrenceEnd(of: event)
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
    func occurrences(
        in window: DateInterval,
        visibleCalendarsOnly: Bool = true,
        calendar: Calendar = .current
    ) -> [EventOccurrence] {
        // Widened for all-day rows' canonical dates; the builder is exact.
        let fetchWindow = CalendarEvent.storeFetchWindow(for: window)
        let windowStart = fetchWindow.start
        let windowEnd = fetchWindow.end

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
                && ($0.recurrenceEndDate ?? distantFuture) >= windowStart
        }

        let plain = (try? modelContext.fetch(FetchDescriptor(predicate: plainPredicate))) ?? []
        let recurring = (try? modelContext.fetch(FetchDescriptor(predicate: recurringPredicate))) ?? []
        return CalendarOccurrenceBuilder.occurrences(
            from: plain + recurring,
            in: window,
            visibleCalendarsOnly: visibleCalendarsOnly,
            calendar: calendar
        )
    }

    // MARK: - Recurring edit/delete semantics

    // Occurrence starts here are in the master's stored encoding (canonical
    // civil dates for all-day series): pass `EventOccurrence.occurrenceKey`,
    // not the displayed `start`.

    /// Detaches one occurrence of a recurring master for an independent edit:
    /// the occurrence joins the master's EXDATEs and a standalone override row
    /// (same fields, linked via `parentEventID`) is returned for the caller to
    /// mutate. EventKit's detached-occurrence shape, so imports map directly.
    @discardableResult
    func detachOccurrence(of master: CalendarEvent, at requestedStart: Date) -> CalendarEvent {
        let occurrenceStart = normalizedOccurrenceKey(requestedStart, of: master)
        let override = CalendarEvent(
            title: master.title,
            startDate: occurrenceStart,
            endDate: master.occurrenceEnd(forStart: occurrenceStart),
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

    // The user-facing single mutations below (delete, drag-reschedule) each
    // run as their own `performTransaction`: a failed save rolls back just
    // that change and throws `SaveError`, so the UI can say so instead of
    // showing a change that never reached the store.

    /// Removes a single occurrence from a recurring master (EXDATE).
    func deleteOccurrence(of master: CalendarEvent, at occurrenceStart: Date) throws {
        try performTransaction {
            master.exceptionDates.append(normalizedOccurrenceKey(occurrenceStart, of: master))
            master.modifiedAt = .now
            save()
        }
    }

    /// Ends a recurring master just before `occurrenceStart`; that occurrence
    /// and everything after (including now-orphaned overrides) is removed.
    func deleteThisAndFuture(of master: CalendarEvent, from requestedStart: Date) throws {
        guard master.recurrenceRuleString.flatMap(RecurrenceRule.init(rruleString:)) != nil else {
            try deleteEventSeries(master)
            return
        }
        try performTransaction {
            let occurrenceStart = normalizedOccurrenceKey(requestedStart, of: master)
            guard var rule = master.recurrenceRuleString.flatMap(RecurrenceRule.init(rruleString:)) else { return }
            let until = occurrenceStart.addingTimeInterval(-1)
            rule.end = .untilDate(until)
            master.recurrenceRuleString = rule.rruleString
            refreshRecurrenceEnd(of: master)
            master.modifiedAt = .now
            for override in overrides(of: master)
            where (override.originalOccurrenceDate ?? override.startDate) >= occurrenceStart {
                modelContext.delete(override)
            }
            save()
        }
    }

    /// Deletes a master plus all of its detached overrides (or a one-off).
    func deleteEventSeries(_ event: CalendarEvent) throws {
        try performTransaction {
            for override in overrides(of: event) {
                deleteRow(override)
            }
            deleteRow(event)
            save()
        }
    }

    /// Moves or resizes a one-off (or override) from a timeline drag.
    func reschedule(_ event: CalendarEvent, start: Date, end: Date) throws {
        try performTransaction {
            event.startDate = start
            event.endDate = end
            noteUpdated(event)
        }
    }

    /// Turns a recurring row into a plain one-off: drops its rule, EXDATEs,
    /// and detached overrides. For an imported series that its source now
    /// reports as a single event; keeping the rule would go on generating
    /// (and alerting for) occurrences that no longer exist.
    func clearRecurrence(of event: CalendarEvent) {
        guard event.recurrenceRuleString != nil || !event.exceptionDates.isEmpty || !overrides(of: event).isEmpty else {
            return
        }
        for override in overrides(of: event) {
            deleteRow(override)
        }
        event.recurrenceRuleString = nil
        event.exceptionDates = []
        refreshRecurrenceEnd(of: event)
        event.modifiedAt = .now
        save()
    }

    /// Reconciles a re-imported series' detached overrides with the file it
    /// came from, which is authoritative for that series. An imported
    /// override (keyed `importedIdentifierPrefix…`) the file no longer
    /// carries is deleted unless its original occurrence is still masked by
    /// an EXDATE: re-importing reset the master's EXDATEs, so that occurrence
    /// renders again and the stale override would double it. A file that
    /// still masks it may simply be partial, so the override stays. Native
    /// overrides (the user's own edits) always stay, re-masked so they
    /// don't double-render either.
    func reconcileImportedOverrides(
        of master: CalendarEvent,
        importedIdentifierPrefix: String,
        keeping currentIdentifiers: Set<String>
    ) {
        var changed = false
        for override in overrides(of: master) {
            // Its key must be in the master's (canonical) encoding.
            normalizeLegacyCivilDates(of: override)
            let original = override.originalOccurrenceDate ?? override.startDate
            let isMasked = RecurrenceExpander.isException(original, exceptionDates: master.exceptionDates)
            if let identifier = override.externalIdentifier, identifier.hasPrefix(importedIdentifierPrefix) {
                guard !currentIdentifiers.contains(identifier), !isMasked else { continue }
                deleteRow(override)
                changed = true
            } else if override.externalIdentifier == nil, master.isRecurring, !isMasked {
                master.exceptionDates.append(original)
                changed = true
            }
        }
        if changed {
            save()
        }
    }

    /// Deletes one row, keeping the import identity cache in step so a later
    /// lookup in the same batch can't return the deleted object.
    private func deleteRow(_ event: CalendarEvent) {
        if let externalIdentifier = event.externalIdentifier,
           importedEventsByExternalIdentifier?[externalIdentifier] === event {
            importedEventsByExternalIdentifier?[externalIdentifier] = nil
        }
        modelContext.delete(event)
    }

    func overrides(of master: CalendarEvent) -> [CalendarEvent] {
        let masterID = master.id
        let descriptor = FetchDescriptor<CalendarEvent>(
            predicate: #Predicate { $0.parentEventID == masterID }
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    /// Re-derives `recurrenceEndDate` from the rule; call whenever the rule
    /// string, start, duration, or time zone changes. COUNT uses the canonical
    /// expander so BY-parts and DST behavior cannot drift from rendering.
    ///
    /// The stored value is the END of the last possible occurrence (its start
    /// plus the event's duration), not its start: the window predicates test
    /// `recurrenceEndDate >= windowStart`, and a final occurrence that starts
    /// before the window but spans into it (an evening event crossing
    /// midnight, a multi-day event) must still be fetched and expanded.
    func refreshRecurrenceEnd(of event: CalendarEvent) {
        guard let rule = event.recurrenceRuleString.flatMap(RecurrenceRule.init(rruleString:)) else {
            event.recurrenceEndDate = nil
            return
        }
        switch rule.end {
        case .untilDate(let until):
            event.recurrenceEndDate = until.addingTimeInterval(event.duration)
        case .occurrenceCount(let count):
            let starts = RecurrenceExpander.occurrenceStarts(
                rule: rule,
                eventStart: event.startDate,
                duration: event.duration,
                window: DateInterval(
                    start: event.startDate.addingTimeInterval(-1),
                    end: .distantFuture
                ),
                timeZone: event.recurrenceTimeZone,
                cap: count
            )
            event.recurrenceEndDate = starts.last.map { $0.addingTimeInterval(event.duration) }
        case nil:
            event.recurrenceEndDate = nil
        }
    }

    /// One-time migration for rows written before COUNT end dates were
    /// persisted. A failed fetch leaves the flag unset so the next launch
    /// retries instead of permanently leaving old rows unbounded.
    @discardableResult
    func backfillRecurrenceEndDatesIfNeeded(userDefaults: UserDefaults = .standard) -> Int {
        // v2: v1 briefly shipped start-side end dates; the bump recomputes
        // them as end-of-final-occurrence for stores that already migrated.
        let key = "calendar.recurrenceEndDate.backfilled.v2"
        guard !userDefaults.bool(forKey: key) else { return 0 }
        guard let events = try? modelContext.fetch(FetchDescriptor<CalendarEvent>()) else { return 0 }

        var changed = 0
        for event in events where event.recurrenceRuleString != nil {
            let previous = event.recurrenceEndDate
            refreshRecurrenceEnd(of: event)
            if event.recurrenceEndDate != previous {
                changed += 1
            }
        }
        if changed > 0 {
            save()
        }
        userDefaults.set(true, forKey: key)
        return changed
    }

    /// Conversion of legacy all-day values (local-midnight instants) to
    /// canonical civil dates (`CalendarEvent.convertLegacyCivilDatesIfNeeded`).
    /// Each legacy instant is read as a day in `calendar`'s zone, which is
    /// best effort: a row created in another zone and never opened since
    /// migrates to the day it showed on this device just before the upgrade.
    /// The per-row `dateEncodingVersion` marker makes it idempotent: stamped
    /// rows are never fetched again, so nothing double-converts. Runs at
    /// launch and before every post-merge dedupe, so legacy rows a sync
    /// delivers later convert too.
    ///
    /// An override's original-occurrence key is in its master's encoding, so
    /// an override whose master can't be resolved yet (a merge delivered it
    /// first) stays legacy and unstamped for a later pass.
    ///
    /// One scoped transaction: changes other writers left pending are saved
    /// first, and if that save fails the migration doesn't run at all
    /// (nothing is rolled back). A failed fetch or commit converts nothing
    /// and retries next time.
    @discardableResult
    func migrateAllDayDatesToCivilEncodingIfNeeded(calendar: Calendar = .current) -> Int {
        do {
            return try migrateLegacyCivilDates(calendar: calendar)
        } catch {
            Self.logger.error("civil date migration failed: \(String(describing: error))")
            return 0
        }
    }

    @discardableResult
    private func migrateLegacyCivilDates(calendar: Calendar) throws -> Int {
        let legacy = try modelContext.fetch(FetchDescriptor<CalendarEvent>(
            predicate: #Predicate { $0.dateEncodingVersion == nil }
        ))
        guard !legacy.isEmpty else { return 0 }
        let parentIDs = Array(Set(legacy.compactMap(\.parentEventID)))
        let parents = parentIDs.isEmpty ? [] : try modelContext.fetch(FetchDescriptor<CalendarEvent>(
            predicate: #Predicate { parentIDs.contains($0.id) }
        ))
        var masterIsAllDay: [UUID: Bool] = [:]
        for parent in parents where masterIsAllDay[parent.id] == nil {
            masterIsAllDay[parent.id] = parent.isAllDay
        }

        return try performTransaction {
            var converted = 0
            for event in legacy {
                var parentIsAllDay: Bool?
                if let parentID = event.parentEventID {
                    guard let resolved = masterIsAllDay[parentID] else { continue }
                    parentIsAllDay = resolved
                }
                if event.convertLegacyCivilDatesIfNeeded(masterIsAllDay: parentIsAllDay, calendar: calendar) {
                    refreshRecurrenceEnd(of: event)
                    converted += 1
                }
            }
            save()
            return converted
        }
    }

    /// Converts `event` if it is still a legacy row, before a mutation writes
    /// canonical values into it; otherwise the next migration pass would
    /// convert those values a second time. Unlike the bulk pass this must
    /// stamp the row now, so an override whose master is missing is
    /// converted against its own all-day state. Returns whether the row was
    /// legacy (so all-day keys derived from it before this call were too).
    @discardableResult
    func normalizeLegacyCivilDates(of event: CalendarEvent, calendar: Calendar = .current) -> Bool {
        guard event.dateEncodingVersion == nil else { return false }
        let masterIsAllDay = event.parentEventID.flatMap { self.event(withID: $0)?.isAllDay }
        if event.convertLegacyCivilDatesIfNeeded(masterIsAllDay: masterIsAllDay, calendar: calendar) {
            refreshRecurrenceEnd(of: event)
        }
        return true
    }

    /// Normalizes a master about to take an occurrence key. A key the UI
    /// derived from a still-legacy all-day row is a legacy instant too, and
    /// converts with it.
    private func normalizedOccurrenceKey(_ key: Date, of master: CalendarEvent) -> Date {
        let wasLegacy = normalizeLegacyCivilDates(of: master)
        return wasLegacy && master.isAllDay ? CivilDay.canonicalDate(forLocal: key) : key
    }

    /// Re-keys a recurring master's EXDATEs and its overrides'
    /// `originalOccurrenceDate` after the series switched between timed and
    /// all-day (`wasAllDay` is the old state), so they keep naming the same
    /// local days: all-day keys are canonical civil dates, timed keys are
    /// instants at the series' start time. Call before saving the edit.
    /// `nativeOverridesOnly` skips imported overrides, for a file re-import
    /// that rebuilds those (and the EXDATEs) in the new encoding itself:
    /// re-keying the stale ones would keep them masked and doubled.
    func reencodeOccurrenceKeys(
        of master: CalendarEvent,
        wasAllDay: Bool,
        nativeOverridesOnly: Bool = false,
        calendar: Calendar = .current
    ) {
        guard master.isAllDay != wasAllDay, master.isRecurring, !master.isOverride else { return }
        let convert: (Date) -> Date
        if master.isAllDay {
            convert = { CivilDay.canonicalDate(forLocal: $0, in: calendar) }
        } else {
            var zone = Calendar(identifier: .gregorian)
            zone.timeZone = master.timeZone ?? calendar.timeZone
            let time = zone.dateComponents([.hour, .minute, .second], from: master.startDate)
            convert = { key in
                let dayStart = CivilDay(canonical: key).startDate(in: zone)
                return zone.date(
                    bySettingHour: time.hour ?? 0,
                    minute: time.minute ?? 0,
                    second: time.second ?? 0,
                    of: dayStart
                ) ?? dayStart
            }
        }
        master.exceptionDates = master.exceptionDates.map(convert)
        for override in overrides(of: master) where !nativeOverridesOnly || override.externalIdentifier == nil {
            override.originalOccurrenceDate = override.originalOccurrenceDate.map(convert)
        }
    }

    // MARK: - Transactions

    /// Runs `body` as one all-or-nothing write: saves inside it are deferred
    /// to a single commit at the end. A failed commit rolls the context back
    /// (so in-memory rows match the store again) and throws `SaveError`, so a
    /// caller like the editor's Save can keep its draft and report the
    /// failure instead of dismissing as if the change had landed. Nested
    /// calls join the outer transaction.
    ///
    /// UI repositories share the main context, so the rollback must only
    /// ever discard this transaction's writes: changes already pending when
    /// it starts are saved first, and if that save fails the transaction
    /// throws before running `body` (rolling back nothing).
    func performTransaction<Result>(_ body: () throws -> Result) throws -> Result {
        guard !isDeferringSaves else { return try body() }
        try savePendingChanges()
        isDeferringSaves = true
        deferredSaveNeeded = false
        let result: Result
        do {
            result = try body()
        } catch {
            isDeferringSaves = false
            deferredSaveNeeded = false
            modelContext.rollback()
            throw error
        }
        isDeferringSaves = false
        if deferredSaveNeeded {
            deferredSaveNeeded = false
            try commit()
        }
        return result
    }

    // MARK: - Import support

    /// Runs an import as one persistence transaction (`performTransaction`):
    /// nothing is reported as imported unless the whole batch committed. The
    /// identity cache is invalidated when the batch ends; all later lookups
    /// return to live SwiftData fetches.
    func performImport<Result>(_ body: () throws -> Result) throws -> Result {
        guard importedEventsByExternalIdentifier == nil else { return try body() }

        let descriptor = FetchDescriptor<CalendarEvent>(sortBy: [SortDescriptor(\.createdAt)])
        let existing = (try? modelContext.fetch(descriptor)) ?? []
        var byExternalIdentifier: [String: CalendarEvent] = [:]
        for event in existing {
            if let externalIdentifier = event.externalIdentifier,
               byExternalIdentifier[externalIdentifier] == nil
            {
                byExternalIdentifier[externalIdentifier] = event
            }
        }
        importedEventsByExternalIdentifier = byExternalIdentifier
        defer { importedEventsByExternalIdentifier = nil }
        return try performTransaction(body)
    }

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
            // A still-legacy row converts before the import writes into it.
            normalizeLegacyCivilDates(of: event)
        } else {
            event = CalendarEvent(externalIdentifier: externalIdentifier)
            modelContext.insert(event)
        }
        apply(event)
        event.modifiedAt = .now
        refreshRecurrenceEnd(of: event)
        importedEventsByExternalIdentifier?[externalIdentifier] = event
        save()
        return event
    }

    /// A native row (no external identity) addressed by the UID it exports
    /// under, `swiftclaw-<id>`, so importing your own export updates the
    /// original instead of creating a duplicate beside it.
    private func nativeEvent(forExportedUID uid: String) -> CalendarEvent? {
        guard uid.hasPrefix(Self.nativeExportUIDPrefix),
              let id = UUID(uuidString: String(uid.dropFirst(Self.nativeExportUIDPrefix.count))),
              let event = event(withID: id),
              event.externalIdentifier == nil
        else { return nil }
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
        // A merge can deliver legacy rows from an older build; convert them
        // first so duplicates collapse in one encoding (unioning legacy
        // EXDATE instants into a canonical survivor would resurrect deleted
        // occurrences). If that fails, skip this pass rather than merge mixed
        // encodings; the next merge retries.
        do {
            try migrateLegacyCivilDates(calendar: .current)
        } catch {
            Self.logger.error("post-merge civil date migration failed: \(String(describing: error))")
            return
        }
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

    /// Best-effort save for background and settings writes: failures are
    /// logged. User-facing mutations and anything that must not report
    /// success on failure go through `performTransaction` /
    /// `performImport`, whose commit throws.
    private func save() {
        if isDeferringSaves {
            deferredSaveNeeded = true
            return
        }
        do {
            try persist(modelContext)
            NotificationCenter.default.post(name: .calendarStoreDidChange, object: nil)
        } catch {
            Self.logger.error("save failed: \(String(describing: error))")
        }
    }

    /// Saves changes some other writer left pending, without rolling back on
    /// failure — they aren't ours to discard.
    private func savePendingChanges() throws {
        guard modelContext.hasChanges else { return }
        do {
            try persist(modelContext)
        } catch {
            Self.logger.error("pending-changes save failed: \(String(describing: error))")
            throw SaveError(underlying: error)
        }
        NotificationCenter.default.post(name: .calendarStoreDidChange, object: nil)
    }

    private func commit() throws {
        do {
            try persist(modelContext)
        } catch {
            Self.logger.error("transaction save failed: \(String(describing: error))")
            modelContext.rollback()
            throw SaveError(underlying: error)
        }
        NotificationCenter.default.post(name: .calendarStoreDidChange, object: nil)
    }
}

extension Notification.Name {
    /// Posted after every successful calendar-store save so interested
    /// services (the alert scheduler) can reconcile without polling.
    static let calendarStoreDidChange = Notification.Name("SwiftClaw.calendarStoreDidChange")
}
