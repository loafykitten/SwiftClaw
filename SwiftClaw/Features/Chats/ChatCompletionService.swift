import Foundation
import SwiftData

/// Runs assistant completions for a `Chat`, in one place, so every entry
/// point (Home's initial message, the Chats view, future composers) gets the
/// same behavior — including tool support — without duplicating the loop.
@MainActor
enum ChatCompletionService {
    /// Generates the next assistant message for the chat and persists it.
    ///
    /// `allowInvestigation` offers the Investigation tool to the model for
    /// this single completion (the composer's one-shot search toggle).
    static func completeChat(
        _ chat: Chat,
        in modelContext: ModelContext,
        allowInvestigation: Bool = false,
        supportsImages: Bool = true,
        reasoningEffort: ModelReasoningEffort? = nil
    ) async {
        let activityScope = ToolActivityScope(chatID: chat.id, generationID: UUID())

        ToolActivityMonitor.shared.beginGeneration(activityScope)
        defer {
            ToolActivityMonitor.shared.endGeneration(activityScope)
        }

        await ToolActivityContext.$currentScope.withValue(activityScope) {
            await completeScopedChat(
                chat,
                in: modelContext,
                allowInvestigation: allowInvestigation,
                supportsImages: supportsImages,
                reasoningEffort: reasoningEffort
            )
        }
    }

    private static func completeScopedChat(
        _ chat: Chat,
        in modelContext: ModelContext,
        allowInvestigation: Bool,
        supportsImages: Bool,
        reasoningEffort: ModelReasoningEffort?
    ) async {
        let capabilities = SettingsStorage.capabilities(for: chat.modelSelection)
        let canUseTools = capabilities.contains(.tools)
        let canUseImages = supportsImages && capabilities.contains(.vision)
        let effectiveReasoningEffort = InferenceService.effectiveReasoningEffort(
            reasoningEffort,
            capabilities: capabilities
        )
        let canInvestigate = allowInvestigation
            && canUseTools
            && effectiveReasoningEffort?.isReasoningEnabled == true

        var messages = chat.sortedMessages.compactMap {
            $0.inferenceMessage(includingImages: canUseImages)
        }

        if canInvestigate {
            // Transient steering hint; deliberately not persisted to the chat.
            messages.append(.system("""
                The user enabled Investigation mode for this message. Use the \
                investigate tool to research the topic before answering. \
                Present the tool's report faithfully: keep the \
                overview-then-deeper-findings structure, keep every [n] \
                citation marker, and reproduce the report's complete \
                "Sources" list at the end of your reply without dropping or \
                renumbering entries.
                """))
        }

        do {
            let response = try await InferenceService.shared.complete(
                messages: messages,
                model: chat.modelSelection,
                reasoningEffort: effectiveReasoningEffort,
                tools: canUseTools
                    ? ToolRegistry.shared.availableTools(includingExplicitlyEnabled: canInvestigate)
                    : []
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
