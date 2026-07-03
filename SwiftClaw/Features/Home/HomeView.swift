import SwiftUI
import SwiftData
import os

struct HomeView: View {
    var onChatCreated: (UUID) -> Void = { _ in }

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.modelContext) private var modelContext
    @AppStorage(SettingsKeys.swiftModel) private var swiftModel = ""

    @State private var blurb = HomeBlurb.initial
    @State private var isCreatingChat = false
    @State private var submissionError: String?
    @State private var presentedError: PresentedAppError?

    private var composerHorizontalPadding: CGFloat {
        #if os(iOS)
        horizontalSizeClass == .compact ? 18 : 40
        #else
        40
        #endif
    }

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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .scrollEdgeEffectStyle(.soft, for: .bottom)
        .chatComposerDismissKeyboardOnTap()
        .safeAreaBar(edge: .bottom) {
            ChatComposerView(
                isBusy: isCreatingChat,
                submissionError: submissionError
            ) { submission in
                submitMessage(submission)
            }
            .padding(.horizontal, composerHorizontalPadding)
            .padding(.bottom, 24)
        }
        .task {
            await generateBlurb()
        }
        .appErrorAlert($presentedError)
    }

    private func submitMessage(_ submission: ChatComposerSubmission) -> Bool {
        let input = submission.text
        guard !input.isEmpty, !isCreatingChat else {
            return false
        }

        isCreatingChat = true
        submissionError = nil

        let chat = Chat(
            title: ChatDefaults.title(for: input),
            modelSelection: submission.model,
            reasoningEffort: submission.reasoningEffort ?? .off,
            isGenerating: true
        )

        let finalizedAttachments: [ImageAttachmentRecord]
        do {
            finalizedAttachments = try ImageAttachmentStore.shared.finalizeDraftAttachments(
                submission.imageAttachments,
                for: chat.id
            )
        } catch {
            presentSubmissionError(.attachmentFinalizationFailed(error))
            isCreatingChat = false
            return false
        }

        let userMessage = ChatMessage(
            role: .user,
            content: input,
            sortIndex: 0,
            imageAttachments: finalizedAttachments
        )

        userMessage.chat = chat
        chat.messages = [userMessage]

        modelContext.insert(chat)
        modelContext.insert(userMessage)

        do {
            try modelContext.save()
            ImageAttachmentStore.shared.deleteDraftAttachments(submission.imageAttachments)
        } catch {
            ImageAttachmentStore.shared.deleteAttachments(finalizedAttachments)
            presentSubmissionError(.saveFailed(error))
            isCreatingChat = false
            return false
        }

        isCreatingChat = false
        onChatCreated(chat.id)

        ChatTaskCoordinator.shared.completeChat(
            chat,
            in: modelContext,
            allowInvestigation: submission.isInvestigationEnabled,
            supportsImages: submission.supportsImages,
            reasoningEffort: submission.reasoningEffort
        )
        ChatTaskCoordinator.shared.generateInitialTitle(
            for: chat,
            userInput: input,
            in: modelContext
        )

        return true
    }

    private func presentSubmissionError(_ error: HomeSubmissionError) {
        submissionError = error.errorDescription
        presentedError = PresentedAppError(error, title: "Couldn't create chat")
    }

    private func generateBlurb() async {
        // Previews must not hit the Keychain or the network; the 60s request
        // timeout blows past the preview engine's 5s update budget.
        guard !ProcessInfo.processInfo.isRunningInPreview else {
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
                model: swiftModel,
                systemPromptMode: .standalone
            )

            let cleaned = HomeBlurb.cleaned(response)
            guard !Task.isCancelled else { return }
            if !cleaned.isEmpty {
                blurb = cleaned
            }
        } catch is CancellationError {
            return
        } catch {
            // Keep the blank line; details land in the unified log.
            HomeBlurb.logger.error("Blurb generation failed: \(String(describing: error), privacy: .public)")
        }
    }
}

private enum HomeSubmissionError: LocalizedError {
    case attachmentFinalizationFailed(any Error)
    case saveFailed(any Error)

    var errorDescription: String? {
        switch self {
        case .attachmentFinalizationFailed:
            "Couldn't attach the selected images."
        case .saveFailed:
            "Couldn't create the chat."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .attachmentFinalizationFailed(let error):
            "Check that the image files still exist and try again. Details: \(error.localizedDescription)"
        case .saveFailed(let error):
            "Your draft attachments were rolled back. Try sending again. Details: \(error.localizedDescription)"
        }
    }
}

private enum HomeBlurb {
    static let logger = AppLog.make("HomeBlurb")

    static let previewFallback = "There's no place like 127.0.0.1"

    /// Blank at runtime (a space reserves the line height) so users never see
    /// the blurb swap; previews show the static fallback since generation is
    /// disabled there.
    static var initial: String {
        ProcessInfo.processInfo.isRunningInPreview ? previewFallback : " "
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
