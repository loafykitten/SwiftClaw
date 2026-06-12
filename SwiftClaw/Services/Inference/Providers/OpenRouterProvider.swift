import Foundation

/// OpenRouter's OpenAI-compatible endpoint: `https://openrouter.ai/api/v1`
struct OpenRouterProvider: OpenAICompatibleProvider {
    let apiKey: String?

    var id: InferenceProviderID { .openRouter }

    func endpoint() throws -> (host: String, basePath: String) {
        ("openrouter.ai", "/api/v1")
    }

    static func fromSettings() -> OpenRouterProvider {
        OpenRouterProvider(apiKey: Keychain.string(forKey: SettingsKeys.openRouterAPIKey))
    }
}
