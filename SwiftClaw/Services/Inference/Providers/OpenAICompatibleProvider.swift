import Foundation

/// An inference provider that exposes an OpenAI-compatible chat completions API.
///
/// Non-OpenAI-compatible providers can be added later by introducing sibling
/// protocols and teaching ``InferenceService`` how to call them.
protocol OpenAICompatibleProvider: Sendable {
    var id: InferenceProviderID { get }

    /// API key for the provider, or nil when none is stored.
    var apiKey: String? { get }

    /// Provider endpoint metadata, including provider-specific URL, auth,
    /// header, and query-string quirks.
    func endpoint() throws -> OpenAICompatibleEndpoint
}

extension OpenAICompatibleProvider {
    /// Builds an OpenAI client pointed at this provider's endpoint.
    func makeClient() throws -> OpenAICompatibleClient {
        guard let apiKey, !apiKey.isEmpty else {
            throw InferenceError.providerNotConfigured(id, reason: "missing API key")
        }

        return OpenAICompatibleClient(
            providerID: id,
            endpoint: try endpoint(),
            apiKey: apiKey
        )
    }
}
