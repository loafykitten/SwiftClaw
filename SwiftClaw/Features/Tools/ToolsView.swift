import SwiftUI

struct ToolsView: View {
    @State private var tools: [ToolListing] = []
    @State private var router = AppRouter.shared
    /// Feature row currently outlined after arriving via a Workspace
    /// "enable this feature" tap; cleared shortly after by `highlightTask`.
    @State private var highlightedFeature: WorkspaceFeature?
    @State private var highlightTask: Task<Void, Never>?

    @AppStorage(SettingsKeys.webSearchEnabled)
    private var isWebSearchEnabled = SettingsStorage.defaultWebSearchEnabled
    @AppStorage(SettingsKeys.investigationEnabled)
    private var isInvestigationEnabled = SettingsStorage.defaultInvestigationEnabled

    @AppStorage(SettingsKeys.investigationMaxSubAgents)
    private var investigationMaxSubAgents = SettingsStorage.defaultInvestigationMaxSubAgents

    @AppStorage(SettingsKeys.emailEnabled)
    private var isEmailEnabled = SettingsStorage.defaultEmailEnabled
    @AppStorage(SettingsKeys.calendarEnabled)
    private var isCalendarEnabled = SettingsStorage.defaultCalendarEnabled
    @AppStorage(SettingsKeys.remindersEnabled)
    private var isRemindersEnabled = SettingsStorage.defaultRemindersEnabled
    @AppStorage(SettingsKeys.notesEnabled)
    private var isNotesEnabled = SettingsStorage.defaultNotesEnabled
    @AppStorage(SettingsKeys.memoryEnabled)
    private var isMemoryEnabled = SettingsStorage.defaultMemoryEnabled

    var body: some View {
        ScrollViewReader { proxy in
            List {
                if !tools.isEmpty {
                    Section {
                        ForEach(tools) { listing in
                            toolRow(for: listing)
                        }
                    } header: {
                        Text("Assistant Tools")
                    }
                }

                Section {
                    ForEach(WorkspaceFeature.allCases) { feature in
                        featureRow(for: feature)
                            .id(feature)
                    }
                } header: {
                    Text("Features")
                } footer: {
                    Text("Features can be enabled or disabled; enabled workspace features appear in Workspace.")
                        .font(.caption)
                }
            }
            .onAppear {
                applyPendingFeatureHighlightIfNeeded(proxy: proxy)
            }
            .onChange(of: router.pendingToolsFeatureHighlight) { _, _ in
                applyPendingFeatureHighlightIfNeeded(proxy: proxy)
            }
        }
        .onAppear(perform: refresh)
        .onChange(of: isNotesEnabled) { _, _ in
            // Toggling Notes here changes `isAvailableForReadTools`, which
            // `search_notes`/`read_note`'s `isConfigured` reads — but `tools`
            // is a snapshot from the last `refresh()`, so without this the
            // Ready/Needs setup badges go stale until the view reappears.
            refresh()
        }
        .onChange(of: isMemoryEnabled) { _, _ in
            // Same staleness for the memory tools' `isConfigured`, which
            // reads `MemoryFeatureModel.shared.isAvailable`.
            refresh()
        }
        .task {
            // A fresh launch never opens Notes UI, so on first appearance
            // `search_notes`/`read_note` can still read "Needs setup" even
            // though Notes is enabled and a vault is already configured.
            // Bootstrap before the second refresh so the listing settles on
            // the accurate status.
            await NotesFeatureModel.shared.prepareReadToolsIfNeeded()
            refresh()
        }
        .onDisappear {
            highlightTask?.cancel()
        }
    }

    private var subAgentSliderRange: ClosedRange<Double> {
        let range = SettingsStorage.investigationMaxSubAgentsRange
        return Double(range.lowerBound)...Double(range.upperBound)
    }

    private var isInvestigationEffectivelyEnabled: Bool {
        isWebSearchEnabled && isInvestigationEnabled
    }

    private var webSearchBinding: Binding<Bool> {
        Binding {
            isWebSearchEnabled
        } set: { enabled in
            isWebSearchEnabled = enabled

            if !enabled {
                isInvestigationEnabled = false
            }
        }
    }

