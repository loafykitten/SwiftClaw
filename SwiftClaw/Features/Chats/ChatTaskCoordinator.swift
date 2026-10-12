import Foundation
import SwiftData

@MainActor
final class ChatTaskCoordinator {
    static let shared = ChatTaskCoordinator()

    private var completionTasks: [UUID: Task<Void, Never>] = [:]
    private var titleTasks: [UUID: Task<Void, Never>] = [:]

    private init() {}

    func completeChat(
        _ chat: Chat,
        in modelContext: ModelContext,
        allowInvestigation: Bool,
        supportsImages: Bool,
        reasoningEffort: ModelReasoningEffort?
    ) {
        let chatID = chat.id
        completionTasks[chatID]?.cancel()
        completionTasks[chatID] = Task { @MainActor [weak self] in
            await ChatCompletionService.completeChat(
                chat,
                in: modelContext,
                allowInvestigation: allowInvestigation,
                supportsImages: supportsImages,
                reasoningEffort: reasoningEffort
            )

            guard !Task.isCancelled else { return }
            self?.completionTasks[chatID] = nil
        }
    }

    func generateInitialTitle(
        for chat: Chat,
        userInput: String,
        in modelContext: ModelContext
    ) {
        let chatID = chat.id
        titleTasks[chatID]?.cancel()
        titleTasks[chatID] = Task { @MainActor [weak self] in
            await ChatTitleService.generateInitialTitle(
                for: chat,
                userInput: userInput,
                in: modelContext
            )

            guard !Task.isCancelled else { return }
            self?.titleTasks[chatID] = nil
        }
    }

    /// Whether a completion task launched this process is still tracked for
    /// the chat — i.e. its persisted `isGenerating` flag is live, not stale.
    func hasActiveCompletion(for chatID: UUID) -> Bool {
        completionTasks[chatID] != nil
    }

    func cancelTasks(for chatID: UUID) {
        completionTasks[chatID]?.cancel()
        completionTasks[chatID] = nil
        titleTasks[chatID]?.cancel()
        titleTasks[chatID] = nil
    }
}
