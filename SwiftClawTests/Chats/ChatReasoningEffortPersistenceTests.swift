import Foundation
import SwiftData
import Testing
@testable import SwiftClaw

@Suite
struct ChatReasoningEffortPersistenceTests {
    @Test func defaultsToOffWhenUnset() {
        let chat = Chat(title: "New chat", modelSelection: "any-model")

        #expect(chat.reasoningEffort == .off)
    }

    @Test func initPersistsReasoningEffortRawValue() {
        let chat = Chat(title: "New chat", modelSelection: "any-model", reasoningEffort: .medium)

        #expect(chat.reasoningEffortRaw == "medium")
        #expect(chat.reasoningEffort == .medium)
    }

    @Test func computedSetterWritesRawValue() {
        let chat = Chat(title: "New chat", modelSelection: "any-model")

        chat.reasoningEffort = .high

        #expect(chat.reasoningEffortRaw == "high")
        #expect(chat.reasoningEffort == .high)
    }

    @Test func recoversFromInvalidRawValueAsOff() {
        let chat = Chat(title: "New chat", modelSelection: "any-model")
        chat.reasoningEffortRaw = "bogus"

        #expect(chat.reasoningEffort == .off)
    }

    @Test func roundTripsThroughSwiftDataPersistingReasoningEffort() throws {
        let container = try Self.inMemoryContainer()
        let context = ModelContext(container)

        let chat = Chat(
            title: "Reasoning chat",
            modelSelection: "neuralwatt:reasoning-model",
            reasoningEffort: .high
        )
        context.insert(chat)
        try context.save()

        let fetched = try #require(context.fetch(FetchDescriptor<Chat>()).first)
        #expect(fetched.reasoningEffortRaw == "high")
        #expect(fetched.reasoningEffort == .high)

        fetched.reasoningEffort = .low
        try context.save()

        let refetched = try #require(context.fetch(FetchDescriptor<Chat>()).first)
        #expect(refetched.reasoningEffortRaw == "low")
        #expect(refetched.reasoningEffort == .low)
    }

    @Test func legacyChatWithNilReasoningEffortRawDefaultsToOff() throws {
        let container = try Self.inMemoryContainer()
        let context = ModelContext(container)

        let chat = Chat(title: "Legacy chat", modelSelection: "any-model")
        context.insert(chat)
        try context.save()

        // Simulate a pre-migration row by clearing the persisted column.
        let refetched = try #require(context.fetch(FetchDescriptor<Chat>()).first)
        refetched.reasoningEffortRaw = nil
        try context.save()

        let legacy = try #require(context.fetch(FetchDescriptor<Chat>()).first)
        #expect(legacy.reasoningEffort == .off)
    }

    // MARK: - Helpers

    private static func inMemoryContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Item.self, Chat.self, ChatMessage.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }
}
