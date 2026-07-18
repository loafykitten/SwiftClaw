import Foundation
import SwiftData
import Testing
@testable import SwiftClaw

@MainActor
struct MemoryCardCoordinatorTests {
    private struct Fixture {
        let container: ModelContainer
        let context: ModelContext
        let repository: MemoryRepository
        let coordinator = MemoryCardCoordinator()
        let chat: Chat
    }

    private static func makeFixture() throws -> Fixture {
        let container = try ModelContainer(
            for: Chat.self, ChatMessage.self,
            MemoryCollection.self, MemoryEntry.self, MemoryProposal.self, MemoryActivityEvent.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let chat = Chat(title: "Test chat", modelSelection: "test-model")
        context.insert(chat)
        try context.save()
        return Fixture(
            container: container,
            context: context,
            repository: MemoryRepository(modelContext: context),
            chat: chat
        )
    }

    private static func memoryCards(in chat: Chat, ofType type: ReviewType) -> [ReviewCardPayload] {
        chat.sortedMessages.compactMap(\.reviewCard).filter { $0.reviewType == type }
    }

    // MARK: - Write chips

    @Test func drainPostsOneChipPerTurnAndIsIdempotent() throws {
        let fixture = try Self.makeFixture()
        let travel = fixture.repository.createCollection(title: "Travel", createdBy: .user)
        let first = fixture.repository.addEntry(
            body: "Fact one", to: travel, createdBy: .ai, sourceChatID: fixture.chat.id
        )
        let second = fixture.repository.addEntry(
            body: "Fact two", to: travel, createdBy: .ai, sourceChatID: fixture.chat.id
        )
        fixture.coordinator.enqueueWrite(entryID: first.id, chatID: fixture.chat.id)
        fixture.coordinator.enqueueWrite(entryID: second.id, chatID: fixture.chat.id)

        fixture.coordinator.drain(for: fixture.chat, using: fixture.context)
        try fixture.context.save()

        let cards = Self.memoryCards(in: fixture.chat, ofType: .memoryWrite)
        #expect(cards.count == 1, "one chip card per turn, one item per write")
        #expect(cards.first?.items.count == 2)
        #expect(cards.first?.items.allSatisfy { $0.action == .undo } == true)
        #expect(first.disclosedAt != nil)
        #expect(second.disclosedAt != nil)

        // A second drain (same turn replayed, or a later turn) posts nothing.
        fixture.coordinator.drain(for: fixture.chat, using: fixture.context)
        #expect(Self.memoryCards(in: fixture.chat, ofType: .memoryWrite).count == 1)
    }

    @Test func drainRehydratesUndisclosedWritesTheQueueLost() throws {
        let fixture = try Self.makeFixture()
        let travel = fixture.repository.createCollection(title: "Travel", createdBy: .user)
        // Simulates a write whose completion failed before draining (or a
        // process restart): persisted, AI-authored, bound to this chat,
        // never disclosed — but not in any in-memory queue.
        fixture.repository.addEntry(
            body: "Orphaned write", to: travel, createdBy: .ai, sourceChatID: fixture.chat.id
        )

        fixture.coordinator.drain(for: fixture.chat, using: fixture.context)

        let cards = Self.memoryCards(in: fixture.chat, ofType: .memoryWrite)
        #expect(cards.count == 1)
        #expect(cards.first?.items.first?.summary == "Orphaned write")
    }

    @Test func drainNeverDisclosesUserEntriesOrOtherChatsWrites() throws {
        let fixture = try Self.makeFixture()
        let travel = fixture.repository.createCollection(title: "Travel", createdBy: .user)
        fixture.repository.addEntry(body: "User-added", to: travel, createdBy: .user)
        fixture.repository.addEntry(
            body: "Other chat's write", to: travel, createdBy: .ai, sourceChatID: UUID()
        )

        fixture.coordinator.drain(for: fixture.chat, using: fixture.context)

        #expect(Self.memoryCards(in: fixture.chat, ofType: .memoryWrite).isEmpty)
    }

    // MARK: - Proposal cards

    @Test func drainPostsProposalCardsOnceAndRehydratesPersistedOnes() throws {
        let fixture = try Self.makeFixture()
        let queued = MemoryProposal(
            entryText: "Queued fact",
            summary: "Remember in \"X\"",
            source: .chat,
            chatID: fixture.chat.id
        )
        let orphaned = MemoryProposal(
            entryText: "Orphaned fact",
            summary: "Remember in \"Y\"",
            source: .chat,
            chatID: fixture.chat.id
        )
        let foreign = MemoryProposal(
            entryText: "Someone else's",
            summary: "Other chat",
            source: .chat,
            chatID: UUID()
        )
        for proposal in [queued, orphaned, foreign] {
            fixture.context.insert(proposal)
        }
        try fixture.context.save()
        fixture.coordinator.enqueueProposal(proposalID: queued.id, chatID: fixture.chat.id)

        fixture.coordinator.drain(for: fixture.chat, using: fixture.context)
        try fixture.context.save()

        let cards = Self.memoryCards(in: fixture.chat, ofType: .memoryProposal)
        #expect(cards.count == 2, "queued + rehydrated, never the foreign chat's")
        #expect(queued.cardPostedAt != nil)
        #expect(orphaned.cardPostedAt != nil)
        #expect(foreign.cardPostedAt == nil)

        fixture.coordinator.drain(for: fixture.chat, using: fixture.context)
        #expect(Self.memoryCards(in: fixture.chat, ofType: .memoryProposal).count == 2)
    }

    // MARK: - Proposal dispatcher

    @Test func approveAppliesEntryAndMarksDisclosed() async throws {
        let fixture = try Self.makeFixture()
        let gated = fixture.repository.createCollection(
            title: "Sensitive", accessLevel: .asksFirst, createdBy: .user
        )
        let proposal = MemoryProposal(
            entryText: "A gated fact",
            targetCollectionID: gated.id,
            summary: "Remember in \"Sensitive\"",
            source: .chat,
            chatID: fixture.chat.id
        )
        fixture.context.insert(proposal)
        try fixture.context.save()

        let dispatcher = MemoryProposalDispatcher(
            modelContainer: fixture.container,
            repositoryProvider: { fixture.repository }
        )
        await dispatcher.perform(action: .approve, itemID: proposal.id)

        let entry = try #require(fixture.repository.allEntries().first)
        #expect(entry.body == "A gated fact")
        #expect(entry.collection?.id == gated.id)
        #expect(entry.disclosedAt != nil, "the proposal card is the disclosure — no chip must follow")
        let saved = try #require(
            try ModelContext(fixture.container).fetch(FetchDescriptor<MemoryProposal>()).first
        )
        #expect(saved.status == .applied)
        #expect(fixture.repository.recentActivity().contains { $0.kind == .proposalAccepted })

        // Idempotent: a second approve is a no-op.
        await dispatcher.perform(action: .approve, itemID: proposal.id)
        #expect(fixture.repository.allEntries().count == 1)
    }

