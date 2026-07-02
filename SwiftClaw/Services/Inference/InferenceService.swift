import Foundation
import OpenAI
import os

enum InferenceProviderID: String, CaseIterable, Sendable {
    case azure = "Azure"
    case neuralwatt = "Neuralwatt"
    case openRouter = "OpenRouter"

    /// Prefix used to namespace model names in settings, e.g. "Azure: gpt-4o".
    var modelPrefix: String { "\(rawValue): " }
}

enum InferenceError: LocalizedError {
    case providerNotConfigured(InferenceProviderID, reason: String)
    case unknownModel(String)
    case emptyResponse
    case toolLoopLimitReached(Int)

    var errorDescription: String? {
        switch self {
        case .providerNotConfigured(let provider, let reason):
            "\(provider.rawValue) is not configured: \(reason)."
        case .unknownModel(let model):
            "No configured provider matches the model \"\(model)\"."
        case .emptyResponse:
            "The model returned an empty response."
        case .toolLoopLimitReached(let limit):
            "The model did not produce a final answer within \(limit) tool-calling rounds."
        }
    }
}

/// A chat message passed to ``InferenceService``.
enum InferenceMessage: Sendable, Equatable {
    case system(String)
    case user(String, imageAttachments: [ImageAttachmentRecord] = [])
    case assistant(String)

    private static let logger = AppLog.make("InferenceMessage")

    var chatParam: ChatQuery.ChatCompletionMessageParam {
        chatParam(includingImages: true)
    }

    func chatParam(includingImages: Bool) -> ChatQuery.ChatCompletionMessageParam {
        switch self {
        case .system(let content):
            return ChatQuery.ChatCompletionMessageParam.system(.init(content: .textContent(content)))
        case .user(let content, let imageAttachments):
            let imageData: [Data] = includingImages ? imageAttachments.compactMap { attachment in
                do {
                    return try Data(contentsOf: attachment.fileURL)
                } catch {
                    Self.logger.warning("""
                        Skipping unreadable image attachment \(attachment.filePath): \
                        \(String(describing: error))
                        """)
                    return nil
                }
            } : []

            guard !imageData.isEmpty else {
                return ChatQuery.ChatCompletionMessageParam.user(.init(content: .string(content)))
            }

            var parts: [ChatQuery.ChatCompletionMessageParam.UserMessageParam.Content.ContentPart] = [
                .text(.init(text: content))
            ]

            parts.append(contentsOf: imageData.map { data in
                .image(.init(imageUrl: .init(imageData: data, detail: .auto)))
            })

            return ChatQuery.ChatCompletionMessageParam.user(.init(content: .contentParts(parts)))
        case .assistant(let content):
            return ChatQuery.ChatCompletionMessageParam.assistant(.init(content: .textContent(content)))
        }
    }
}

enum InferenceSystemPromptMode: Sendable {
    case prependPersona
    case standalone
}

/// A model selection resolved to its provider and provider-specific model identifier.
struct ResolvedModel: Sendable {
    let provider: any OpenAICompatibleProvider

    /// Identifier sent to the API: the deployment name for Azure, the model name otherwise.
    let modelID: String

    let capabilities: Set<ModelCapability>
}

/// Runs chat completions against whichever provider backs a configured model.
///
/// Model selections are the namespaced strings produced by
/// `SettingsStorage.availableModels` and stored by the settings pickers,
/// e.g. "Azure: gpt-4o" or "OpenRouter: openai/gpt-4o-mini".
struct InferenceService: Sendable {
    static let shared = InferenceService()

    private static let logger = AppLog.make("InferenceService")

    /// Resolves a model selection string into a provider and model identifier.
    func resolve(_ modelSelection: String) throws -> ResolvedModel {
        let selection = modelSelection.trimmingCharacters(in: .whitespacesAndNewlines)

        if let title = selection.removingPrefix(InferenceProviderID.azure.modelPrefix) {
            guard let deployment = SettingsStorage.loadDeployments()
                .first(where: { $0.modelPickerTitle == title }) else {
                throw InferenceError.unknownModel(modelSelection)
            }

            return ResolvedModel(
                provider: AzureProvider.fromSettings(),
                modelID: deployment.deploymentName,
                capabilities: deployment.capabilities
            )
        }

        if let model = selection.removingPrefix(InferenceProviderID.neuralwatt.modelPrefix) {
            return ResolvedModel(
                provider: NeuralwattProvider.fromSettings(),
                modelID: model,
                capabilities: SettingsStorage.capabilities(for: selection)
            )
        }

        if let model = selection.removingPrefix(InferenceProviderID.openRouter.modelPrefix) {
            return ResolvedModel(
                provider: OpenRouterProvider.fromSettings(),
                modelID: model,
                capabilities: SettingsStorage.capabilities(for: selection)
            )
        }

        throw InferenceError.unknownModel(modelSelection)
    }

