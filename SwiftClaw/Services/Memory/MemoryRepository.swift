import Foundation
import Observation
import SwiftData

nonisolated enum MemoryError: LocalizedError, Equatable {
    case collectionNotFound
    case cannotDeleteInbox
    case cannotScopeInbox
    case entryNotFound(handle: String)
    case ambiguousHandle(handle: String, matchCount: Int)
    case alreadySuperseded
    case notUndoable
    /// The store rejected the save. The context was rolled back, so nothing
    /// from the attempted mutation persisted.
    case saveFailed

    var errorDescription: String? {
        switch self {
        case .collectionNotFound:
            "That memory collection no longer exists."
        case .cannotDeleteInbox:
            "The Inbox is built in and can't be deleted."
        case .cannotScopeInbox:
            "The Inbox is built in and can't be scoped to a feature."
        case .entryNotFound(let handle):
            "No memory entry matches the handle \"\(handle)\"."
        case .ambiguousHandle(let handle, let matchCount):
            "The handle \"\(handle)\" matches \(matchCount) memory entries — use more characters."
        case .alreadySuperseded:
            "That memory entry was already superseded; supersede the current entry instead."
        case .notUndoable:
            "That memory entry has been edited or superseded since it was added, so the write can no longer be undone."
        case .saveFailed:
            "Memory couldn't be saved, so no change was made."
        }
    }
}

/// Single mutation boundary for all Memory/SwiftData writes (the
/// `EmailRepository` precedent). Every mutation records its
/// `MemoryActivityEvent` in the same save — the activity feed is the audit
/// trail behind hard-delete undo — and bumps `mutationGeneration` so the
/// Phase-2 `MemoryPromptBuilder` can key its cached serialization on it.
///
/// Reads intended for the UI go through `@Query` in views; this repository
/// serves mutations, tool calls, search, and the Workspace tile summary.
@MainActor
@Observable
final class MemoryRepository {
    private static let logger = AppLog.make("memory")

    let modelContext: ModelContext

    /// Incremented on every successful mutation save. The prompt builder's
    /// cache invalidation: a cached serialized store is valid only while
    /// this value is unchanged (mutation-batched, per the design's
    /// prefix-stability requirement).
    private(set) var mutationGeneration = 0

    /// Performs the actual store write. A seam so tests can inject a
    /// persistence failure; production always calls `ModelContext.save()`.
    private let persist: @MainActor (ModelContext) throws -> Void

    /// Nonzero while `performBatch` is running: mutation saves are deferred
    /// to one save when the outermost batch finishes.
    private var batchDepth = 0

    init(
        modelContext: ModelContext,
        persist: @escaping @MainActor (ModelContext) throws -> Void = { try $0.save() }
    ) {
        self.modelContext = modelContext
        self.persist = persist
    }

    // MARK: - Inbox

    static let inboxTitle = "Inbox"

    /// Fetches the built-in Inbox, creating it on first use. The Inbox is
    /// the pressure valve for uncertain classification — undeletable,
    /// unscopable, and always `writesFreely` (a proposal the user accepted
    /// or a low-confidence AI save must never be blocked from landing).
    @discardableResult
    func ensureInbox() throws -> MemoryCollection {
        if let inbox = fetchInbox() {
            return inbox
        }
        let inbox = MemoryCollection(
            title: Self.inboxTitle,
            details: "Memories the assistant couldn't confidently file into a collection.",
            accessLevel: .writesFreely,
            isInbox: true,
            createdBy: .user
        )
        modelContext.insert(inbox)
        try save()
        return inbox
    }

