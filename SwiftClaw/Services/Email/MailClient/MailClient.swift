import Foundation

/// Result of a single mailbox fetch: the newly-fetched messages plus the
/// mailbox's UIDVALIDITY and the highest UID encountered in this batch (so
/// the caller can record a high-water mark for incremental sync). `maxUID`
/// is `nil` when the fetch returned no messages.
nonisolated struct MailboxFetchResult: Sendable, Hashable {
    let messages: [FetchedMessage]
    let uidValidity: UInt32
    let maxUID: UInt32?
}

/// Cheap UID-only (with flags) snapshot of a mailbox's current membership,
/// used by `MailSyncWorker`'s deletion- + flag-reconciliation pass. Unlike
/// `fetchMailbox` this performs no body fetch — one round-trip + a small
/// per-message payload (UID is always implicit; `FetchMessageInfoOptions`
/// `.uidFlagsOnly` only pulls `\Seen`/`\Flagged`). Practical to run on every
/// sync so the local store stays a faithful mirror of server membership.
nonisolated struct MailboxUIDSet: Sendable, Hashable {
    let uidValidity: UInt32
    let uids: Set<UInt32>
    /// Current `\Seen`/`\Flagged` state per UID, keyed by the UID value.
    /// Populated from the same cheap fetch as `uids`; lets the worker
    /// reconcile server-side flag drift on messages that already exist
    /// locally without a separate re-fetch pass.
    let flagsByUID: [UInt32: MailFlagSnapshot]
}

/// Minimal flag record carried alongside a `MailboxUIDSet` entry. Mirrors
/// the subset of IMAP flags SwiftClaw tracks; anything else the server
/// advertises is ignored.
nonisolated struct MailFlagSnapshot: Sendable, Hashable {
    let isRead: Bool
    let isFlagged: Bool

    init(isRead: Bool = false, isFlagged: Bool = false) {
        self.isRead = isRead
        self.isFlagged = isFlagged
    }
}

nonisolated enum MailFolderRole: String, Codable, Sendable, Hashable {
    case inbox
    case sent
    case drafts
    case trash
    case archive
    case junk
    case custom
}

nonisolated struct MailFolderDescriptor: Codable, Sendable, Hashable {
    let name: String
    let role: MailFolderRole
    let delimiter: String?
}

/// Domain-level normalized representation of a fetched email, decoupled from any
/// IMAP library type. The repository maps this into the SwiftData `Email` model.
nonisolated struct FetchedMessage: Sendable, Hashable {
    let uid: Int
    let messageID: String?
    let subject: String
    let fromAddress: String
    let toAddresses: [String]
    let ccAddresses: [String]
    let bccAddresses: [String]
    let date: Date
    let internalDate: Date?
    let bodyText: String
    let bodyHTML: String?
    let inReplyTo: String?
    let references: [String]
    let isRead: Bool
    let isFlagged: Bool
    let mailbox: String
    let attachmentDescriptors: [FetchedAttachmentDescriptor]
}

nonisolated struct FetchedAttachmentDescriptor: Sendable, Hashable {
    let filename: String
    let mimeType: String
    let sizeBytes: Int
    let partNumber: String?
    /// Attachment bytes when the fetch path already pulled them (the
    /// `fetchMailbox` full-body fetch does — `SwiftMailClient.normalize`
    /// populates this from `MessagePart.data`). `nil` when the calling
    /// path is metadata-only (e.g. `.uidFlagsOnly` scans). On upsert, the
    /// sync worker writes any non-nil payload to `EmailAttachmentStore`
    /// before entering the MainActor repository transaction, then records
    /// the relative path on the `EmailAttachment` row so the viewer can
    /// resolve an absolute URL without a separate fetch.
    let data: Data?

    init(
        filename: String,
        mimeType: String,
        sizeBytes: Int,
        partNumber: String?,
        data: Data? = nil
    ) {
        self.filename = filename
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
        self.partNumber = partNumber
        self.data = data
    }
}

