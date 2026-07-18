import SwiftUI

enum SettingsSection: String, CaseIterable, Hashable, Identifiable {
    case appearance = "Appearance"
    case persona = "Persona"
    case personality = "Personality"
    case providers = "Providers"
    case behaviors = "Model Behaviors"
    // Always visible (not feature-gated): notification sources span Chats +
    // Email, so no single feature section fits.
    case notifications = "Notifications"
    case email = "Email"
    case calendar = "Calendar"
    case reminders = "Reminders"
    case notes = "Notes"
    case memory = "Memory"
    case tools = "Tools"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .appearance: "paintpalette"
        case .persona: "person.crop.circle"
        case .personality: "wand.and.sparkles"
        case .providers: "server.rack"
        case .behaviors: "slider.horizontal.3"
        case .notifications: "bell.badge"
        case .email: "envelope"
        case .calendar: "calendar"
        case .reminders: "checklist"
        case .notes: "note.text"
        case .memory: "brain"
        case .tools: "wrench.and.screwdriver"
        }
    }

    /// The toggleable feature backing this section; `nil` for always-visible
    /// sections. Feature-backed sections are hidden until enabled in Tools.
    var feature: WorkspaceFeature? {
        switch self {
        case .email: .email
        case .calendar: .calendar
        case .reminders: .reminders
        case .notes: .notes
        case .memory: .memory
        default: nil
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
        case "notifications":
            self = .notifications
        case "email":
            self = .email
        case "calendar":
            self = .calendar
        case "reminder", "reminders":
            self = .reminders
        case "note", "notes":
            self = .notes
        case "memory":
            self = .memory
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

    @AppStorage(SettingsKeys.emailEnabled) private var isEmailEnabled = SettingsStorage.defaultEmailEnabled
    @AppStorage(SettingsKeys.calendarEnabled) private var isCalendarEnabled = SettingsStorage.defaultCalendarEnabled
    @AppStorage(SettingsKeys.remindersEnabled) private var isRemindersEnabled = SettingsStorage.defaultRemindersEnabled
    @AppStorage(SettingsKeys.notesEnabled) private var isNotesEnabled = SettingsStorage.defaultNotesEnabled
    @AppStorage(SettingsKeys.memoryEnabled) private var isMemoryEnabled = SettingsStorage.defaultMemoryEnabled

    private var visibleSections: [SettingsSection] {
        SettingsSection.allCases.filter { section in
            section.feature.map(isFeatureEnabled) ?? true
        }
    }

    private func isFeatureEnabled(_ feature: WorkspaceFeature) -> Bool {
        switch feature {
        case .email: isEmailEnabled
        case .calendar: isCalendarEnabled
        case .reminders: isRemindersEnabled
        case .notes: isNotesEnabled
        case .memory: isMemoryEnabled
        }
    }

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
        .onChange(of: visibleSections) { _, newValue in
            pruneHiddenSections(visible: newValue)
        }
    }

    /// Drops sections that just became hidden from the selection, history
    /// stacks, and compact path so disabling a feature can't strand the
    /// window on (or navigate back to) a hidden section.
    private func pruneHiddenSections(visible: [SettingsSection]) {
        backStack.removeAll { !visible.contains($0) }
        forwardStack.removeAll { !visible.contains($0) }
        compactNavigationPath.removeAll { !visible.contains($0) }
        if let selectedSection, !visible.contains(selectedSection) {
            isNavigatingViaHistory = true
            self.selectedSection = .appearance
        }
    }

    private var regularBody: some View {
        NavigationSplitView {
            List(selection: $selectedSection) {
                ForEach(visibleSections) { section in
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
            List(visibleSections) { section in
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
              let section = SettingsSection(launchArgument: requestedSection),
              visibleSections.contains(section) else { return }

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
        guard visibleSections.contains(requestedSection) else {
            router.clearPendingSettingsSection(requestedSection)
            return
        }

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
        case .notifications:
            NotificationSettingsView()
        case .email:
            EmailSettingsView()
        case .calendar:
            CalendarSettingsView()
        case .reminders:
            RemindersSettingsView()
        case .notes:
            NotesSettingsView()
        case .memory:
            MemorySettingsView()
        case .tools:
            ToolsView()
        }
    }
}
