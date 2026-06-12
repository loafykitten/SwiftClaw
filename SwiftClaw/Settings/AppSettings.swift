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
    static let defaultBrightness = 0.82
    static let brightnessRange: ClosedRange<Double> = 0.2...1.0

    static func color(hue: Double, brightness: Double = defaultBrightness) -> Color {
        Color(
            hue: min(max(hue, 0), 1),
            saturation: 0.72,
            brightness: min(max(brightness, 0), 1)
        )
    }
}

enum SettingsKeys {
    static let theme = "settings.appearance.theme"
    static let accentHue = "settings.appearance.accentHue"
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
