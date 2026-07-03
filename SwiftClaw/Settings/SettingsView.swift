import SwiftUI

enum SettingsSection: String, CaseIterable, Hashable, Identifiable {
    case appearance = "Appearance"
    case persona = "Persona"
    case personality = "Personality"
    case providers = "Providers"
    case behaviors = "Model Behaviors"
    case email = "Email"
    case tools = "Tools"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .appearance: "paintpalette"
        case .persona: "person.crop.circle"
        case .personality: "wand.and.sparkles"
        case .providers: "server.rack"
        case .behaviors: "slider.horizontal.3"
        case .email: "envelope"
        case .tools: "wrench.and.screwdriver"
        }
    }
}

#if DEBUG
private extension SettingsSection {
    init?(launchArgument: String) {
        switch launchArgument.lowercased().filter(\.isLetter) {
        case "appearance":
            self = .appearance
        case "persona":
            self = .persona
        case "personality":
            self = .personality
        case "providers":
            self = .providers
        case "behaviors", "modelbehaviors":
            self = .behaviors
        case "email":
            self = .email
        case "tools":
            self = .tools
        default:
            return nil
        }
    }
}
#endif

struct SettingsView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var router = AppRouter.shared
    @State private var selectedSection: SettingsSection? = .appearance
    @State private var compactNavigationPath: [SettingsSection] = []
    @State private var backStack: [SettingsSection] = []
    @State private var forwardStack: [SettingsSection] = []
    @State private var hasAppliedLaunchSettingsSection = false
    /// Set right before a back/forward assignment so the `onChange` observer
    /// knows not to treat that assignment as a new user navigation.
    @State private var isNavigatingViaHistory = false

    var body: some View {
        Group {
            if horizontalSizeClass == .compact {
                compactBody
            } else {
                regularBody
            }
        }
        .onAppear(perform: applyLaunchSettingsSectionIfNeeded)
        .onAppear(perform: applyRequestedSettingsSectionIfNeeded)
        .onChange(of: router.pendingSettingsSection) { _, _ in
            applyRequestedSettingsSectionIfNeeded()
        }
    }

    private var regularBody: some View {
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
            #if os(macOS)
            .toolbar(removing: .sidebarToggle)
            #endif
        } detail: {
            detailContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle(selectedSection?.rawValue ?? "Settings")
        }
        .toolbar {
            #if os(macOS)
            ToolbarItemGroup(placement: .navigation) {
                Button("Back", systemImage: "chevron.left", action: goBack)
                    .disabled(backStack.isEmpty)
                    .keyboardShortcut("[", modifiers: .command)
                Button("Forward", systemImage: "chevron.right", action: goForward)
                    .disabled(forwardStack.isEmpty)
                    .keyboardShortcut("]", modifiers: .command)
            }
            #endif
        }
        #if os(macOS)
        .frame(minWidth: 640, minHeight: 560)
        #endif
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

    private var compactBody: some View {
        NavigationStack(path: $compactNavigationPath) {
            List(SettingsSection.allCases) { section in
                NavigationLink(value: section) {
                    Label(section.rawValue, systemImage: section.systemImage)
                }
            }
            .navigationTitle("Settings")
            .navigationDestination(for: SettingsSection.self) { section in
                sectionContent(for: section)
                    .navigationTitle(section.rawValue)
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

    private func applyLaunchSettingsSectionIfNeeded() {
        #if DEBUG
        guard !hasAppliedLaunchSettingsSection else { return }
        hasAppliedLaunchSettingsSection = true

        guard let requestedSection = ProcessInfo.processInfo.argumentValue(after: "-SwiftClawInitialSettingsSection"),
              let section = SettingsSection(launchArgument: requestedSection) else { return }

        selectedSection = section
        if horizontalSizeClass == .compact {
            compactNavigationPath = [section]
        }
        #else
        hasAppliedLaunchSettingsSection = true
        #endif
    }

    private func applyRequestedSettingsSectionIfNeeded() {
        guard let requestedSection = router.pendingSettingsSection else { return }

        selectedSection = requestedSection
        if horizontalSizeClass == .compact {
            compactNavigationPath = [requestedSection]
        }
        router.clearPendingSettingsSection(requestedSection)
    }

    @ViewBuilder
    private var detailContent: some View {
        if let selectedSection {
            sectionContent(for: selectedSection)
        } else {
            Text("Select a settings section")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func sectionContent(for section: SettingsSection) -> some View {
        switch section {
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
        case .tools:
            ToolsView()
        }
    }
}
