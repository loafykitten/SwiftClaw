import Foundation
import SwiftData

/// A user-created calendar (color + visibility grouping for events).
///
/// Lives in the CloudKit-backed "calendar" model configuration, which forbids
/// `@Attribute(.unique)` and requires every property to be optional or carry a
/// default (see docs/conventions/MODELS.md). Identity is app-level: `id`, with
/// `CalendarRepository` resolving lookups deterministically and collapsing
/// remote-merge duplicates.
@Model
final class UserCalendar {
    var id: UUID = UUID()
    var name: String = ""
    /// Display color as "#RRGGBB". Stored as a string so the model stays
    /// platform-neutral and CloudKit-serializable.
    var colorHex: String = UserCalendar.defaultColorHex
    var isVisible: Bool = true
    var sortOrder: Int = 0
    /// `EKCalendar.calendarIdentifier` when this calendar was imported from
    /// Apple Calendar; the upsert key that makes re-imports idempotent.
    var externalIdentifier: String? = nil
    var createdAt: Date = Date.now
    @Relationship(deleteRule: .cascade, inverse: \CalendarEvent.calendar)
    var events: [CalendarEvent]? = nil

    static let defaultColorHex = "#0A84FF"

    init(
        id: UUID = UUID(),
        name: String = "",
        colorHex: String = UserCalendar.defaultColorHex,
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
