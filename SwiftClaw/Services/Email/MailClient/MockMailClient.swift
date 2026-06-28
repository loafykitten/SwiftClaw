import Foundation

/// In-memory `MailClient` used by tests and SwiftUI previews. Maintains
/// mailbox state keyed by name; never touches the network or Keychain.
actor MockMailClient: MailClient {
    private var mailboxes: [String: [FetchedMessage]] = [:]
    private(set) var sentEmails: [OutgoingEmail] = []
    private(set) var flagUpdates: [(uid: Int, mailbox: String, updates: MailFlagUpdate)] = []
    private(set) var moves: [(uid: Int, from: String, to: String)] = []
    private(set) var deletes: [Int] = []
    /// Tracks `delete(uid:in:)` calls separately from
    /// `deletePermanently` — `deletes` is the soft-delete (move-to-Trash)
    /// path; `permanentDeletes` is the irreversible expunge path.
    private(set) var permanentDeletes: [Int] = []

    /// Test-configurable resolved special-use folder names. Returned by
    /// `resolveSpecialUseMailboxes()` so tests can assert the cache path is
    /// hit; defaults to `nil` (resolution returns "Archive"/"Trash"/nil).
    var mockArchiveMailbox: String? = nil
    var mockTrashMailbox: String? = nil
    var mockSentMailbox: String? = nil
    private(set) var specialUseResolutionCount: Int = 0

    nonisolated let isConfigured: Bool
    nonisolated let supportsIDLE = false

    init(isConfigured: Bool = true) {
        self.isConfigured = isConfigured
    }

    func setMailbox(_ name: String, messages: [FetchedMessage]) {
        mailboxes[name] = messages
    }

    func addMessage(_ message: FetchedMessage, to mailbox: String) {
        var existing = mailboxes[mailbox] ?? []
        existing.append(message)
        mailboxes[mailbox] = existing
    }

    func testConnection() async throws {
        guard isConfigured else { throw MailClientError.notConfigured }
    }

    /// Mock UIDVALIDITY for `MailboxFetchResult`. Tests that exercise
    /// incremental sync can mutate this between calls to simulate a folder
    /// rebuild.
    private(set) var uidValidity: UInt32 = 1

    func setUIDValidity(_ newValue: UInt32) {
        uidValidity = newValue
    }

    private(set) var fetchRequests: [(name: String, sinceUID: UInt32?, maxMessages: Int?)] = []

    func fetchMailbox(
        name: String,
        sinceUID: UInt32? = nil,
        maxMessages: Int? = nil
    ) async throws -> MailboxFetchResult {
        fetchRequests.append((name: name, sinceUID: sinceUID, maxMessages: maxMessages))
        let all = mailboxes[name] ?? []
        let filteredByUID: [FetchedMessage]
        if let sinceUID, sinceUID > 0 {
            filteredByUID = all.filter { UInt32($0.uid) > sinceUID }
        } else {
            filteredByUID = all
        }
        let filtered: [FetchedMessage]
        if let maxMessages, maxMessages > 0, filteredByUID.count > maxMessages {
            filtered = Array(filteredByUID.sorted { $0.uid < $1.uid }.suffix(maxMessages))
        } else {
            filtered = filteredByUID
        }
        let maxUID = filtered.map { UInt32($0.uid) }.max()
        return MailboxFetchResult(
            messages: filtered,
            uidValidity: uidValidity,
            maxUID: maxUID
        )
    }

    func fetchMailboxUIDSet(name: String) async throws -> MailboxUIDSet {
        let all = mailboxes[name] ?? []
        var uids: Set<UInt32> = []
        uids.reserveCapacity(all.count)
        var flagsByUID: [UInt32: MailFlagSnapshot] = [:]
        flagsByUID.reserveCapacity(all.count)
        for message in all {
            let uidValue = UInt32(message.uid)
            uids.insert(uidValue)
            flagsByUID[uidValue] = MailFlagSnapshot(
                isRead: message.isRead,
                isFlagged: message.isFlagged
            )
        }
        return MailboxUIDSet(
            uidValidity: uidValidity,
            uids: uids,
            flagsByUID: flagsByUID
        )
    }

    func setFlags(uid: Int, mailbox: String, updates: MailFlagUpdate) async throws {
        flagUpdates.append((uid, mailbox, updates))
        guard var messages = mailboxes[mailbox],
              let index = messages.firstIndex(where: { $0.uid == uid }) else { return }
        let original = messages[index]
        messages[index] = FetchedMessage(
            uid: original.uid,
            messageID: original.messageID,
            subject: original.subject,
            fromAddress: original.fromAddress,
            toAddresses: original.toAddresses,
            ccAddresses: original.ccAddresses,
            bccAddresses: original.bccAddresses,
            date: original.date,
            internalDate: original.internalDate,
            bodyText: original.bodyText,
            bodyHTML: original.bodyHTML,
            inReplyTo: original.inReplyTo,
            references: original.references,
            isRead: updates.isRead ?? original.isRead,
            isFlagged: updates.isFlagged ?? original.isFlagged,
            mailbox: original.mailbox,
            attachmentDescriptors: original.attachmentDescriptors
        )
        mailboxes[mailbox] = messages
    }

    func move(uid: Int, from mailbox: String, to destination: String) async throws {
        moves.append((uid, mailbox, destination))
        guard var messages = mailboxes[mailbox],
              let index = messages.firstIndex(where: { $0.uid == uid }) else { return }
        let original = messages.remove(at: index)
        mailboxes[mailbox] = messages
        let moved = FetchedMessage(
            uid: original.uid,
            messageID: original.messageID,
            subject: original.subject,
            fromAddress: original.fromAddress,
            toAddresses: original.toAddresses,
            ccAddresses: original.ccAddresses,
            bccAddresses: original.bccAddresses,
            date: original.date,
            internalDate: original.internalDate,
            bodyText: original.bodyText,
            bodyHTML: original.bodyHTML,
            inReplyTo: original.inReplyTo,
            references: original.references,
            isRead: original.isRead,
            isFlagged: original.isFlagged,
            mailbox: destination,
            attachmentDescriptors: original.attachmentDescriptors
        )
        mailboxes[destination, default: []].append(moved)
    }

    /// `delete` is a recoverable move to the Trash mailbox rather than an
    /// irreversible removal. Tests that previously asserted on `deletes`
    /// should assert on `moves` (where `to == "Trash"` or the configured
    /// `mockTrashMailbox`). The irreversible path is `deletePermanently`.
    func delete(uid: Int, in mailbox: String) async throws {
        let trashMailbox = mockTrashMailbox ?? "Trash"
        try await move(uid: uid, from: mailbox, to: trashMailbox)
        deletes.append(uid)
    }

    func deletePermanently(uid: Int, in mailbox: String) async throws {
        permanentDeletes.append(uid)
        mailboxes[mailbox]?.removeAll { $0.uid == uid }
    }

    func send(_ email: OutgoingEmail) async throws {
        sentEmails.append(email)
    }

    /// Archive: moves to the configured mock archive mailbox (or `"Archive"`
    /// as the fallback). Mirrors `SwiftMailClient.archive`'s SPECIAL-USE
    /// resolution so callers can test that the resolved name is used instead
    /// of the old hardcode.
    func archive(uid: Int, from mailbox: String) async throws {
        let archiveMailbox = mockArchiveMailbox ?? "Archive"
        try await move(uid: uid, from: mailbox, to: archiveMailbox)
    }

    func resolveSpecialUseMailboxes() async throws {
        specialUseResolutionCount += 1
        // No-op beyond counting — tests configure the resolved names
        // directly via `mockArchiveMailbox` / `mockTrashMailbox` /
        // `mockSentMailbox` and assert the cache is consulted.
    }
}
