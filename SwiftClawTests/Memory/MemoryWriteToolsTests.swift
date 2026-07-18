import Foundation
import SwiftData
import Testing
@testable import SwiftClaw

@MainActor
struct MemoryWriteToolsTests {
    private struct Fixture {
        let container: ModelContainer
        let repository: MemoryRepository
        let coordinator: MemoryCardCoordinator
        let dependencies: MemoryWriteToolDependencies
        let chatID = UUID()
    }

    private static func makeFixture(available: Bool = true) throws -> Fixture {
        let container = try ModelContainer(
            for: MemoryCollection.self, MemoryEntry.self, MemoryProposal.self, MemoryActivityEvent.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let repository = MemoryRepository(modelContext: ModelContext(container))
        return Fixture(
            container: container,
            repository: repository,
            coordinator: MemoryCardCoordinator(),
            dependencies: MemoryWriteToolDependencies(
                isAvailable: { available },
                repository: { repository }
            )
        )
    }

    // MARK: - add_memory

    @Test func addToWritesFreelyCollectionSavesImmediatelyAndQueuesChip() async throws {
        let fixture = try Self.makeFixture()
        let travel = fixture.repository.createCollection(title: "Travel preferences", createdBy: .user)
        let tool = AddMemoryTool(
            modelContainer: fixture.container,
            chatID: fixture.chatID,
            coordinator: fixture.coordinator,
            dependencies: fixture.dependencies
        )

        let result = try await tool.execute(arguments: [
            "content": .string("Prefers window seats"),
            "collection": .string(travel.handle),
            "tags": .array([.string("flights")]),
        ])

        #expect(result.contains("Saved to \"Travel preferences\""))
        let entry = try #require(fixture.repository.allEntries().first)
        #expect(entry.body == "Prefers window seats")
        #expect(entry.createdBy == .ai)
        #expect(entry.sourceChatID == fixture.chatID)
        #expect(entry.tags == ["flights"])
        #expect(fixture.coordinator.hasQueuedDisclosures(forChatID: fixture.chatID))
    }

    @Test func addToAsksFirstCollectionProposesInstead() async throws {
        let fixture = try Self.makeFixture()
        let gated = fixture.repository.createCollection(
            title: "Sensitive",
            accessLevel: .asksFirst,
            createdBy: .user
        )
        let tool = AddMemoryTool(
            modelContainer: fixture.container,
            chatID: fixture.chatID,
            coordinator: fixture.coordinator,
            dependencies: fixture.dependencies
        )

        let result = try await tool.execute(arguments: [
            "content": .string("A gated fact"),
            "collection": .string("Sensitive"),
        ])

        #expect(result.contains("awaiting the user's decision"))
        #expect(fixture.repository.allEntries().isEmpty, "asks-first writes never apply directly")
        let proposals = try ModelContext(fixture.container).fetch(FetchDescriptor<MemoryProposal>())
        let proposal = try #require(proposals.first)
        #expect(proposal.status == .pending)
        #expect(proposal.targetCollectionID == gated.id)
        #expect(proposal.chatID == fixture.chatID)
        #expect(fixture.coordinator.hasQueuedDisclosures(forChatID: fixture.chatID))
    }

    @Test func addWithoutCollectionFilesToInbox() async throws {
        let fixture = try Self.makeFixture()
        let tool = AddMemoryTool(
            modelContainer: fixture.container,
            chatID: fixture.chatID,
            coordinator: fixture.coordinator,
            dependencies: fixture.dependencies
        )

        _ = try await tool.execute(arguments: ["content": .string("An unfiled fact")])

        let entry = try #require(fixture.repository.allEntries().first)
        #expect(entry.collection?.isInbox == true)
    }

    @Test func addWithUnresolvableCollectionErrorsInsteadOfMisfiling() async throws {
        let fixture = try Self.makeFixture()
        let tool = AddMemoryTool(
            modelContainer: fixture.container,
            chatID: fixture.chatID,
            coordinator: fixture.coordinator,
            dependencies: fixture.dependencies
        )

        await #expect(throws: ToolError.self) {
            try await tool.execute(arguments: [
                "content": .string("A fact"),
                "collection": .string("No such collection"),
            ])
        }
        #expect(fixture.repository.allEntries().isEmpty)
    }