    /// Runs a chat completion and returns the full response text.
    ///
    /// When `tools` is non-empty, the tools are offered to the model and any
    /// tool calls it makes are executed locally, with results fed back until
    /// the model produces a final text answer (an agentic loop).
    func complete(
        messages: [InferenceMessage],
        model modelSelection: String,
        temperature: Double? = nil,
        reasoningEffort: ModelReasoningEffort? = nil,
        systemPromptMode: InferenceSystemPromptMode = .prependPersona,
        tools: [any Tool] = []
    ) async throws -> String {
        let resolved = try resolve(modelSelection)
        let client = try resolved.provider.makeClient()

        let supportsImages = resolved.capabilities.contains(.vision)
        let supportsTools = resolved.capabilities.contains(.tools)
        let effectiveReasoningEffort = Self.effectiveReasoningEffort(
            reasoningEffort,
            capabilities: resolved.capabilities
        )

        let preparedMessages = Self.messagesByApplyingSystemPromptMode(
            messages,
            systemPromptMode: systemPromptMode
        )
        Self.logFormattedSystemPrompt(
            in: preparedMessages,
            providerID: resolved.provider.id,
            modelID: resolved.modelID
        )

        var chatMessages = preparedMessages.map { $0.chatParam(includingImages: supportsImages) }
        let toolParams = supportsTools && !tools.isEmpty ? try tools.map { try $0.chatToolParam() } : nil
        let maxRounds = 8

        for _ in 0..<maxRounds {
            let query = Self.makeChatQuery(
                messages: chatMessages,
                modelID: resolved.modelID,
                temperature: temperature,
                reasoningEffort: effectiveReasoningEffort,
                tools: toolParams
            )

            Self.logger.info("""
                Requesting completion via \(resolved.provider.id.rawValue, privacy: .public) \
                model \(resolved.modelID, privacy: .public) \
                with \(toolParams?.count ?? 0, privacy: .public) tools
                """)

            let result: ChatResult
            do {
                result = try await client.complete(query: query)
            } catch {
                Self.logger.error("""
                    Completion via \(resolved.provider.id.rawValue, privacy: .public) \
                    model \(resolved.modelID, privacy: .public) failed: \
                    \(String(describing: error))
                    """)
                throw error
            }

            let message = result.choices.first?.message

            Self.logger.info("""
                Response finish_reason \
                \(result.choices.first?.finishReason ?? "nil", privacy: .public), \
                \(message?.toolCalls?.count ?? 0, privacy: .public) tool calls
                """)

            if let toolCalls = message?.toolCalls, !toolCalls.isEmpty {
                chatMessages.append(.assistant(.init(
                    content: message?.content.map { .textContent($0) },
                    toolCalls: toolCalls
                )))

                for call in toolCalls {
                    let output = await Self.executeToolCall(call, tools: tools)
                    chatMessages.append(.tool(.init(
                        content: .textContent(output),
                        toolCallId: call.id
                    )))
                }

                continue
            }

            guard let content = message?.content,
                  !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                Self.logger.error("""
                    Completion via \(resolved.provider.id.rawValue, privacy: .public) \
                    model \(resolved.modelID, privacy: .public) returned no content
                    """)
                throw InferenceError.emptyResponse
            }

            Self.logger.info("""
                Completion via \(resolved.provider.id.rawValue, privacy: .public) \
                model \(resolved.modelID, privacy: .public) succeeded \
                (\(content.count, privacy: .public) characters)
                """)

            return content
        }

