import Foundation
import SwiftData
import Testing
@testable import SwiftClaw

@MainActor
struct MemoryReviewIntegrationTests {
    private struct Fixture {
        let container: ModelContainer
        let context: ModelContext
        let repository: MemoryRepository
        let collector = MemoryProposalRunCollector()
        let dependencies: MemoryWriteToolDependencies
    }

    private static func makeFixture() throws -> Fixture {
        let container = try ModelContainer(
            for: Chat.self, ChatMessage.self,
            MemoryCollection.self, MemoryEntry.self, MemoryProposal.self, MemoryActivityEvent.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        // The router writes through `container.mainContext`; sharing that
        // context here keeps assertions reading the same live instances.
        let context = container.mainContext
        let repository = MemoryRepository(modelContext: context)
        return Fixture(
            container: container,
            context: context,
            repository: repository,
            dependencies: MemoryWriteToolDependencies(
                isAvailable: { true },
                repository: { repository }
            )
        )
    }

    // MARK: - propose_memory

    @Test func proposeMemoryEnforcesTheHardCap() async throws {
        let fixture = try Self.makeFixture()
        let tool = ProposeMemoryTool(
            feature: .email,
            modelContainer: fixture.container,
            collector: fixture.collector,
            dependencies: fixture.dependencies
        )

        for index in 1...ProposeMemoryTool.maxProposalsPerRun {
            _ = try await tool.execute(arguments: [
                "content": .string("Pattern \(index)"),
                "reason": .string("Noticed repeatedly"),
            ])
        }
        await #expect(throws: ToolError.self) {
            try await tool.execute(arguments: [
                "content": .string("One too many"),
                "reason": .string("Cap test"),
            ])
        }

        let proposals = try fixture.context.fetch(FetchDescriptor<MemoryProposal>())
        #expect(proposals.count == ProposeMemoryTool.maxProposalsPerRun)
        #expect(proposals.allSatisfy { $0.source == .emailReview && $0.status == .pending })
        #expect(fixture.collector.proposalIDs.count == ProposeMemoryTool.maxProposalsPerRun)
    }

