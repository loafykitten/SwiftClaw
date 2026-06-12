import SwiftUI

struct ChatComposerView: View {
    private let controlRowHeight: CGFloat = 28

    var isBusy = false
    var submissionError: String?
    var onSubmit: (String, String) -> Bool

    @AppStorage(SettingsKeys.homeModel) private var selectedModel = ""
    @AppStorage(SettingsKeys.swiftModel) private var swiftModel = ""
    @AppStorage(SettingsKeys.clawModel) private var clawModel = ""

    @State private var messageText = ""
    @State private var availableModels = SettingsStorage.loadAvailableModels()

    private var selectedModelTitle: String {
        guard !availableModels.isEmpty else {
            return "(N/A)"
        }

        if selectedModel == HomeModelSelection.swiftModel, isSwiftModelAvailable {
            return "Swift Model"
        }

        if selectedModel == HomeModelSelection.clawModel, isClawModelAvailable {
            return "Claw Model"
        }

        return effectiveModel ?? availableModels[0]
    }

    private var effectiveModel: String? {
        if selectedModel == HomeModelSelection.swiftModel {
            return isSwiftModelAvailable ? swiftModel : nil
        }

        if selectedModel == HomeModelSelection.clawModel {
            return isClawModelAvailable ? clawModel : nil
        }

        if !selectedModel.isEmpty, availableModels.contains(selectedModel) {
            return selectedModel
        }

        if !swiftModel.isEmpty, availableModels.contains(swiftModel) {
            return swiftModel
        }

        return availableModels.first
    }

    private var modelSelectionDisabled: Bool {
        availableModels.isEmpty || isBusy
    }

    private var composerControlsDisabled: Bool {
        modelSelectionDisabled || effectiveModel == nil
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
        selectedModel == HomeModelSelection.swiftModel || selectedModel == HomeModelSelection.clawModel
    }

    private var modelSelectionMenu: some View {
        Menu {
            ForEach(quickModelOptions) { option in
                Button {
                    selectedModel = option.selection
                } label: {
                    if selectedModel == option.selection {
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

                    Button {} label: {
                        Image(systemName: "magnifyingglass")
                            .frame(width: controlRowHeight, height: controlRowHeight)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(composerControlsDisabled)
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
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            refreshModels()
        }
    }

    private func refreshModels() {
        availableModels = SettingsStorage.loadAvailableModels()
    }

    private func submitMessage() {
        let input = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, let model = effectiveModel, !isBusy else {
            return
        }

        if onSubmit(input, model) {
            messageText = ""
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