    private func fetchInbox() -> MemoryCollection? {
        var descriptor = FetchDescriptor<MemoryCollection>(
            predicate: #Predicate { $0.isInbox },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor))?.first
    }

    // MARK: - Collections

    func collection(id: UUID) -> MemoryCollection? {
        var descriptor = FetchDescriptor<MemoryCollection>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor))?.first
    }

    func collections() -> [MemoryCollection] {
        let descriptor = FetchDescriptor<MemoryCollection>(
            sortBy: [SortDescriptor(\.createdAt)]
        )
        let fetched = (try? modelContext.fetch(descriptor)) ?? []
        // In-memory id tie-break (UUID isn't SortDescriptor-comparable):
        // rows sharing a createdAt must not reorder between fetches — the
        // prompt builder's "deterministic prefix" depends on this ordering.
        return fetched.sorted {
            ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString)
        }
    }

    @discardableResult
    func createCollection(
        title: String,
        details: String? = nil,
        tags: [String] = [],
        accessLevel: MemoryCollection.AccessLevel = .writesFreely,
        scope: WorkspaceFeature? = nil,
        isPinned: Bool = false,
        createdBy: MemoryActor,
        chatID: UUID? = nil
    ) throws -> MemoryCollection {
        let collection = MemoryCollection(
            title: title,
            details: details,
            tags: tags,
            accessLevel: accessLevel,
            scope: scope,
            isPinned: isPinned,
            createdBy: createdBy
        )
        modelContext.insert(collection)
        recordEvent(
            kind: .added,
            collectionID: collection.id,
            snapshotText: title,
            actor: createdBy,
            chatID: chatID
        )
        try save()
        return collection
    }

    /// User edits to a collection's descriptive fields. Access level and
    /// scope have dedicated methods below because they carry extra rules.
    func updateCollection(
        _ collection: MemoryCollection,
        title: String? = nil,
        details: String?? = nil,
        tags: [String]? = nil,
        isPinned: Bool? = nil,
        actor: MemoryActor
    ) throws {
        if let title { collection.title = title }
        if let details { collection.details = details }
        if let tags { collection.tags = tags }
        if let isPinned { collection.isPinned = isPinned }
        collection.updatedAt = .now
        recordEvent(
            kind: .edited,
            collectionID: collection.id,
            snapshotText: collection.title,
            actor: actor
        )
        try save()
    }

    /// Always a user action — the AI never changes a collection's access
    /// level (the asksFirst → writesFreely switch is additionally
    /// confirmation-gated in the UI).
    func setAccessLevel(
        _ accessLevel: MemoryCollection.AccessLevel,
        for collection: MemoryCollection
    ) throws {
        guard collection.accessLevel != accessLevel else { return }
        collection.accessLevel = accessLevel
        collection.updatedAt = .now
        recordEvent(
            kind: .accessChanged,
            collectionID: collection.id,
            snapshotText: collection.title,
            actor: .user
        )
        try save()
    }

    func setScope(
        _ scope: WorkspaceFeature?,
        for collection: MemoryCollection,
        actor: MemoryActor
    ) throws {
        guard !collection.isInbox else { throw MemoryError.cannotScopeInbox }
        guard collection.scope != scope else { return }
        collection.scope = scope
        collection.updatedAt = .now
        recordEvent(
            kind: .edited,
            collectionID: collection.id,
            snapshotText: collection.title,
            actor: actor
        )
        try save()
    }

    func deleteCollection(_ collection: MemoryCollection, actor: MemoryActor) throws {
        guard !collection.isInbox else { throw MemoryError.cannotDeleteInbox }
        let title = collection.title
        let collectionID = collection.id
        // Cascade deletion is about to remove these entries; any fact
        // elsewhere that one of them superseded is re-pointed at a surviving
        // successor, or becomes current again, rather than staying stamped
        // by (and hidden behind) a dead entry.
        repairSupersededStamps(removing: Set(collection.entries.map(\.id)))
        modelContext.delete(collection)
        recordEvent(
            kind: .deleted,
            collectionID: collectionID,
            snapshotText: title,
            actor: actor
        )
        try save()
    }

    // MARK: - Entries

    /// `disclosedAt` is non-nil only for writes whose disclosure already
    /// happened at write time (a proposal card the user just accepted) — it
    /// must land in the same save as the entry, or a crash in between
    /// leaves an "undisclosed" AI entry that `MemoryCardCoordinator` would
    /// rehydrate into a duplicate chip.
    @discardableResult
    func addEntry(
        body: String,
        tags: [String] = [],
        to collection: MemoryCollection,
        createdBy: MemoryActor,
        sourceChatID: UUID? = nil,
        disclosedAt: Date? = nil
    ) throws -> MemoryEntry {
        let entry = MemoryEntry(
            body: body,
            tags: tags,
            createdBy: createdBy,
            sourceChatID: sourceChatID,
            disclosedAt: disclosedAt
        )
        entry.collection = collection
        modelContext.insert(entry)
        collection.updatedAt = .now
        recordEvent(
            kind: .added,
            entryID: entry.id,
            collectionID: collection.id,
            snapshotText: body,
            actor: createdBy,
            chatID: sourceChatID
        )
        try save()
        return entry
    }

    func editEntry(
        _ entry: MemoryEntry,
        body: String? = nil,
        tags: [String]? = nil,
        actor: MemoryActor
    ) throws {
        let previousBody = entry.body
        if let body { entry.body = body }
        if let tags { entry.tags = tags }
        entry.updatedAt = .now
        entry.collection?.updatedAt = .now
        recordEvent(
            kind: .edited,
            entryID: entry.id,
            collectionID: entry.collection?.id,
            snapshotText: previousBody,
            actor: actor
        )
        try save()
    }

    func moveEntry(
        _ entry: MemoryEntry,
        to collection: MemoryCollection,
        actor: MemoryActor
    ) throws {
        guard entry.collection?.id != collection.id else { return }
        entry.collection?.updatedAt = .now
        entry.collection = collection
        entry.updatedAt = .now
        collection.updatedAt = .now
        recordEvent(
            kind: .movedCollection,
            entryID: entry.id,
            collectionID: collection.id,
            snapshotText: entry.body,
            actor: actor
        )
        try save()
    }

    /// The only way an established fact changes: a replacement entry is
    /// added and the old one is stamped `supersededByID` — never an in-place
    /// rewrite. Contradictions stay visible with timestamps.
    @discardableResult
    func supersedeEntry(
        _ old: MemoryEntry,
        withBody body: String,
        tags: [String]? = nil,
        createdBy: MemoryActor,
        sourceChatID: UUID? = nil,
        disclosedAt: Date? = nil
    ) throws -> MemoryEntry {
        guard old.supersededByID == nil else { throw MemoryError.alreadySuperseded }
        let replacement = MemoryEntry(
            body: body,
            tags: tags ?? old.tags,
            createdBy: createdBy,
            sourceChatID: sourceChatID,
            disclosedAt: disclosedAt
        )
        replacement.collection = old.collection
        modelContext.insert(replacement)
        old.supersededByID = replacement.id
        old.updatedAt = .now
        old.collection?.updatedAt = .now
        recordEvent(
            kind: .superseded,
            entryID: replacement.id,
            collectionID: old.collection?.id,
            snapshotText: old.body,
            actor: createdBy,
            chatID: sourceChatID
        )
        try save()
        return replacement
    }

    func deleteEntry(_ entry: MemoryEntry, actor: MemoryActor) throws {
        let body = entry.body
        let entryID = entry.id
        let collection = entry.collection
        repairSupersededStamps(removing: entryID)
        modelContext.delete(entry)
        collection?.updatedAt = .now
        recordEvent(
            kind: .deleted,
            entryID: entryID,
            collectionID: collection?.id,
            snapshotText: body,
            actor: actor
        )
        try save()
    }

    /// The disclosure chip's Undo: the write never happened, so this is a
    /// hard delete (no tombstone — the activity event's snapshot is the
    /// audit trail). Only allowed while the entry is unmodified and
    /// unsuperseded; a supersession write that's undone also un-stamps the
    /// fact it replaced, restoring it as current.
    func undoEntryWrite(_ entry: MemoryEntry) throws {
        guard entry.isUndoableWrite else { throw MemoryError.notUndoable }
        let body = entry.body
        let entryID = entry.id
        let collection = entry.collection
        repairSupersededStamps(removing: entryID)
        modelContext.delete(entry)
        collection?.updatedAt = .now
        recordEvent(
            kind: .undone,
            entryID: entryID,
            collectionID: collection?.id,
            snapshotText: body,
            actor: .user
        )
        try save()
    }

    /// Removing an entry (delete or undo) must not leave dangling
    /// `supersededByID` stamps. See `repairSupersededStamps(removing:)`.
    private func repairSupersededStamps(removing entryID: UUID) {
        repairSupersededStamps(removing: [entryID])
    }

    /// Re-points every surviving entry stamped by a removed one. A removed
    /// entry that was itself superseded hands its predecessors on to its
    /// own (surviving) successor — deleting B from `A → B → C` leaves
    /// `A → C`, never a revived A beside C. Only when no successor survives
    /// does the predecessor become current again. Collection deletion
    /// repairs every affected stamp from one fetch rather than one fetch
    /// per cascaded entry.
    private func repairSupersededStamps(removing entryIDs: Set<UUID>) {
        guard !entryIDs.isEmpty else { return }
        let predicate = #Predicate<MemoryEntry> { $0.supersededByID != nil }
        let stamped = (try? modelContext.fetch(FetchDescriptor(predicate: predicate))) ?? []
        var successorOfRemoved: [UUID: UUID] = [:]
        for entry in stamped where entryIDs.contains(entry.id) {
            successorOfRemoved[entry.id] = entry.supersededByID
        }
        let restoredAt = Date.now
        for entry in stamped where !entryIDs.contains(entry.id) {
            guard var successor = entry.supersededByID, entryIDs.contains(successor) else { continue }
            // Walk past removed links; `visited` guards a corrupt cycle.
            var visited: Set<UUID> = []
            var survivor: UUID?
            while visited.insert(successor).inserted {
                guard entryIDs.contains(successor) else {
                    survivor = successor
                    break
                }
                guard let next = successorOfRemoved[successor] else { break }
                successor = next
            }
            entry.supersededByID = survivor
            if survivor == nil {
                // Exposure fragments are keyed by the owning collection's
                // timestamp, including when a deletion restores a fact
                // elsewhere.
                entry.collection?.updatedAt = restoredAt
            }
        }
    }

    // MARK: - Handle resolution

    /// Resolves a model-facing entry handle — a prefix of the entry UUID's
    /// hex form, canonically the first 8 characters (`MemoryEntry.handle`).
    /// Errors on no match and on ambiguity rather than guessing.
    func resolveEntry(handle: String) throws -> MemoryEntry {
        try Self.resolve(handle: handle, in: allEntries(), id: \.id) {
            switch $0 {
            case .empty, .notFound: MemoryError.entryNotFound(handle: handle)
            case .ambiguous(let count): MemoryError.ambiguousHandle(handle: handle, matchCount: count)
            }
        }
    }

    /// `resolveEntry(handle:)`'s counterpart for collections — used by
    /// `open_memory_collection`, which also accepts a title (resolved at the
    /// tool layer); this handles the handle form.
    func resolveCollection(handle: String) throws -> MemoryCollection {
        try Self.resolve(handle: handle, in: collections(), id: \.id) {
            switch $0 {
            case .empty, .notFound: MemoryError.collectionNotFound
            case .ambiguous(let count): MemoryError.ambiguousHandle(handle: handle, matchCount: count)
            }
        }
    }

    private enum HandleResolutionFailure {
        case empty
        case notFound
        case ambiguous(Int)
    }

    private static func resolve<T>(
        handle: String,
        in candidates: [T],
        id: KeyPath<T, UUID>,
        error: (HandleResolutionFailure) -> MemoryError
    ) throws -> T {
        let normalized = handle
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "")
        guard !normalized.isEmpty else { throw error(.empty) }
        let matches = candidates.filter {
            $0[keyPath: id].uuidString.lowercased()
                .replacingOccurrences(of: "-", with: "")
                .hasPrefix(normalized)
        }
        switch matches.count {
        case 0: throw error(.notFound)
        case 1: return matches[0]
        default: throw error(.ambiguous(matches.count))
        }
    }

    func entry(id: UUID) -> MemoryEntry? {
        var descriptor = FetchDescriptor<MemoryEntry>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor))?.first
    }

    func allEntries() -> [MemoryEntry] {
        let descriptor = FetchDescriptor<MemoryEntry>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    // MARK: - Search

    /// Which collections a search covers, by scope.
    enum ScopeFilter: Hashable {
        case any
        case global
        case feature(WorkspaceFeature)
    }

    struct SearchFilter {
        var tags: [String] = []
        var accessLevel: MemoryCollection.AccessLevel?
        var scope: ScopeFilter = .any
        var aiCreatedOnly = false

        nonisolated init(
            tags: [String] = [],
            accessLevel: MemoryCollection.AccessLevel? = nil,
            scope: ScopeFilter = .any,
            aiCreatedOnly: Bool = false
        ) {
            self.tags = tags
            self.accessLevel = accessLevel
            self.scope = scope
            self.aiCreatedOnly = aiCreatedOnly
        }
    }

    /// The single search seam shared by the Memory UI and the
    /// `search_memory` tool — in-memory lexical matching via the shared
    /// `SearchQuery` over entry bodies, entry/collection tags, collection
    /// titles, and provenance. Deliberately not `SearchIndex` (see
    /// `docs/MEMORY_PLAN.md`); this method is where a future index-backed
    /// swap would land. Superseded entries are included — search and the UI
    /// see everything; only prompt injection excludes them.
    func search(
        _ text: String,
        filter: SearchFilter = SearchFilter(),
        limit: Int? = nil
    ) -> [MemoryEntry] {
        if let limit, limit <= 0 { return [] }
        let query = SearchQuery.Compiled(text)
        guard let limit else {
            return allEntries().filter { entry in
                matchesSearch(entry, query: query, filter: filter)
            }
        }

        // Lexical and relationship filters cannot be expressed by one
        // SwiftData predicate. Page newest-first until enough matches are
        // found so bounded UI/tool searches avoid retaining the full store.
        let batchSize = max(50, limit * 2)
        var offset = 0
        var matches: [MemoryEntry] = []
        while matches.count < limit {
            var descriptor = FetchDescriptor<MemoryEntry>(
                sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
            )
            descriptor.fetchLimit = batchSize
            descriptor.fetchOffset = offset
            let batch = (try? modelContext.fetch(descriptor)) ?? []
            guard !batch.isEmpty else { break }
            for entry in batch where matches.count < limit {
                if matchesSearch(entry, query: query, filter: filter) {
                    matches.append(entry)
                }
            }
            guard batch.count == batchSize else { break }
            offset += batch.count
        }
        return matches
    }

    private func matchesSearch(
        _ entry: MemoryEntry,
        query: SearchQuery.Compiled,
        filter: SearchFilter
    ) -> Bool {
        guard matchesFilter(entry, filter: filter) else { return false }
        guard query.isActive else { return true }
        return query.matches(in: searchValues(for: entry))
    }

    private func matchesFilter(_ entry: MemoryEntry, filter: SearchFilter) -> Bool {
        if filter.aiCreatedOnly, entry.createdBy != .ai { return false }
        if let accessLevel = filter.accessLevel,
           entry.collection?.accessLevel != accessLevel { return false }
        switch filter.scope {
        case .any:
            break
        case .global:
            guard entry.collection?.scope == nil else { return false }
        case .feature(let feature):
            guard entry.collection?.scope == feature else { return false }
        }
        if !filter.tags.isEmpty {
            let entryTags = Set(entry.tags + (entry.collection?.tags ?? []))
            guard filter.tags.allSatisfy(entryTags.contains) else { return false }
        }
        return true
    }

    private func searchValues(for entry: MemoryEntry) -> [String] {
        var values = [entry.body, entry.handle, entry.createdBy.rawValue]
        values.append(contentsOf: entry.tags)
        if let collection = entry.collection {
            values.append(collection.title)
            values.append(contentsOf: collection.tags)
        }
        return values
    }

    /// Records the resolution of a memory proposal in the activity feed
    /// (`MemoryProposalDispatcher` records an acceptance in the same batch
    /// as its writes, and a dismissal after the terminal status save
    /// succeeds). Entry/collection writes an acceptance performed have
    /// their own events already; this row records the decision itself.
    func recordProposalResolution(
        accepted: Bool,
        proposal: MemoryProposal,
        collectionID: UUID?
    ) throws {
        recordEvent(
            kind: accepted ? .proposalAccepted : .proposalDismissed,
            collectionID: collectionID,
            snapshotText: proposal.entryText.isEmpty ? proposal.summary : proposal.entryText,
            actor: .user,
            chatID: proposal.chatID
        )
        try save()
    }

    // MARK: - Activity & summary

    func recentActivity(limit: Int = 100) -> [MemoryActivityEvent] {
        var descriptor = FetchDescriptor<MemoryActivityEvent>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    nonisolated struct Summary: Sendable {
        let collectionCount: Int
        let activeEntryCount: Int
        let pendingProposalCount: Int
        let lastActivityAt: Date?
    }

    /// The Workspace tile's numbers.
    func summary() -> Summary {
        let pendingRawValue = MemoryProposal.Status.pending.rawValue
        let pendingDescriptor = FetchDescriptor<MemoryProposal>(
            predicate: #Predicate { $0.statusRawValue == pendingRawValue }
        )
        let entryDescriptor = FetchDescriptor<MemoryEntry>(
            predicate: #Predicate { $0.supersededByID == nil }
        )
        return Summary(
            collectionCount: (try? modelContext.fetchCount(FetchDescriptor<MemoryCollection>())) ?? 0,
            activeEntryCount: (try? modelContext.fetchCount(entryDescriptor)) ?? 0,
            pendingProposalCount: (try? modelContext.fetchCount(pendingDescriptor)) ?? 0,
            lastActivityAt: recentActivity(limit: 1).first?.createdAt
        )
    }

    // MARK: - Persistence

    private func recordEvent(
        kind: MemoryActivityEvent.Kind,
        entryID: UUID? = nil,
        collectionID: UUID? = nil,
        snapshotText: String? = nil,
        actor: MemoryActor,
        chatID: UUID? = nil
    ) {
        modelContext.insert(MemoryActivityEvent(
            kind: kind,
            entryID: entryID,
            collectionID: collectionID,
            snapshotText: snapshotText,
            actor: actor,
            chatID: chatID
        ))
    }

    /// Runs several mutations as one save: either all of them persist or
    /// none do. Mutation saves inside `body` are deferred; a throw from
    /// `body` rolls the context back, and a failed final save throws
    /// `MemoryError.saveFailed` (also after rolling back). Used where a
    /// partial write would be misleading — a proposal approval, or a new
    /// collection with its seed entries.
    func performBatch<T>(_ body: () throws -> T) throws -> T {
        batchDepth += 1
        let result: T
        do {
            result = try body()
        } catch {
            batchDepth -= 1
            if batchDepth == 0 { modelContext.rollback() }
            throw error
        }
        batchDepth -= 1
        try save()
        return result
    }

    /// Persists the current context and bumps `mutationGeneration`. Every
    /// mutation method above funnels through this so the activity event and
    /// the mutation land in one save and the prompt cache invalidates once.
    /// A failure rolls the context back — so unsaved mutations don't linger
    /// as ghosts that `@Query` UI and the prompt builder would show as if
    /// persisted — and throws `MemoryError.saveFailed`, so no caller can
    /// report a write that didn't happen.
    func save() throws {
        guard batchDepth == 0 else { return }
        do {
            try persist(modelContext)
            mutationGeneration += 1
        } catch {
            modelContext.rollback()
            Self.logger.error("MemoryRepository save failed: \(String(describing: error))")
            throw MemoryError.saveFailed
        }
    }
}
