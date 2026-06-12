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
    static let azureResourceName = "settings.azure.resourceName"
    static let azureAPIKey = "settings.azure.apiKey"
    static let azureDeployments = "settings.azure.deployments"
    static let neuralwattAPIKey = "settings.neuralwatt.apiKey"
    static let neuralwattModels = "settings.neuralwatt.models"
    static let openRouterAPIKey = "settings.openRouter.apiKey"
    static let openRouterModels = "settings.openRouter.models"
    static let swiftModel = "settings.behaviors.swiftModel"
    static let clawModel = "settings.behaviors.clawModel"
    static let deepResearchModel = "settings.behaviors.deepResearchModel"
    static let homeModel = "settings.home.model"
}

struct AzureDeployment: Identifiable, Codable, Hashable {
    var id = UUID()
    var deploymentName: String
    var displayName: String

    var modelPickerTitle: String {
        if displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return deploymentName
        }

        return displayName
    }
}

enum SettingsStorage {
    static func loadAvailableModels() -> [String] {
        availableModels(
            azureDeployments: loadDeployments(),
            neuralwattModels: loadStringList(forKey: SettingsKeys.neuralwattModels),
            openRouterModels: loadStringList(forKey: SettingsKeys.openRouterModels)
        )
    }

    static func availableModels(
        azureDeployments: [AzureDeployment],
        neuralwattModels: [String],
        openRouterModels: [String]
    ) -> [String] {
        let azureModels = azureDeployments.map { deployment in
            InferenceProviderID.azure.modelPrefix + deployment.modelPickerTitle
        }
        let neuralwatt = neuralwattModels.map { InferenceProviderID.neuralwatt.modelPrefix + $0 }
        let openRouter = openRouterModels.map { InferenceProviderID.openRouter.modelPrefix + $0 }

        return azureModels + neuralwatt + openRouter
    }

    static func loadDeployments() -> [AzureDeployment] {
        guard let data = UserDefaults.standard.data(forKey: SettingsKeys.azureDeployments) else {
            return []
        }

        return (try? JSONDecoder().decode([AzureDeployment].self, from: data)) ?? []
    }

    static func saveDeployments(_ deployments: [AzureDeployment]) {
        guard let data = try? JSONEncoder().encode(deployments) else {
            return
        }

        UserDefaults.standard.set(data, forKey: SettingsKeys.azureDeployments)
    }

    static func loadStringList(forKey key: String) -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    static func saveStringList(_ values: [String], forKey key: String) {
        UserDefaults.standard.set(values, forKey: key)
    }
}
