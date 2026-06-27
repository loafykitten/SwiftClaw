# SwiftData Model Conventions

- `@Model final class` with `@Attribute(.unique) var id: UUID`.
- Enums persisted as a raw `String` plus a computed accessor (template:
  `ChatMessage.roleRawValue` / `.role`).
- `@Relationship(deleteRule: .cascade, inverse: \Child.parent)` for
  owned-to-many (template: `Chat.messages`).
- JSON blobs on a `Data?` property (template: `ChatMessage.imageAttachmentsData`;
  reused for `reviewCardData` ↔ `reviewCard`).
- New domain types are `Codable, Sendable, Hashable` where it applies (Swift 6
  strict concurrency).