    private var investigationBinding: Binding<Bool> {
        Binding {
            isInvestigationEffectivelyEnabled
        } set: { enabled in
            isInvestigationEnabled = isWebSearchEnabled && enabled
        }
    }

    @ViewBuilder
    private func toolToggle(for listing: ToolListing) -> some View {
        switch listing.id {
        case "web_search":
            Toggle("Web Search", isOn: webSearchBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .help(isWebSearchEnabled ? "Turn Web Search off" : "Turn Web Search on")
                .accessibilityLabel("Web Search")
        case "investigate":
            Toggle("Investigation", isOn: investigationBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(!isWebSearchEnabled)
                .help(isWebSearchEnabled ? "Turn Investigation on or off" : "Web Search is off")
                .accessibilityLabel("Investigation")
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func toolRow(for listing: ToolListing) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: listing.systemImage)
                    .font(.title3)
                    .frame(width: 28)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(listing.displayName)
                        .font(.headline)
                    Text(listing.description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                HStack(spacing: 12) {
                    Text(listing.isConfigured ? "Ready" : "Needs setup")
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            (listing.isConfigured ? Color.green : Color.orange).opacity(0.15),
                            in: Capsule()
                        )
                        .foregroundStyle(listing.isConfigured ? .green : .orange)

                    toolToggle(for: listing)
                }
            }

            if listing.id == "investigate" {
                investigationConfiguration
                    .padding(.leading, 40)
                    .disabled(!isInvestigationEffectivelyEnabled)
                    .opacity(isInvestigationEffectivelyEnabled ? 1 : 0.55)
            }
        }
        .padding(.vertical, 4)
    }

    private func featureRow(for feature: WorkspaceFeature) -> some View {
        HStack(spacing: 12) {
            Image(systemName: feature.systemImage)
                .font(.title3)
                .frame(width: 28)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(feature.displayName)
                    .font(.headline)
                Text(feature.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            Toggle(feature.displayName, isOn: featureBinding(for: feature))
                .labelsHidden()
                .toggleStyle(.switch)
                .help(featureBinding(for: feature).wrappedValue
                    ? "Turn \(feature.displayName) off"
                    : "Turn \(feature.displayName) on")
                .accessibilityLabel(feature.displayName)
        }
        .padding(.vertical, 4)
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.tint, lineWidth: 2)
                .padding(-6)
                .opacity(highlightedFeature == feature ? 1 : 0)
        }
    }

    private func featureBinding(for feature: WorkspaceFeature) -> Binding<Bool> {
        switch feature {
        case .email: $isEmailEnabled
        case .calendar: $isCalendarEnabled
        case .reminders: $isRemindersEnabled
        case .notes: $isNotesEnabled
        case .memory: $isMemoryEnabled
        }
    }

    private func applyPendingFeatureHighlightIfNeeded(proxy: ScrollViewProxy) {
        guard let feature = router.pendingToolsFeatureHighlight else { return }
        router.clearPendingToolsFeatureHighlight(feature)

        highlightTask?.cancel()
        highlightTask = Task {
            // Give the list a beat to lay out when the window/section was
            // just opened, otherwise scrollTo can land before rows exist.
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.3)) {
                proxy.scrollTo(feature, anchor: .center)
                highlightedFeature = feature
            }
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.6)) {
                highlightedFeature = nil
            }
        }
    }

    private var investigationConfiguration: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Max sub-agents")
                    .font(.subheadline)
                Spacer()
                Text("\(investigationMaxSubAgents)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Slider(
                value: Binding(
                    get: { Double(investigationMaxSubAgents) },
                    set: { investigationMaxSubAgents = Int($0.rounded()) }
                ),
                in: subAgentSliderRange,
                step: 1
            )
            .frame(maxWidth: 240)

            Text("How many follow-up lines of inquiry run in parallel.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private func refresh() {
        tools = ToolRegistry.shared.tools.map { ToolListing(tool: $0) }
    }
}

nonisolated private struct ToolListing: Identifiable {
    let id: String
    let displayName: String
    let description: String
    let systemImage: String
    let isConfigured: Bool

    init(tool: any Tool) {
        id = tool.name
        displayName = tool.displayName
        description = tool.description
        systemImage = tool.systemImage
        isConfigured = tool.isConfigured
    }
}
