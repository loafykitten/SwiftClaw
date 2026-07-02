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

    var body: some View {
        LabeledContent {
            Picker("Reasoning Effort", selection: $selection) {
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
        .accessibilityValue(ModelReasoningEffort(rawValue: selection)?.displayName ?? "Off")
    }
}
