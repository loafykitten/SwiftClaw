import SwiftUI
import SwiftData
import os

struct HomeView: View {
    var onChatCreated: (UUID) -> Void = { _ in }

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.modelContext) private var modelContext
    @AppStorage(SettingsKeys.swiftModel) private var swiftModel = ""
    @AppStorage(SettingsKeys.personaDisplayName) private var personaDisplayName = ""
    @AppStorage(SettingsKeys.assistantDisplayName)
    private var assistantDisplayName = AssistantPersona.defaultDisplayName
    @AppStorage(SettingsKeys.assistantPersonalityPreset)
    private var assistantPersonalityPreset = AssistantPersonalityLibrary.defaultPresetID
    @AppStorage(SettingsKeys.assistantUsesCustomPersonality) private var assistantUsesCustomPersonality = false
    @AppStorage(SettingsKeys.assistantCustomPersonality) private var assistantCustomPersonality = ""

    @StateObject private var generatedContent = HomeDayGreetingViewModel()
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

    private var personaCacheKey: String {
        [
            personaDisplayName,
            assistantDisplayName,
            assistantPersonalityPreset,
            assistantUsesCustomPersonality.description,
            assistantCustomPersonality,
        ].joined(separator: "\u{1F}")
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

                TimelineView(.everyMinute) { timeline in
                    VStack(spacing: 4) {
                        HomeDayGreetingView(viewModel: generatedContent)

                        Text(generatedContent.blurb)
                            .font(.callout)
                            .italic()
                            .foregroundStyle(.tertiary)
                            .contentTransition(.opacity)
                            .animation(.easeInOut(duration: 0.4), value: generatedContent.blurb)
                    }
                    // The trigger uses the clock-based fallback phase while
                    // the cache key inside the view model uses the daylight-
                    // derived phase. Around sunset-dependent boundaries the
                    // greeting can lag one phase until the next visit — an
                    // accepted approximation; re-keying on the real phase
                    // would need the async context before the task fires.
                    .task(id: HomeContentRefreshID(
                        phase: HomeDayPhase.cachePhase(now: timeline.date),
                        persona: personaCacheKey,
                        model: swiftModel
                    )) {
                        generatedContent.refresh(
                            swiftModel: swiftModel,
                            personaKey: personaCacheKey
                        )
                    }
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
                await submitMessage(submission)
            }
            .padding(.horizontal, composerHorizontalPadding)
            .padding(.bottom, 24)
        }
        .appErrorAlert($presentedError)
    }

    private func submitMessage(_ submission: ChatComposerSubmission) async -> Bool {
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
            finalizedAttachments = try await ImageAttachmentStore.shared.finalizeDraftAttachmentsAsync(
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
}

private struct HomeContentRefreshID: Hashable {
    let phase: HomeDayCachePhase
    let persona: String
    let model: String
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

enum HomeBlurb {
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
