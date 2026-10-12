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
/// IMAP operations run over a persistent per-account connection from
/// `IMAPSessionPool` (long-running fetches on the `.sync` channel, quick
/// mutations on `.interactive`) instead of a fresh connect/login/disconnect
/// per call. SMTP stays per-send: sends are infrequent user actions and SMTP
/// servers aggressively close idle connections, so there's nothing to reuse.
///
/// Password overrides: the add-account sheet needs to test credentials before
/// they've been written to the Keychain (otherwise the test-then-confirm flow
/// is unreachable on a new account — `confirm()` is the only path that
/// persists the passwords). Provide `imapPasswordOverride` /
/// `smtpPasswordOverride` to short-circuit the Keychain read for
/// `testConnection()` only; sync paths still go through the Keychain.
/// Transport security for every IMAP/SMTP connection SwiftClaw opens.
///
/// SwiftMail's `.automatic` default treats STARTTLS on IMAP 143 / SMTP 587 as
/// opportunistic (an attacker who strips the capability gets a plaintext
/// login) and falls back to plaintext SMTP on any other port. SwiftClaw never
/// authenticates in the clear: implicit-TLS ports use TLS from the first byte
/// and every other port requires a successful STARTTLS upgrade before login.
nonisolated enum MailTransportPolicy {
    /// IMAP 143 is the STARTTLS port; 993 and anything non-standard use
    /// implicit TLS.
    static func imap(port: Int) -> MailTransportSecurity {
        port == 143 ? .startTLS : .implicitTLS
    }

    /// SMTP 465 is implicit TLS; 587, 25, 2525, and other submission ports
    /// must upgrade with STARTTLS.
    static func smtp(port: Int) -> MailTransportSecurity {
        port == 465 ? .implicitTLS : .startTLS
    }
}

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
        let smtpServer = makeSMTPServer()
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

        do {
            return try await withIMAPSession(channel: .sync) { server in
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
                let infosToFetch: [MessageInfo]
                if sinceUID == nil,
                   let maxMessages,
                   maxMessages > 0,
                   let latest = selection.latest(maxMessages) {
                    // Sequence numbers are contiguous positions in the
                    // selected mailbox, so this asks the server for exactly
                    // the newest N entries without guessing from sparse UIDs.
                    infosToFetch = try await server.fetchMessageInfosBulk(
                        using: latest,
                        options: .default
                    )
                } else {
                    infosToFetch = try await server.fetchMessageInfos(
                        uidRange: UID(lowerBound)...,
                        options: .default
                    )
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
                return MailboxFetchResult(
                    messages: fetched,
                    uidValidity: selection.uidValidity.value,
                    maxUID: fetched.isEmpty ? nil : maxUID
                )
            }
        } catch {
            Self.logger.error("""
                fetchMailbox(\(name, privacy: .public)) failed: \
                \(String(describing: error))
                """)
            throw MailClientError.fetchFailed(error.localizedDescription)
        }
    }

    func fetchMailboxUIDSet(name: String) async throws -> MailboxUIDSet {
        guard isConfigured else { throw MailClientError.notConfigured }

        do {
            return try await withIMAPSession(channel: .sync) { server in
                let selection = try await server.selectMailbox(name)
                // `.uidFlagsOnly` requests just FLAGS (UID is always implicit on
                // a UID FETCH). One round-trip + ~50 bytes/message — practical
                // to run on every sync even for thousands of messages.
                let infos = try await server.fetchMessageInfos(
                    uidRange: UID(1)...,
                    options: .uidFlagsOnly
                )

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
            }
        } catch {
            Self.logger.error("""
                fetchMailboxUIDSet(\(name, privacy: .public)) failed: \
                \(String(describing: error))
                """)
            throw MailClientError.fetchFailed(error.localizedDescription)
        }
    }

    func listFolders() async throws -> [MailFolderDescriptor] {
        guard isConfigured else { throw MailClientError.notConfigured }

        do {
            let folders = try await withIMAPSession(channel: .sync) { server in
                Self.classify(try await server.listMailboxes())
            }

            // Adopt catalog names when the server advertised the role, but
            // keep already-resolved names when it didn't — servers without
            // SPECIAL-USE resolve Sent/Trash via `resolveSpecialUseMailboxes`'s
            // name heuristics, and Gmail's archive (`\All`) never appears in
            // the catalog. Clobbering those with nil would break the Sent
            // APPEND and archive paths.
            func catalogName(for role: MailFolderRole) -> String? {
                folders.first { $0.role == role }?.name
            }
            let snapshot = account
            _ = await MainActor.run {
                EmailAccountStore.shared.mergeDiscoveredFolders(into: snapshot) { updated in
                    updated.folders = folders
                    updated.sentMailbox = catalogName(for: .sent) ?? updated.sentMailbox
                    updated.draftsMailbox = catalogName(for: .drafts) ?? updated.draftsMailbox
                    updated.trashMailbox = catalogName(for: .trash) ?? updated.trashMailbox
                    updated.archiveMailbox = catalogName(for: .archive) ?? updated.archiveMailbox
                    updated.junkMailbox = catalogName(for: .junk) ?? updated.junkMailbox
                }
            }
            return folders
        } catch {
            Self.logger.error("""
                listFolders failed: \(String(describing: error))
                """)
            throw MailClientError.fetchFailed(error.localizedDescription)
        }
    }

    func setFlags(uid: Int, mailbox: String, updates: MailFlagUpdate) async throws {
        guard isConfigured else { throw MailClientError.notConfigured }

        do {
            try await withIMAPSession(channel: .interactive) { server in
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
            }
        } catch {
            throw MailClientError.fetchFailed(error.localizedDescription)
        }
    }

    func move(uid: Int, from mailbox: String, to destination: String) async throws {
        guard isConfigured else { throw MailClientError.notConfigured }

        do {
            try await withIMAPSession(channel: .interactive) { server in
                _ = try await server.selectMailbox(mailbox)
                let target = UID(UInt32(uid))
                guard await server.supportsUIDPlus else {
                    // SwiftMail's non-UIDPLUS fallback is COPY + \Deleted +
                    // an unqualified EXPUNGE, which would also purge every
                    // message any client has marked \Deleted in the source
                    // folder — and no earlier snapshot can rule that out.
                    // Do the COPY + \Deleted ourselves and leave the expunge
                    // to whichever client next expunges the folder.
                    try await server.copy(messages: UIDSet([target]), to: destination)
                    try await server.store(flags: [.deleted], on: UIDSet([target]), operation: .add)
                    throw MailClientError.movedWithoutExpunge(source: mailbox, destination: destination)
                }
                try await server.move(message: target, to: destination)
            }
        } catch let error as MailClientError {
            throw error
        } catch {
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
            throw error
        }
    }

    func deletePermanently(uid: Int, in mailbox: String) async throws {
        guard isConfigured else { throw MailClientError.notConfigured }

        do {
            try await withIMAPSession(channel: .interactive) { server in
                _ = try await server.selectMailbox(mailbox)

                let uidSet = UIDSet([UID(UInt32(uid))])
                try await server.store(flags: [.deleted], on: uidSet, operation: .add)
                // A bare EXPUNGE removes every message flagged \Deleted in
                // the folder, including deletions another client has staged
                // but not committed, so only `UID EXPUNGE` (UIDPLUS, RFC 4315)
                // is safe. Without it the message stays flagged.
                guard await server.supportsUIDPlus else {
                    throw MailClientError.targetedExpungeUnsupported(mailbox: mailbox)
                }
                try await server.expunge(messages: uidSet)
            }
        } catch let error as MailClientError {
            throw error
        } catch {
            throw MailClientError.fetchFailed(error.localizedDescription)
        }
    }

    func send(_ email: OutgoingEmail) async throws {
        guard isConfigured else { throw MailClientError.notConfigured }
        // `makeSwiftMailEmail` drops entries without a deliverable address so
        // empty groups don't break the envelope; anything else is a typo the
        // user must fix, not a recipient to silently skip.
        let invalid = EmailAddressParser.invalidRecipients(
            email.toAddresses + email.ccAddresses + email.bccAddresses
        )
        guard invalid.isEmpty else {
            throw MailClientError.sendFailed(
                "Not a valid email address: \(invalid.joined(separator: ", "))"
            )
        }

        let server = makeSMTPServer()
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

        if account.folders == nil {
            _ = try await listFolders()
            return
        }

        do {
            let resolved = try await withIMAPSession(channel: .interactive) { server in
                _ = try await server.listSpecialUseMailboxes()
                return (
                    archive: try? await server.archiveFolder.name,
                    trash: try? await server.trashFolder.name,
                    sent: try? await server.sentFolder.name
                )
            }

            // Persist the resolved names back to `EmailAccountStore` so
            // subsequent archive/delete/send calls hit the cache instead of
            // re-listing mailboxes every time. Fill only names that are still
            // unresolved on the current account.
            let snapshot = account
            _ = await MainActor.run {
                EmailAccountStore.shared.mergeDiscoveredFolders(into: snapshot) { updated in
                    if updated.archiveMailbox == nil { updated.archiveMailbox = resolved.archive }
                    if updated.trashMailbox == nil { updated.trashMailbox = resolved.trash }
                    if updated.sentMailbox == nil { updated.sentMailbox = resolved.sent }
                }
            }
        } catch {
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
        do {
            try await withIMAPSession(channel: .interactive) { server in
                let swiftMailEmail = Self.makeSwiftMailEmail(from: email)
                _ = try await server.append(
                    email: swiftMailEmail,
                    to: sentMailbox,
                    flags: [.seen]
                )
            }
        } catch {
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
            sender: swiftMailAddress(email.fromAddress) ?? EmailAddress(address: email.fromAddress),
            recipients: email.toAddresses.compactMap(swiftMailAddress),
            ccRecipients: email.ccAddresses.compactMap(swiftMailAddress),
            bccRecipients: email.bccAddresses.compactMap(swiftMailAddress),
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

    /// Maps a stored address (`Alice Smith <alice@example.com>` or a bare
    /// address) to SwiftMail's split form: SMTP `MAIL FROM` / `RCPT TO` use
    /// only `address`, the display name stays in the headers. `nil` for an
    /// entry with no deliverable address (e.g. an empty group like
    /// `undisclosed-recipients:;`); `send` rejects any other such entry up
    /// front, so only empty groups are dropped here.
    static func swiftMailAddress(_ raw: String) -> EmailAddress? {
        let mailbox = EmailAddressParser.mailbox(raw)
        guard EmailAddressParser.isDeliverableAddress(mailbox.address) else { return nil }
        return EmailAddress(name: mailbox.name, address: mailbox.address)
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

    static func classify(_ infos: [Mailbox.Info]) -> [MailFolderDescriptor] {
        var descriptors: [MailFolderDescriptor] = []
        var seenNames = Set<String>()
        var hasInbox = false

        for info in infos {
            guard info.isSelectable else { continue }
            guard !info.attributes.contains(.flagged) else { continue }

            let nameKey = info.name.lowercased()
            guard seenNames.insert(nameKey).inserted else { continue }

            let role: MailFolderRole
            if info.name.caseInsensitiveCompare("INBOX") == .orderedSame {
                guard !hasInbox else { continue }
                hasInbox = true
                role = .inbox
            } else if info.attributes.contains(.inbox) {
                guard !hasInbox else { continue }
                hasInbox = true
                role = .inbox
            } else if info.attributes.contains(.sent) {
                role = .sent
            } else if info.attributes.contains(.drafts) {
                role = .drafts
            } else if info.attributes.contains(.trash) {
                role = .trash
            } else if info.attributes.contains(.archive) {
                role = .archive
            } else if info.attributes.contains(.junk) {
                role = .junk
            } else {
                role = .custom
            }

            if role == .custom, isGmailSystemNamespace(info) {
                continue
            }

            descriptors.append(MailFolderDescriptor(
                name: info.name,
                role: role,
                delimiter: info.hierarchyDelimiter
            ))
        }

        return descriptors
    }

    private static func isGmailSystemNamespace(_ info: Mailbox.Info) -> Bool {
        let lowercased = info.name.lowercased()
        let delimiters = [info.hierarchyDelimiter, "/", "."].compactMap(\.self)
        for prefix in ["[gmail]", "[google mail]"] {
            for delimiter in delimiters where lowercased.hasPrefix(prefix + delimiter) {
                return true
            }
        }
        return false
    }

    /// Fresh, standalone server for `testConnection()` only — the Test
    /// button must prove a cold connect + login works (and may be running
    /// with password overrides that shouldn't touch the shared sessions).
    /// Every other IMAP operation goes through `withIMAPSession`.
    private func makeIMAPServer() -> IMAPServer {
        IMAPServer(
            host: imapHost,
            port: imapPort,
            transportSecurity: MailTransportPolicy.imap(port: imapPort)
        )
    }

    private func makeSMTPServer() -> SwiftMail.SMTPServer {
        SwiftMail.SMTPServer(
            host: smtpHost,
            port: smtpPort,
            transportSecurity: MailTransportPolicy.smtp(port: smtpPort)
        )
    }

    /// Runs `body` on the account's persistent IMAP session for the given
    /// channel (see `IMAPSessionPool`). The session connects + logs in
    /// lazily and reuses the connection across calls; callers must not
    /// invoke another session-backed client method from inside `body` (the
    /// per-session serialization is non-reentrant and would deadlock).
    private func withIMAPSession<T: Sendable>(
        channel: IMAPSessionPool.Channel,
        _ body: @Sendable (IMAPServer) async throws -> T
    ) async throws -> T {
        let session = await IMAPSessionPool.shared.session(for: account, channel: channel)
        return try await session.perform(
            username: imapUsername,
            password: imapPassword ?? "",
            body
        )
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