    @Test func proposeMemoryScopesNewCollectionsToTheReviewedFeature() async throws {
        let fixture = try Self.makeFixture()
        let tool = ProposeMemoryTool(
            feature: .email,
            modelContainer: fixture.container,
            collector: fixture.collector,
            dependencies: fixture.dependencies
        )

        _ = try await tool.execute(arguments: [
            "content": .string("Always deletes cold outreach unread"),
            "reason": .string("Consistent across weeks"),
            "new_collection_title": .string("Email review preferences"),
        ])

        let proposal = try #require(
            try fixture.context.fetch(FetchDescriptor<MemoryProposal>()).first
        )
        #expect(proposal.newCollectionTitle == "Email review preferences")
        #expect(proposal.scope == .email)
        #expect(proposal.chatID == nil, "the review chat may not exist yet at proposal time")
    }

    @Test func proposeMemoryRejectsUnresolvableCollections() async throws {
        let fixture = try Self.makeFixture()
        let tool = ProposeMemoryTool(
            feature: .notes,
            modelContainer: fixture.container,
            collector: fixture.collector,
            dependencies: fixture.dependencies
        )

        await #expect(throws: ToolError.self) {
            try await tool.execute(arguments: [
                "content": .string("A fact"),
                "reason": .string("Because"),
                "collection": .string("No such collection"),
            ])
        }
        #expect(try fixture.context.fetch(FetchDescriptor<MemoryProposal>()).isEmpty)
    }

    // MARK: - Review context (read recipe)

    @Test func reviewContextIncludesPinnedAndFeatureScopedOnly() throws {
        let fixture = try Self.makeFixture()
        let pinnedElsewhere = fixture.repository.createCollection(
            title: "Identity", scope: .calendar, isPinned: true, createdBy: .user
        )
        fixture.repository.addEntry(body: "Works as a designer", to: pinnedElsewhere, createdBy: .user)
        let emailScoped = fixture.repository.createCollection(
            title: "Email review preferences", scope: .email, createdBy: .user
        )
        fixture.repository.addEntry(body: "Deletes newsletters unread", to: emailScoped, createdBy: .ai)
        let globalUnpinned = fixture.repository.createCollection(title: "Dining", createdBy: .user)
        fixture.repository.addEntry(body: "Orders medium spice", to: globalUnpinned, createdBy: .user)
        let otherScoped = fixture.repository.createCollection(
            title: "Notes habits", scope: .notes, createdBy: .user
        )
        fixture.repository.addEntry(body: "Daily notes every morning", to: otherScoped, createdBy: .user)

        let block = try #require(MemoryReviewContextBuilder.block(
            for: .email, repository: fixture.repository, isEnabled: true
        ))

        // Pinned rides into every review regardless of its own scope.
        #expect(block.contains("Works as a designer"))
        #expect(block.contains("Deletes newsletters unread"))
        // Nothing else: not global-unpinned, not other-feature scopes.
        #expect(!block.contains("Orders medium spice"))
        #expect(!block.contains("Daily notes every morning"))
    }

    @Test func reviewContextCarriesDeclinedProposalsAndGatesOnEnablement() throws {
        let fixture = try Self.makeFixture()
        let declined = MemoryProposal(
            entryText: "Always archives receipts",
            summary: "Declined once",
            status: .rejected,
            source: .emailReview,
            resolvedAt: .now
        )
        let declinedElsewhere = MemoryProposal(
            entryText: "Notes-only declined text",
            summary: "Other feature",
            status: .rejected,
            source: .notesReview,
            resolvedAt: .now
        )
        fixture.context.insert(declined)
        fixture.context.insert(declinedElsewhere)
        try fixture.context.save()

        let block = try #require(MemoryReviewContextBuilder.block(
            for: .email, repository: fixture.repository, isEnabled: true
        ))
        #expect(block.contains("Previously declined"))
        #expect(block.contains("Always archives receipts"))
        #expect(!block.contains("Notes-only declined text"))

        #expect(MemoryReviewContextBuilder.block(
            for: .email, repository: fixture.repository, isEnabled: false
        ) == nil)
        #expect(MemoryReviewContextBuilder.block(
            for: .reminders, repository: fixture.repository, isEnabled: true
        ) == nil, "nothing pinned/scoped/declined for reminders → no block at all")
    }

    // MARK: - Proposal routing

    @Test func routePostsCardsIntoThePreferredChat() throws {
        let fixture = try Self.makeFixture()
        let reviewChat = Chat(title: "Inbox review — Jul 17", modelSelection: "test")
        fixture.context.insert(reviewChat)
        let proposal = MemoryProposal(
            entryText: "A pattern", summary: "Worth keeping", source: .emailReview
        )
        fixture.context.insert(proposal)
        try fixture.context.save()

        MemoryReviewProposalRouter.route(
            proposalIDs: [proposal.id],
            for: .email,
            preferredChatID: reviewChat.id,
            modelContainer: fixture.container,
            coordinator: MemoryCardCoordinator()
        )

        #expect(proposal.chatID == reviewChat.id)
        #expect(proposal.cardPostedAt != nil)
        let cards = reviewChat.sortedMessages.compactMap(\.reviewCard)
        #expect(cards.count == 1)
        #expect(cards.first?.reviewType == .memoryProposal)
    }

    @Test func routeFallsBackToASharedSuggestionsChatAndReusesIt() throws {
        let fixture = try Self.makeFixture()
        let first = MemoryProposal(entryText: "Pattern one", summary: "One", source: .notesReview)
        let second = MemoryProposal(entryText: "Pattern two", summary: "Two", source: .notesReview)
        fixture.context.insert(first)
        fixture.context.insert(second)
        try fixture.context.save()

        MemoryReviewProposalRouter.route(
            proposalIDs: [first.id],
            for: .notes,
            preferredChatID: nil,
            modelContainer: fixture.container,
            coordinator: MemoryCardCoordinator()
        )
        MemoryReviewProposalRouter.route(
            proposalIDs: [second.id],
            for: .notes,
            preferredChatID: nil,
            modelContainer: fixture.container,
            coordinator: MemoryCardCoordinator()
        )

        let chats = try fixture.context.fetch(FetchDescriptor<Chat>())
        let suggestionChats = chats.filter(\.isMemorySuggestionsChat)
        #expect(suggestionChats.count == 1, "later runs reuse the unarchived suggestions chat")
        let cards = suggestionChats.first?.sortedMessages.compactMap(\.reviewCard) ?? []
        #expect(cards.count == 2)
    }

    @Test func routeSweepsOrphansFromInterruptedRuns() throws {
        let fixture = try Self.makeFixture()
        // An earlier email-review run crashed after inserting but before
        // routing: pending, unposted, no chat binding, not in any collector.
        let orphan = MemoryProposal(
            entryText: "Orphaned pattern", summary: "Lost run", source: .emailReview
        )
        // Foreign-source orphans stay put for their own feature's next run.
        let foreignOrphan = MemoryProposal(
            entryText: "Calendar orphan", summary: "Other lane", source: .calendarReview
        )
        fixture.context.insert(orphan)
        fixture.context.insert(foreignOrphan)
        try fixture.context.save()

        MemoryReviewProposalRouter.route(
            proposalIDs: [],
            for: .email,
            preferredChatID: nil,
            modelContainer: fixture.container,
            coordinator: MemoryCardCoordinator()
        )

        #expect(orphan.cardPostedAt != nil)
        #expect(orphan.chatID != nil)
        #expect(foreignOrphan.cardPostedAt == nil)
        #expect(foreignOrphan.chatID == nil)
    }
}
