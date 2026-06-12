import SwiftUI

struct HomeView: View {
    @AppStorage(SettingsKeys.homeModel) private var selectedModel = ""
    @AppStorage(SettingsKeys.swiftModel) private var swiftModel = ""
    @AppStorage(SettingsKeys.clawModel) private var clawModel = ""

    @State private var messageText = ""
    @State private var selectedMode = "Chat"
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

        return nil
    }

    private var chatControlsDisabled: Bool {
        availableModels.isEmpty
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

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 4) {
                Image(systemName: "cat")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 80, height: 80)
                    .foregroundStyle(.tint)

                Text("SwiftClaw")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Text("Good morning, User!")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            Text("There's no place like 127.0.0.1")
                .font(.callout)
                .italic()
                .foregroundStyle(.tertiary)
                .padding(.top, 12)

            Spacer()

            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 8) {
                    TextField("Message SwiftClaw...", text: $messageText, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.body)
                        .lineLimit(1...3)
                        .fixedSize(horizontal: false, vertical: true)
                        .disabled(chatControlsDisabled)
                        .onKeyPress { keyPress in
                            guard keyPress.key == .return,
                                  keyPress.modifiers.contains(.shift) else {
                                return .ignored
                            }

                            messageText.append("\n")
                            return .handled
                        }

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
                    .padding(.top, 2)
                    .disabled(chatControlsDisabled)
                }

                Divider()
                    .padding(.vertical, 4)

                HStack {
                    HStack(spacing: 12) {
                        Button {} label: {
                            Image(systemName: "paperclip")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .disabled(chatControlsDisabled)

                        Button {} label: {
                            Image(systemName: "magnifyingglass")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .disabled(chatControlsDisabled)
                    }

                    Spacer()

                    HStack(spacing: 8) {
                        Picker("", selection: $selectedMode) {
                            Text("Agent").tag("Agent")
                            Text("Chat").tag("Chat")
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 130)
                        .disabled(chatControlsDisabled)

                        Button {} label: {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.title2)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                        .disabled(chatControlsDisabled)
                    }
                }
            }
            .padding(16)
            .glassEffect(in: .rect(cornerRadius: 16.0))
            .padding(.horizontal, 40)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear(perform: refreshModels)
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            refreshModels()
        }
    }

    private func refreshModels() {
        availableModels = SettingsStorage.loadAvailableModels()
    }
}

private enum HomeModelSelection {
    static let swiftModel = "settings.home.modelPreset.swift"
    static let clawModel = "settings.home.modelPreset.claw"
}

private struct HomeModelOption: Identifiable {
    let title: String
    let selection: String

    var id: String { selection }
}

#Preview {
    HomeView()
        .frame(width: 700, height: 500)
}
