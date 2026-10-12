import Foundation
import SwiftData

/// Builds and sends replies to an `Email`. Extracted from
/// `EmailReplyComposerView` so the notification inline-reply action and the
/// composer sheet share one draft-building + send path (Message-ID
/// generation, threading headers, Sent-folder seeding via
/// `upsertSentMessage`).
@MainActor
enum EmailReplySender {
    /// Prefill values for a reply: recipients, subject with a single reply
    /// marker, and the quoted original below the (empty) compose area.
    struct ReplyDraft {
        var toAddresses: String
        var ccAddresses: String
        var subject: String
        var bodyText: String
    }

    static func draft(replyingTo email: Email) -> ReplyDraft {
        ReplyDraft(
            toAddresses: EmailAddressParser.listEntry(email.fromAddress),
            ccAddresses: email.ccAddresses.map(EmailAddressParser.listEntry).joined(separator: ", "),
            // Recognize the full reply/forward marker set (re/fw/fwd/aw/wg) so
            // non-English or forwarded subjects don't get a doubled "Re: " prefix.
            subject: ThreadResolver.replyMarker(email.subject).isEmpty
                ? "Re: \(email.subject)"
                : email.subject,
            bodyText: replyQuote(for: email)
        )
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
    static func replyQuote(for email: Email) -> String {
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

    /// Sends a reply and locally records it so the thread updates
    /// immediately. See `EmailRepository.upsertSentMessage` for the
    /// synthetic-row lifecycle (client-side uid; the row gets promoted on the
    /// next Sent-folder sync).
    static func send(
        replyingTo email: Email,
        account: StoredEmailAccount,
        toAddresses: [String],
        ccAddresses: [String],
        subject: String,
        bodyText: String,
        modelContext: ModelContext,
        clientFactory: (StoredEmailAccount) -> MailClient = { SwiftMailClient(account: $0) }
    ) async throws {
        // Generate one Message-ID up front so the delivered message,
        // the Sent-folder APPEND, and the local seed row all share it.
        // `upsertSentMessage` dedups on this value, so a shared ID also
        // makes double-Send + a future Sent-folder sync idempotent.
        let domain = fromAddressDomain(of: account)
        let messageID = "<\(UUID().uuidString)@\(domain)>"
        let outgoing = OutgoingEmail(
            fromAddress: account.fromAddress,
            toAddresses: toAddresses,
            ccAddresses: ccAddresses,
            subject: subject,
            bodyText: bodyText,
            messageID: messageID,
            inReplyTo: email.messageID,
            references: email.allReferenceIDs
        )
        try await clientFactory(account).send(outgoing)
        let sentMailbox = account.resolvedSentMailbox ?? "Sent"
        EmailRepository(modelContext: modelContext).upsertSentMessage(
            outgoing,
            account: account,
            sentMailbox: sentMailbox
        )
    }

    /// One-shot reply used by the notification inline-reply action: the
    /// user's text on top of the standard quoted original, to the original
    /// sender + Cc list, with the draft's reply subject.
    static func sendQuickReply(
        to email: Email,
        bodyText: String,
        modelContext: ModelContext,
        clientFactory: (StoredEmailAccount) -> MailClient = { SwiftMailClient(account: $0) }
    ) async throws {
        guard let account = EmailAccountStore.shared.account(for: email.accountID),
              account.isComplete else {
            throw EmailReplySenderError.accountUnavailable
        }
        let draft = draft(replyingTo: email)
        try await send(
            replyingTo: email,
            account: account,
            toAddresses: parseAddresses(draft.toAddresses),
            ccAddresses: parseAddresses(draft.ccAddresses),
            subject: draft.subject,
            bodyText: bodyText + draft.bodyText,
            modelContext: modelContext,
            clientFactory: clientFactory
        )
    }

    /// Splits a recipient field into individual addresses, keeping display
    /// names (`Alice Smith <alice@example.com>`). Commas inside a quoted
    /// display name don't split; `SwiftMailClient` extracts the bare address
    /// for the SMTP envelope.
    static func parseAddresses(_ raw: String) -> [String] {
        EmailAddressParser.split(raw)
    }

    /// Extracts the domain for the Message-ID host (e.g. `me@example.com`
    /// → `example.com`). Falls back to `localhost` if parsing fails.
    private static func fromAddressDomain(of account: StoredEmailAccount) -> String {
        let address = EmailAddressParser.mailbox(account.fromAddress).address
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

enum EmailReplySenderError: LocalizedError {
    case accountUnavailable

    var errorDescription: String? {
        switch self {
        case .accountUnavailable:
            "The email's account is no longer configured."
        }
    }
}
