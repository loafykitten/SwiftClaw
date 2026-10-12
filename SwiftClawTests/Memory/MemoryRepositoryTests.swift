import Foundation
import Observation
import SwiftData
import Testing
@testable import SwiftClaw

@MainActor
struct MemoryRepositoryTests {
    // MARK: - Inbox

    @Test func ensureInboxCreatesOnceAndIsIdempotent() throws {
        let repository = try Self.makeRepository()
        let first = try repository.ensureInbox()
        let second = try repository.ensureInbox()

        #expect(first.id == second.id)
        #expect(first.isInbox)
        #expect(first.accessLevel == .writesFreely)
        #expect(first.scope == nil)
        let inboxes = repository.collections().filter(\.isInbox)
        #expect(inboxes.count == 1)
    }

    @Test func inboxRefusesDeletionAndScoping() throws {
        let repository = try Self.makeRepository()
        let inbox = try repository.ensureInbox()

        #expect(throws: MemoryError.self) {
            try repository.deleteCollection(inbox, actor: .user)
        }
        #expect(throws: MemoryError.self) {
            try repository.setScope(.email, for: inbox, actor: .user)
        }
        #expect(repository.collections().contains { $0.isInbox })
    }

    // MARK: - Mutations & activity events

    @Test func addEntryRecordsActivityEventInSameSave() throws {
        let repository = try Self.makeRepository()
        let collection = try repository.createCollection(title: "Travel preferences", createdBy: .user)
        let chatID = UUID()

        let entry = try repository.addEntry(
            body: "Prefers window seats on long-haul flights",
            tags: ["flights"],
            to: collection,
            createdBy: .ai,
            sourceChatID: chatID
        )

        let events = repository.recentActivity()
        let added = try #require(events.first { $0.kind == .added && $0.entryID == entry.id })
        #expect(added.snapshotText == "Prefers window seats on long-haul flights")
        #expect(added.actor == .ai)
        #expect(added.chatID == chatID)
        #expect(added.collectionID == collection.id)
        #expect(entry.createdBy == .ai)
        #expect(entry.sourceChatID == chatID)
    }

    @Test func editEntrySnapshotsPreviousBody() throws {
        let repository = try Self.makeRepository()
        let collection = try repository.createCollection(title: "Preferences", createdBy: .user)
        let entry = try repository.addEntry(body: "Original fact", to: collection, createdBy: .ai)

        try repository.editEntry(entry, body: "Corrected fact", actor: .user)

        #expect(entry.body == "Corrected fact")
        let event = try #require(repository.recentActivity().first { $0.kind == .edited })
        #expect(event.snapshotText == "Original fact")
        #expect(event.actor == .user)
    }

    @Test func deleteEntrySnapshotsBodyAndClearsSupersededStamps() throws {
        let repository = try Self.makeRepository()
        let collection = try repository.createCollection(title: "Facts", createdBy: .user)
        let old = try repository.addEntry(body: "Lives in Portland", to: collection, createdBy: .ai)
        let replacement = try repository.supersedeEntry(old, withBody: "Lives in Seattle", createdBy: .ai)

        try repository.deleteEntry(replacement, actor: .user)

        // The replaced fact becomes current again — no dangling stamp.
        #expect(old.supersededByID == nil)
        let event = try #require(repository.recentActivity().first { $0.kind == .deleted })
        #expect(event.snapshotText == "Lives in Seattle")
    }

    @Test func accessLevelChangeRecordsEventAndNoOpsWhenUnchanged() throws {
        let repository = try Self.makeRepository()
        let collection = try repository.createCollection(
            title: "Sensitive",
            accessLevel: .asksFirst,
            createdBy: .user
        )

        try repository.setAccessLevel(.writesFreely, for: collection)
        try repository.setAccessLevel(.writesFreely, for: collection)

        #expect(collection.accessLevel == .writesFreely)
        let events = repository.recentActivity().filter { $0.kind == .accessChanged }
        #expect(events.count == 1)
        #expect(events.first?.actor == .user)
    }

    @Test func moveEntryRecordsMoveAndDisablesUndo() throws {
        let repository = try Self.makeRepository()
        let source = try repository.createCollection(title: "Inbox-ish", createdBy: .user)
        let target = try repository.createCollection(title: "Home", createdBy: .user)
        let entry = try repository.addEntry(body: "A fact", to: source, createdBy: .ai)
        #expect(entry.isUndoableWrite)

        try repository.moveEntry(entry, to: target, actor: .user)

        #expect(entry.collection?.id == target.id)
        #expect(!entry.isUndoableWrite)
        let event = try #require(repository.recentActivity().first { $0.kind == .movedCollection })
        #expect(event.collectionID == target.id)
    }

    @Test func deleteCollectionUnstampsFactsItsEntriesSuperseded() throws {
        let repository = try Self.makeRepository()
        let source = try repository.createCollection(title: "Source", createdBy: .user)
        let other = try repository.createCollection(title: "Elsewhere", createdBy: .user)
        let old = try repository.addEntry(body: "Original fact", to: other, createdBy: .ai)
        let replacement = try repository.supersedeEntry(old, withBody: "Replacement fact", createdBy: .ai)
        // The replacement moves into the collection that's about to die.
        try repository.moveEntry(replacement, to: source, actor: .user)

        try repository.deleteCollection(source, actor: .user)

        // Cascade removed the replacement; the original must be current
        // again, not permanently hidden behind a dead supersession stamp.
        #expect(old.supersededByID == nil)
        #expect(other.activeEntries.map(\.id) == [old.id])
    }

    @Test func collectionsOrderIsStableAcrossEqualTimestamps() throws {
        let repository = try Self.makeRepository()
        let sharedDate = Date(timeIntervalSinceReferenceDate: 800_000_000)
        for index in 0..<5 {
            let collection = MemoryCollection(
                title: "Tied \(index)",
                createdBy: .user,
                createdAt: sharedDate
            )
            repository.modelContext.insert(collection)
        }
        try repository.save()

        let first = repository.collections().map(\.id)
        let second = repository.collections().map(\.id)
        #expect(first == second)
        // Deterministic rule, not fetch order: sorted by id within a tie.
        #expect(first.map(\.uuidString) == first.map(\.uuidString).sorted())
    }

    @Test func deleteCollectionCascadesEntries() throws {
        let repository = try Self.makeRepository()
        let collection = try repository.createCollection(title: "Doomed", createdBy: .user)
        try repository.addEntry(body: "Entry one", to: collection, createdBy: .user)
        try repository.addEntry(body: "Entry two", to: collection, createdBy: .user)

        try repository.deleteCollection(collection, actor: .user)

        #expect(repository.allEntries().isEmpty)
        let event = try #require(repository.recentActivity().first { $0.kind == .deleted })
        #expect(event.snapshotText == "Doomed")
    }

    // MARK: - Supersession

    @Test func supersedeStampsOldEntryAndExcludesItFromActiveEntries() throws {
        let repository = try Self.makeRepository()
        let collection = try repository.createCollection(title: "Facts", createdBy: .user)
        let old = try repository.addEntry(body: "Works at Acme", to: collection, createdBy: .ai)

        let replacement = try repository.supersedeEntry(
            old,
            withBody: "Works at Initech",
            createdBy: .ai
        )

        #expect(old.supersededByID == replacement.id)
        #expect(replacement.collection?.id == collection.id)
        #expect(collection.activeEntries.map(\.id) == [replacement.id])
        let event = try #require(repository.recentActivity().first { $0.kind == .superseded })
        #expect(event.snapshotText == "Works at Acme")
        #expect(event.entryID == replacement.id)
    }

    @Test func supersedingAnAlreadySupersededEntryThrows() throws {
        let repository = try Self.makeRepository()
        let collection = try repository.createCollection(title: "Facts", createdBy: .user)
        let old = try repository.addEntry(body: "Fact v1", to: collection, createdBy: .ai)
        _ = try repository.supersedeEntry(old, withBody: "Fact v2", createdBy: .ai)

        #expect(throws: MemoryError.self) {
            try repository.supersedeEntry(old, withBody: "Fact v3", createdBy: .ai)
        }
    }

    // MARK: - Undo

    @Test func undoDeletesUnmodifiedEntryAndRestoresSupersededFact() throws {
        let repository = try Self.makeRepository()
        let collection = try repository.createCollection(title: "Facts", createdBy: .user)
        let old = try repository.addEntry(body: "Drinks coffee", to: collection, createdBy: .ai)
        let replacement = try repository.supersedeEntry(old, withBody: "Drinks tea", createdBy: .ai)

        try repository.undoEntryWrite(replacement)

        #expect(old.supersededByID == nil)
        #expect(repository.allEntries().map(\.id) == [old.id])
        let event = try #require(repository.recentActivity().first { $0.kind == .undone })
        #expect(event.snapshotText == "Drinks tea")
        #expect(event.actor == .user)
    }

    @Test func undoRefusedOnceEntryIsEdited() throws {
        let repository = try Self.makeRepository()
        let collection = try repository.createCollection(title: "Facts", createdBy: .user)
        let entry = try repository.addEntry(body: "A fact", to: collection, createdBy: .ai)
        try repository.editEntry(entry, body: "An edited fact", actor: .user)

        #expect(!entry.isUndoableWrite)
        #expect(throws: MemoryError.self) {
            try repository.undoEntryWrite(entry)
        }
        #expect(repository.allEntries().count == 1)
    }

    @Test func undoRefusedOnceEntryIsSuperseded() throws {
        let repository = try Self.makeRepository()
        let collection = try repository.createCollection(title: "Facts", createdBy: .user)
        let entry = try repository.addEntry(body: "A fact", to: collection, createdBy: .ai)
        _ = try repository.supersedeEntry(entry, withBody: "A newer fact", createdBy: .ai)

        #expect(!entry.isUndoableWrite)
        #expect(throws: MemoryError.self) {
            try repository.undoEntryWrite(entry)
        }
    }

    // MARK: - Handle resolution

    @Test func resolveEntryMatchesEightHexHandle() throws {
        let repository = try Self.makeRepository()
        let collection = try repository.createCollection(title: "Facts", createdBy: .user)
        let entry = try repository.addEntry(body: "A fact", to: collection, createdBy: .ai)

        let resolved = try repository.resolveEntry(handle: entry.handle)
        #expect(resolved.id == entry.id)

        // Case-insensitive, tolerant of surrounding whitespace.
        let uppercased = try repository.resolveEntry(handle: " \(entry.handle.uppercased()) ")
        #expect(uppercased.id == entry.id)
    }

    @Test func resolveEntryErrorsOnAmbiguityAndMissing() throws {
        let repository = try Self.makeRepository()
        let collection = try repository.createCollection(title: "Facts", createdBy: .user)
        let idA = try #require(UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001"))
        let idB = try #require(UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000002"))
        for id in [idA, idB] {
            let entry = MemoryEntry(id: id, body: "Fact \(id)", createdBy: .user)
            entry.collection = collection
            repository.modelContext.insert(entry)
        }
        try repository.save()

        #expect(throws: MemoryError.self) {
            try repository.resolveEntry(handle: "aaaaaaaa")
        }
        // A longer prefix that disambiguates resolves normally.
        let resolved = try repository.resolveEntry(handle: "aaaaaaaa-0000-0000-0000-000000000001")
        #expect(resolved.id == idA)

        #expect(throws: MemoryError.self) {
            try repository.resolveEntry(handle: "ffffffff")
        }
        #expect(throws: MemoryError.self) {
            try repository.resolveEntry(handle: "   ")
        }
    }

    // MARK: - Search

    @Test func searchMatchesBodyCollectionTitleAndTags() throws {
        let repository = try Self.makeRepository()
        let travel = try repository.createCollection(
            title: "Travel preferences",
            tags: ["travel"],
            createdBy: .user
        )
        let dining = try repository.createCollection(title: "Dining", createdBy: .user)
        let seats = try repository.addEntry(
            body: "Prefers window seats",
            to: travel,
            createdBy: .ai
        )
        let spice = try repository.addEntry(
            body: "Orders medium spice",
            tags: ["thai"],
            to: dining,
            createdBy: .user
        )

        #expect(repository.search("window").map(\.id) == [seats.id])
        // Collection title terms match entries in that collection.
        #expect(repository.search("travel").map(\.id) == [seats.id])
        // Entry tags match.
        #expect(repository.search("thai").map(\.id) == [spice.id])
        // Multi-token queries require every token.
        #expect(repository.search("window spice").isEmpty)
        // Empty query returns everything.
        #expect(repository.search("").count == 2)
    }

    @Test func searchFiltersApply() throws {
        let repository = try Self.makeRepository()
        let scoped = try repository.createCollection(
            title: "Email review preferences",
            accessLevel: .asksFirst,
            scope: .email,
            createdBy: .user
        )
        let global = try repository.createCollection(title: "Identity", createdBy: .user)
        let aiEntry = try repository.addEntry(body: "Deletes newsletters unread", to: scoped, createdBy: .ai)
        let userEntry = try repository.addEntry(body: "Works as a designer", to: global, createdBy: .user)

        let aiOnly = repository.search("", filter: .init(aiCreatedOnly: true))
        #expect(aiOnly.map(\.id) == [aiEntry.id])

        let emailScoped = repository.search("", filter: .init(scope: .feature(.email)))
        #expect(emailScoped.map(\.id) == [aiEntry.id])

        let globalOnly = repository.search("", filter: .init(scope: .global))
        #expect(globalOnly.map(\.id) == [userEntry.id])

        let asksFirst = repository.search("", filter: .init(accessLevel: .asksFirst))
        #expect(asksFirst.map(\.id) == [aiEntry.id])

        let tagged = repository.search("", filter: .init(tags: ["missing-tag"]))
        #expect(tagged.isEmpty)
    }

    @Test func searchIncludesSupersededEntries() throws {
        let repository = try Self.makeRepository()
        let collection = try repository.createCollection(title: "Facts", createdBy: .user)
        let old = try repository.addEntry(body: "Lives in Portland", to: collection, createdBy: .ai)
        _ = try repository.supersedeEntry(old, withBody: "Lives in Seattle", createdBy: .ai)

        // The UI sees everything; only prompt injection excludes superseded.
        #expect(repository.search("Portland").map(\.id) == [old.id])
    }

    @Test func boundedSearchPagesUntilItFindsEnoughMatches() throws {
        let repository = try Self.makeRepository()
        let collection = try repository.createCollection(title: "Facts", createdBy: .user)
        let baseline = Date(timeIntervalSinceReferenceDate: 800_000_000)
        for index in 0..<55 {
            let entry = MemoryEntry(
                body: "Unrelated \(index)",
                createdBy: .user,
                createdAt: baseline.addingTimeInterval(Double(index + 10)),
                updatedAt: baseline.addingTimeInterval(Double(index + 10))
            )
            entry.collection = collection
            repository.modelContext.insert(entry)
        }
        let olderMatch = MemoryEntry(
            body: "Needle one",
            createdBy: .user,
            createdAt: baseline,
            updatedAt: baseline
        )
        olderMatch.collection = collection
        repository.modelContext.insert(olderMatch)
        try repository.save()

        #expect(repository.search("needle", limit: 1).map(\.id) == [olderMatch.id])
        #expect(repository.search("", limit: 3).count == 3)
        #expect(repository.search("needle", limit: 0).isEmpty)
    }

    // MARK: - Summary & generation

    @Test func summaryCountsActiveEntriesAndPendingProposals() throws {
        let repository = try Self.makeRepository()
        let collection = try repository.createCollection(title: "Facts", createdBy: .user)
        let old = try repository.addEntry(body: "Fact v1", to: collection, createdBy: .ai)
        _ = try repository.supersedeEntry(old, withBody: "Fact v2", createdBy: .ai)
        repository.modelContext.insert(MemoryProposal(
            entryText: "Proposed fact",
            summary: "Noticed a pattern",
            source: .emailReview
        ))
        repository.modelContext.insert(MemoryProposal(
            entryText: "Rejected fact",
            summary: "Declined",
            status: .rejected,
            source: .chat
        ))
        try repository.save()

        let summary = repository.summary()
        #expect(summary.collectionCount == 1)
        #expect(summary.activeEntryCount == 1)
        #expect(summary.pendingProposalCount == 1)
        #expect(summary.lastActivityAt != nil)
    }

    @Test func mutationGenerationBumpsOnEverySave() throws {
        let repository = try Self.makeRepository()
        let before = repository.mutationGeneration
        let collection = try repository.createCollection(title: "Facts", createdBy: .user)
        try repository.addEntry(body: "A fact", to: collection, createdBy: .user)

        #expect(repository.mutationGeneration == before + 2)
    }

    @Test func mutationGenerationIsObservable() async throws {
        let repository = try Self.makeRepository()
        await confirmation { didChange in
            withObservationTracking {
                _ = repository.mutationGeneration
            } onChange: {
                didChange()
            }

            _ = try? repository.createCollection(title: "Facts", createdBy: .user)
        }
    }

    // MARK: - Persistence failures

    @Test func failedSaveThrowsRollsBackAndLeavesNoGhostEntry() throws {
        let failSaves = LockedValue(false)
        let repository = try Self.makeRepository(failSaves: failSaves)
        let collection = try repository.createCollection(title: "Facts", createdBy: .user)
        let generation = repository.mutationGeneration

        failSaves.update { $0 = true }
        #expect(throws: MemoryError.saveFailed) {
            try repository.addEntry(body: "Never persisted", to: collection, createdBy: .ai)
        }

        #expect(repository.allEntries().isEmpty)
        #expect(!repository.recentActivity().contains { $0.snapshotText == "Never persisted" })
        #expect(repository.mutationGeneration == generation)
    }

    @Test func performBatchCommitsOnceOrRollsBackEverything() throws {
        let failSaves = LockedValue(false)
        let repository = try Self.makeRepository(failSaves: failSaves)
        let generation = repository.mutationGeneration

        try repository.performBatch {
            let collection = try repository.createCollection(title: "Trip", createdBy: .ai)
            try repository.addEntry(body: "Seed one", to: collection, createdBy: .ai)
            try repository.addEntry(body: "Seed two", to: collection, createdBy: .ai)
        }
        #expect(repository.mutationGeneration == generation + 1)
        #expect(repository.allEntries().count == 2)

        failSaves.update { $0 = true }
        #expect(throws: MemoryError.saveFailed) {
            try repository.performBatch {
                let collection = try repository.createCollection(title: "Doomed", createdBy: .ai)
                try repository.addEntry(body: "Doomed seed", to: collection, createdBy: .ai)
            }
        }
        #expect(!repository.collections().contains { $0.title == "Doomed" })
        #expect(repository.allEntries().count == 2)

        // A throw from the body itself also discards the batch's mutations.
        failSaves.update { $0 = false }
        #expect(throws: MemoryError.alreadySuperseded) {
            try repository.performBatch {
                try repository.createCollection(title: "Also doomed", createdBy: .ai)
                throw MemoryError.alreadySuperseded
            }
        }
        #expect(!repository.collections().contains { $0.title == "Also doomed" })
    }

    // MARK: - Supersession chains

    /// Deleting the middle of `A → B → C` must re-point A at C, not revive A
    /// as a current fact beside C.
    @Test func deletingAnIntermediateSupersessionRedirectsItsPredecessor() throws {
        let repository = try Self.makeRepository()
        let collection = try repository.createCollection(title: "Facts", createdBy: .user)
        let first = try repository.addEntry(body: "Lives in Portland", to: collection, createdBy: .ai)
        let second = try repository.supersedeEntry(first, withBody: "Lives in Seattle", createdBy: .ai)
        let third = try repository.supersedeEntry(second, withBody: "Lives in Denver", createdBy: .ai)

        try repository.deleteEntry(second, actor: .user)

        #expect(first.supersededByID == third.id)
        #expect(third.supersededByID == nil)
        #expect(repository.allEntries().filter { $0.supersededByID == nil }.map(\.body) == ["Lives in Denver"])
    }

    @Test func deletingTheWholeTailOfAChainRestoresThePredecessor() throws {
        let repository = try Self.makeRepository()
        let kept = try repository.createCollection(title: "Kept", createdBy: .user)
        let doomed = try repository.createCollection(title: "Doomed", createdBy: .user)
        let first = try repository.addEntry(body: "Original", to: kept, createdBy: .ai)
        let second = try repository.supersedeEntry(first, withBody: "Second", createdBy: .ai)
        let third = try repository.supersedeEntry(second, withBody: "Third", createdBy: .ai)
        try repository.moveEntry(second, to: doomed, actor: .user)
        try repository.moveEntry(third, to: doomed, actor: .user)

        try repository.deleteCollection(doomed, actor: .user)

        #expect(first.supersededByID == nil)
    }

    @Test func collectionDeletionRedirectsPastRemovedLinksToASurvivor() throws {
        let repository = try Self.makeRepository()
        let kept = try repository.createCollection(title: "Kept", createdBy: .user)
        let doomed = try repository.createCollection(title: "Doomed", createdBy: .user)
        let first = try repository.addEntry(body: "Original", to: kept, createdBy: .ai)
        let second = try repository.supersedeEntry(first, withBody: "Second", createdBy: .ai)
        let third = try repository.supersedeEntry(second, withBody: "Third", createdBy: .ai)
        try repository.moveEntry(second, to: doomed, actor: .user)

        try repository.deleteCollection(doomed, actor: .user)

        #expect(first.supersededByID == third.id)
    }

    // MARK: - Helpers

    private struct InjectedSaveFailure: Error {}

    private static func makeRepository(failSaves: LockedValue<Bool>? = nil) throws -> MemoryRepository {
        let container = try ModelContainer(
            for: MemoryCollection.self, MemoryEntry.self, MemoryProposal.self, MemoryActivityEvent.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return MemoryRepository(modelContext: ModelContext(container)) { context in
            if failSaves?.value == true { throw InjectedSaveFailure() }
            try context.save()
        }
    }
}
