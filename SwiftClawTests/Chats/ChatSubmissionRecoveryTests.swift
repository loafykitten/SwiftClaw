import Foundation
import SwiftData
import Testing
@testable import SwiftClaw

@MainActor
struct ChatSubmissionRecoveryTests {
    // MARK: - Interrupted generations

    @Test func recoveryClearsStaleGeneratingFlagsAndExplainsTheInterruption() throws {
        let container = try Self.inMemoryContainer()
        let context = container.mainContext
        let stale = Chat(title: "Stale", modelSelection: "m", isGenerating: true)
        let idle = Chat(title: "Idle", modelSelection: "m")
        context.insert(stale)
        context.insert(idle)
        try context.save()

        let recovered = ChatGenerationRecovery.recoverInterruptedGenerations(
            in: context,
            hasLiveCompletion: { _ in false }
        )

        #expect(recovered == 1)
        #expect(stale.isGenerating == false)
        #expect(stale.errorMessage == ChatGenerationRecovery.interruptedMessage)
        #expect(idle.errorMessage == nil)
        #expect(context.hasChanges == false)
    }

    @Test func recoveryLeavesChatsWithALiveCompletionGenerating() throws {
        let container = try Self.inMemoryContainer()
        let context = container.mainContext
        let live = Chat(title: "Live", modelSelection: "m", isGenerating: true)
        context.insert(live)
        try context.save()

        let recovered = ChatGenerationRecovery.recoverInterruptedGenerations(
            in: context,
            hasLiveCompletion: { $0 == live.id }
        )

        #expect(recovered == 0)
        #expect(live.isGenerating)
        #expect(live.errorMessage == nil)
    }

    // MARK: - Failed submission rollback

    @Test func discardingAnUnsavedMessageKeepsItOutOfTheNextSave() throws {
        let container = try Self.inMemoryContainer()
        let context = container.mainContext
        let chat = Chat(title: "Chat", modelSelection: "m")
        context.insert(chat)
        chat.appendMessage(role: .user, content: "first")
        try context.save()
        let savedUpdatedAt = chat.updatedAt
        let savedLatest = chat.latestVisibleMessageAt

        let attachment = ImageAttachmentRecord(
            filePath: "/tmp/swiftclaw-deleted-\(UUID().uuidString).jpg",
            byteCount: 1,
            pixelWidth: 1,
            pixelHeight: 1
        )
        let failed = chat.appendMessage(
            role: .user,
            content: "second",
            imageAttachments: [attachment]
        )
        chat.discardUnsavedMessage(failed, in: context, restoringUpdatedAt: savedUpdatedAt)
        try context.save()

        let messages = try context.fetch(FetchDescriptor<ChatMessage>())
        #expect(messages.map(\.content) == ["first"])
        #expect(chat.messages.map(\.content) == ["first"])
        #expect(chat.updatedAt == savedUpdatedAt)
        #expect(chat.latestVisibleMessageAt == savedLatest)
    }

    @Test func deletingAnUnsavedNewChatLeavesNothingToPersist() throws {
        // Mirrors HomeView's save-failure path: the chat + first message were
        // inserted but never saved.
        let container = try Self.inMemoryContainer()
        let context = container.mainContext
        let chat = Chat(title: "New", modelSelection: "m", isGenerating: true)
        let message = ChatMessage(role: .user, content: "hello", sortIndex: 0)
        message.chat = chat
        chat.messages = [message]
        context.insert(chat)
        context.insert(message)

        context.delete(message)
        context.delete(chat)
        try context.save()

        #expect(try context.fetchCount(FetchDescriptor<Chat>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<ChatMessage>()) == 0)
    }

    private static func inMemoryContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Item.self, Chat.self, ChatMessage.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }
}
