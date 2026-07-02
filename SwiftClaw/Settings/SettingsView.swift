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
    @State private var backStack: [SettingsSection] = []
    @State private var forwardStack: [SettingsSection] = []
    /// Set right before a back/forward assignment so the `onChange` observer
    /// knows not to treat that assignment as a new user navigation.
    @State private var isNavigatingViaHistory = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedSection) {
                ForEach(SettingsSection.allCases) { section in
                    Label(section.rawValue, systemImage: section.systemImage)
                        .listItemTint(.monochrome)
                        .tag(section)
                }
            }
            .listStyle(.sidebar)
            .frame(minWidth: 180)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            detailContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle(selectedSection?.rawValue ?? "Settings")
        }
        .frame(minWidth: 640, minHeight: 560)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button("Back", systemImage: "chevron.left", action: goBack)
                    .disabled(backStack.isEmpty)
                    .keyboardShortcut("[", modifiers: .command)
                Button("Forward", systemImage: "chevron.right", action: goForward)
                    .disabled(forwardStack.isEmpty)
                    .keyboardShortcut("]", modifiers: .command)
            }
        }
        .onChange(of: selectedSection) { oldValue, _ in
            guard !isNavigatingViaHistory else {
                isNavigatingViaHistory = false
                return
            }
            if let oldValue {
                backStack.append(oldValue)
                forwardStack.removeAll()
            }
        }
    }

    private func goBack() {
        guard let previous = backStack.popLast(), let current = selectedSection else { return }
        forwardStack.append(current)
        isNavigatingViaHistory = true
        selectedSection = previous
    }

    private func goForward() {
        guard let next = forwardStack.popLast(), let current = selectedSection else { return }
        backStack.append(current)
        isNavigatingViaHistory = true
        selectedSection = next
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
