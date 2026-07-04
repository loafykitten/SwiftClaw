import Foundation
import os
import SwiftMail

/// `MailClient` backed by the SwiftMail (Cocoanetics) library.
///
/// Bound to a single `StoredEmailAccount`. Reads IMAP/SMTP host/port/username
/// from the account struct and passwords from the Keychain under the account's
/// per-account keys (`EmailAccountKeychainKeys.imapPassword(for:)` etc.) on
/// each call so that settings changes take effect on the next connection
/// without rebuilding the client.
///
/// Password overrides: the add-account sheet needs to test credentials before
/// they've been written to the Keychain (otherwise the test-then-confirm flow
/// is unreachable on a new account — `confirm()` is the only path that
/// persists the passwords). Provide `imapPasswordOverride` /
/// `smtpPasswordOverride` to short-circuit the Keychain read for
/// `testConnection()` only; sync paths still go through the Keychain.
final class SwiftMailClient: MailClient, @unchecked Sendable {
    private static let logger = AppLog.make("mail")

    private let account: StoredEmailAccount
    private let imapPasswordOverride: String?
    private let smtpPasswordOverride: String?

    nonisolated init(
        account: StoredEmailAccount,
        imapPasswordOverride: String? = nil,
        smtpPasswordOverride: String? = nil
    ) {
        self.account = account
        self.imapPasswordOverride = imapPasswordOverride
        self.smtpPasswordOverride = smtpPasswordOverride
    }

    var isConfigured: Bool {
        account.isComplete
            && !(imapPassword?.isEmpty ?? true)
            && !(smtpPassword?.isEmpty ?? true)
    }

    var supportsIDLE: Bool { false }

    // MARK: - Settings accessors

    private var imapHost: String { account.imapHost }
    private var imapPort: Int { account.imapPort }
    private var imapUsername: String { account.imapUsername }
    private var imapPassword: String? {
        if let override = imapPasswordOverride { return override }
        return Keychain.string(forKey: EmailAccountKeychainKeys.imapPassword(for: account.id))
    }
    private var smtpHost: String { account.smtpHost }
    private var smtpPort: Int { account.smtpPort }
    private var smtpUsername: String { account.smtpUsername }
    private var smtpPassword: String? {
        if let override = smtpPasswordOverride { return override }
        return Keychain.string(forKey: EmailAccountKeychainKeys.smtpPassword(for: account.id))
    }

    // MARK: - MailClient

    func testConnection() async throws {
        guard isConfigured else { throw MailClientError.notConfigured }

        // IMAP.
        let imapServer = makeIMAPServer()
        do {
            try await imapServer.connect()
            try await imapServer.login(username: imapUsername, password: imapPassword ?? "")
            try? await imapServer.disconnect()
        } catch {
            try? await imapServer.disconnect()
            Self.logger.error("""
                testConnection IMAP failed: \(String(describing: error))
                """)
            throw MailClientError.authenticationFailed(error.localizedDescription)
        }

        // SMTP.
        let smtpServer = SwiftMail.SMTPServer(host: smtpHost, port: smtpPort)
        do {
            try await smtpServer.connect()
            try await smtpServer.login(username: smtpUsername, password: smtpPassword ?? "")
            try? await smtpServer.disconnect()
        } catch {
            try? await smtpServer.disconnect()
            Self.logger.error("""
                testConnection SMTP failed: \(String(describing: error))
                """)
            throw MailClientError.authenticationFailed(error.localizedDescription)
        }
    }

