import SwiftUI

struct ChatComposerView: View {
    private let controlRowHeight: CGFloat = 28

    var isBusy = false
    var submissionError: String?

    /// Called with the message text, model selection, and whether the user
    /// enabled Investigation for this message.
    var onSubmit: (String, String, Bool) -> Bool

    @AppStorage(SettingsKeys.homeModel) private var selectedModel = ""
    @AppStorage(SettingsKeys.swiftModel) private var swiftModel = ""
    @AppStorage(SettingsKeys.clawModel) private var clawModel = ""

    @State private var messageText = ""
    @State private var availableModels = SettingsStorage.loadAvailableModels()
    @State private var isInvestigationEnabled = false
    @State private var isInvestigationAvailable = InvestigateTool().isConfigured

    private var activeModelSelection: String {
        isInvestigationEnabled ? HomeModelSelection.clawModel : selectedModel
    }

    private var selectedModelTitle: String {
        guard !availableModels.isEmpty else {
            return "(N/A)"
        }

        if activeModelSelection == HomeModelSelection.swiftModel, isSwiftModelAvailable {
            return "Swift Model"
        }

        if activeModelSelection == HomeModelSelection.clawModel, isClawModelAvailable {
            return "Claw Model"
        }

        return effectiveModel ?? availableModels[0]
    }

    private var effectiveModel: String? {
        if activeModelSelection == HomeModelSelection.swiftModel {
            return isSwiftModelAvailable ? swiftModel : nil
        }

        if activeModelSelection == HomeModelSelection.clawModel {
            return isClawModelAvailable ? clawModel : nil
        }

        if !activeModelSelection.isEmpty, availableModels.contains(activeModelSelection) {
            return activeModelSelection
        }

        if !swiftModel.isEmpty, availableModels.contains(swiftModel) {
            return swiftModel
        }

        return availableModels.first
    }

    private var modelSelectionDisabled: Bool {
        // Investigation sends this message with the Claw Model, so the
        // selector locks while the one-shot toggle is on.
        availableModels.isEmpty || isBusy || isInvestigationEnabled
    }

    private var composerControlsDisabled: Bool {
        availableModels.isEmpty || isBusy || effectiveModel == nil
    }

    private var canSubmitMessage: Bool {
        !composerControlsDisabled && !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isSwiftModelAvailable: Bool {
        !swiftModel.isEmpty && availableModels.contains(swiftModel)
    }

    private var isClawModelAvailable: Bool {
        !clawModel.isEmpty && availableModels.contains(clawModel)
    }

    private var quickModelOptions: [HomeModelOption] {
        var options: [HomeModelOption] = []

        if isSwiftModelAvailable {
            options.append(HomeModelOption(title: "Swift Model", selection: HomeModelSelection.swiftModel))
        }

        if isClawModelAvailable {
            options.append(HomeModelOption(title: "Claw Model", selection: HomeModelSelection.clawModel))
        }

        return options
    }

    private var isQuickModelSelection: Bool {
        activeModelSelection == HomeModelSelection.swiftModel || activeModelSelection == HomeModelSelection.clawModel
    }

    private var modelSelectionMenu: some View {
        Menu {
            ForEach(quickModelOptions) { option in
                Button {
                    selectedModel = option.selection
                } label: {
                    if activeModelSelection == option.selection {
                        Label(option.title, systemImage: "checkmark")
                    } else {
                        Text(option.title)
                    }
                }
            }

            if !quickModelOptions.isEmpty {
                Divider()
            }

            ForEach(availableModels, id: \.self) { model in
                Button {
                    selectedModel = model
                } label: {
                    if !isQuickModelSelection, model == effectiveModel {
                        Label(model, systemImage: "checkmark")
                    } else {
                        Text(model)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(selectedModelTitle)
                    .font(.caption)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2)
            }
            .foregroundStyle(.secondary)
        }
        .menuIndicator(.hidden)
        .disabled(modelSelectionDisabled)
        .frame(height: controlRowHeight, alignment: .center)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                TextField("Message SwiftClaw...", text: $messageText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .lineLimit(1...3)
                    .fixedSize(horizontal: false, vertical: true)
                    .disabled(composerControlsDisabled)
                    .onKeyPress { keyPress in
                        guard keyPress.key == .return else {
                            return .ignored
                        }

                        if keyPress.modifiers.contains(.shift) {
                            messageText.append("\n")
                        } else {
                            submitMessage()
                        }

                        return .handled
                    }
            }

            Divider()
                .padding(.top, 4)

            HStack(alignment: .center) {
                HStack(spacing: 12) {
                    Button {} label: {
                        Image(systemName: "paperclip")
                            .frame(width: controlRowHeight, height: controlRowHeight)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(composerControlsDisabled)

                    Button {
                        setInvestigation(!isInvestigationEnabled)
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .frame(width: controlRowHeight, height: controlRowHeight)
                            .background {
                                if isInvestigationEnabled {
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(Color.accentColor.opacity(0.18))
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(isInvestigationEnabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .disabled(composerControlsDisabled || !isInvestigationAvailable || !isClawModelAvailable)
                    .help(
                        isInvestigationAvailable && isClawModelAvailable
                            ? "Investigate this message in depth using the Claw Model"
                            : "Investigation needs a Brave Search key plus Claw and Swift Models"
                    )
                    .accessibilityLabel("Investigation mode")
                    .accessibilityAddTraits(isInvestigationEnabled ? .isSelected : [])
                }

                Spacer()

                HStack(spacing: 8) {
                    modelSelectionMenu
                        .frame(width: 160, alignment: .trailing)

                    Button {
                        submitMessage()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                            .frame(width: controlRowHeight, height: controlRowHeight)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .disabled(!canSubmitMessage)
                }
            }
            .frame(height: controlRowHeight, alignment: .center)
            .padding(.vertical, 8)

            if let submissionError {
                Text(submissionError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 10)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .glassEffect(in: .rect(cornerRadius: 16.0))
        .onAppear(perform: refreshModels)
        .onDisappear {
            // Reset the transient one-shot toggle if the composer goes away.
            setInvestigation(false)
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            refreshModels()
        }
        .onReceive(NotificationCenter.default.publisher(for: SettingsNotifications.keychainDidChange)) { notification in
            guard notification.userInfo?[SettingsNotifications.changedKey] as? String == SettingsKeys.braveSearchAPIKey else {
                return
            }

            refreshModels()
        }
    }

    private func refreshModels() {
        availableModels = SettingsStorage.loadAvailableModels()
        isInvestigationAvailable = InvestigateTool().isConfigured

        if !isInvestigationAvailable || !isClawModelAvailable {
            setInvestigation(false)
        }
    }

    /// Turns investigation mode on or off. While on, this message uses the
    /// Claw Model without changing the saved home model selection.
    private func setInvestigation(_ enabled: Bool) {
        guard enabled != isInvestigationEnabled else {
            return
        }

        isInvestigationEnabled = enabled
    }

    private func submitMessage() {
        let input = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, let model = effectiveModel, !isBusy else {
            return
        }

        if onSubmit(input, model, isInvestigationEnabled && isInvestigationAvailable) {
            messageText = ""
            // Investigation is a one-shot toggle: it always resets (and the
            // model selector unlocks) after the message is submitted.
            setInvestigation(false)
        }
    }
}

enum HomeModelSelection {
    static let swiftModel = "settings.home.modelPreset.swift"
    static let clawModel = "settings.home.modelPreset.claw"
}

private struct HomeModelOption: Identifiable {
    let title: String
    let selection: String

    var id: String { selection }
}
