import SwiftUI

struct ModelSectionHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.headline)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(nil)
        }
    }
}

struct ModelSelectionRow: View {
    @Binding var selection: String
    let models: [String]

    // Keep a stale selection visible instead of rendering a blank picker.
    private var isSelectionMissing: Bool {
        !selection.isEmpty && !models.contains(selection)
    }

    var body: some View {
        LabeledContent {
            Picker(selection: $selection) {
                Text("None").tag("")
                if isSelectionMissing {
                    Text("\(selection) (unavailable)").tag(selection)
                }
                ForEach(models, id: \.self) { model in
                    Text(model).tag(model)
                }
            } label: {
                Text("Model")
            }
            .labelsHidden()
            .frame(maxWidth: 360, alignment: .trailing)
        } label: {
            Text("Model")
        }
    }
}

struct ReasoningEffortRow: View {
    @Binding var selection: String
    var isDisabled: Bool = false

    // The Claw model is reasoning-designated, so a stale persisted `off`
    // (or an unknown raw value) displays as the default effort instead of
    // an empty picker.
    private var normalizedSelection: ModelReasoningEffort {
        let stored = ModelReasoningEffort(rawValue: selection)
        guard let stored, stored.isReasoningEnabled else {
            return SettingsStorage.defaultClawReasoningEffort
        }
        return stored
    }

    var body: some View {
        LabeledContent {
            Picker(
                "Reasoning Effort",
                selection: Binding(
                    get: { normalizedSelection.rawValue },
                    set: { selection = $0 }
                )
            ) {
                ForEach(ModelReasoningEffort.selectableCases) { effort in
                    Text(effort.displayName).tag(effort.rawValue)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 360, alignment: .trailing)
            .disabled(isDisabled)
            .help("Reasoning effort sent for the Claw model")
        } label: {
            Text("Reasoning Effort")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Claw reasoning effort")
        .accessibilityValue(normalizedSelection.displayName)
    }
}
