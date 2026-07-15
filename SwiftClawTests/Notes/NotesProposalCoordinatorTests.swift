import Foundation
import Testing
import SwiftData
@testable import SwiftClaw

/// Covers `NotesProposalCoordinator.drain`'s rehydration path: a proposal a
/// tool persisted before a failed/cancelled completion (or before the
/// in-memory queue was lost to a relaunch) must still get exactly one review
/// card on the next successful completion for its own chat — never a second
/// card if it's already been posted, and never a card on the wrong chat.
@MainActor
struct NotesProposalCoordinatorTests {
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Chat.self, ChatMessage.self, NoteEditProposal.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    @discardableResult
    private func insertChat(in container: ModelContainer) -> Chat {
        let context = ModelContext(container)
        let chat = Chat(title: "Notes", modelSelection: "test-model")
        context.insert(chat)
        try? context.save()
        return chat
    }

    private func insertProposal(_ proposal: NoteEditProposal, in container: ModelContainer) {
        let context = ModelContext(container)
        context.insert(proposal)
        try? context.save()
    }

    private func fetchChat(id: UUID, in container: ModelContainer) -> Chat? {
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<Chat>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private func fetchProposal(id: UUID, in container: ModelContainer) -> NoteEditProposal? {
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<NoteEditProposal>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private func cardCount(in chat: Chat) -> Int {
        chat.visibleMessages.filter { $0.reviewCard?.reviewType == .noteProposal }.count
    }

    // MARK: - Queue-loss / restart rehydration

    @Test func drainPostsACardForAPendingProposalNeverEnqueuedOnAFreshCoordinatorInstance() throws {
        let container = try makeContainer()
        let chat = insertChat(in: container)
        let chatID = chat.id

        // Simulates a tool that persisted its proposal, then the process
        // restarted (or the completion failed) before the in-memory queue
        // ever recorded it — a brand-new `NotesProposalCoordinator` has no
        // knowledge of this proposal's id at all.
        let proposal = NoteEditProposal(
            kind: .edit,
            notePath: "note.md",
            baseContentHash: "hash",
            proposedContent: "new content",
            summary: "Rewrite the note",
            chatID: chat.id
        )
        insertProposal(proposal, in: container)

        let coordinator = NotesProposalCoordinator()
        let context = ModelContext(container)
        var chatDescriptor = FetchDescriptor<Chat>(predicate: #Predicate { $0.id == chatID })
        chatDescriptor.fetchLimit = 1
        let contextChat = try #require(context.fetch(chatDescriptor).first)
        coordinator.drain(for: contextChat, using: context)
        try context.save()

        let updatedChat = try #require(fetchChat(id: chat.id, in: container))
        #expect(cardCount(in: updatedChat) == 1)

        let resolvedProposal = try #require(fetchProposal(id: proposal.id, in: container))
        #expect(resolvedProposal.cardPostedAt != nil)
    }

    @Test func repeatedDrainsNeverPostASecondCardForTheSameProposal() throws {
        let container = try makeContainer()
        let chat = insertChat(in: container)
        let chatID = chat.id

        let proposal = NoteEditProposal(
            kind: .edit,
            notePath: "note.md",
            baseContentHash: "hash",
            proposedContent: "new content",
            summary: "Rewrite the note",
            chatID: chat.id
        )
        insertProposal(proposal, in: container)

        let coordinator = NotesProposalCoordinator()

        let firstContext = ModelContext(container)
        var firstChatDescriptor = FetchDescriptor<Chat>(predicate: #Predicate { $0.id == chatID })
        firstChatDescriptor.fetchLimit = 1
        let firstContextChat = try #require(firstContext.fetch(firstChatDescriptor).first)
        coordinator.drain(for: firstContextChat, using: firstContext)
        try firstContext.save()

        let secondContext = ModelContext(container)
        // A second completion on the same chat, with nothing newly queued —
        // the persisted proposal is already `cardPostedAt`-marked, so this
        // drain must be a no-op rather than posting a duplicate card.
        var secondChatDescriptor = FetchDescriptor<Chat>(predicate: #Predicate { $0.id == chatID })
        secondChatDescriptor.fetchLimit = 1
        let secondContextChat = try #require(secondContext.fetch(secondChatDescriptor).first)
        coordinator.drain(for: secondContextChat, using: secondContext)
        try secondContext.save()

        let updatedChat = try #require(fetchChat(id: chat.id, in: container))
        #expect(cardCount(in: updatedChat) == 1)
    }

    // MARK: - Per-chat isolation

    @Test func drainNeverPostsACardForAnotherChatsPendingProposal() throws {
        let container = try makeContainer()
        let chatA = insertChat(in: container)
        let chatB = insertChat(in: container)

        let proposalForB = NoteEditProposal(
            kind: .edit,
            notePath: "note.md",
            baseContentHash: "hash",
            proposedContent: "new content",
            summary: "Rewrite the note",
            chatID: chatB.id
        )
        insertProposal(proposalForB, in: container)

        let coordinator = NotesProposalCoordinator()
        let context = ModelContext(container)
        coordinator.drain(for: chatA, using: context)
        try context.save()

        let updatedChatA = try #require(fetchChat(id: chatA.id, in: container))
        #expect(cardCount(in: updatedChatA) == 0)

        let resolvedProposal = try #require(fetchProposal(id: proposalForB.id, in: container))
        #expect(resolvedProposal.cardPostedAt == nil)
    }

    // MARK: - No card after a failed completion

    @Test func drainNeverPostsACardForAResolvedProposalThatNeverGotOne() throws {
        let container = try makeContainer()
        let chat = insertChat(in: container)

        // A proposal that was rejected/applied through some other path
        // (never through a posted card, hypothetically) must not retroactively
        // get a card from a later drain — only `.pending` rows qualify.
        let proposal = NoteEditProposal(
            kind: .edit,
            notePath: "note.md",
            baseContentHash: "hash",
            proposedContent: "new content",
            summary: "Rewrite the note",
            status: .rejected,
            chatID: chat.id
        )
        insertProposal(proposal, in: container)

        let coordinator = NotesProposalCoordinator()
        let context = ModelContext(container)
        coordinator.drain(for: chat, using: context)
        try context.save()

        let updatedChat = try #require(fetchChat(id: chat.id, in: container))
        #expect(cardCount(in: updatedChat) == 0)
    }
}
