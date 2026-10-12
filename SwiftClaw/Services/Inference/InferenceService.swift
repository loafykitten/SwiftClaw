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

    var chatParam: ChatQuery.ChatCompletionMessageParam {
        get async {
            await chatParam(includingImages: true)
        }
    }

    func chatParam(includingImages: Bool) async -> ChatQuery.ChatCompletionMessageParam {
        switch self {
        case .system(let content):
            return ChatQuery.ChatCompletionMessageParam.system(.init(content: .textContent(content)))
        case .user(let content, let imageAttachments):
            var imageData: [Data] = []
            if includingImages {
                for attachment in imageAttachments {
                    if let data = await InferenceImageDataCache.shared.data(for: attachment) {
                        imageData.append(data)
                    }
                }
            }

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

private actor InferenceImageDataCache {
    static let shared = InferenceImageDataCache()

    private let capacity = 40
    private var dataByAttachment: [ImageAttachmentRecord: Data] = [:]
    private var insertionOrder: [ImageAttachmentRecord] = []

    func data(for attachment: ImageAttachmentRecord) -> Data? {
        // Chat image files are immutable. Exact record equality (including
        // path, byte count, and creation date) invalidates relocated/replaced
        // attachments, while the bounded FIFO keeps stale entries finite.
        if let cached = dataByAttachment[attachment] {
            return cached
        }

        do {
            let data = try Data(contentsOf: attachment.fileURL)
            dataByAttachment[attachment] = data
            insertionOrder.append(attachment)
            if insertionOrder.count > capacity {
                dataByAttachment.removeValue(forKey: insertionOrder.removeFirst())
            }
            return data
        } catch {
            AppLog.make("InferenceMessage").warning("""
                Skipping unreadable image attachment \(attachment.filePath): \
                \(String(describing: error))
                """)
            return nil
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
        tools: [any Tool] = [],
        contextTokenBudget: Int? = nil
    ) async throws -> String {
        let resolved = try resolve(modelSelection)
        let client = try resolved.provider.makeClient()

        let supportsTools = resolved.capabilities.contains(.tools)
        let effectiveReasoningEffort = Self.effectiveReasoningEffort(
            reasoningEffort,
            capabilities: resolved.capabilities
        )

        var preparedMessages = Self.messagesByApplyingSystemPromptMode(
            messages,
            systemPromptMode: systemPromptMode
        )
        if let contextTokenBudget {
            preparedMessages = Self.messagesTrimmedToTokenBudget(
                preparedMessages,
                budget: contextTokenBudget
            )
        }
        Self.logFormattedSystemPrompt(
            in: preparedMessages,
            providerID: resolved.provider.id,
            modelID: resolved.modelID
        )

        var chatMessages = await Self.chatParams(
            for: preparedMessages,
            capabilities: resolved.capabilities
        )
        let toolParams = supportsTools && !tools.isEmpty ? try tools.map { try $0.chatToolParam() } : nil
        let maxRounds = 8

        for _ in 0..<maxRounds {
            try Task.checkCancellation()
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

                chatMessages += try await Self.toolResultMessages(for: toolCalls, tools: tools)
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

    /// Executes one response's tool calls in order and returns their result
    /// messages. Cancellation ends the round: once the completion is
    /// cancelled, no later call in the batch may run (and mutate memory,
    /// proposals, or other state).
    static func toolResultMessages(
        for calls: [ChatQuery.ChatCompletionMessageParam.AssistantMessageParam.ToolCallParam],
        tools: [any Tool]
    ) async throws -> [ChatQuery.ChatCompletionMessageParam] {
        var messages = [ChatQuery.ChatCompletionMessageParam]()
        for call in calls {
            try Task.checkCancellation()
            let output = try await executeToolCall(call, tools: tools)
            messages.append(.tool(.init(
                content: .textContent(output),
                toolCallId: call.id
            )))
        }
        return messages
    }

    /// Executes a single model-requested tool call, returning the output or
    /// an error description for the model to react to. Cancellation is
    /// rethrown rather than reported to the model.
    private static func executeToolCall(
        _ call: ChatQuery.ChatCompletionMessageParam.AssistantMessageParam.ToolCallParam,
        tools: [any Tool]
    ) async throws -> String {
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
            if error is CancellationError || Task.isCancelled {
                logger.info("Tool \(toolName, privacy: .public) cancelled")
                throw CancellationError()
            }
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
        let preparedMessages = Self.messagesByApplyingSystemPromptMode(
            messages,
            systemPromptMode: systemPromptMode
        )
        Self.logFormattedSystemPrompt(
            in: preparedMessages,
            providerID: resolved.provider.id,
            modelID: resolved.modelID
        )

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let chatMessages = await Self.chatParams(
                        for: preparedMessages,
                        capabilities: resolved.capabilities
                    )
                    let query = ChatQuery(
                        messages: chatMessages,
                        model: resolved.modelID,
                        temperature: temperature
                    )
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

    static func chatParams(
        for messages: [InferenceMessage],
        capabilities: Set<ModelCapability>
    ) async -> [ChatQuery.ChatCompletionMessageParam] {
        let includingImages = capabilities.contains(.vision)
        var params: [ChatQuery.ChatCompletionMessageParam] = []
        params.reserveCapacity(messages.count)
        for message in messages {
            params.append(await message.chatParam(includingImages: includingImages))
        }
        return params
    }

    static func messagesTrimmedToTokenBudget(
        _ messages: [InferenceMessage],
        budget: Int
    ) -> [InferenceMessage] {
        let systemMessages = messages.filter(\.isSystem)
        let conversationalMessages = messages.filter { !$0.isSystem }
        let remainingBudget = max(
            0,
            budget - systemMessages.reduce(0) { $0 + $1.estimatedTokens }
        )
        let turns = conversationalMessages.reduce(into: [[InferenceMessage]]()) { turns, message in
            if message.isUser || turns.isEmpty {
                turns.append([message])
            } else {
                turns[turns.index(before: turns.endIndex)].append(message)
            }
        }

        var retainedTurns: [[InferenceMessage]] = []
        var usedTokens = 0
        for turn in turns.reversed() {
            let turnTokens = turn.reduce(0) { $0 + $1.estimatedTokens }
            if !retainedTurns.isEmpty, usedTokens + turnTokens > remainingBudget {
                break
            }
            retainedTurns.append(turn)
            usedTokens += turnTokens
        }

        return systemMessages + retainedTurns.reversed().flatMap { $0 }
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

        // Only the size is logged: the prompt carries persona text, injected
        // memories, and email/calendar context that must not reach the logs.
        let characterCount = systemPrompts.reduce(0) { $0 + $1.count }

        logger.info("""
            System prompt sent via \(providerID.rawValue, privacy: .public) \
            model \(modelID, privacy: .public): \
            \(systemPrompts.count) parts, \(characterCount) characters
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

private extension InferenceMessage {
    var isSystem: Bool {
        if case .system = self { return true }
        return false
    }

    var isUser: Bool {
        if case .user = self { return true }
        return false
    }

    var estimatedTokens: Int {
        switch self {
        case .system(let content), .user(let content, _), .assistant(let content):
            TokenEstimator.estimatedTokens(for: content)
        }
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
