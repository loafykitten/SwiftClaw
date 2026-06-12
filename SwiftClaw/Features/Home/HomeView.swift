import SwiftUI
import os

struct HomeView: View {
    private let composerControlRowHeight: CGFloat = 28

    @AppStorage(SettingsKeys.homeModel) private var selectedModel = ""
    @AppStorage(SettingsKeys.swiftModel) private var swiftModel = ""
    @AppStorage(SettingsKeys.clawModel) private var clawModel = ""

    @State private var messageText = ""
    @State private var availableModels = SettingsStorage.loadAvailableModels()
    @State private var blurb = HomeBlurb.initial

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
        .disabled(chatControlsDisabled)
        .frame(height: composerControlRowHeight, alignment: .center)
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 18) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "cat")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 52, height: 52)
                        .foregroundStyle(.tint)
                        .alignmentGuide(.firstTextBaseline) { dimensions in
                            dimensions[VerticalAlignment.center] + 12
                        }

                    Text("SwiftClaw")
                        .font(.system(size: 32, weight: .bold))
                }

                VStack(spacing: 4) {
                    Text("Good morning, User!")
                        .font(.title3)
                        .foregroundStyle(.secondary)

                    Text(blurb)
                        .font(.callout)
                        .italic()
                        .foregroundStyle(.tertiary)
                        .contentTransition(.opacity)
                        .animation(.easeInOut(duration: 0.4), value: blurb)
                }
            }

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
                }

                Divider()
                    .padding(.top, 4)

                HStack(alignment: .center) {
                    HStack(spacing: 12) {
                        Button {} label: {
                            Image(systemName: "paperclip")
                                .frame(width: composerControlRowHeight, height: composerControlRowHeight)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .disabled(chatControlsDisabled)

                        Button {} label: {
                            Image(systemName: "magnifyingglass")
                                .frame(width: composerControlRowHeight, height: composerControlRowHeight)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .disabled(chatControlsDisabled)
                    }

                    Spacer()

                    HStack(spacing: 8) {
                        modelSelectionMenu
                            .frame(width: 160, alignment: .trailing)

                        Button {} label: {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.title2)
                                .frame(width: composerControlRowHeight, height: composerControlRowHeight)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                        .disabled(chatControlsDisabled)
                    }
                }
                .frame(height: composerControlRowHeight, alignment: .center)
                .padding(.vertical, 8)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .glassEffect(in: .rect(cornerRadius: 16.0))
            .padding(.horizontal, 40)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear(perform: refreshModels)
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            refreshModels()
        }
        .task {
            await generateBlurb()
        }
    }

    private func refreshModels() {
        availableModels = SettingsStorage.loadAvailableModels()
    }

    private func generateBlurb() async {
        // Previews must not hit the Keychain or the network; the 60s request
        // timeout blows past the preview engine's 5s update budget.
        guard !HomeBlurb.isRunningInPreview else {
            return
        }

        guard !swiftModel.isEmpty else {
            HomeBlurb.logger.info("Skipping blurb generation: no Swift Model configured")
            return
        }

        do {
            let response = try await InferenceService.shared.complete(
                messages: [
                    .system(HomeBlurb.systemPrompt),
                    .user("Write one new blurb."),
                ],
                model: swiftModel
            )

            let cleaned = HomeBlurb.cleaned(response)
            if !cleaned.isEmpty {
                blurb = cleaned
            }
        } catch {
            // Keep the blank line; details land in the unified log.
            HomeBlurb.logger.error("Blurb generation failed: \(String(describing: error), privacy: .public)")
        }
    }
}

private enum HomeBlurb {
    static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.caffeineplz.SwiftClaw",
        category: "HomeBlurb"
    )

    static let previewFallback = "There's no place like 127.0.0.1"

    static var isRunningInPreview: Bool {
        ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    }

    /// Blank at runtime (a space reserves the line height) so users never see
    /// the blurb swap; previews show the static fallback since generation is
    /// disabled there.
    static var initial: String {
        isRunningInPreview ? previewFallback : " "
    }

    static let systemPrompt = """
        You write the single-line greeting blurb shown on the home screen of SwiftClaw, \
        a personal macOS AI assistant app with a cat mascot. Write one short, cozy, witty \
        one-liner that blends programming, networking, or terminal culture with warmth or \
        cat energy. The tone to match: "There's no place like 127.0.0.1" or \
        "sudo make me a good day" - but never reuse those examples. Hard rules: at most \
        60 characters, no emoji, no surrounding quotes, no explanation. Reply with the \
        blurb text only.
        """

    /// Trims the response to a single line and strips wrapping quotes some models add.
    static func cleaned(_ raw: String) -> String {
        let firstLine = raw
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""

        return firstLine.trimmingCharacters(in: CharacterSet(charactersIn: "\"'\u{201C}\u{201D}\u{2018}\u{2019}"))
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
