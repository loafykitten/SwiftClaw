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
        // Keyed off the review-chat identity, not off whether the card still
        // has live emails. Otherwise once the user cleans up the card (all
        // items actioned) or the emails are gone, the chat would silently
        // lose its email context + tools and the assistant would deny having
        // any email access at all.
        let isEmailReviewChat = chat.isEmailReviewChat
        let reviewCardPayloads = chat.sortedMessages.compactMap(\.reviewCard)
        let emailReviewContext: String? = isEmailReviewChat
            ? EmailReviewFollowUpContextBuilder.makeContext(
                for: reviewCardPayloads,
                in: modelContext
              )
            : nil

        var messages = chat.sortedMessages.compactMap {
            $0.inferenceMessage(includingImages: canUseImages)
        }

        // Memory store injection — appended before the per-turn transient
        // hints below so the (deterministic, mutation-cached) block sits as
        // early and as stably as possible in the hoisted system prompt; the
        // per-message recall block is inherently per-turn and rides last.
        let isMemoryInjectionEnabled = SettingsStorage.isMemoryEnabled()
            && MemoryFeatureModel.shared.repository != nil
        if isMemoryInjectionEnabled, let promptBuilder = MemoryFeatureModel.shared.promptBuilder {
            let exposure = promptBuilder.exposure()
            messages.append(.system(exposure.block))
            if exposure.tier == .index,
               let latestUserMessage = chat.sortedMessages.last(where: { $0.role == .user })?.content,
               let recall = promptBuilder.recallBlock(for: latestUserMessage) {
                messages.append(.system(recall))
            }
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
        if isEmailReviewChat {
            // Always ground the assistant in this chat's email capabilities —
            // even when no specific emails are attached (card cleared/empty),
            // so it never claims it lacks email access.
            messages.append(.system(
                emailReviewContext ?? EmailReviewFollowUpContextBuilder.capabilityOnlyContext()
            ))
        }
        // Last on purpose: this line changes every turn, so it must sit at
        // the tail of the hoisted system prompt to keep the prefix cacheable.
        messages.append(.system(PromptDateContext.currentString()))

        var tools: [any Tool] = []
        if canUseTools {
            // A fresh launch never opens Notes UI, so `NotesFeatureModel`
            // hasn't bootstrapped from persisted settings yet — without this,
            // `search_notes`/`read_note` would incorrectly filter out of a
            // cold chat even when Notes is enabled and a vault is already
            // configured. Idempotent/cheap once bootstrapped.
            await NotesFeatureModel.shared.prepareReadToolsIfNeeded()
            tools = ToolRegistry.shared.availableTools(includingExplicitlyEnabled: canInvestigate)
            if isEmailReviewChat {
                tools.append(EmailReviewAddNoteTool(modelContainer: modelContext.container))
                tools.append(EmailReviewSetFlagTool(modelContainer: modelContext.container))
                tools.append(EmailReviewRefreshTool(chatID: chat.id))
            }
            // Proposal tools need the current chat id + ModelContainer to
            // insert a `NoteEditProposal` and queue it on the right chat, so
            // they're built fresh per completion rather than living on
            // `ToolRegistry.shared` — the Phase 4 read tools stay there
            // unchanged since they need no chat-scoped state.
            if NotesFeatureModel.shared.isAvailableForReadTools {
                tools.append(ProposeNoteEditTool(modelContainer: modelContext.container, chatID: chat.id))
                tools.append(ProposeNoteCreateTool(modelContainer: modelContext.container, chatID: chat.id))
            }
            // Memory write tools are request-bound for the same reason as
            // the Notes proposal tools: they need the chat id + container to
            // route disclosures/proposals onto the right chat. The read
            // tools (search/open) live on `ToolRegistry.shared`.
            if MemoryFeatureModel.shared.isAvailable {
                tools.append(AddMemoryTool(modelContainer: modelContext.container, chatID: chat.id))
                tools.append(SupersedeMemoryTool(modelContainer: modelContext.container, chatID: chat.id))
                tools.append(CreateMemoryCollectionTool(modelContainer: modelContext.container, chatID: chat.id))
            }
        }

        var assistantResponse: String?
        do {
            let response = try await InferenceService.shared.complete(
                messages: messages,
                model: chat.modelSelection,
                reasoningEffort: effectiveReasoningEffort,
                tools: tools
            )

            guard !Task.isCancelled else { return }
            chat.appendMessage(role: .assistant, content: response)
            assistantResponse = response
            // Must run after the assistant's own message is appended but
            // before `modelContext.save()` below, so the reply and every
            // proposal card land in the same save/turn.
            NotesProposalCoordinator.shared.drain(for: chat, using: modelContext)
            MemoryCardCoordinator.shared.drain(for: chat, using: modelContext)
            chat.isGenerating = false
            chat.errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            chat.isGenerating = false
            chat.errorMessage = error.localizedDescription
        }

        do {
            guard !Task.isCancelled else { return }
            try modelContext.save()
            AppRouter.shared.noteNewChatMessages(in: chat.id)
            if let assistantResponse, !AppRouter.shared.isViewingChat(chat.id) {
                AppNotificationService.shared.notifyChatReply(
                    chatID: chat.id,
                    chatTitle: chat.title,
                    preview: assistantResponse
                )
            }
        } catch {
            chat.errorMessage = "Couldn't save the assistant response."
        }
    }
}