    func fetchMailbox(
        name: String,
        sinceUID: UInt32? = nil,
        maxMessages: Int? = nil
    ) async throws -> MailboxFetchResult {
        guard isConfigured else { throw MailClientError.notConfigured }

        let server = makeIMAPServer()
        do {
            try await server.connect()
            try await server.login(username: imapUsername, password: imapPassword ?? "")
            let selection = try await server.selectMailbox(name)

            // Only fetch the messages the server hasn't already delivered to
            // us. `sinceUID` is the high-water mark from the last successful
            // sync with this UIDVALIDITY; if it's missing or zero (or the
            // UIDVALIDITY changed — the caller resets in that case) we fall
            // back to a full mailbox scan. Clamp against `UInt32.max` so a
            // pathological high-water doesn't overflow `+ 1`.
            let lowerBound: UInt32 = (sinceUID ?? 0) < UInt32.max
                ? (sinceUID ?? 0) + 1
                : UInt32.max
            let infos: [MessageInfo]
            if lowerBound > 1 {
                infos = try await server.fetchMessageInfos(
                    uidRange: UID(lowerBound)...,
                    options: .default
                )
            } else {
                infos = try await server.fetchMessageInfos(
                    uidRange: UID(1)...,
                    options: .default
                )
            }

            let infosToFetch: [MessageInfo]
            if let maxMessages, maxMessages > 0, infos.count > maxMessages {
                infosToFetch = Array(
                    infos
                        .filter { $0.uid != nil }
                        .sorted { ($0.uid?.value ?? 0) < ($1.uid?.value ?? 0) }
                        .suffix(maxMessages)
                )
            } else {
                infosToFetch = infos
            }

            var fetched: [FetchedMessage] = []
            fetched.reserveCapacity(infosToFetch.count)
            var maxUID: UInt32 = (sinceUID ?? 0)
            for info in infosToFetch {
                guard let uid = info.uid else { continue }
                let message = try await server.fetchMessage(from: info)
                fetched.append(Self.normalize(message, uid: uid, mailbox: name))
                if uid.value > maxUID { maxUID = uid.value }
            }
            try? await server.disconnect()
            return MailboxFetchResult(
                messages: fetched,
                uidValidity: selection.uidValidity.value,
                maxUID: fetched.isEmpty ? nil : maxUID
            )
        } catch {
            Self.logger.error("""
                fetchMailbox(\(name, privacy: .public)) failed: \
                \(String(describing: error))
                """)
            try? await server.disconnect()
            throw MailClientError.fetchFailed(error.localizedDescription)
        }
    }

    func fetchMailboxUIDSet(name: String) async throws -> MailboxUIDSet {
        guard isConfigured else { throw MailClientError.notConfigured }

        let server = makeIMAPServer()
        do {
            try await server.connect()
            try await server.login(username: imapUsername, password: imapPassword ?? "")
            let selection = try await server.selectMailbox(name)
            // `.uidFlagsOnly` requests just FLAGS (UID is always implicit on
            // a UID FETCH). One round-trip + ~50 bytes/message — practical
            // to run on every sync even for thousands of messages.
            let infos = try await server.fetchMessageInfos(
                uidRange: UID(1)...,
                options: .uidFlagsOnly
            )
            try? await server.disconnect()

            var uids: Set<UInt32> = []
            uids.reserveCapacity(infos.count)
            var flagsByUID: [UInt32: MailFlagSnapshot] = [:]
            flagsByUID.reserveCapacity(infos.count)
            for info in infos {
                guard let uid = info.uid else { continue }
                uids.insert(uid.value)
                flagsByUID[uid.value] = MailFlagSnapshot(
                    isRead: info.flags.contains(.seen),
                    isFlagged: info.flags.contains(.flagged)
                )
            }
            return MailboxUIDSet(
                uidValidity: selection.uidValidity.value,
                uids: uids,
                flagsByUID: flagsByUID
            )
        } catch {
            Self.logger.error("""
                fetchMailboxUIDSet(\(name, privacy: .public)) failed: \
                \(String(describing: error))
                """)
            try? await server.disconnect()
            throw MailClientError.fetchFailed(error.localizedDescription)
        }
    }