/// A reply/forward/compose outgoing email, normalized to domain primitives.
///
/// `messageID` / `inReplyTo` / `references` carry RFC-822 threading headers
/// so replies correctly thread on the recipient side AND in SwiftClaw.
/// When set, `SwiftMailClient.send` writes them as `Message-ID` /
/// `In-Reply-To` / `References` headers on the outgoing message.
nonisolated struct OutgoingEmail: Sendable {
    let fromAddress: String
    let toAddresses: [String]
    let ccAddresses: [String]
    let bccAddresses: [String]
    let subject: String
    let bodyText: String
    let bodyHTML: String?
    /// Optional explicit Message-ID. When `nil`, the SMTP library generates
    /// one. Set when the same message is APPENDed to Sent so dedup survives
    /// retry across send + append.
    let messageID: String?
    /// `In-Reply-To` header value (the Message-ID being replied to).
    let inReplyTo: String?
    /// `References` header value (full ancestry chain, including
    /// `inReplyTo`).
    let references: [String]

    init(
        fromAddress: String,
        toAddresses: [String] = [],
        ccAddresses: [String] = [],
        bccAddresses: [String] = [],
        subject: String,
        bodyText: String,
        bodyHTML: String? = nil,
        messageID: String? = nil,
        inReplyTo: String? = nil,
        references: [String] = []
    ) {
        self.fromAddress = fromAddress
        self.toAddresses = toAddresses
        self.ccAddresses = ccAddresses
        self.bccAddresses = bccAddresses
        self.subject = subject
        self.bodyText = bodyText
        self.bodyHTML = bodyHTML
        self.messageID = messageID
        self.inReplyTo = inReplyTo
        self.references = references
    }
}

/// Domain-level flag updates applied via the underlying IMAP server.
nonisolated struct MailFlagUpdate: Sendable {
    let isRead: Bool?
    let isFlagged: Bool?
}

/// Abstracts IMAP+SMTP capabilities behind a single protocol so the rest of the
/// codebase can be tested with `MockMailClient` and so we can swap IMAP libraries
/// without touching the repository/scheduler layer.
nonisolated protocol MailClient: Sendable {
    /// Whether the underlying account credentials and hosts are configured.
    var isConfigured: Bool { get }

    /// Whether the server speaks IDLE (for efficient push sync in the future).
    var supportsIDLE: Bool { get }

    /// Verify the account is reachable: connects IMAP + SMTP, authenticates,
    /// then disconnects. Used by the add-account sheet's "Test" button.
    /// Throws `MailClientError` on any failure.
    func testConnection() async throws

    /// Fetch messages from the named mailbox since the given UID.
    /// `sinceUID == nil` or `0` fetches from the start of the mailbox.
    /// `maxMessages` caps the returned body fetch to the newest messages in
    /// that range. Returns the messages plus the mailbox's UIDVALIDITY and
    /// the highest UID seen in the returned batch.
    /// Incremental callers should pass the previously-recorded `lastSeenUID`
    /// so the server only returns new mail; if the UIDVALIDITY has changed
    /// since the last sync the caller should reset to `nil` and re-fetch all.
    func fetchMailbox(name: String, sinceUID: UInt32?, maxMessages: Int?) async throws -> MailboxFetchResult

    /// Cheap UID + flags scan of a mailbox's *current* membership, with no
    /// body fetch. Used by `MailSyncWorker` to reconcile server-side
    /// deletions (rows whose UID is missing from the server set get
    /// soft-deleted locally) and `\Seen`/`\Flagged` drift on messages that
    /// still exist. One round-trip + a small per-message payload — cheap
    /// enough to run on every sync so the local store mirrors the server
    /// faithfully instead of drifting indefinitely between full re-fetches.
    func fetchMailboxUIDSet(name: String) async throws -> MailboxUIDSet

    /// List selectable server folders and normalize provider-specific
    /// SPECIAL-USE metadata into app-level roles.
    func listFolders() async throws -> [MailFolderDescriptor]

    /// Apply flag changes (read / flagged) to a message identified by UID.
    func setFlags(uid: Int, mailbox: String, updates: MailFlagUpdate) async throws

    /// Move a message identified by UID to another mailbox (used for archive/trash).
    func move(uid: Int, from mailbox: String, to destination: String) async throws

    /// Archive a message: move it to the account's SPECIAL-USE Archive
    /// folder. Gmail's archive target is `[Gmail]/All Mail` (there's no
    /// literal `"Archive"` folder); Outlook/others vary. The client resolves
    /// the right name internally + caches it on `StoredEmailAccount`.
    func archive(uid: Int, from mailbox: String) async throws

    /// Permanently delete a message (expunge from the current mailbox). Used
    /// only by the explicit "Delete Permanently" affordance in the Trash
    /// mailbox — the regular `delete` moves to Trash.
    func deletePermanently(uid: Int, in mailbox: String) async throws

    /// Soft-delete: move the message to the account's Trash folder.
    /// Recoverable until the user empties Trash / expunges via
    /// `deletePermanently`. The destination folder is resolved via the
    /// account's cached special-use Trash name (falling back to `"Trash"`).
    func delete(uid: Int, in mailbox: String) async throws

    /// Send an outgoing email via SMTP. Threading headers (`In-Reply-To` /
    /// `References`) are populated from `OutgoingEmail`. Optionally APPENDs
    /// the sent message to the account's Sent folder so it shows up locally
    /// + on other clients — implementation is best-effort and must not
    /// fail the send if the APPEND can't be performed.
    func send(_ email: OutgoingEmail) async throws

    /// Resolve and cache the account's SPECIAL-USE folder names (Archive /
    /// Trash / Sent) via IMAP `LIST (SPECIAL-USE)`. Idempotent — returns the
    /// already-cached names if the account's `StoredEmailAccount` already
    /// has all three. Used by the delete→Trash, archive, and Sent-APPEND
    /// paths so the right server-side folder is targeted per provider.
    /// Throws on connection failure; callers swallow + fall back to defaults.
    func resolveSpecialUseMailboxes() async throws
}

