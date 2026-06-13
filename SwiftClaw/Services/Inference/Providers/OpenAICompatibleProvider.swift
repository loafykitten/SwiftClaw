import Foundation
import OpenAI

/// An inference provider that exposes an OpenAI-compatible chat completions API.
///
/// Non-OpenAI-compatible providers can be added later by introducing sibling
/// protocols and teaching ``InferenceService`` how to call them.
protocol OpenAICompatibleProvider: Sendable {
    var id: InferenceProviderID { get }

    /// API key for the provider, or nil when none is stored.
    var apiKey: String? { get }

    /// Host and base path of the provider's OpenAI-compatible endpoint.
    /// Throws when required configuration (such as the Azure resource name) is missing.
    func endpoint() throws -> (host: String, basePath: String)
}

extension OpenAICompatibleProvider {
    /// Builds an OpenAI client pointed at this provider's endpoint.
    func makeClient() throws -> OpenAI {
        guard let apiKey, !apiKey.isEmpty else {
            throw InferenceError.providerNotConfigured(id, reason: "missing API key")
        }

        let endpoint = try endpoint()

        return OpenAI(configuration: OpenAI.Configuration(
            token: apiKey,
            host: endpoint.host,
            basePath: endpoint.basePath,
            // Generous timeout: investigation runs and slower local models
            // routinely outlive the library's 60s default.
            timeoutInterval: 300,
            // OpenAI-compatible providers commonly omit fields the strict
            // decoder treats as required.
            parsingOptions: .relaxed
        ))
    }
}
