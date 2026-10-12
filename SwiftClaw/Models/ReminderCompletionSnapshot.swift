import Foundation

// swiftformat:disable redundantSendable
/// What one completion did to its recurring master, recorded on the log row
/// (`Reminder.completionSnapshotData`). Undo restores `before` exactly, and
/// only while the master still matches `after`: replaying the completion
/// from the current rule can't tell a COUNT the user edited from the one
/// the completion consumed.
nonisolated struct ReminderCompletionSnapshot: Codable, Sendable, Hashable {
    /// The master fields a completion advances.
    struct State: Codable, Sendable, Hashable {
        var dueDate: Date?
        var completedAt: Date?
        var recurrenceRuleString: String?
        var afterCompletionRepeat: ReminderAfterCompletionRepeat?
    }

    var before: State
    var after: State
}

// swiftformat:enable redundantSendable

extension Reminder {
    /// The completion this log row records; nil on masters, one-offs, and
    /// logs written before snapshots existed.
    var completionSnapshot: ReminderCompletionSnapshot? {
        get {
            completionSnapshotData.flatMap { try? JSONDecoder().decode(ReminderCompletionSnapshot.self, from: $0) }
        }
        set { completionSnapshotData = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }

    /// The fields a completion advances, as they are now.
    var recurrenceState: ReminderCompletionSnapshot.State {
        ReminderCompletionSnapshot.State(
            dueDate: dueDate,
            completedAt: completedAt,
            recurrenceRuleString: recurrenceRuleString,
            afterCompletionRepeat: afterCompletionRepeat
        )
    }
}
