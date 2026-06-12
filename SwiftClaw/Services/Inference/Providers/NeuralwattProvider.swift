import Foundation

/// Neuralwatt's OpenAI-compatible endpoint: `https://api.neuralwatt.com/v1`
struct NeuralwattProvider: OpenAICompatibleProvider {
    let apiKey: String?

    var id: InferenceProviderID { .neuralwatt }

    func endpoint() throws -> (host: String, basePath: String) {
        ("api.neuralwatt.com", "/v1")
    }

    static func fromSettings() -> NeuralwattProvider {
        NeuralwattProvider(apiKey: Keychain.string(forKey: SettingsKeys.neuralwattAPIKey))
    }
}
