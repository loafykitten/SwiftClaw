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
    /// Reports the reminders actually handed to the model, keyed by ID with
    /// the `modifiedAt` the model saw, so the service stamps `lastReviewedAt`
    /// after a successful pass only on rows that haven't changed since.
    private let onRemindersFetched: @MainActor ([UUID: Date]) -> Void

    init(
        modelContainer: ModelContainer,
        onRemindersFetched: @escaping @MainActor ([UUID: Date]) -> Void = { _ in }
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
            let candidates = repository.pendingReminders(
                dueBefore: horizon,
                includeUndated: includeUndated
            )
            let reminders = Self.page(candidates, limit: limit)

            onRemindersFetched(Dictionary(
                reminders.map { ($0.id, $0.modifiedAt) },
                uniquingKeysWith: { first, _ in first }
            ))

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
                if !Self.needsReview(reminder) {
                    parts.append("previously reviewed: yes")
                }
                return "- " + parts.joined(separator: " | ")
            }
            let header = reminders.count < candidates.count
                ? "\(reminders.count) of \(candidates.count) reminders (new or changed ones first):"
                : "\(reminders.count) reminders:"
            return header + "\n" + lines.joined(separator: "\n")
        }
    }

    /// Whether a reminder is new or changed since its last review stamp.
    static func needsReview(_ reminder: Reminder) -> Bool {
        guard let reviewedAt = reminder.lastReviewedAt else { return true }
        return reminder.modifiedAt > reviewedAt
    }

    /// The first `limit` candidates in their (due-date) order, except that
    /// new or changed reminders are admitted ahead of reviewed ones. A
    /// scheduled pass runs because something changed; if that row sorted
    /// past a plain prefix the model would never see it, it would never be
    /// stamped, and every later pass would re-run for nothing.
    static func page(_ candidates: [Reminder], limit: Int) -> [Reminder] {
        guard candidates.count > limit else { return candidates }
        var chosen = Set(candidates.indices.filter { needsReview(candidates[$0]) }.prefix(limit))
        for index in candidates.indices where chosen.count < limit {
            chosen.insert(index)
        }
        return candidates.indices.filter(chosen.contains).map { candidates[$0] }
    }

    static func isOverdue(_ reminder: Reminder, now: Date) -> Bool {
        reminder.isOverdue(now: now)
    }
}
