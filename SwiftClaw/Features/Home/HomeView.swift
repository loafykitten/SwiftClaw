import SwiftUI
import SwiftData
import os

struct HomeView: View {
    var onChatCreated: (UUID) -> Void = { _ in }

    @Environment(\.modelContext) private var modelContext
    @AppStorage(SettingsKeys.swiftModel) private var swiftModel = ""

    @State private var blurb = HomeBlurb.initial
    @State private var isCreatingChat = false
    @State private var submissionError: String?

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 18) {
                HStack(alignment: .center, spacing: 10) {
                    Image("HomeMascot")
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 48, height: 48)
                        .accessibilityHidden(true)

                    Text("SwiftClaw")
                        .font(.system(size: 32, weight: .bold))
                }

                VStack(spacing: 4) {
                    HomeDayGreetingView(swiftModel: swiftModel)

                    Text(blurb)
                        .font(.callout)
                        .italic()
                        .foregroundStyle(.tertiary)
                        .contentTransition(.opacity)
                        .animation(.easeInOut(duration: 0.4), value: blurb)
                }
            }

            Spacer()

            ChatComposerView(
                isBusy: isCreatingChat,
                submissionError: submissionError
            ) { input, model in
                submitMessage(input: input, model: model)
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            await generateBlurb()
        }
    }

    private func submitMessage(input: String, model: String) -> Bool {
        guard !input.isEmpty, !isCreatingChat else {
            return false
        }

        isCreatingChat = true
        submissionError = nil

        let chat = Chat(
            title: ChatDefaults.title(for: input),
            modelSelection: model,
            isGenerating: true
        )
        let systemMessage = ChatMessage(
            role: .system,
            content: ChatDefaults.systemPrompt,
            sortIndex: 0
        )
        let userMessage = ChatMessage(
            role: .user,
            content: input,
            sortIndex: 1
        )

        systemMessage.chat = chat
        userMessage.chat = chat
        chat.messages = [systemMessage, userMessage]

        modelContext.insert(chat)
        modelContext.insert(systemMessage)
        modelContext.insert(userMessage)

        do {
            try modelContext.save()
        } catch {
            submissionError = "Couldn't create the chat."
            isCreatingChat = false
            return false
        }

        isCreatingChat = false
        onChatCreated(chat.id)

        Task {
            await ChatCompletionService.completeChat(chat, in: modelContext)
        }

        return true
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

#Preview {
    HomeView()
        .frame(width: 700, height: 500)
}
