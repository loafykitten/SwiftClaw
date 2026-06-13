import SwiftUI

enum AppTheme: String, CaseIterable, Identifiable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"

    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum AccentColor {
    static let defaultHue = 0.52
    static let defaultSaturation = 0.72
    static let defaultBrightness = 0.82
    static let defaultLightness = defaultBrightness * (2 - defaultSaturation) / 2
    static let defaultQuoteHue = 0.08
    static let defaultQuoteLightness = 0.62
    static let lightnessRange: ClosedRange<Double> = 0.18...0.95

    static func color(hue: Double, lightness: Double = defaultLightness) -> Color {
        let rgb = hslToRGB(
            hue: hue,
            saturation: defaultSaturation,
            lightness: min(max(lightness, lightnessRange.lowerBound), lightnessRange.upperBound)
        )

        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    static func migrateStoredLightnessIfNeeded(userDefaults: UserDefaults = .standard) {
        guard userDefaults.object(forKey: SettingsKeys.accentLightness) == nil else {
            return
        }

        guard userDefaults.object(forKey: SettingsKeys.accentBrightness) != nil else {
            return
        }

        let brightness = userDefaults.double(forKey: SettingsKeys.accentBrightness)
        let lightness = brightness * (2 - defaultSaturation) / 2
        userDefaults.set(
            min(max(lightness, lightnessRange.lowerBound), lightnessRange.upperBound),
            forKey: SettingsKeys.accentLightness
        )
    }

    private static func hslToRGB(hue: Double, saturation: Double, lightness: Double) -> (red: Double, green: Double, blue: Double) {
        let hue = min(max(hue, 0), 1)
        let saturation = min(max(saturation, 0), 1)
        let lightness = min(max(lightness, 0), 1)

        guard saturation > 0 else {
            return (lightness, lightness, lightness)
        }

        let chroma = (1 - abs(2 * lightness - 1)) * saturation
        let huePrime = hue == 1 ? 0 : hue * 6
        let x = chroma * (1 - abs(huePrime.truncatingRemainder(dividingBy: 2) - 1))
        let match = lightness - chroma / 2

        let rgb: (red: Double, green: Double, blue: Double)
        switch huePrime {
        case 0..<1:
            rgb = (chroma, x, 0)
        case 1..<2:
            rgb = (x, chroma, 0)
        case 2..<3:
            rgb = (0, chroma, x)
        case 3..<4:
            rgb = (0, x, chroma)
        case 4..<5:
            rgb = (x, 0, chroma)
        default:
            rgb = (chroma, 0, x)
        }

        return (rgb.red + match, rgb.green + match, rgb.blue + match)
    }
}

enum SettingsKeys {
    static let theme = "settings.appearance.theme"
    static let accentHue = "settings.appearance.accentHue"
    static let accentLightness = "settings.appearance.accentLightness"
    static let accentBrightness = "settings.appearance.accentBrightness"
    static let quoteAccentHue = "settings.appearance.quoteAccentHue"
    static let quoteAccentLightness = "settings.appearance.quoteAccentLightness"
    static let azureResourceName = "settings.azure.resourceName"
    static let azureAPIKey = "settings.azure.apiKey"
    static let azureDeployments = "settings.azure.deployments"
    static let neuralwattAPIKey = "settings.neuralwatt.apiKey"
    static let neuralwattModels = "settings.neuralwatt.models"
    static let openRouterAPIKey = "settings.openRouter.apiKey"
    static let braveSearchAPIKey = "settings.braveSearch.apiKey"
    static let braveSearchRequestsPerSecond = "settings.braveSearch.requestsPerSecond"
    static let investigationMaxSubAgents = "settings.tools.investigation.maxSubAgents"
    static let openRouterModels = "settings.openRouter.models"
    static let swiftModel = "settings.behaviors.swiftModel"
    static let clawModel = "settings.behaviors.clawModel"
    static let deepResearchModel = "settings.behaviors.deepResearchModel"
    static let homeModel = "settings.home.model"
    static let personaDisplayName = "settings.persona.displayName"
    static let personaAvatarData = "settings.persona.avatarData"
}

enum SettingsNotifications {
    static let keychainDidChange = Notification.Name("settings.keychain.didChange")
    static let changedKey = "changedKey"
}

struct AzureDeployment: Identifiable, Codable, Hashable {
    var id = UUID()
    var deploymentName: String
    var displayName: String
    var capabilities = ModelCapability.defaultCapabilities

    var modelPickerTitle: String {
        if displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return deploymentName
        }

        return displayName
    }

    init(
        id: UUID = UUID(),
        deploymentName: String,
        displayName: String,
        capabilities: Set<ModelCapability> = ModelCapability.defaultCapabilities
    ) {
        self.id = id
        self.deploymentName = deploymentName
        self.displayName = displayName
        self.capabilities = capabilities
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case deploymentName
        case displayName
        case capabilities
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        deploymentName = try container.decode(String.self, forKey: .deploymentName)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        capabilities = try container.decodeIfPresent(Set<ModelCapability>.self, forKey: .capabilities)
            ?? ModelCapability.defaultCapabilities
    }
}

enum ModelCapability: String, CaseIterable, Codable, Hashable, Identifiable {
    case reasoning
    case tools
    case vision
    case json

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .reasoning: "Reasoning"
        case .tools: "Tools"
        case .vision: "Vision"
        case .json: "JSON"
        }
    }

    static let defaultCapabilities: Set<ModelCapability> = [.vision, .json]
}

