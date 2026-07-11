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

    /// The list new reminders default into. Prefers the user's configured
    /// choice, falls back to the first list, creating "Reminders" on first use
    /// so the app never has zero lists once the feature is enabled.
    func defaultList(preferredID: UUID? = nil) -> ReminderList {
        if let preferredID, let preferred = list(withID: preferredID) {
            return preferred
        }
        if let first = lists().first {
            return first
        }
        return createList(name: String(localized: "Reminders"))
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

    func pendingReminders() -> [Reminder] {
        allReminders().filter { !$0.isCompleted && !$0.isCompletionLog }
    }

    func scheduled() -> [Reminder] {
        pendingReminders().filter { $0.dueDate != nil }
    }

    func flagged() -> [Reminder] {
        pendingReminders().filter(\.isFlagged)
    }

    func completed() -> [Reminder] {
        allReminders().filter { $0.completedAt != nil }
    }

    func inbox() -> [Reminder] {
        pendingReminders().filter { $0.dueDate == nil }
    }

    func reminders(in list: ReminderList) -> [Reminder] {
        let listID = list.id
        return allReminders().filter { $0.list?.id == listID && !$0.isCompletionLog }
    }

    // MARK: - Completion Semantics

    /// Completes a reminder in one transaction. Recurring masters keep one row
    /// for the next pending occurrence and insert detached completed log rows
    /// so undo and history stay cheap and deterministic.
    func complete(_ reminder: Reminder, at date: Date = .now) {
        guard !reminder.isCompletionLog else { return }
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
    /// explicit "skip this occurrence" action.
    func skipOccurrence(of master: Reminder) {
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
            advanceFixedScheduleMaster(master, markExhaustedAt: nil)
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
        let all = allReminders()
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
        let descriptor = FetchDescriptor<Reminder>(
            predicate: #Predicate { $0.parentReminderID != nil }
        )
        let logs = (try? modelContext.fetch(descriptor)) ?? []
        for log in logs {
            if reminder(withID: log.parentReminderID!) == nil {
                modelContext.delete(log)
            }
        }
    }

    private func allReminders() -> [Reminder] {
        let descriptor = FetchDescriptor<Reminder>(
            sortBy: [
                SortDescriptor(\.sortOrder),
                SortDescriptor(\.createdAt),
            ]
        )
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
