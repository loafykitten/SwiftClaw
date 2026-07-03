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
        toAddresses = email.fromAddress
        ccAddresses = email.ccAddresses.joined(separator: ", ")
        // Recognize the full reply/forward marker set (re/fw/fwd/aw/wg) so
        // non-English or forwarded subjects don't get a doubled "Re: " prefix.
        subject = ThreadResolver.replyMarker(email.subject).isEmpty
            ? "Re: \(email.subject)"
            : email.subject
        bodyText = Self.replyQuote(for: email)
    }

    /// Builds the reply body: an empty compose area on top followed by a
    /// standard `--- ... wrote:` separator + the replied message's full plain
    /// text body line-prefixed with `> `. Quoting the full body (instead of
    /// the previous 140-char `snippet`) makes the reply actually usable —
    /// the recipient sees their original message with context preserved, and
    /// the sender can edit down inline.
    ///
    /// Truncated to a sane upper bound so a 200KB plaintext newsletter
    /// doesn't blow up the composer + the outgoing SMTP payload. 8000 chars
    /// ≈ 4-5 screens; anything longer gets a `[…]` marker.
    private static func replyQuote(for email: Email) -> String {
        let original = email.plainTextBody
        let trimmed = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let cap = 8000
        let quoted: String
        if trimmed.count <= cap {
            quoted = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
                .map { "> \($0)" }
                .joined(separator: "\n")
        } else {
            let prefix = String(trimmed.prefix(cap))
            let block = prefix.split(separator: "\n", omittingEmptySubsequences: false)
                .map { "> \($0)" }
                .joined(separator: "\n")
            quoted = block + "\n> […]\n"
        }
        return "\n\n---\nOn \(email.date.formatted()), \(email.fromAddress) wrote:\n\(quoted)"
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
            // Generate one Message-ID up front so the delivered message,
            // the Sent-folder APPEND, and the local seed row all share it.
            // `upsertSentMessage` dedups on this value, so a shared ID also
            // makes double-Send + a future Sent-folder sync idempotent.
            let domain = accountFromAddressDomain()
            let messageID = "<\(UUID().uuidString)@\(domain)>"
            let outgoing = OutgoingEmail(
                fromAddress: account.fromAddress,
                toAddresses: parseAddresses(toAddresses),
                ccAddresses: parseAddresses(ccAddresses),
                subject: subject,
                bodyText: bodyText,
                messageID: messageID,
                inReplyTo: email.messageID,
                references: email.allReferenceIDs
            )
            try await SwiftMailClient(account: account).send(outgoing)
            guard !Task.isCancelled else { return }
            // Locally record the just-sent reply so it shows up in the
            // thread immediately. See `EmailRepository.upsertSentMessage`
            // for the synthetic-row lifecycle (uid is client-side + the
            // row gets promoted on the next Sent-folder sync).
            let sentMailbox = account.resolvedSentMailbox ?? "Sent"
            EmailRepository(modelContext: modelContext).upsertSentMessage(
                outgoing,
                account: account,
                sentMailbox: sentMailbox
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

    private func parseAddresses(_ raw: String) -> [String] {
        raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private enum EmailReplyComposerError: LocalizedError {
        case sendFailed(any Error)

        var errorDescription: String? {
            "Couldn't send reply"
        }

        var recoverySuggestion: String? {
            switch self {
            case .sendFailed(let error):
                "The reply remains in the composer. Check the account connection and try again. Details: \(error.localizedDescription)"
            }
        }
    }

    /// Extracts the domain for the Message-ID host (e.g. `me@example.com`
    /// → `example.com`). Falls back to `localhost` if parsing fails.
    private func accountFromAddressDomain() -> String {
        let address = account.fromAddress
        if let at = address.lastIndex(of: "@"),
           at < address.endIndex {
            let domain = address[address.index(after: at)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !domain.isEmpty {
                return String(domain)
            }
        }
        return "localhost"
    }
}
