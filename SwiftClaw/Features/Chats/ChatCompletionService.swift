import Foundation
import SwiftData

/// Runs assistant completions for a `Chat`, in one place, so every entry
/// point (Home's initial message, the Chats view, future composers) gets the
/// same behavior — including tool support — without duplicating the loop.
@MainActor
enum ChatCompletionService {
    /// Generates the next assistant message for the chat and persists it.
    static func completeChat(_ chat: Chat, in modelContext: ModelContext) async {
        do {
            let response = try await InferenceService.shared.complete(
                messages: chat.sortedMessages.compactMap(\.inferenceMessage),
                model: chat.modelSelection,
                tools: ToolRegistry.shared.availableTools
            )

            chat.appendMessage(role: .assistant, content: response)
            chat.isGenerating = false
            chat.errorMessage = nil
        } catch {
            chat.isGenerating = false
            chat.errorMessage = error.localizedDescription
        }

        do {
            try modelContext.save()
        } catch {
            chat.errorMessage = "Couldn't save the assistant response."
        }
    }
}
