import SwiftUI
import SwiftData

/// Reply composer sheet for an `Email` message. Extracted from
/// `EmailView.swift` along the composer concern boundary.
struct EmailReplyComposerView: View {
    let email: Email
    let account: StoredEmailAccount
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var toAddresses: String = ""
    @State private var ccAddresses: String = ""
    @State private var subject: String = ""
    @State private var bodyText: String = ""
    @State private var isSending = false
    @State private var sendTask: Task<Void, Never>?
    @State private var sendError: PresentedAppError?

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Reply") { dismiss() }

            Form {
                Section("Recipients") {
                    TextField("To", text: $toAddresses)
                    TextField("Cc", text: $ccAddresses)
                }
                Section("Subject") {
                    TextField("Subject", text: $subject)
                }
                Section("Body") {
                    TextEditor(text: $bodyText)
                        .frame(minHeight: 220)
                }
                if let sendError {
                    Section {
                        Text(sendError.message)
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)

            SheetFooter(
                confirmTitle: "Send",
                isDisabled: isSending || sendTask != nil || toAddresses.isEmpty
            ) {
                startSending()
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 480)
        #endif
        .onAppear(perform: prefill)
        .onDisappear {
            sendTask?.cancel()
            sendTask = nil
        }
        .appErrorAlert($sendError)
    }

    private func prefill() {
        let draft = EmailReplySender.draft(replyingTo: email)
        toAddresses = draft.toAddresses
        ccAddresses = draft.ccAddresses
        subject = draft.subject
        bodyText = draft.bodyText
    }

    private func send() async {
        isSending = true
        defer {
            if !Task.isCancelled {
                isSending = false
            }
        }
        do {
            guard !Task.isCancelled else { return }
            // `EmailReplySender` owns Message-ID generation, threading
            // headers, and the local Sent-row seed (`upsertSentMessage`).
            try await EmailReplySender.send(
                replyingTo: email,
                account: account,
                toAddresses: EmailReplySender.parseAddresses(toAddresses),
                ccAddresses: EmailReplySender.parseAddresses(ccAddresses),
                subject: subject,
                bodyText: bodyText,
                modelContext: modelContext
            )
            guard !Task.isCancelled else { return }
            dismiss()
        } catch {
            guard !Task.isCancelled else { return }
            sendError = PresentedAppError(
                EmailReplyComposerError.sendFailed(error),
                title: "Couldn't send reply"
            )
        }
    }

    private func startSending() {
        guard sendTask == nil else { return }
        sendError = nil
        sendTask = Task { @MainActor in
            await send()
            guard !Task.isCancelled else { return }
            sendTask = nil
        }
    }

    private enum EmailReplyComposerError: LocalizedError {
        case sendFailed(any Error)

        var errorDescription: String? {
            "Couldn't send reply"
        }

        var recoverySuggestion: String? {
            switch self {
            case .sendFailed(let error as EmailReplySenderError):
                "\(error.localizedDescription) The reply remains in the composer; fix it and send again."
            case .sendFailed(let error):
                "The reply remains in the composer. Check the account connection and try again. Details: \(error.localizedDescription)"
            }
        }
    }
}
