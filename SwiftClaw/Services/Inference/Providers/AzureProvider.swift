import Foundation

/// Azure AI Foundry's OpenAI-compatible endpoint:
/// `https://{resource-name}.services.ai.azure.com/openai/v1`
struct AzureProvider: OpenAICompatibleProvider {
    let resourceName: String
    let apiKey: String?

    var id: InferenceProviderID { .azure }

    func endpoint() throws -> OpenAICompatibleEndpoint {
        let trimmedName = resourceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw InferenceError.providerNotConfigured(id, reason: "missing resource name")
        }

        return OpenAICompatibleEndpoint(
            host: "\(trimmedName).services.ai.azure.com",
            basePath: "/openai/v1"
        )
    }

    static func fromSettings() -> AzureProvider {
        AzureProvider(
            resourceName: UserDefaults.standard.string(forKey: SettingsKeys.azureResourceName) ?? "",
            apiKey: Keychain.string(forKey: SettingsKeys.azureAPIKey)
        )
    }
}
