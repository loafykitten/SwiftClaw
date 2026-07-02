import SwiftUI

private enum SettingsSection: String, CaseIterable, Hashable, Identifiable {
    case appearance = "Appearance"
    case persona = "Persona"
    case personality = "Personality"
    case providers = "Providers"
    case behaviors = "Model Behaviors"
    case email = "Email"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .appearance: "paintpalette"
        case .persona: "person.crop.circle"
        case .personality: "wand.and.sparkles"
        case .providers: "server.rack"
        case .behaviors: "slider.horizontal.3"
        case .email: "envelope"
        }
    }
}

struct SettingsView: View {
    @State private var selectedSection: SettingsSection? = .appearance
    @AppStorage(SettingsKeys.accentHue) private var accentHue = AccentColor.defaultHue
    @AppStorage(SettingsKeys.accentLightness) private var accentLightness = AccentColor.defaultLightness

    private var accent: Color {
        AccentColor.color(hue: accentHue, lightness: accentLightness)
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedSection) {
                ForEach(SettingsSection.allCases) { section in
                    Label(section.rawValue, systemImage: section.systemImage)
                        .tag(section)
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("Settings")
            .frame(minWidth: 180)
        } detail: {
            detailContent
                .navigationTitle(selectedSection?.rawValue ?? "Settings")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .tint(accent)
        .frame(minWidth: 640, minHeight: 560)
    }

    @ViewBuilder
    private var detailContent: some View {
        switch selectedSection {
        case .appearance:
            AppearanceSettingsView()
        case .persona:
            PersonaSettingsView()
        case .personality:
            PersonalitySettingsView()
        case .providers:
            ProviderSettingsView()
        case .behaviors:
            BehaviorSettingsView()
        case .email:
            EmailSettingsView()
        case nil:
            Text("Select a settings section")
                .foregroundStyle(.secondary)
        }
    }
}
