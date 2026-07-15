# SwiftData Model Conventions

- `@Model final class` with `@Attribute(.unique) var id: UUID`.
  - **Exception — CloudKit-backed configuration** (`CalendarEvent`,
    `UserCalendar`, `Reminder`, `ReminderList`): CloudKit forbids unique
    constraints and requires every property to be optional or defaulted and
    every relationship optional. These models keep a plain
    `var id: UUID = UUID()` and route identity through their repository
    (`CalendarRepository` / `ReminderRepository` — deterministic lookups,
    post-merge dedup).
    Apply the same shape to any future model destined for the CloudKit
    configuration in `SwiftClawModelContainerFactory`.
- Enums persisted as a raw `String` plus a computed accessor (template:
  `ChatMessage.roleRawValue` / `.role`).
- `@Relationship(deleteRule: .cascade, inverse: \Child.parent)` for
  owned-to-many (template: `Chat.messages`).
- JSON blobs on a `Data?` property (template: `ChatMessage.imageAttachmentsData`;
  reused for `reviewCardData` ↔ `reviewCard`).
- New domain types are `Codable`, `Sendable`, and `Hashable` where applicable.
