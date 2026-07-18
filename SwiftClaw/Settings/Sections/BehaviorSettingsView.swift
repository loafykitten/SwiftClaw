import SwiftUI

struct BehaviorSettingsView: View {
    @State private var modelAvailability = ModelAvailabilityStore.shared
    @AppStorage(SettingsKeys.swiftModel) private var swiftModel = ""
    @AppStorage(SettingsKeys.clawModel) private var clawModel = ""
    @AppStorage(SettingsKeys.clawReasoningEffort)
    private var clawReasoningEffortRaw = SettingsStorage.defaultClawReasoningEffort.rawValue
    @AppStorage(SettingsKeys.chatContextTokenBudget)
    private var chatContextTokenBudget = SettingsStorage.defaultChatContextTokenBudget
    @AppStorage(SettingsKeys.deepResearchModel) private var deepResearchModel = ""

    /// Non-reasoning models offered for the Swift (lightweight/title-gen) picker.
    private var swiftModels: [String] {
        modelAvailability.availableModels(requiresReasoning: false)
    }

    /// Reasoning-capable models offered for the Claw (companion) picker.
    private var clawModels: [String] {
        modelAvailability.availableModels(requiresReasoning: true)
    }

    private var availableModels: [String] {
        modelAvailability.availableModels
    }

    private var clawModelIsUnset: Bool {
        clawModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Form {
            Section {
                ModelSelectionRow(selection: $swiftModel, models: swiftModels)
            } header: {
                ModelSectionHeader(title: "Swift Model", subtitle: "Title gen, non-reasoning tasks")
            } footer: {
                modelAvailabilityFooter
            }

            Section {
                ModelSelectionRow(selection: $clawModel, models: clawModels)
                ReasoningEffortRow(
                    selection: $clawReasoningEffortRaw,
                    isDisabled: clawModelIsUnset
                )
            } header: {
                ModelSectionHeader(title: "Claw Model", subtitle: "Bigger tasks, reasoning tasks")
            }

            Section {
                ModelSelectionRow(selection: $deepResearchModel, models: availableModels)
            } header: {
                ModelSectionHeader(title: "Research Model", subtitle: "Investigation, Deep Research tasks")
            }

            Section {
                Stepper(
                    value: $chatContextTokenBudget,
                    in: SettingsStorage.chatContextTokenBudgetRange,
                    step: 10_000
                ) {
                    LabeledContent("Token Budget") {
                        Text(chatContextTokenBudget.formatted())
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                ModelSectionHeader(title: "Chat Context", subtitle: "Oldest turns are dropped first")
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refreshModels)
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            refreshModels()
        }
    }

    private func refreshModels() {
        modelAvailability.refresh()
    }

    @ViewBuilder
    private var modelAvailabilityFooter: some View {
        if !modelAvailability.loadFailures.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Some provider model settings couldn't be loaded.")
                ForEach(modelAvailability.loadFailures) { failure in
                    Text(failure.message)
                }
            }
            .foregroundStyle(.orange)
        } else if availableModels.isEmpty {
            Text("No models available. Add deployments or models in the Providers section.")
                .foregroundStyle(.secondary)
        }
    }
}
