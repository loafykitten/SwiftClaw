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

    var errorDescription: String? {
        switch self {
        case .providerNotConfigured(let provider, let reason):
            "\(provider.rawValue) is not configured: \(reason)."
        case .unknownModel(let model):
            "No configured provider matches the model \"\(model)\"."
        case .emptyResponse:
            "The model returned an empty response."
        }
    }
}

/// A chat message passed to ``InferenceService``.
enum InferenceMessage: Sendable {
    case system(String)
    case user(String)
    case assistant(String)

    var chatParam: ChatQuery.ChatCompletionMessageParam {
        switch self {
        case .system(let content): .system(.init(content: .textContent(content)))
        case .user(let content): .user(.init(content: .string(content)))
        case .assistant(let content): .assistant(.init(content: .textContent(content)))
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
    func complete(
        messages: [InferenceMessage],
        model modelSelection: String,
        temperature: Double? = nil
    ) async throws -> String {
        let resolved = try resolve(modelSelection)
        let client = try resolved.provider.makeClient()

        let query = ChatQuery(
            messages: messages.map(\.chatParam),
            model: resolved.modelID,
            temperature: temperature
        )

        Self.logger.info("""
            Requesting completion via \(resolved.provider.id.rawValue, privacy: .public) \
            model \(resolved.modelID, privacy: .public)
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

        guard let content = result.choices.first?.message.content,
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