struct ProviderModel: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var capabilities = ModelCapability.defaultCapabilities

    init(
        id: UUID = UUID(),
        name: String,
        capabilities: Set<ModelCapability> = ModelCapability.defaultCapabilities
    ) {
        self.id = id
        self.name = name
        self.capabilities = capabilities
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case capabilities
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        capabilities = try container.decodeIfPresent(Set<ModelCapability>.self, forKey: .capabilities)
            ?? ModelCapability.defaultCapabilities
    }
}

enum ModelReasoningEffort: String, CaseIterable, Identifiable, Sendable {
    case off
    case minimal
    case low
    case medium
    case high

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off: "Off"
        case .minimal: "Minimal"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        }
    }

    var isReasoningEnabled: Bool {
        self != .off
    }
}

enum SettingsStorage {
    static func loadAvailableModels(userDefaults: UserDefaults = .standard) -> [String] {
        availableModels(
            azureDeployments: loadDeployments(userDefaults: userDefaults),
            neuralwattModels: loadProviderModels(forKey: SettingsKeys.neuralwattModels, userDefaults: userDefaults),
            openRouterModels: loadProviderModels(forKey: SettingsKeys.openRouterModels, userDefaults: userDefaults)
        )
    }

    static func availableModels(
        azureDeployments: [AzureDeployment],
        neuralwattModels: [ProviderModel],
        openRouterModels: [ProviderModel]
    ) -> [String] {
        let azureModels = azureDeployments.map { deployment in
            InferenceProviderID.azure.modelPrefix + deployment.modelPickerTitle
        }
        let neuralwatt = neuralwattModels.map { InferenceProviderID.neuralwatt.modelPrefix + $0.name }
        let openRouter = openRouterModels.map { InferenceProviderID.openRouter.modelPrefix + $0.name }

        return azureModels + neuralwatt + openRouter
    }

    static func capabilities(
        for modelSelection: String,
        userDefaults: UserDefaults = .standard
    ) -> Set<ModelCapability> {
        let selection = modelSelection.trimmingCharacters(in: .whitespacesAndNewlines)

        if let title = selection.removingPrefix(InferenceProviderID.azure.modelPrefix) {
            return loadDeployments(userDefaults: userDefaults)
                .first { $0.modelPickerTitle == title }?
                .capabilities ?? ModelCapability.defaultCapabilities
        }

        if let model = selection.removingPrefix(InferenceProviderID.neuralwatt.modelPrefix) {
            return loadProviderModels(forKey: SettingsKeys.neuralwattModels, userDefaults: userDefaults)
                .first { $0.name == model }?
                .capabilities ?? ModelCapability.defaultCapabilities
        }

        if let model = selection.removingPrefix(InferenceProviderID.openRouter.modelPrefix) {
            return loadProviderModels(forKey: SettingsKeys.openRouterModels, userDefaults: userDefaults)
                .first { $0.name == model }?
                .capabilities ?? ModelCapability.defaultCapabilities
        }

        return ModelCapability.defaultCapabilities
    }

    static func loadDeployments(userDefaults: UserDefaults = .standard) -> [AzureDeployment] {
        guard let data = userDefaults.data(forKey: SettingsKeys.azureDeployments) else {
            return []
        }

        return (try? JSONDecoder().decode([AzureDeployment].self, from: data)) ?? []
    }

    static func saveDeployments(_ deployments: [AzureDeployment], userDefaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(deployments) else {
            return
        }

        userDefaults.set(data, forKey: SettingsKeys.azureDeployments)
    }

    static func loadProviderModels(
        forKey key: String,
        userDefaults: UserDefaults = .standard
    ) -> [ProviderModel] {
        if let data = userDefaults.data(forKey: key),
           let models = try? JSONDecoder().decode([ProviderModel].self, from: data) {
            return models
        }

        return userDefaults.stringArray(forKey: key)?.map {
            ProviderModel(name: $0)
        } ?? []
    }

    static func saveProviderModels(
        _ models: [ProviderModel],
        forKey key: String,
        userDefaults: UserDefaults = .standard
    ) {
        guard let data = try? JSONEncoder().encode(models) else {
            return
        }

        userDefaults.set(data, forKey: key)
    }

    static let defaultBraveSearchRequestsPerSecond = 1.0
    static let braveSearchRequestsPerSecondRange: ClosedRange<Double> = 0.5...20

    static func loadBraveSearchRequestsPerSecond() -> Double {
        let stored = UserDefaults.standard.double(forKey: SettingsKeys.braveSearchRequestsPerSecond)

        guard stored > 0 else {
            return defaultBraveSearchRequestsPerSecond
        }

        return min(
            max(stored, braveSearchRequestsPerSecondRange.lowerBound),
            braveSearchRequestsPerSecondRange.upperBound
        )
    }

    static let defaultInvestigationMaxSubAgents = 3
    static let investigationMaxSubAgentsRange: ClosedRange<Int> = 1...5

    static func loadInvestigationMaxSubAgents() -> Int {
        let stored = UserDefaults.standard.integer(forKey: SettingsKeys.investigationMaxSubAgents)

        guard stored > 0 else {
            return defaultInvestigationMaxSubAgents
        }

        return min(
            max(stored, investigationMaxSubAgentsRange.lowerBound),
            investigationMaxSubAgentsRange.upperBound
        )
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
