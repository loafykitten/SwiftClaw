import Foundation
import SwiftData

/// A user-created reminder list (color + visibility grouping for reminders).
///
/// Lives in the CloudKit-backed "calendar" model configuration, which forbids
/// `@Attribute(.unique)` and requires every property to be optional or carry a
/// default (see docs/conventions/MODELS.md). Identity is app-level: `id`, with
/// `ReminderRepository` resolving lookups deterministically and collapsing
/// remote-merge duplicates.
@Model
final class ReminderList {
    var id: UUID = UUID()
    var name: String = ""
    /// Display color as "#RRGGBB". Stored as a string so the model stays
    /// platform-neutral and CloudKit-serializable.
    var colorHex: String = ReminderList.defaultColorHex
    var isVisible: Bool = true
    var sortOrder: Int = 0
    /// `EKCalendar.calendarIdentifier` for the Apple Reminders list; the
    /// upsert key that makes re-imports idempotent.
    var externalIdentifier: String?
    var createdAt: Date = Date.now
    @Relationship(deleteRule: .cascade, inverse: \Reminder.list)
    var reminders: [Reminder]? = nil

    static let defaultColorHex = "#FF9F0A"

    init(
        id: UUID = UUID(),
        name: String = "",
        colorHex: String = ReminderList.defaultColorHex,
        isVisible: Bool = true,
        sortOrder: Int = 0,
        externalIdentifier: String? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.isVisible = isVisible
        self.sortOrder = sortOrder
        self.externalIdentifier = externalIdentifier
        self.createdAt = createdAt
    }
}