    func setFlags(uid: Int, mailbox: String, updates: MailFlagUpdate) async throws {
        guard isConfigured else { throw MailClientError.notConfigured }

        let server = makeIMAPServer()
        do {
            try await server.connect()
            try await server.login(username: imapUsername, password: imapPassword ?? "")
            _ = try await server.selectMailbox(mailbox)

            var flagsToAdd: [Flag] = []
            var flagsToRemove: [Flag] = []
            if let isRead = updates.isRead {
                if isRead { flagsToAdd.append(.seen) } else { flagsToRemove.append(.seen) }
            }
            if let isFlagged = updates.isFlagged {
                if isFlagged { flagsToAdd.append(.flagged) } else { flagsToRemove.append(.flagged) }
            }

            let uidSet = UIDSet([UID(UInt32(uid))])
            if !flagsToAdd.isEmpty {
                try await server.store(flags: flagsToAdd, on: uidSet, operation: .add)
            }
            if !flagsToRemove.isEmpty {
                try await server.store(flags: flagsToRemove, on: uidSet, operation: .remove)
            }
            try? await server.disconnect()
        } catch {
            try? await server.disconnect()
            throw MailClientError.fetchFailed(error.localizedDescription)
        }
    }

    func move(uid: Int, from mailbox: String, to destination: String) async throws {
        guard isConfigured else { throw MailClientError.notConfigured }

        let server = makeIMAPServer()
        do {
            try await server.connect()
            try await server.login(username: imapUsername, password: imapPassword ?? "")
            _ = try await server.selectMailbox(mailbox)
            try await server.move(message: UID(UInt32(uid)), to: destination)
            try? await server.disconnect()
        } catch {
            try? await server.disconnect()
            throw MailClientError.fetchFailed(error.localizedDescription)
        }
    }

    func archive(uid: Int, from mailbox: String) async throws {
        // Resolve the account's SPECIAL-USE Archive folder (Gmail uses
        // `[Gmail]/All Mail`; there is no literal "Archive" folder on Gmail,
        // and the previous hardcode silently failed `move` + diverged local
        // vs server state).
        let archiveMailbox = await resolvedArchiveMailbox()
        try await move(uid: uid, from: mailbox, to: archiveMailbox)
    }

    func delete(uid: Int, in mailbox: String) async throws {
        guard isConfigured else { throw MailClientError.notConfigured }

        // "Delete" is a recoverable move to the account's Trash folder rather
        // than an irreversible `\Deleted + expunge`. The real expunge path is
        // reserved for the explicit "Delete Permanently" affordance
        // (`deletePermanently`) so users don't lose mail they expected to be
        // recoverable.
        let trashMailbox = await resolvedTrashMailbox()
        do {
            try await move(uid: uid, from: mailbox, to: trashMailbox)
        } catch {
            Self.logger.error("""
                delete (move to Trash) failed for \(mailbox, privacy: .public): \
                \(String(describing: error))
                """)
            throw MailClientError.fetchFailed(error.localizedDescription)
        }
    }

    func deletePermanently(uid: Int, in mailbox: String) async throws {
        guard isConfigured else { throw MailClientError.notConfigured }

        let server = makeIMAPServer()
        do {
            try await server.connect()
            try await server.login(username: imapUsername, password: imapPassword ?? "")
            _ = try await server.selectMailbox(mailbox)

            let uidSet = UIDSet([UID(UInt32(uid))])
            try await server.store(flags: [.deleted], on: uidSet, operation: .add)
            try await server.expunge()
            try? await server.disconnect()
        } catch {
            try? await server.disconnect()
            throw MailClientError.fetchFailed(error.localizedDescription)
        }
    }

