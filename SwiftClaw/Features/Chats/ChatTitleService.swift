import Foundation
import SwiftData
import os

/// Generates concise model-authored titles for chats.
///
/// Always prefers the user's Swift Model preset (a cheap one-shot, no
/// reasoning) and falls back to the chat's own model selection + reasoning
/// effort when the Swift Model is unavailable. System prompts are sent via
/// `.standalone` so no persona is injected.
@MainActor
enum ChatTitleService {
    private static let logger = AppLog.make("ChatTitleService")

    static let initialSystemPrompt = """
        Please generate a concise 5-10 word chat summary title based on the user's input.
        """

    static let regenerateSystemPrompt = """
        Please generate a concise 5-10 word chat summary title based on the following input; \
        the initial message and a sample of the latest messages.
        """

    /// Generates a title for a freshly created chat from the user's first
    /// message. Leaves the existing `ChatDefaults`-truncated title in place
    /// on failure or an empty result.
    static func generateInitialTitle(
        for chat: Chat,
        userInput: String,
        in modelContext: ModelContext
    ) async {
        guard !ProcessInfo.processInfo.isRunningInPreview else { return }

        let messages: [InferenceMessage] = [
            .system(initialSystemPrompt),
            .user(userInput),
        ]

        await generate(for: chat, messages: messages, in: modelContext)
    }

    /// Regenerates a title from the chat's first message plus a sample of the
    /// most recent messages. Skips email-review chats, whose title prefix
    /// gates email tool registration in `ChatCompletionService`.
    static func regenerateTitle(
        for chat: Chat,
        in modelContext: ModelContext
    ) async {
        guard !ProcessInfo.processInfo.isRunningInPreview else { return }

        guard !chat.title.hasPrefix(EmailReviewNotifyTool.reviewChatTitlePrefix) else {
            logger.notice("Skipping title regeneration for email-review chat")
            return
        }

        let visible = chat.visibleMessages
        guard let firstMessage = visible.first else { return }

        // First message + last 6 messages (chronological), deduped.
        var sampled: [ChatMessage] = [firstMessage]
        for message in visible.suffix(6)
            where !sampled.contains(where: { $0.id == message.id }) {
            sampled.append(message)
        }
        sampled.sort { lhs, rhs in
            if lhs.createdAt == rhs.createdAt {
                return lhs.sortIndex < rhs.sortIndex
            }
            return lhs.createdAt < rhs.createdAt
        }

        let messages: [InferenceMessage] = [.system(regenerateSystemPrompt)]
            + sampled.compactMap { $0.inferenceMessage(includingImages: false) }

        guard messages.count > 1 else { return }

        await generate(for: chat, messages: messages, in: modelContext)
    }

    private static func generate(
        for chat: Chat,
        messages: [InferenceMessage],
        in modelContext: ModelContext
    ) async {
        let (model, reasoning) = resolveModel(for: chat)

        let response: String
        do {
            response = try await InferenceService.shared.complete(
                messages: messages,
                model: model,
                reasoningEffort: reasoning,
                systemPromptMode: .standalone
            )
        } catch is CancellationError {
            return
        } catch {
            logger.error("Title generation failed: \(String(describing: error), privacy: .public)")
            return
        }

        guard !Task.isCancelled else { return }
        let cleaned = cleaned(response)
        guard !cleaned.isEmpty else { return }

        chat.title = cleaned

        do {
            guard !Task.isCancelled else { return }
            try modelContext.save()
        } catch {
            logger.error("Couldn't persist generated title: \(String(describing: error), privacy: .public)")
        }
    }

    /// Resolves which model + reasoning effort to use for title generation:
    /// the user's Swift Model preset when configured and resolvable;
    /// otherwise the chat's own model selection and reasoning effort.
    private static func resolveModel(
        for chat: Chat
    ) -> (model: String, reasoning: ModelReasoningEffort?) {
        let swiftModel = SettingsStorage.loadModelSelection(forKey: SettingsKeys.swiftModel)
        if !swiftModel.isEmpty {
            do {
                _ = try InferenceService.shared.resolve(swiftModel)
                return (swiftModel, nil)
            } catch {
                logger.notice(
                    "Swift Model unavailable, falling back to chat model: \(String(describing: error), privacy: .public)"
                )
            }
        }
        return (chat.modelSelection, chat.reasoningEffort)
    }

    /// Trims the response to a single line and strips wrapping quotes some
    /// models add.
    private static func cleaned(_ raw: String) -> String {
        let firstLine = raw
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""

        return firstLine.trimmingCharacters(
            in: CharacterSet(charactersIn: "\"'\u{201C}\u{201D}\u{2018}\u{2019}")
        )
    }
}
