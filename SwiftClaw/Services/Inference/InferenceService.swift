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
enum InferenceMessage: Sendable {
    case system(String)
    case user(String, imageAttachments: [ImageAttachmentRecord] = [])
    case assistant(String)

    var chatParam: ChatQuery.ChatCompletionMessageParam {
        switch self {
        case .system(let content):
            return ChatQuery.ChatCompletionMessageParam.system(.init(content: .textContent(content)))
        case .user(let content, let imageAttachments):
            let imageData = imageAttachments.compactMap { attachment in
                try? Data(contentsOf: attachment.fileURL)
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

/// A model selection resolved to its provider and provider-specific model identifier.
struct ResolvedModel: Sendable {
    let provider: any OpenAICompatibleProvider

    /// Identifier sent to the API: the deployment name for Azure, the model name otherwise.
    let modelID: String
}

/// Runs chat completions against whichever provider backs a configured model.
///
/// Model selections are the namespaced strings produced by
/// `SettingsStorage.availableModels` and stored by the settings pickers,
/// e.g. "Azure: gpt-4o" or "OpenRouter: openai/gpt-4o-mini".
struct InferenceService: Sendable {
    static let shared = InferenceService()

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.caffeineplz.SwiftClaw",
        category: "InferenceService"
    )

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
                modelID: deployment.deploymentName
            )
        }

        if let model = selection.removingPrefix(InferenceProviderID.neuralwatt.modelPrefix) {
            return ResolvedModel(provider: NeuralwattProvider.fromSettings(), modelID: model)
        }

        if let model = selection.removingPrefix(InferenceProviderID.openRouter.modelPrefix) {
            return ResolvedModel(provider: OpenRouterProvider.fromSettings(), modelID: model)
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
        tools: [any Tool] = []
    ) async throws -> String {
        let resolved = try resolve(modelSelection)
        let client = try resolved.provider.makeClient()

        var chatMessages = messages.map(\.chatParam)
        let toolParams = tools.isEmpty ? nil : try tools.map { try $0.chatToolParam() }
        let maxRounds = 8

        for _ in 0..<maxRounds {
            let query = ChatQuery(
                messages: chatMessages,
                model: resolved.modelID,
                temperature: temperature,
                tools: toolParams
            )

            Self.logger.info("""
                Requesting completion via \(resolved.provider.id.rawValue, privacy: .public) \
                model \(resolved.modelID, privacy: .public) \
                with \(toolParams?.count ?? 0, privacy: .public) tools
                """)

            let result: ChatResult
            do {
                result = try await client.chats(query: query)
            } catch {
                Self.logger.error("""
                    Completion via \(resolved.provider.id.rawValue, privacy: .public) \
                    model \(resolved.modelID, privacy: .public) failed: \
                    \(String(describing: error), privacy: .public)
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
                \(String(describing: error), privacy: .public)
                """)
            return "Error: \(error.localizedDescription)"
        }
    }

    /// Runs a chat completion, streaming response text deltas as they arrive.
    func streamCompletion(
        messages: [InferenceMessage],
        model modelSelection: String,
        temperature: Double? = nil
    ) throws -> AsyncThrowingStream<String, Error> {
        let resolved = try resolve(modelSelection)
        let client = try resolved.provider.makeClient()

        let query = ChatQuery(
            messages: messages.map(\.chatParam),
            model: resolved.modelID,
            temperature: temperature
        )

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await chunk in client.chatsStream(query: query) {
                        if let delta = chunk.choices.first?.delta.content, !delta.isEmpty {
                            continuation.yield(delta)
                        }
                    }

                    continuation.finish()
                } catch {
                    Self.logger.error("""
                        Streaming via \(resolved.provider.id.rawValue, privacy: .public) \
                        model \(resolved.modelID, privacy: .public) failed: \
                        \(String(describing: error), privacy: .public)
                        """)
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private extension String {
    func removingPrefix(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else {
            return nil
        }

        return String(dropFirst(prefix.count))
    }
}