    func send(_ email: OutgoingEmail) async throws {
        guard isConfigured else { throw MailClientError.notConfigured }

        let server = SwiftMail.SMTPServer(host: smtpHost, port: smtpPort)
        do {
            try await server.connect()
            try await server.login(username: smtpUsername, password: smtpPassword ?? "")
            try await server.sendEmail(Self.makeSwiftMailEmail(from: email))
            try? await server.disconnect()
        } catch {
            try? await server.disconnect()
            Self.logger.error("""
                send failed: \(String(describing: error))
                """)
            throw MailClientError.sendFailed(error.localizedDescription)
        }

        // Best-effort APPEND to the account's Sent folder so the reply
        // shows up locally (on the next sync) and on other clients. Any
        // failure here is logged and swallowed — the send already succeeded
        // and the user shouldn't see a send error for an APPEND problem.
        await appendToSentIfNeeded(email: email)
    }

    // MARK: - Special-use folder resolution

    /// Resolves and caches the account's Archive/Trash/Sent folder names via
    /// IMAP `LIST (SPECIAL-USE)`. Idempotent — short-circuits when all three
    /// are already cached on `StoredEmailAccount`. Throws on connection
    /// failure; callers fall back to defaults.
    func resolveSpecialUseMailboxes() async throws {
        // Short-circuit when all three are already resolved. (Additive — a
        // re-resolve after a server-side folder rename requires the user to
        // remove + re-add the account, which already clears
        // `MailboxSyncStateStore`.)
        if account.archiveMailbox != nil,
           account.trashMailbox != nil,
           account.sentMailbox != nil {
            return
        }
        guard isConfigured else { throw MailClientError.notConfigured }

        let server = makeIMAPServer()
        do {
            try await server.connect()
            try await server.login(username: imapUsername, password: imapPassword ?? "")
            _ = try await server.listSpecialUseMailboxes()

            var updated = account
            if updated.archiveMailbox == nil,
               let archive = try? await server.archiveFolder.name {
                updated.archiveMailbox = archive
            }
            if updated.trashMailbox == nil,
               let trash = try? await server.trashFolder.name {
                updated.trashMailbox = trash
            }
            if updated.sentMailbox == nil,
               let sent = try? await server.sentFolder.name {
                updated.sentMailbox = sent
            }
            try? await server.disconnect()

            // Persist the resolved names back to `EmailAccountStore` so
            // subsequent archive/delete/send calls hit the cache instead of
            // re-listing mailboxes every time.
            let accountToUpdate = updated
            await MainActor.run {
                EmailAccountStore.shared.update(accountToUpdate)
            }
        } catch {
            try? await server.disconnect()
            Self.logger.error("""
                resolveSpecialUseMailboxes failed: \(String(describing: error))
                """)
            throw MailClientError.fetchFailed(error.localizedDescription)
        }
    }

    /// Best-effort APPEND of the just-sent message to the account's Sent
    /// folder. Any failure is logged and swallowed because the send itself
    /// has already succeeded.
    private func appendToSentIfNeeded(email: OutgoingEmail) async {
        guard let sentMailbox = await resolvedSentMailbox() else {
            // No Sent folder resolved (or resolution failed) — skip the
            // APPEND. The reply is still delivered; it just won't appear in
            // SwiftClaw until the next sync happens to pick it up from Sent.
            return
        }
        let server = makeIMAPServer()
        do {
            try await server.connect()
            try await server.login(username: imapUsername, password: imapPassword ?? "")
            let swiftMailEmail = Self.makeSwiftMailEmail(from: email)
            _ = try await server.append(
                email: swiftMailEmail,
                to: sentMailbox,
                flags: [.seen]
            )
            try? await server.disconnect()
        } catch {
            try? await server.disconnect()
            Self.logger.error("""
                APPEND to Sent (\(sentMailbox, privacy: .public)) failed: \
                \(String(describing: error))
                """)
        }
    }