        Self.logger.error("Tool-calling loop exceeded \(maxRounds, privacy: .public) rounds")
        throw InferenceError.toolLoopLimitReached(maxRounds)
    }

    /// Executes a single model-requested tool call, returning the output or
    /// an error description for the model to react to.
    private static func executeToolCall(
        _ call: ChatQuery.ChatCompletionMessageParam.AssistantMessageParam.ToolCallParam,
        tools: [any Tool]
    ) async -> String {
        let toolName = call.function.name

        guard let tool = tools.first(where: { $0.name == toolName }) else {
            logger.error("Model requested unknown tool \(toolName, privacy: .public)")
            return "Error: unknown tool \"\(toolName)\"."
        }

        logger.info("Executing tool \(toolName, privacy: .public)")

        do {
            let output = try await tool.execute(argumentsJSON: call.function.arguments)
            logger.info("""
                Tool \(toolName, privacy: .public) succeeded \
                (\(output.count, privacy: .public) characters)
                """)
            return output
        } catch {
            logger.error("""
                Tool \(toolName, privacy: .public) failed: \
                \(String(describing: error))
                """)
            return "Error: \(error.localizedDescription)"
        }
    }

    /// Runs a chat completion, streaming response text deltas as they arrive.
    func streamCompletion(
        messages: [InferenceMessage],
        model modelSelection: String,
        temperature: Double? = nil,
        systemPromptMode: InferenceSystemPromptMode = .prependPersona
    ) throws -> AsyncThrowingStream<String, Error> {
        let resolved = try resolve(modelSelection)
        let client = try resolved.provider.makeClient()
        let supportsImages = resolved.capabilities.contains(.vision)

        let preparedMessages = Self.messagesByApplyingSystemPromptMode(
            messages,
            systemPromptMode: systemPromptMode
        )
        Self.logFormattedSystemPrompt(
            in: preparedMessages,
            providerID: resolved.provider.id,
            modelID: resolved.modelID
        )

        let query = ChatQuery(
            messages: preparedMessages.map { $0.chatParam(includingImages: supportsImages) },
            model: resolved.modelID,
            temperature: temperature
        )

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await chunk in client.streamCompletion(query: query) {
                        if let delta = chunk.choices.first?.delta.content, !delta.isEmpty {
                            continuation.yield(delta)
                        }
                    }

                    continuation.finish()
                } catch {
                    Self.logger.error("""
                        Streaming via \(resolved.provider.id.rawValue, privacy: .public) \
                        model \(resolved.modelID, privacy: .public) failed: \
                        \(String(describing: error))
                        """)
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func effectiveReasoningEffort(
        _ reasoningEffort: ModelReasoningEffort?,
        capabilities: Set<ModelCapability>
    ) -> ModelReasoningEffort? {
        capabilities.contains(.reasoning) ? reasoningEffort : nil
    }

    static func messagesByApplyingSystemPromptMode(
        _ messages: [InferenceMessage],
        systemPromptMode: InferenceSystemPromptMode,
        personaPrompt: String = AssistantPersona.personaPrompt(),
        conversationalOutputPrompt: String = AssistantPersona.conversationalOutputPrompt
    ) -> [InferenceMessage] {
        guard systemPromptMode == .prependPersona else {
            return messages
        }

        let trimmedPersonaPrompt = personaPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedConversationalOutputPrompt = conversationalOutputPrompt
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedPersonaPrompt.isEmpty || !trimmedConversationalOutputPrompt.isEmpty else {
            return messages
        }

        let legacyPrompt = AssistantPersona.legacyDefaultSystemPrompt
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var systemPrompts: [String] = []
        var nonSystemMessages: [InferenceMessage] = []

        for message in messages {
            switch message {
            case .system(let content):
                let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedContent.isEmpty && trimmedContent != legacyPrompt {
                    systemPrompts.append(trimmedContent)
                }
            case .user, .assistant:
                nonSystemMessages.append(message)
            }
        }

        let basePrompts = [trimmedPersonaPrompt, trimmedConversationalOutputPrompt]
            .filter { !$0.isEmpty }
        let combinedSystemPrompt = (basePrompts + systemPrompts)
            .joined(separator: "\n\n")

        return [.system(combinedSystemPrompt)] + nonSystemMessages
    }

    private static func logFormattedSystemPrompt(
        in messages: [InferenceMessage],
        providerID: InferenceProviderID,
        modelID: String
    ) {
        let systemPrompts = messages.compactMap { message -> String? in
            guard case .system(let content) = message else {
                return nil
            }

            return content
        }

        let formattedPrompt = systemPrompts.isEmpty
            ? "(none)"
            : systemPrompts.joined(separator: "\n\n")

        logger.info("""
            Formatted system prompt sent via \(providerID.rawValue, privacy: .public) \
            model \(modelID, privacy: .public):
            \(formattedPrompt, privacy: .public)
            """)
    }

    static func makeChatQuery(
        messages: [ChatQuery.ChatCompletionMessageParam],
        modelID: String,
        temperature: Double?,
        reasoningEffort: ModelReasoningEffort?,
        tools: [ChatQuery.ChatCompletionToolParam]?
    ) -> ChatQuery {
        ChatQuery(
            messages: messages,
            model: modelID,
            reasoningEffort: reasoningEffort?.chatQueryReasoningEffort,
            temperature: temperature,
            tools: tools
        )
    }
}

private extension ModelReasoningEffort {
    var chatQueryReasoningEffort: ChatQuery.ReasoningEffort {
        switch self {
        case .off: .none
        case .minimal: .minimal
        case .low: .low
        case .medium: .medium
        case .high: .high
        }
    }
}
