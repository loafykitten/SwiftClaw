import Foundation
import os
import SwiftData

/// Single mutation boundary for all Reminders/SwiftData writes (the Email
/// pattern — see `EmailRepository`). Also the identity authority: reminder
/// models live in the CloudKit-backed configuration, which forbids
/// `@Attribute(.unique)`, so `id` is not DB-enforced. Every lookup resolves
/// deterministically (earliest `createdAt` wins) and `dedupeAfterRemoteMerge`
/// collapses duplicates a CloudKit merge can produce.
@MainActor
final class ReminderRepository {
    private static let logger = AppLog.make("reminders.repository")
    private static let importChunkSize = 400

    struct ImportedReminderIdentity {
        let externalIdentifier: String
        let fallbackExternalIdentifier: String?

        init(externalIdentifier: String, fallbackExternalIdentifier: String? = nil) {
            self.externalIdentifier = externalIdentifier
            self.fallbackExternalIdentifier = fallbackExternalIdentifier
        }
    }

    let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - Lists

    func lists() -> [ReminderList] {
        let descriptor = FetchDescriptor<ReminderList>(
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.createdAt)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    func list(withID id: UUID) -> ReminderList? {
        var descriptor = FetchDescriptor<ReminderList>(
            predicate: #Predicate { $0.id == id },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor))?.first
    }

    @discardableResult
    func createList(
        name: String,
        colorHex: String = ReminderList.defaultColorHex,
        externalIdentifier: String? = nil
    ) -> ReminderList {
        let list = ReminderList(
            name: name,
            colorHex: colorHex,
            sortOrder: (lists().map(\.sortOrder).max() ?? -1) + 1,
            externalIdentifier: externalIdentifier
        )
        modelContext.insert(list)
        save()
        return list
    }

    /// Resolves the list new reminders should use without creating one. Editor
    /// sheets use this so opening and cancelling remains a no-op.
    func preferredList(preferredID: UUID? = nil) -> ReminderList? {
        if let preferredID, let preferred = list(withID: preferredID) {
            return preferred
        }
        return lists().first
    }

    /// The list new reminders default into. Prefers the user's configured
    /// choice, falls back to the first list, creating "Reminders" only when a
    /// caller is ready to persist content.
    func defaultList(preferredID: UUID? = nil) -> ReminderList {
        preferredList(preferredID: preferredID)
            ?? createList(name: String(localized: "Reminders"))
    }

    func renameList(_ list: ReminderList, name: String) {
        list.name = name
        save()
    }

    func deleteList(_ list: ReminderList) {
        modelContext.delete(list)
        save()
    }

    /// Persist after in-place edits (recolor, visibility toggle, sort order).
    func noteUpdated(_: ReminderList) {
        save()
    }

    // MARK: - Reminders

    func reminder(withID id: UUID) -> Reminder? {
        var descriptor = FetchDescriptor<Reminder>(
            predicate: #Predicate { $0.id == id },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor))?.first
    }

    func reminder(withExternalIdentifier externalIdentifier: String) -> Reminder? {
        var descriptor = FetchDescriptor<Reminder>(
            predicate: #Predicate { $0.externalIdentifier == externalIdentifier },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor))?.first
    }

    func reminders(withIDs ids: Set<UUID>) -> [Reminder] {
        guard !ids.isEmpty else { return [] }
        let descriptor = FetchDescriptor<Reminder>(
            predicate: #Predicate { ids.contains($0.id) }
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    @discardableResult
    func insert(_ reminder: Reminder, into list: ReminderList? = nil) -> Reminder {
        if let list {
            reminder.list = list
        }
        modelContext.insert(reminder)
        save()
        return reminder
    }

    /// Stamp + persist after in-place edits made by callers (the editor binds
    /// directly to the model).
    func noteUpdated(_ reminder: Reminder) {
        reminder.modifiedAt = .now
        refreshRecurrenceEnd(of: reminder)
        save()
    }

    /// Persists in-place mutations that don't change user-visible content
    /// (review stamps) — unlike `noteUpdated` it leaves `modifiedAt` alone.
    func saveChanges() {
        save()
    }

    // MARK: - Smart Views

    /// Pending masters and one-offs, bounded in the store before models are
    /// materialized. Dated rows lead in due order; optional undated rows trail
    /// oldest-first, matching review-tool ordering.
    func pendingReminders(
        dueBefore: Date? = nil,
        includeUndated: Bool = true,
        limit: Int? = nil
    ) -> [Reminder] {
        if let limit, limit <= 0 { return [] }

        var datedDescriptor: FetchDescriptor<Reminder>
        if let dueBefore {
            let distantFuture = Date.distantFuture
            datedDescriptor = FetchDescriptor(
                predicate: #Predicate {
                    $0.completedAt == nil
                        && $0.parentReminderID == nil
                        && $0.dueDate != nil
                        && ($0.dueDate ?? distantFuture) <= dueBefore
                },
                sortBy: [SortDescriptor(\.dueDate), SortDescriptor(\.createdAt)]
            )
        } else {
            datedDescriptor = FetchDescriptor(
                predicate: #Predicate {
                    $0.completedAt == nil
                        && $0.parentReminderID == nil
                        && $0.dueDate != nil
                },
                sortBy: [SortDescriptor(\.dueDate), SortDescriptor(\.createdAt)]
            )
        }
        if let limit {
            datedDescriptor.fetchLimit = limit
        }
        var result = (try? modelContext.fetch(datedDescriptor)) ?? []

        guard includeUndated, limit.map({ result.count < $0 }) ?? true else {
            return result
        }
        var undatedDescriptor = FetchDescriptor<Reminder>(
            predicate: #Predicate {
                $0.completedAt == nil
                    && $0.parentReminderID == nil
                    && $0.dueDate == nil
            },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        if let limit {
            undatedDescriptor.fetchLimit = limit - result.count
        }
        result.append(contentsOf: (try? modelContext.fetch(undatedDescriptor)) ?? [])
        return result
    }

    func reminders(in list: ReminderList) -> [Reminder] {
        let listID = list.id
        return allReminders().filter { $0.list?.id == listID && !$0.isCompletionLog }
    }

    // MARK: - Completion Semantics

    /// Completes a reminder in one transaction. Recurring masters keep one row
    /// for the next pending occurrence and insert detached completed log rows
    /// so undo and history stay cheap and deterministic.
    ///
    /// `expectedOccurrence` is the due date the caller rendered. A recurring
    /// master stays pending after completing (its `dueDate` rolls forward), so
    /// a double-click would otherwise consume two occurrences; passing the
    /// rendered date makes the stale second call a no-op. `nil` skips the
    /// check (non-UI callers).
    func complete(_ reminder: Reminder, at date: Date = .now, expectedOccurrence: Date?? = nil) {
        guard !reminder.isCompletionLog else { return }
        if reminder.isRecurring, let expectedOccurrence, reminder.dueDate != expectedOccurrence {
            return
        }
        if let repeatRule = reminder.afterCompletionRepeat {
            completeAfterCompletionMaster(reminder, repeatRule: repeatRule, at: date)
        } else if reminder.recurrenceRuleString != nil {
            completeFixedScheduleMaster(reminder, at: date)
        } else {
            reminder.completedAt = date
            reminder.modifiedAt = .now
        }
        save()
    }

    /// Undoes a completion. For log rows this restores the master's scheduled
    /// occurrence and removes the log; for plain reminders it clears
    /// `completedAt`.
    func uncomplete(_ reminder: Reminder) {
        if reminder.isCompletionLog {
            uncompleteLog(reminder)
        } else {
            reminder.completedAt = nil
            reminder.modifiedAt = .now
        }
        save()
    }

    /// Advances a recurring master without writing history. Used for an
    /// explicit "skip this occurrence" action. Skipping the final COUNT
    /// occurrence retires the series at `date` (without it the master would
    /// stay pending at the same due date forever).
    func skipOccurrence(of master: Reminder, at date: Date = .now) {
        guard !master.isCompletionLog else { return }
        if let repeatRule = master.afterCompletionRepeat, let dueDate = master.dueDate {
            master.dueDate = ReminderRecurrenceEngine.nextDueDate(
                afterCompletion: dueDate,
                repeat: repeatRule,
                hasDueTime: master.hasDueTime,
                calendar: calendar(for: master)
            )
            master.modifiedAt = .now
        } else if master.recurrenceRuleString != nil {
            advanceFixedScheduleMaster(master, markExhaustedAt: date)
        }
        save()
    }

    func completionLog(of master: Reminder) -> [Reminder] {
        let masterID = master.id
        let descriptor = FetchDescriptor<Reminder>(
            predicate: #Predicate { $0.parentReminderID == masterID }
        )
        return ((try? modelContext.fetch(descriptor)) ?? []).sorted {
            ($0.completedAt ?? .distantPast) < ($1.completedAt ?? .distantPast)
        }
    }

    /// The newest completion log for each requested master, used to keep old
    /// history rows non-reversible without loading unrelated completion logs.
    func latestCompletionLogIDs(for parentIDs: Set<UUID>) -> Set<UUID> {
        guard !parentIDs.isEmpty else { return [] }
        let optionalParentIDs = parentIDs.map(Optional.some)
        let descriptor = FetchDescriptor<Reminder>(
            predicate: #Predicate { optionalParentIDs.contains($0.parentReminderID) }
        )
        var newest: [UUID: Reminder] = [:]
        for log in (try? modelContext.fetch(descriptor)) ?? [] {
            guard let parentID = log.parentReminderID else { continue }
            if let current = newest[parentID],
               (current.completedAt ?? .distantPast) >= (log.completedAt ?? .distantPast)
            {
                continue
            }
            newest[parentID] = log
        }
        return Set(newest.values.map(\.id))
    }

    /// Deletes a master plus all of its detached completion logs (or a one-off).
    func deleteReminder(_ reminder: Reminder) {
        if reminder.isCompletionLog {
            modelContext.delete(reminder)
        } else {
            for log in completionLog(of: reminder) {
                modelContext.delete(log)
            }
            modelContext.delete(reminder)
        }
        save()
    }

    // MARK: - Import support

    /// Upsert keyed on `externalIdentifier` — re-imports update in place
    /// instead of duplicating. Returns the persisted reminder.
    @discardableResult
    func upsertImportedReminder(
        externalIdentifier: String,
        apply: (Reminder) -> Void
    ) -> Reminder {
        let reminder: Reminder
        if let existing = self.reminder(withExternalIdentifier: externalIdentifier) {
            reminder = existing
        } else {
            reminder = Reminder(externalIdentifier: externalIdentifier)
            modelContext.insert(reminder)
        }
        apply(reminder)
        reminder.modifiedAt = .now
        refreshRecurrenceEnd(of: reminder)
        save()
        return reminder
    }

    /// Prefetches import identities once, then saves once per bounded chunk.
    /// Chunk commits deliberately permit partial progress for very large files.
    @discardableResult
    func upsertImportedReminders(
        _ identities: [ImportedReminderIdentity],
        deduplicateAfterApplying: Bool = false,
        apply: (ImportedReminderIdentity, Reminder) -> Void
    ) -> [Reminder] {
        guard !identities.isEmpty else { return [] }

        let requestedIdentifiers = Set(identities.flatMap { identity in
            [identity.externalIdentifier, identity.fallbackExternalIdentifier].compactMap { $0 }
        })
        let optionalRequestedIdentifiers = requestedIdentifiers.map(Optional.some)
        let existingDescriptor = FetchDescriptor<Reminder>(
            predicate: #Predicate { optionalRequestedIdentifiers.contains($0.externalIdentifier) },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        let existing = (try? modelContext.fetch(existingDescriptor)) ?? []
        var remindersByIdentifier: [String: Reminder] = [:]
        for reminder in existing {
            guard let identifier = reminder.externalIdentifier,
                  requestedIdentifiers.contains(identifier),
                  remindersByIdentifier[identifier] == nil
            else { continue }
            remindersByIdentifier[identifier] = reminder
        }

        var upserted: [Reminder] = []
        upserted.reserveCapacity(identities.count)
        for chunkStart in stride(from: 0, to: identities.count, by: Self.importChunkSize) {
            let chunkEnd = min(chunkStart + Self.importChunkSize, identities.count)
            for identity in identities[chunkStart ..< chunkEnd] {
                let reminder = remindersByIdentifier[identity.externalIdentifier]
                    ?? identity.fallbackExternalIdentifier.flatMap { remindersByIdentifier[$0] }
                    ?? Reminder(externalIdentifier: identity.externalIdentifier)
                if reminder.modelContext == nil {
                    modelContext.insert(reminder)
                }
                apply(identity, reminder)
                reminder.modifiedAt = .now
                refreshRecurrenceEnd(of: reminder)
                remindersByIdentifier[identity.externalIdentifier] = reminder
                if let fallback = identity.fallbackExternalIdentifier {
                    remindersByIdentifier[fallback] = reminder
                }
                upserted.append(reminder)
            }
            if deduplicateAfterApplying, chunkEnd == identities.count {
                dedupeLists()
                dedupeReminders()
                sweepOrphanedCompletionLogs()
            }
            save()
        }
        return upserted
    }

    func listMatching(externalIdentifier: String) -> ReminderList? {
        var descriptor = FetchDescriptor<ReminderList>(
            predicate: #Predicate { $0.externalIdentifier == externalIdentifier },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor))?.first
    }

    // MARK: - CloudKit dedup

    /// Collapses duplicates a CloudKit merge can introduce: lists sharing a
    /// name or `externalIdentifier`, reminders sharing an `id` or
    /// `externalIdentifier`, and log rows whose master is gone. Keeps the
    /// earliest `createdAt` and re-points relationships at the survivor.
    func dedupeAfterRemoteMerge() {
        dedupeLists()
        dedupeReminders()
        sweepOrphanedCompletionLogs()
        save()
    }

    /// Re-derives `recurrenceEndDate` from the rule; call whenever the rule
    /// string is (re)assigned. COUNT ends can't be cheaply bounded without
    /// expansion, so they conservatively keep `nil` (always fetched).
    func refreshRecurrenceEnd(of reminder: Reminder) {
        guard let rule = reminder.recurrenceRuleString.flatMap(RecurrenceRule.init(rruleString:)) else {
            reminder.recurrenceEndDate = nil
            return
        }
        if case let .untilDate(until) = rule.end {
            reminder.recurrenceEndDate = until
        } else {
            reminder.recurrenceEndDate = nil
        }
    }

    private func completeFixedScheduleMaster(_ master: Reminder, at date: Date) {
        insertCompletionLog(for: master, at: date)
        advanceFixedScheduleMaster(master, markExhaustedAt: date)
    }

    private func completeAfterCompletionMaster(
        _ master: Reminder,
        repeatRule: ReminderAfterCompletionRepeat,
        at date: Date
    ) {
        insertCompletionLog(for: master, at: date)
        master.dueDate = ReminderRecurrenceEngine.nextDueDate(
            afterCompletion: date,
            repeat: repeatRule,
            hasDueTime: master.hasDueTime,
            calendar: calendar(for: master)
        )
        master.completedAt = nil
        master.modifiedAt = .now
    }

    private func advanceFixedScheduleMaster(_ master: Reminder, markExhaustedAt date: Date?) {
        guard let dueDate = master.dueDate,
              let ruleString = master.recurrenceRuleString
        else {
            master.completedAt = date
            master.modifiedAt = .now
            return
        }

        let result = ReminderRecurrenceEngine.nextDueDate(
            afterScheduled: dueDate,
            ruleString: ruleString,
            timeZone: timeZone(for: master)
        )
        master.recurrenceRuleString = result.updatedRuleString
        master.dueDate = result.nextDueDate ?? dueDate
        master.completedAt = result.nextDueDate == nil ? date : nil
        refreshRecurrenceEnd(of: master)
        master.modifiedAt = .now
    }

    @discardableResult
    private func insertCompletionLog(for master: Reminder, at date: Date) -> Reminder {
        let log = Reminder(
            title: master.title,
            notes: master.notes,
            urlString: master.urlString,
            dueDate: master.dueDate,
            hasDueTime: master.hasDueTime,
            timeZoneIdentifier: master.timeZoneIdentifier,
            priority: master.priority,
            isFlagged: master.isFlagged,
            completedAt: date,
            sortOrder: master.sortOrder,
            source: master.source,
            list: master.list
        )
        log.parentReminderID = master.id
        log.originalOccurrenceDate = master.dueDate
        log.checklistData = master.checklistData
        modelContext.insert(log)
        return log
    }

    private func uncompleteLog(_ log: Reminder) {
        guard let parentID = log.parentReminderID,
              let master = reminder(withID: parentID)
        else {
            modelContext.delete(log)
            return
        }

        // Only the latest log may rewind the master — undoing an older
        // occurrence would drag `dueDate` back behind still-present logs and
        // re-inflate COUNT for an advance that still stands.
        let latest = completionLog(of: master).last
        guard log.id == latest?.id else { return }

        let oldDueDate = master.dueDate
        if let original = log.originalOccurrenceDate {
            master.dueDate = original
        }
        if oldDueDate != log.originalOccurrenceDate {
            incrementCountRuleIfNeeded(on: master)
        }
        if master.completedAt == log.completedAt {
            master.completedAt = nil
        }
        master.modifiedAt = .now
        modelContext.delete(log)
    }

    private func incrementCountRuleIfNeeded(on reminder: Reminder) {
        guard var rule = reminder.recurrenceRuleString.flatMap(RecurrenceRule.init(rruleString:)),
              case let .occurrenceCount(count) = rule.end
        else { return }
        rule.end = .occurrenceCount(count + 1)
        reminder.recurrenceRuleString = rule.rruleString
        refreshRecurrenceEnd(of: reminder)
    }

    private func dedupeLists() {
        var byKey: [String: ReminderList] = [:]
        for list in lists().sorted(by: { $0.createdAt < $1.createdAt }) {
            // Same key as `CalendarRepository.dedupeCalendars`: never merge by
            // name — two intentionally distinct lists may share one.
            let key = list.externalIdentifier ?? list.id.uuidString
            if let survivor = byKey[key] {
                for reminder in list.reminders ?? [] {
                    reminder.list = survivor
                }
                modelContext.delete(list)
            } else {
                byKey[key] = list
            }
        }
    }

    private func dedupeReminders() {
        // Earliest `createdAt` wins (the repository's identity rule);
        // `allReminders()` is sortOrder-first, which would pick the wrong
        // survivor when a duplicate was manually reordered.
        let all = allReminders().sorted {
            $0.createdAt != $1.createdAt
                ? $0.createdAt < $1.createdAt
                : $0.id.uuidString < $1.id.uuidString
        }
        var byKey: [String: Reminder] = [:]
        var replacedIDs: [UUID: UUID] = [:]
        for reminder in all {
            let key = reminder.externalIdentifier ?? reminder.id.uuidString
            if let survivor = byKey[key] {
                replacedIDs[reminder.id] = survivor.id
                modelContext.delete(reminder)
            } else {
                byKey[key] = reminder
            }
        }
        guard !replacedIDs.isEmpty else { return }
        for reminder in all where reminder.parentReminderID != nil {
            if let parentID = reminder.parentReminderID,
               let survivorID = replacedIDs[parentID],
               reminder.isDeleted == false
            {
                reminder.parentReminderID = survivorID
            }
        }
    }

    private func sweepOrphanedCompletionLogs() {
        let mastersDescriptor = FetchDescriptor<Reminder>(
            predicate: #Predicate { $0.parentReminderID == nil }
        )
        let survivingMasterIDs = Set(
            ((try? modelContext.fetch(mastersDescriptor)) ?? []).map(\.id)
        )
        let logsDescriptor = FetchDescriptor<Reminder>(
            predicate: #Predicate { $0.parentReminderID != nil }
        )
        let logs = (try? modelContext.fetch(logsDescriptor)) ?? []
        for log in logs {
            if !survivingMasterIDs.contains(log.parentReminderID!) {
                modelContext.delete(log)
            }
        }
    }

    private func allReminders() -> [Reminder] {
        // Unordered fetch: the comparator below is the single ordering
        // authority (a descriptor sortBy would be discarded by it anyway).
        let descriptor = FetchDescriptor<Reminder>()
        return ((try? modelContext.fetch(descriptor)) ?? []).sorted {
            if $0.sortOrder != $1.sortOrder {
                return $0.sortOrder < $1.sortOrder
            }
            if $0.dueDate != $1.dueDate {
                return ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture)
            }
            return $0.createdAt < $1.createdAt
        }
    }

    private func timeZone(for reminder: Reminder) -> TimeZone {
        reminder.timeZone ?? .current
    }

    private func calendar(for reminder: Reminder) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone(for: reminder)
        return calendar
    }

    // MARK: - Persistence

    private func save() {
        do {
            try modelContext.save()
            NotificationCenter.default.post(name: .reminderStoreDidChange, object: nil)
        } catch {
            Self.logger.error("save failed: \(String(describing: error))")
        }
    }
}

extension Notification.Name {
    /// Posted after every successful reminder-store save so interested
    /// services (alerts/sync) can reconcile without polling.
    static let reminderStoreDidChange = Notification.Name("SwiftClaw.reminderStoreDidChange")
}