    /// Builds the library-level `SwiftMail.Email` from the domain
    /// `OutgoingEmail`, populating `In-Reply-To` / `References` /
    /// `Message-ID` from the threading fields. Shared by the SMTP `send`
    /// path and the best-effort Sent-folder APPEND so the two stay in
    /// sync for an on-server dedup by Message-ID.
    private static func makeSwiftMailEmail(from email: OutgoingEmail) -> SwiftMail.Email {
        var additionalHeaders: [String: String] = [:]
        if let inReplyTo = email.inReplyTo, !inReplyTo.isEmpty {
            additionalHeaders["In-Reply-To"] = inReplyTo
        }
        if !email.references.isEmpty {
            additionalHeaders["References"] = email.references.joined(separator: " ")
        }
        var swiftMailEmail = SwiftMail.Email(
            sender: EmailAddress(address: email.fromAddress),
            recipients: email.toAddresses.map { EmailAddress(address: $0) },
            ccRecipients: email.ccAddresses.map { EmailAddress(address: $0) },
            bccRecipients: email.bccAddresses.map { EmailAddress(address: $0) },
            subject: email.subject,
            textBody: email.bodyText,
            htmlBody: email.bodyHTML
        )
        if !additionalHeaders.isEmpty {
            swiftMailEmail.additionalHeaders = additionalHeaders
        }
        if let messageID = email.messageID, !messageID.isEmpty,
           let parsed = SwiftMail.MessageID(messageID)
        {
            swiftMailEmail.messageID = parsed
        }
        return swiftMailEmail
    }

    /// Resolves the account's Archive mailbox name. Triggers a one-shot
    /// `listSpecialUseMailboxes()` fetch on cache miss so an archive action
    /// on Gmail targets `[Gmail]/All Mail` rather than the non-existent
    /// `"Archive"`. Falls back to the account default on failure.
    private func resolvedArchiveMailbox() async -> String {
        if let cached = account.archiveMailbox { return cached }
        try? await resolveSpecialUseMailboxes()
        if let refreshed = await MainActor.run(body: {
            EmailAccountStore.shared.account(for: account.id)?.archiveMailbox
        }) {
            return refreshed
        }
        return account.resolvedArchiveMailbox
    }

    private func resolvedTrashMailbox() async -> String {
        if let cached = account.trashMailbox { return cached }
        try? await resolveSpecialUseMailboxes()
        if let refreshed = await MainActor.run(body: {
            EmailAccountStore.shared.account(for: account.id)?.trashMailbox
        }) {
            return refreshed
        }
        return account.resolvedTrashMailbox
    }

    private func resolvedSentMailbox() async -> String? {
        if let cached = account.sentMailbox { return cached }
        try? await resolveSpecialUseMailboxes()
        return await MainActor.run(body: {
            EmailAccountStore.shared.account(for: account.id)?.sentMailbox
                ?? account.resolvedSentMailbox
        })
    }

    // MARK: - Helpers

    private func makeIMAPServer() -> IMAPServer {
        IMAPServer(host: imapHost, port: imapPort)
    }

    private static func normalize(_ message: SwiftMail.Message, uid: UID, mailbox: String) -> FetchedMessage {
        let header = message.header
        return FetchedMessage(
            uid: Int(uid.value),
            messageID: header.messageId?.description,
            subject: header.subject ?? "",
            fromAddress: EmailAddressDisplayFormatter.string(header.from ?? ""),
            toAddresses: header.to.map(EmailAddressDisplayFormatter.string),
            ccAddresses: header.cc.map(EmailAddressDisplayFormatter.string),
            bccAddresses: header.bcc.map(EmailAddressDisplayFormatter.string),
            date: header.date ?? .now,
            internalDate: header.internalDate,
            bodyText: message.textBody ?? "",
            bodyHTML: message.htmlBody,
            inReplyTo: header.inReplyTo?.description,
            references: (header.references ?? []).map { $0.description },
            isRead: header.flags.contains(.seen),
            isFlagged: header.flags.contains(.flagged),
            mailbox: mailbox,
            attachmentDescriptors: message.attachments.map { part in
                FetchedAttachmentDescriptor(
                    filename: part.filename ?? "attachment",
                    mimeType: part.contentType,
                    sizeBytes: part.data?.count ?? 0,
                    partNumber: part.section.description,
                    data: part.data
                )
            }
        )
    }
}