    @Test func toolsGateOnAvailability() async throws {
        let fixture = try Self.makeFixture(available: false)
        let tool = AddMemoryTool(
            modelContainer: fixture.container,
            chatID: fixture.chatID,
            coordinator: fixture.coordinator,
            dependencies: fixture.dependencies
        )

        #expect(!tool.isConfigured)
        await #expect(throws: ToolError.self) {
            try await tool.execute(arguments: ["content": .string("A fact")])
        }
    }

    // MARK: - supersede_memory

    @Test func supersedeInWritesFreelyCollectionAppliesImmediately() async throws {
        let fixture = try Self.makeFixture()
        let facts = fixture.repository.createCollection(title: "Facts", createdBy: .user)
        let old = fixture.repository.addEntry(body: "Works at Acme", to: facts, createdBy: .ai)
        let tool = SupersedeMemoryTool(
            modelContainer: fixture.container,
            chatID: fixture.chatID,
            coordinator: fixture.coordinator,
            dependencies: fixture.dependencies
        )

        let result = try await tool.execute(arguments: [
            "handle": .string(old.handle),
            "content": .string("Works at Initech"),
        ])

        #expect(result.contains("Superseded"))
        #expect(old.supersededByID != nil)
        #expect(facts.activeEntries.map(\.body) == ["Works at Initech"])
        #expect(fixture.coordinator.hasQueuedDisclosures(forChatID: fixture.chatID))
    }

    @Test func supersedeInAsksFirstCollectionProposesWithTarget() async throws {
        let fixture = try Self.makeFixture()
        let gated = fixture.repository.createCollection(
            title: "Sensitive",
            accessLevel: .asksFirst,
            createdBy: .user
        )
        let old = fixture.repository.addEntry(body: "Old fact", to: gated, createdBy: .user)
        let tool = SupersedeMemoryTool(
            modelContainer: fixture.container,
            chatID: fixture.chatID,
            coordinator: fixture.coordinator,
            dependencies: fixture.dependencies
        )

        _ = try await tool.execute(arguments: [
            "handle": .string(old.handle),
            "content": .string("New fact"),
        ])

        #expect(old.supersededByID == nil, "nothing applies until approval")
        let proposal = try #require(
            try ModelContext(fixture.container).fetch(FetchDescriptor<MemoryProposal>()).first
        )
        #expect(proposal.supersedesEntryID == old.id)
        #expect(proposal.targetCollectionID == gated.id)
    }

    @Test func supersedeWithUnknownHandleErrors() async throws {
        let fixture = try Self.makeFixture()
        let tool = SupersedeMemoryTool(
            modelContainer: fixture.container,
            chatID: fixture.chatID,
            coordinator: fixture.coordinator,
            dependencies: fixture.dependencies
        )

        await #expect(throws: ToolError.self) {
            try await tool.execute(arguments: [
                "handle": .string("ffffffff"),
                "content": .string("New fact"),
            ])
        }
    }

    // MARK: - create_memory_collection

    @Test func createWritesFreelyCollectionSeedsEntriesImmediately() async throws {
        let fixture = try Self.makeFixture()
        let tool = CreateMemoryCollectionTool(
            modelContainer: fixture.container,
            chatID: fixture.chatID,
            coordinator: fixture.coordinator,
            dependencies: fixture.dependencies
        )

        let result = try await tool.execute(arguments: [
            "title": .string("Coffee preferences"),
            "scope": .string("email"),
            "initial_entries": .array([.string("Drinks oat lattes"), .string("No decaf")]),
        ])

        #expect(result.contains("Created \"Coffee preferences\""))
        let collection = try #require(
            fixture.repository.collections().first { $0.title == "Coffee preferences" }
        )
        #expect(collection.accessLevel == .writesFreely)
        #expect(collection.scope == .email)
        #expect(collection.createdBy == .ai)
        #expect(collection.activeEntries.count == 2)
        #expect(fixture.coordinator.hasQueuedDisclosures(forChatID: fixture.chatID))
    }

    @Test func createAsksFirstCollectionIsOneProposalCarryingSeeds() async throws {
        let fixture = try Self.makeFixture()
        let tool = CreateMemoryCollectionTool(
            modelContainer: fixture.container,
            chatID: fixture.chatID,
            coordinator: fixture.coordinator,
            dependencies: fixture.dependencies
        )

        _ = try await tool.execute(arguments: [
            "title": .string("Health notes"),
            "access_level": .string("asks_first"),
            "initial_entries": .array([.string("Allergic to penicillin"), .string("Runs on Tuesdays")]),
        ])

        #expect(fixture.repository.collections().isEmpty, "nothing exists until approval")
        let proposal = try #require(
            try ModelContext(fixture.container).fetch(FetchDescriptor<MemoryProposal>()).first
        )
        #expect(proposal.newCollectionTitle == "Health notes")
        #expect(proposal.newCollectionAccessLevel == .asksFirst)
        #expect(MemoryProposalDispatcher.entryTexts(for: proposal)
            == ["Allergic to penicillin", "Runs on Tuesdays"])
    }

    @Test func createRefusesDuplicateTitle() async throws {
        let fixture = try Self.makeFixture()
        fixture.repository.createCollection(title: "Travel preferences", createdBy: .user)
        let tool = CreateMemoryCollectionTool(
            modelContainer: fixture.container,
            chatID: fixture.chatID,
            coordinator: fixture.coordinator,
            dependencies: fixture.dependencies
        )

        await #expect(throws: ToolError.self) {
            try await tool.execute(arguments: ["title": .string("travel PREFERENCES")])
        }
    }
}
