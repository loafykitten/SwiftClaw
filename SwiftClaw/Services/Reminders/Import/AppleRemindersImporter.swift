import EventKit
import Foundation
import os

/// Imports Apple Reminders (EventKit) data into SwiftClaw's own store.
/// Re-runnable: everything upserts by EventKit's external identifier, with
/// the stable device-local identifier as a fallback, so a second import
/// updates rather than duplicates. Requires full reminders
/// access (`NSRemindersFullAccessUsageDescription` + the reminders
/// entitlement). Checklists never come across — EventKit has no subtask API.
@MainActor
final class AppleRemindersImporter {
    private static let logger = AppLog.make("reminders.import")

    struct Summary: Sendable {
        var listCount = 0
        var reminderCount = 0
        /// Reminders whose repeat rule didn't fit our RRULE subset (or had no
        /// due date to anchor it) and were imported without a repeat.
        var degradedRuleCount = 0
    }

    enum ImportError: LocalizedError {
        case accessDenied

        var errorDescription: String? {
            switch self {
            case .accessDenied:
                "SwiftClaw wasn't allowed to read your reminders. You can grant access in System Settings › Privacy & Security › Reminders."
            }
        }
    }

    private let store = EKEventStore()

    private struct SnapshotImport {
        let snapshot: ReminderKitMapping.Snapshot
        let target: ReminderList
    }

    private struct PreparedImport {
        let identity: ReminderRepository.ImportedReminderIdentity
        let snapshot: ReminderKitMapping.Snapshot
        let target: ReminderList
        let due: ReminderKitMapping.ResolvedDueDate
        let ruleString: String?
    }

    func requestAccess() async throws {
        let granted = try await store.requestFullAccessToReminders()
        guard granted else { throw ImportError.accessDenied }
    }

    /// The user's reminder lists, for the source picker.
    func availableLists() -> [(identifier: String, title: String, colorHex: String)] {
        store.calendars(for: .reminder).map {
            ($0.calendarIdentifier, $0.title, EventKitMapping.colorHex(from: $0.cgColor))
        }
    }

    /// Imports the selected source lists (all their to-dos, completed
    /// included). Throws `ReminderRepository.ImportSaveError` when saving
    /// fails, so the caller reports only what was committed.
    @discardableResult
    func importLists(identifiers: Set<String>, repository: ReminderRepository) async throws -> Summary {
        var summary = Summary()
        let sourceLists = store.calendars(for: .reminder).filter { identifiers.contains($0.calendarIdentifier) }
        var imports: [SnapshotImport] = []

        for source in sourceLists {
            let snapshots = await fetchSnapshots(in: source)
            let target = upsertList(from: source, repository: repository)
            summary.listCount += 1
            imports.append(contentsOf: snapshots.map { SnapshotImport(snapshot: $0, target: target) })
        }
        try Self.importSnapshots(imports, repository: repository, summary: &summary)
        Self.logger.info("""
            apple import: \(summary.listCount, privacy: .public) lists, \
            \(summary.reminderCount, privacy: .public) reminders, \
            \(summary.degradedRuleCount, privacy: .public) degraded repeats
            """)
        return summary
    }

    /// Applies fetched snapshots to the store. Separated from the EventKit
    /// walking so upsert behavior is testable without an `EKEventStore`.
    static func importSnapshots(
        _ snapshots: [ReminderKitMapping.Snapshot],
        into target: ReminderList,
        repository: ReminderRepository,
        summary: inout Summary
    ) throws {
        try importSnapshots(
            snapshots.map { SnapshotImport(snapshot: $0, target: target) },
            repository: repository,
            summary: &summary
        )
    }

    private static func importSnapshots(
        _ imports: [SnapshotImport],
        repository: ReminderRepository,
        summary: inout Summary
    ) throws {
        var prepared: [PreparedImport] = []
        prepared.reserveCapacity(imports.count)
        for item in imports {
            let snapshot = item.snapshot
            guard let stableIdentifier = snapshot.externalIdentifier ?? snapshot.localIdentifier else {
                continue
            }
            // EventKit can expose only its device-local identity at first and
            // gain a cross-device external identity later. Reuse the row
            // imported under the local key; the repository resolves both keys
            // from its single prefetch before applying the batch.
            let identity = ReminderRepository.ImportedReminderIdentity(
                externalIdentifier: stableIdentifier,
                fallbackExternalIdentifier: snapshot.localIdentifier
            )
            let due = ReminderKitMapping.resolvedDueDate(from: snapshot.dueDateComponents)
            // A repeat without a due date has no anchor to roll forward from;
            // drop it alongside genuinely unmappable rules.
            // A date-only series' UNTIL is a civil day, like its due date.
            let storedRule = due.hasDueTime
                ? snapshot.recurrenceRule
                : snapshot.recurrenceRule?.civilizingUntil(readingIn: .current)
            let ruleString = due.date == nil ? nil : storedRule?.rruleString
            if snapshot.hadUnmappableRecurrence || (snapshot.recurrenceRule != nil && ruleString == nil) {
                summary.degradedRuleCount += 1
            }
            prepared.append(PreparedImport(
                identity: identity,
                snapshot: snapshot,
                target: item.target,
                due: due,
                ruleString: ruleString
            ))
            summary.reminderCount += 1
        }

        var remaining = prepared[...]
        try repository.upsertImportedReminders(
            prepared.map(\.identity),
            deduplicateAfterApplying: true
        ) { _, reminder in
            let item = remaining.removeFirst()
            let snapshot = item.snapshot
            reminder.externalIdentifier = item.identity.externalIdentifier
            reminder.title = snapshot.title
            reminder.notes = snapshot.notes
            reminder.urlString = snapshot.urlString
            reminder.dueDate = item.due.date
            reminder.hasDueTime = item.due.hasDueTime
            reminder.timeZoneIdentifier = item.due.timeZoneIdentifier
            reminder.priorityRawValue = snapshot.priorityRawValue
            reminder.completedAt = snapshot.isCompleted
                ? (snapshot.completedAt ?? reminder.completedAt ?? .now)
                : nil
            reminder.recurrenceRuleString = item.ruleString
            if snapshot.recurrenceRule != nil || snapshot.hadUnmappableRecurrence {
                reminder.afterCompletionRepeat = nil
            }
            // Checklists are local-only data EventKit can't see; leave
            // whatever the user built intact on re-import.
            reminder.source = .appleImport
            reminder.list = item.target
        }
    }

    // MARK: - Lists

    private func upsertList(from source: EKCalendar, repository: ReminderRepository) -> ReminderList {
        if let existing = repository.listMatching(externalIdentifier: source.calendarIdentifier) {
            existing.name = source.title
            existing.colorHex = EventKitMapping.colorHex(from: source.cgColor)
            repository.noteUpdated(existing)
            return existing
        }
        return repository.createList(
            name: source.title,
            colorHex: EventKitMapping.colorHex(from: source.cgColor),
            externalIdentifier: source.calendarIdentifier
        )
    }

    // MARK: - Reminders

    private func fetchSnapshots(in list: EKCalendar) async -> [ReminderKitMapping.Snapshot] {
        await withCheckedContinuation { continuation in
            let predicate = store.predicateForReminders(in: [list])
            store.fetchReminders(matching: predicate) { @Sendable ekReminders in
                // Map to Sendable snapshots here — this completion runs on an
                // arbitrary queue and EKReminder can't cross to the actor.
                continuation.resume(returning: (ekReminders ?? []).map(ReminderKitMapping.snapshot(from:)))
            }
        }
    }
}
