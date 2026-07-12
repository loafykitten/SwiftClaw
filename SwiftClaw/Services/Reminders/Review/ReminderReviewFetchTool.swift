import Foundation
import SwiftData

/// System-only tool the reminders-review pass uses to pull the to-dos it
/// should look at. NOT registered on `ToolRegistry.shared` — constructed per
/// pass by `ReminderReviewService` in a scoped registry (the
/// `CalendarReviewFetchTool` pattern). Returns pending masters only —
/// completion-log rows are history, and a recurring master's `dueDate` is
/// already its next pending occurrence.
final class ReminderReviewFetchTool: Tool {
    let name = "fetch_reminders"
    let displayName = "Fetch Reminders"
    let description = """
    Fetches the user's pending reminders. All filters are optional: \
    due_within_days (default 7) bounds how far ahead due dates are included — \
    overdue reminders are always included; include_undated (default true) \
    includes reminders with no due date; limit (default 50, max 200).
    """
    let systemImage = "checklist"
    let parameters: [ToolParameter] = [
        ToolParameter(name: "due_within_days", type: .integer, description: "Include reminders due within this many days from now (default 7). Overdue reminders are always included."),
        ToolParameter(name: "include_undated", type: .boolean, description: "Include reminders with no due date (default true)."),
        ToolParameter(name: "limit", type: .integer, description: "Maximum reminders returned (default 50)."),
    ]

    var isConfigured: Bool { true }
    var isEnabled: Bool { true }

    private let modelContainer: ModelContainer
    /// Reports the reminder IDs actually handed to the model so the service
    /// can stamp `lastReviewedAt` after a successful pass.
    private let onRemindersFetched: @MainActor ([UUID]) -> Void

    init(
        modelContainer: ModelContainer,
        onRemindersFetched: @escaping @MainActor ([UUID]) -> Void = { _ in }
    ) {
        self.modelContainer = modelContainer
        self.onRemindersFetched = onRemindersFetched
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        let dueWithinDays = arguments["due_within_days"]?.intValue ?? 7
        let includeUndated = arguments["include_undated"]?.boolValue ?? true
        let limit = min(200, max(1, arguments["limit"]?.intValue ?? 50))
        guard dueWithinDays >= 0 else {
            throw ToolError.invalidArguments("due_within_days must be zero or greater")
        }

        return await MainActor.run {
            let now = Date.now
            let horizon = now.addingTimeInterval(TimeInterval(dueWithinDays) * 24 * 3600)
            let repository = ReminderRepository(modelContext: ModelContext(modelContainer))
            var reminders = repository.pendingReminders().filter { reminder in
                guard let due = reminder.dueDate else { return includeUndated }
                return due <= horizon
            }
            // Due items first in due order; undated ones trail in creation
            // order so a stale inbox reads oldest-first.
            reminders.sort { lhs, rhs in
                switch (lhs.dueDate, rhs.dueDate) {
                case let (lhsDue?, rhsDue?): lhsDue < rhsDue
                case (nil, nil): lhs.createdAt < rhs.createdAt
                case (nil, _): false
                case (_, nil): true
                }
            }
            reminders = Array(reminders.prefix(limit))

            onRemindersFetched(reminders.map(\.id))

            guard !reminders.isEmpty else {
                return "No pending reminders match this window."
            }

            let lines = reminders.map { reminder -> String in
                var parts = [
                    "reminderGUID: \(reminder.id.uuidString)",
                    "title: \(reminder.title)",
                ]
                if let due = reminder.dueDate {
                    parts.append(reminder.hasDueTime
                        ? "due: \(due.formatted(date: .abbreviated, time: .shortened))"
                        : "due: \(due.formatted(.dateTime.year().month().day())) (date-only)")
                    if Self.isOverdue(reminder, now: now) {
                        parts.append("overdue: yes")
                    }
                } else {
                    parts.append("no due date")
                }
                if let name = reminder.list?.name, !name.isEmpty {
                    parts.append("list: \(name)")
                }
                switch reminder.priority {
                case .none: break
                case .high: parts.append("priority: high")
                case .medium: parts.append("priority: medium")
                case .low: parts.append("priority: low")
                }
                if reminder.isFlagged {
                    parts.append("flagged: yes")
                }
                if reminder.isRecurring {
                    parts.append("recurring: yes")
                }
                let checklist = reminder.checklist
                if !checklist.isEmpty {
                    parts.append("checklist: \(checklist.count(where: \.isDone))/\(checklist.count) done")
                }
                if let notes = reminder.notes, !notes.isEmpty {
                    parts.append("notes: \(notes.prefix(120))")
                }
                // Flag reminders an earlier pass already surfaced (and that
                // haven't changed since) so the model doesn't repeat itself.
                if let reviewedAt = reminder.lastReviewedAt, reminder.modifiedAt <= reviewedAt {
                    parts.append("previously reviewed: yes")
                }
                return "- " + parts.joined(separator: " | ")
            }
            return "\(reminders.count) reminders:\n" + lines.joined(separator: "\n")
        }
    }

    /// Timed reminders are overdue past their due instant; date-only ones
    /// keep all of their local day and are overdue once that day has passed.
    static func isOverdue(_ reminder: Reminder, now: Date) -> Bool {
        guard let due = reminder.dueDate else { return false }
        if reminder.hasDueTime {
            return due < now
        }
        return due < Calendar.current.startOfDay(for: now)
    }
}