extension MailClient {
    func fetchMailbox(name: String, sinceUID: UInt32?) async throws -> MailboxFetchResult {
        try await fetchMailbox(name: name, sinceUID: sinceUID, maxMessages: nil)
    }
}

nonisolated enum MailClientError: LocalizedError {
    case notConfigured
    case connectFailed(String)
    case authenticationFailed(String)
    case mailboxNotFound(String)
    case fetchFailed(String)
    case sendFailed(String)
    case unsupported(String)
    /// The server lacks UIDPLUS, so the message was copied to `destination`
    /// and marked `\Deleted` in `source` but not expunged: a folder-wide
    /// EXPUNGE could also purge mail another client marked deleted.
    case movedWithoutExpunge(source: String, destination: String)
    /// The server lacks UIDPLUS, so the message is marked `\Deleted` in
    /// `mailbox` but can't be expunged on its own.
    case targetedExpungeUnsupported(mailbox: String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "Email account is not configured. Add IMAP/SMTP credentials in Settings → Email."
        case .connectFailed(let reason):
            "Couldn't connect to the mail server: \(reason)"
        case .authenticationFailed(let reason):
            "Mail authentication failed: \(reason)"
        case .mailboxNotFound(let name):
            "Mailbox \"\(name)\" could not be found on the server."
        case .fetchFailed(let reason):
            "Fetching mail failed: \(reason)"
        case .sendFailed(let reason):
            "Sending mail failed: \(reason)"
        case .unsupported(let reason):
            "Operation not supported: \(reason)"
        case .movedWithoutExpunge(let source, let destination):
            "The server doesn't support targeted expunge, so the message was copied to \"\(destination)\" "
                + "and only marked deleted in \"\(source)\". It will disappear from \"\(source)\" "
                + "when another mail app expunges that folder."
        case .targetedExpungeUnsupported(let mailbox):
            "The server doesn't support targeted expunge, so the message is only marked deleted in "
                + "\"\(mailbox)\". It will be removed when another mail app expunges that folder."
        }
    }
}