    @Test func approveWithVanishedTargetRoutesToInbox() async throws {
        let fixture = try Self.makeFixture()
        let proposal = MemoryProposal(
            entryText: "A homeless fact",
            targetCollectionID: UUID(),
            summary: "Remember",
            source: .chat,
            chatID: fixture.chat.id
        )
        fixture.context.insert(proposal)
        try fixture.context.save()

        let dispatcher = MemoryProposalDispatcher(
            modelContainer: fixture.container,
            repositoryProvider: { fixture.repository }
        )
        await dispatcher.perform(action: .approve, itemID: proposal.id)

        let entry = try #require(fixture.repository.allEntries().first)
        #expect(entry.collection?.isInbox == true, "never force-file — the Inbox is the pressure valve")
    }

    @Test func approveNewCollectionProposalCreatesItWithSeeds() async throws {
        let fixture = try Self.makeFixture()
        let proposal = MemoryProposal(
            entryText: "Seed one\nSeed two",
            newCollectionTitle: "Health notes",
            newCollectionAccessLevel: .asksFirst,
            summary: "Create collection",
            source: .chat,
            chatID: fixture.chat.id
        )
        fixture.context.insert(proposal)
        try fixture.context.save()

        await MemoryProposalDispatcher(
            modelContainer: fixture.container,
            repositoryProvider: { fixture.repository }
        ).perform(action: .approve, itemID: proposal.id)

        let collection = try #require(
            fixture.repository.collections().first { $0.title == "Health notes" }
        )
        #expect(collection.accessLevel == .asksFirst)
        #expect(collection.activeEntries.map(\.body).sorted() == ["Seed one", "Seed two"])
    }

    @Test func approveSupersessionProposalStampsTheOldEntry() async throws {
        let fixture = try Self.makeFixture()
        let gated = fixture.repository.createCollection(
            title: "Sensitive", accessLevel: .asksFirst, createdBy: .user
        )
        let old = fixture.repository.addEntry(body: "Old fact", to: gated, createdBy: .user)
        let proposal = MemoryProposal(
            entryText: "New fact",
            targetCollectionID: gated.id,
            supersedesEntryID: old.id,
            summary: "Update",
            source: .chat,
            chatID: fixture.chat.id
        )
        fixture.context.insert(proposal)
        try fixture.context.save()

        await MemoryProposalDispatcher(
            modelContainer: fixture.container,
            repositoryProvider: { fixture.repository }
        ).perform(action: .approve, itemID: proposal.id)

        #expect(old.supersededByID != nil)
        #expect(gated.activeEntries.map(\.body) == ["New fact"])
    }

    @Test func rejectIsDurableAndWritesNothing() async throws {
        let fixture = try Self.makeFixture()
        let proposal = MemoryProposal(
            entryText: "Declined fact",
            summary: "Remember",
            source: .chat,
            chatID: fixture.chat.id
        )
        fixture.context.insert(proposal)
        try fixture.context.save()

        await MemoryProposalDispatcher(
            modelContainer: fixture.container,
            repositoryProvider: { fixture.repository }
        ).perform(action: .reject, itemID: proposal.id)

        #expect(fixture.repository.allEntries().isEmpty)
        let saved = try #require(
            try ModelContext(fixture.container).fetch(FetchDescriptor<MemoryProposal>()).first
        )
        #expect(saved.status == .rejected)
        #expect(saved.resolvedAt != nil)
        #expect(fixture.repository.recentActivity().contains { $0.kind == .proposalDismissed })
    }

    // MARK: - Write dispatcher (undo)

    @Test func undoDeletesUnmodifiedWriteAndRespectsGuard() async throws {
        let fixture = try Self.makeFixture()
        let travel = fixture.repository.createCollection(title: "Travel", createdBy: .user)
        let entry = fixture.repository.addEntry(
            body: "Undo me", to: travel, createdBy: .ai, sourceChatID: fixture.chat.id
        )
        let dispatcher = MemoryWriteDispatcher(repositoryProvider: { fixture.repository })

        await dispatcher.perform(action: .undo, itemID: entry.id)
        #expect(fixture.repository.allEntries().isEmpty)

        // An edited entry refuses undo — the write is no longer "unwatched".
        let kept = fixture.repository.addEntry(
            body: "Keep me", to: travel, createdBy: .ai, sourceChatID: fixture.chat.id
        )
        fixture.repository.editEntry(kept, body: "Keep me, edited", actor: .user)
        await dispatcher.perform(action: .undo, itemID: kept.id)
        #expect(fixture.repository.allEntries().count == 1)
    }
}
