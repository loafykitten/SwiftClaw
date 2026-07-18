import Foundation
import SwiftData

/// One atomic memory fact (target ~15–40 tokens), living in exactly one home
/// collection. Facts are superseded, never overwritten or silently merged:
/// updating adds a replacement entry and stamps this one's `supersededByID`,
/// so contradictions the model cannot resolve stay visible with timestamps.
/// Deletion is user-initiated (or the chip's undo of an unmodified AI write).
@Model
final class MemoryEntry {
    @Attribute(.unique) var id: UUID
    var body: String
    var tagsData: Data?
    var createdByRawValue: String
    /// The conversation this entry was captured from, when AI-created.
    var sourceChatID: UUID?
    /// Set when a replacement entry superseded this fact. Superseded entries
    /// are excluded from prompt injection but remain browsable in the UI.
    var supersededByID: UUID?
    /// When this AI-written entry's disclosure chip was posted to its chat —
    /// `MemoryCardCoordinator`'s crash-safety marker, mirroring
    /// `MemoryProposal.cardPostedAt`: an autonomous write whose completion
    /// failed before draining still gets exactly one chip on that chat's
    /// next successful turn. Always nil for user-created entries.
    var disclosedAt: Date?
    var createdAt: Date
    var updatedAt: Date
    var collection: MemoryCollection?

    init(
        id: UUID = UUID(),
        body: String,
        tags: [String] = [],
        createdBy: MemoryActor,
        sourceChatID: UUID? = nil,
        supersededByID: UUID? = nil,
        disclosedAt: Date? = nil,
        createdAt: Date = .now,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.body = body
        self.tagsData = MemoryTagsCoding.encode(tags)
        self.createdByRawValue = createdBy.rawValue
        self.sourceChatID = sourceChatID
        self.supersededByID = supersededByID
        self.disclosedAt = disclosedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    var createdBy: MemoryActor {
        get { MemoryActor(rawValue: createdByRawValue) ?? .user }
        set { createdByRawValue = newValue.rawValue }
    }

    var tags: [String] {
        get { MemoryTagsCoding.decode(tagsData) }
        set { tagsData = MemoryTagsCoding.encode(newValue) }
    }

    /// The model-facing handle: the first 8 hex characters of `id`, chosen
    /// over full UUIDs because a full UUID costs ~20 tokens against a
    /// 15–40-token fact. `MemoryRepository.resolveEntry(handle:)` resolves
    /// prefixes and errors on ambiguity.
    var handle: String {
        String(id.uuidString.prefix(8)).lowercased()
    }

    /// Whether a disclosure chip's Undo may still hard-delete this entry:
    /// only while the write is unmodified and unsuperseded — afterwards undo
    /// would destroy edits the user (or a later supersession) layered on top.
    var isUndoableWrite: Bool {
        updatedAt == createdAt && supersededByID == nil
    }
}
