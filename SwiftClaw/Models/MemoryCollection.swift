import Foundation
import SwiftData

/// Who performed a memory mutation or created a record — the provenance the
/// feature doc requires on every entry and activity event. The built-in
/// Inbox is app-created but user-owned, so it records `.user`.
nonisolated enum MemoryActor: String, Codable, Sendable {
    case user
    case ai
}

/// JSON coding for the `tagsData` blobs shared by `MemoryCollection`,
/// `MemoryEntry`, and `MemoryProposal` (per `docs/conventions/MODELS.md`,
/// JSON blobs live on `Data?`). Empty tag lists encode as nil so untagged
/// records don't carry an empty-array blob.
nonisolated enum MemoryTagsCoding {
    static func decode(_ data: Data?) -> [String] {
        guard let data, !data.isEmpty,
              let tags = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return tags
    }

    static func encode(_ tags: [String]) -> Data? {
        guard !tags.isEmpty else { return nil }
        return try? JSONEncoder().encode(tags)
    }
}

/// A named group of related memory entries. The stable `id` is the only
/// identity — titles are freely editable. Access level gates *how* an AI
/// write lands (immediately vs. via proposal), never whether reads happen.
/// See `docs/features/MEMORY.md`.
@Model
final class MemoryCollection {
    @Attribute(.unique) var id: UUID
    /// A short descriptive sentence — tells both the user and the model what
    /// the collection holds and when to open it.
    var title: String
    var details: String?
    var tagsData: Data?
    var accessLevelRawValue: String
    /// nil = global; otherwise a `WorkspaceFeature` rawValue. Scope is an
    /// injection-priority hint for background review runs, not a silo.
    var scopeRawValue: String?
    /// Pinned collections are injected in every chat exposure tier and every
    /// background review run regardless of scope.
    var isPinned: Bool
    /// The built-in Inbox for uncertain classification: created lazily by
    /// `MemoryRepository`, undeletable, unscopable.
    var isInbox: Bool
    var createdByRawValue: String
    var createdAt: Date
    var updatedAt: Date
    @Relationship(deleteRule: .cascade, inverse: \MemoryEntry.collection)
    var entries: [MemoryEntry]

    init(
        id: UUID = UUID(),
        title: String,
        details: String? = nil,
        tags: [String] = [],
        accessLevel: AccessLevel = .writesFreely,
        scope: WorkspaceFeature? = nil,
        isPinned: Bool = false,
        isInbox: Bool = false,
        createdBy: MemoryActor,
        createdAt: Date = .now,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.details = details
        self.tagsData = MemoryTagsCoding.encode(tags)
        self.accessLevelRawValue = accessLevel.rawValue
        self.scopeRawValue = scope?.rawValue
        self.isPinned = isPinned
        self.isInbox = isInbox
        self.createdByRawValue = createdBy.rawValue
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.entries = []
    }

    /// How an AI write to this collection lands. New AI-created collections
    /// default to `.writesFreely` (the frictionless-capture path); switching
    /// `.asksFirst` → `.writesFreely` is always a user-confirmed action.
    enum AccessLevel: String, Codable, Sendable, CaseIterable {
        case asksFirst
        case writesFreely
    }

    var accessLevel: AccessLevel {
        get { AccessLevel(rawValue: accessLevelRawValue) ?? .asksFirst }
        set { accessLevelRawValue = newValue.rawValue }
    }

    var scope: WorkspaceFeature? {
        get { scopeRawValue.flatMap(WorkspaceFeature.init(rawValue:)) }
        set { scopeRawValue = newValue?.rawValue }
    }

    var createdBy: MemoryActor {
        get { MemoryActor(rawValue: createdByRawValue) ?? .user }
        set { createdByRawValue = newValue.rawValue }
    }

    var tags: [String] {
        get { MemoryTagsCoding.decode(tagsData) }
        set { tagsData = MemoryTagsCoding.encode(newValue) }
    }

    /// Entries that are current facts — the set injected into prompts.
    /// Superseded entries stay visible in the UI but never re-injected.
    var activeEntries: [MemoryEntry] {
        entries.filter { $0.supersededByID == nil }
    }

    /// The model-facing handle (first 8 hex characters of `id`), used by
    /// `open_memory_collection` and the compact index — same rationale as
    /// `MemoryEntry.handle`.
    var handle: String {
        String(id.uuidString.prefix(8)).lowercased()
    }
}
