import Foundation
import SwiftData

/// A reminder master record. Fixed-schedule recurrence stores one row whose
/// `dueDate` is the next pending occurrence, plus detached completed log rows
/// (`parentReminderID` + `originalOccurrenceDate`) for history. After-completion
/// repeats use the same master/log shape but advance from completion time.
///
/// Lives in the CloudKit-backed "calendar" model configuration, which forbids
/// `@Attribute(.unique)` and requires every property to be optional or carry a
/// default (see docs/conventions/MODELS.md). Identity is app-level: `id`, with
/// `ReminderRepository` resolving lookups deterministically and collapsing
/// remote-merge duplicates by `externalIdentifier`.
@Model
final class Reminder {
    var id: UUID = UUID()
    var title: String = ""
    var notes: String?
    var urlString: String?
    /// Nil = inbox item. Date-only reminders store local start-of-day with
    /// `hasDueTime == false` and nil `timeZoneIdentifier`, matching all-day
    /// calendar event floating semantics.
    var dueDate: Date?
    var hasDueTime: Bool = false
    var timeZoneIdentifier: String?
    /// RFC 5545 / EventKit reminder priority scale: 0 none, 1 high, 5 medium,
    /// 9 low. The computed accessor buckets imported intermediate values.
    var priorityRawValue: Int = ReminderPriority.none.rawValue
    var isFlagged: Bool = false
    var completedAt: Date?
    var sortOrder: Int = 0
    /// JSON `[ReminderChecklistItem]`.
    var checklistData: Data?
    /// RFC 5545 RRULE value for fixed-schedule repeats. Nil = one-off or
    /// after-completion repeat.
    var recurrenceRuleString: String?
    /// Derived from the rule's UNTIL/COUNT whenever the rule is saved; nil for
    /// an infinite recurrence or after-completion repeat.
    var recurrenceEndDate: Date?
    /// JSON `ReminderAfterCompletionRepeat`. Mutually exclusive with
    /// `recurrenceRuleString`; the draft/editor enforces that later.
    var afterCompletionRepeatData: Data?
    /// Detached completed occurrence log: the master this row records, and the
    /// scheduled occurrence that was completed.
    var parentReminderID: UUID?
    var originalOccurrenceDate: Date?
    /// Logs only: JSON `ReminderCompletionSnapshot` of the master before and
    /// after this completion, so undo can restore it exactly.
    var completionSnapshotData: Data?
    /// EventKit `calendarItemExternalIdentifier` or VTODO UID; the upsert key
    /// that makes re-imports idempotent.
    var externalIdentifier: String?
    var sourceRawValue: String = ReminderSource.native.rawValue
    var createdAt: Date = Date.now
    var modifiedAt: Date = Date.now
    /// Last time a reminders-review pass included this reminder.
    var lastReviewedAt: Date?
    var list: ReminderList?

    init(
        id: UUID = UUID(),
        title: String = "",
        notes: String? = nil,
        urlString: String? = nil,
        dueDate: Date? = nil,
        hasDueTime: Bool = false,
        timeZoneIdentifier: String? = nil,
        priority: ReminderPriority = .none,
        isFlagged: Bool = false,
        completedAt: Date? = nil,
        sortOrder: Int = 0,
        recurrenceRuleString: String? = nil,
        recurrenceEndDate: Date? = nil,
        externalIdentifier: String? = nil,
        source: ReminderSource = .native,
        list: ReminderList? = nil
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.urlString = urlString
        self.dueDate = dueDate
        self.hasDueTime = hasDueTime
        self.timeZoneIdentifier = timeZoneIdentifier
        priorityRawValue = priority.rawValue
        self.isFlagged = isFlagged
        self.completedAt = completedAt
        self.sortOrder = sortOrder
        self.recurrenceRuleString = recurrenceRuleString
        self.recurrenceEndDate = recurrenceEndDate
        self.externalIdentifier = externalIdentifier
        sourceRawValue = source.rawValue
        self.list = list
    }

    var source: ReminderSource {
        get { ReminderSource(rawValue: sourceRawValue) ?? .native }
        set { sourceRawValue = newValue.rawValue }
    }

    var priority: ReminderPriority {
        get {
            switch priorityRawValue {
            case 1 ... 4: .high
            case 5: .medium
            case 6 ... 9: .low
            default: .none
            }
        }
        set { priorityRawValue = newValue.rawValue }
    }

    var isCompleted: Bool {
        completedAt != nil
    }

    var isCompletionLog: Bool {
        parentReminderID != nil
    }

    /// Either repeat encoding makes the reminder a recurring master.
    var isRecurring: Bool {
        recurrenceRuleString != nil || afterCompletionRepeatData != nil
    }

    /// The one overdue rule every surface shares (rows, calendar chips,
    /// workspace tile, AI review): timed reminders are overdue past their due
    /// instant; date-only ones keep all of their local day and only go
    /// overdue once that day has passed. Completed reminders never are.
    func isOverdue(now: Date, calendar: Calendar = .current) -> Bool {
        guard !isCompleted, let dueDate else { return false }
        if hasDueTime {
            return dueDate < now
        }
        return dueDate < calendar.startOfDay(for: now)
    }

    /// Whether the reminder's list is shown in the UI (list-less reminders
    /// are always visible).
    var isInVisibleList: Bool {
        list?.isVisible ?? true
    }

    var timeZone: TimeZone? {
        timeZoneIdentifier.flatMap(TimeZone.init(identifier:))
    }

    var url: URL? {
        urlString.flatMap(URL.init(string:))
    }

    var checklist: [ReminderChecklistItem] {
        get { Self.decodeJSON([ReminderChecklistItem].self, from: checklistData) ?? [] }
        set { checklistData = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue) }
    }

    var afterCompletionRepeat: ReminderAfterCompletionRepeat? {
        get { Self.decodeJSON(ReminderAfterCompletionRepeat.self, from: afterCompletionRepeatData) }
        set { afterCompletionRepeatData = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }

    private static func decodeJSON<T: Decodable>(_ type: T.Type, from data: Data?) -> T? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

// swiftformat:disable redundantSendable
nonisolated enum ReminderSource: String, Codable, Sendable, Hashable {
    case native
    case appleImport
    case icsImport
}

nonisolated enum ReminderPriority: Int, Codable, Sendable, Hashable, CaseIterable {
    case none = 0
    case high = 1
    case medium = 5
    case low = 9
}

nonisolated struct ReminderChecklistItem: Codable, Sendable, Hashable, Identifiable {
    var id: UUID
    var text: String
    var isDone: Bool

    init(id: UUID = UUID(), text: String, isDone: Bool = false) {
        self.id = id
        self.text = text
        self.isDone = isDone
    }
}

nonisolated struct ReminderAfterCompletionRepeat: Codable, Sendable, Hashable {
    enum Unit: String, Codable, Sendable, Hashable, CaseIterable {
        case day
        case week
        case month
        case year
    }

    var count: Int
    var unit: Unit
}

// swiftformat:enable redundantSendable
