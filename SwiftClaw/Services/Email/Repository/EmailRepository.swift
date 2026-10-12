import Foundation
import SwiftData
import os

/// Result of `EmailRepository.upsertMessages`: which rows were newly inserted,
/// as Sendable summaries so `MailSyncWorker` can carry them off the MainActor
/// (e.g. into new-mail notifications) without touching `Email` models.
nonisolated struct EmailUpsertOutcome: Sendable {
    let inserted: [InsertedEmailSummary]
    /// False when the SwiftData save failed and the batch was rolled back.
    /// `MailSyncWorker` must not advance the mailbox high-water mark past
    /// messages that never reached the store.
    var persisted: Bool = true

    var insertedCount: Int {
        inserted.count
    }
}

nonisolated struct InsertedEmailSummary: Sendable {
    let id: UUID
    let fromDisplay: String
    let subject: String
    let snippet: String
    let isRead: Bool
}

nonisolated struct MailboxReconciliationOutcome: Sendable {
    let removedCount: Int
    let changedFlagCount: Int
}

/// A local read/flag change still waiting for server confirmation, as a
/// Sendable snapshot `MailSyncWorker` can retry off the MainActor.
nonisolated struct PendingFlagSync: Sendable, Hashable {
    let emailID: UUID
    let uid: Int
    let isRead: Bool
    let isFlagged: Bool
}

extension Email {
    /// The IMAP UID this row can be addressed by on the server, or `nil` when
    /// its `uid` is a client-side placeholder: a just-sent echo awaiting the
    /// Sent sync, a message moved to Trash whose destination UID isn't known
    /// yet, or a row whose UID was invalidated by a UIDVALIDITY reset. Server
    /// mutations must go through this so they never address an unrelated
    /// message that happens to own the placeholder number.
    var serverUID: Int? {
        guard !isLocallySynthetic, uid > 0, uid <= Int(UInt32.max) else { return nil }
        return uid
    }
}

/// Single mutation boundary for all Email/SwiftData writes. The first
/// repository abstraction in the codebase — call out new repositories in
/// `AGENTS.md` when introducing them.
///
/// Mutations are MainActor-isolated. Reads intended for the UI go through
/// `@Query` in views; this repository is for sync, flag reconciliation,
/// threading, and review selection.
@MainActor
final class EmailRepository {
    private static let logger = AppLog.make("mail.repository")

    /// Visible to sibling-file extensions of `EmailRepository` (e.g.
    /// `EmailReviewSelection`); not part of the external API.
    let modelContext: ModelContext
    private let attachmentStore: EmailAttachmentStore
    private let saveUpsertChanges: () throws -> Void

    init(
        modelContext: ModelContext,
        attachmentStore: EmailAttachmentStore = .shared,
        saveUpsertChanges: (() throws -> Void)? = nil
    ) {
        self.modelContext = modelContext
        self.attachmentStore = attachmentStore
        self.saveUpsertChanges = saveUpsertChanges ?? { try modelContext.save() }
    }

    // MARK: - Upsert

    /// Inserts new messages and updates flags/bodies for already-known messages.
    /// Returns the newly inserted messages (count + notification-relevant
    /// summaries); updates and reconciliations are not reported.
    /// Metadata-only convenience over `upsertPreparedMessages`: attachment
    /// rows are created with empty file paths and NO bytes are written to
    /// disk. Production sync must go through `EmailAttachmentStore.prepare`
    /// + `upsertPreparedMessages` so attachment I/O stays off the main actor;
    /// this entry point exists for tests and callers without attachment data.
    @discardableResult
    func upsertMessages(
        _ fetched: [FetchedMessage],
        mailbox: String,
        accountID: UUID,
        role: MailFolderRole = .inbox
    ) -> EmailUpsertOutcome {
        let prepared = fetched.map { message in
            PreparedFetchedMessage(
                message: message,
                emailID: UUID(),
                attachments: message.attachmentDescriptors.map { descriptor in
                    PreparedEmailAttachment(
                        filename: descriptor.filename,
                        filePath: "",
                        mimeType: descriptor.mimeType,
                        sizeBytes: descriptor.sizeBytes
                    )
                }
            )
        }
        return upsertPreparedMessages(
            prepared,
            mailbox: mailbox,
            accountID: accountID,
            role: role
        )
    }

    /// `invalidatingExistingUIDs` is for a UIDVALIDITY reset: every UID the
    /// store holds for this folder is dead, so a recycled number must not tie
    /// old content to a different server message. All rows get placeholder
    /// UIDs first; fetched messages then re-key rows by Message-ID or insert,
    /// and rows left unmatched keep a placeholder that the reconcile pass
    /// treats as absent from the server.
    @discardableResult
    func upsertPreparedMessages(
        _ prepared: [PreparedFetchedMessage],
        mailbox: String,
        accountID: UUID,
        role: MailFolderRole = .inbox,
        invalidatingExistingUIDs: Bool = false
    ) -> EmailUpsertOutcome {
        if invalidatingExistingUIDs {
            invalidateUIDs(mailbox: mailbox, accountID: accountID)
        } else if prepared.isEmpty {
            return EmailUpsertOutcome(inserted: [])
        }
        let fetched = prepared.map(\.message)
        var inserted: [InsertedEmailSummary] = []
        let existing = fetchExistingMailboxIndex(uids: fetched.map(\.uid), mailbox: mailbox, accountID: accountID)
        // Fallback dedup for locally-synthetic Sent rows seeded by
        // `upsertSentMessage` before a real Sent-folder sync. Such rows use
        // a client-side uid with no server counterpart, so the UID-based
        // index above won't find them — but their `messageID` matches the
        // real server message. When the real row arrives we rewrite the
        // synthetic row's uid + clear `isLocallySynthetic` instead of
        // inserting a duplicate. See `upsertSentMessage` for the full
        // synthetic-row lifecycle.
        let messageIDsToFetched: [String: FetchedMessage] = {
            var dict: [String: FetchedMessage] = [:]
            for message in fetched {
                guard let mid = message.messageID, !mid.isEmpty else { continue }
                if dict[mid] == nil { dict[mid] = message }
            }
            return dict
        }()
        let existingByMessageID = fetchExistingByMessageID(
            messageIDs: Array(messageIDsToFetched.keys),
            mailbox: mailbox,
            accountID: accountID
        )
        // When syncing a real `\Archive` folder, a message archived from
        // another client has left INBOX (the deletion pass may have already
        // soft-deleted its local row earlier in this very sync). Match it back
        // by `messageID` across mailboxes and reclaim that row as archived,
        // rather than inserting a duplicate Archive copy and leaving a
        // wrongly-trashed INBOX row behind.
        let reclaimable = role == .archive
            ? fetchArchiveReclaimCandidates(
                messageIDs: Array(messageIDsToFetched.keys),
                archiveMailbox: mailbox,
                accountID: accountID
            )
            : [:]

        // A row matches at most one fetched message: rows already matched by
        // UID are off-limits to Message-ID matching, so two server copies
        // sharing a Message-ID don't collapse into one row.
        var matchedRowIDs = Set(existing.values.map(\.id))
        for preparedMessage in prepared {
            let message = preparedMessage.message
            if let existingEmail = existing[message.uid] {
                existingEmail.role = role
                reconcileFlags(existing: existingEmail, fetched: message)
            } else if let mid = message.messageID, !mid.isEmpty,
                      let matched = existingByMessageID[mid],
                      matchedRowIDs.insert(matched.id).inserted {
                // The same message under a UID this row doesn't carry yet:
                // a just-sent echo or a pending move to Trash receiving its
                // real server UID (see `upsertSentMessage` / `delete`), a row
                // re-keyed after a UIDVALIDITY reset, or a message another
                // client moved out of this folder and back. For real rows the
                // server just confirmed membership here, so folder state
                // follows the folder (a reconcile soft-delete must not leave a
                // restored message stuck in Trash). Placeholder rows keep their
                // local state: it reflects the user's own pending action.
                if !matched.isLocallySynthetic, matched.uid != message.uid {
                    matched.isArchived = role == .archive
                    matched.isDeleted = role == .trash
                }
                matched.uid = message.uid
                matched.isLocallySynthetic = false
                matched.role = role
                reconcileFlags(existing: matched, fetched: message)
            } else if let mid = message.messageID, !mid.isEmpty,
                      let reclaimed = reclaimable[mid] {
                // Server-side archive of a message we still hold under INBOX
                // (or had just soft-deleted this pass): move the existing row
                // into the Archive mailbox instead of inserting a second copy.
                reclaimed.uid = message.uid
                reclaimed.mailbox = mailbox
                reclaimed.isArchived = true
                reclaimed.isDeleted = false
                reclaimed.role = role
                reconcileFlags(existing: reclaimed, fetched: message)
            } else {
                let email = insert(
                    prepared: preparedMessage,
                    mailbox: mailbox,
                    accountID: accountID,
                    role: role
                )
                inserted.append(InsertedEmailSummary(
                    id: email.id,
                    fromDisplay: email.displayFromAddress,
                    subject: email.subject,
                    snippet: email.snippet,
                    isRead: email.isRead
                ))
            }
        }

        do {
            try saveUpsertChanges()
        } catch {
            Self.logger.error("upsertMessages save failed: \(String(describing: error))")
            attachmentStore.deletePreparedMessages(prepared)
            modelContext.rollback()
            return EmailUpsertOutcome(inserted: [], persisted: false)
        }

        return EmailUpsertOutcome(inserted: inserted)
    }

    /// Replaces every UID held for `(mailbox, accountID)` with a placeholder
    /// (see `upsertPreparedMessages(invalidatingExistingUIDs:)`). Rows that
    /// already carry a placeholder keep it.
    private func invalidateUIDs(mailbox: String, accountID: UUID) {
        let descriptor = FetchDescriptor<Email>(
            predicate: #Predicate { email in
                email.mailbox == mailbox && email.accountID == accountID
            }
        )
        guard let rows = try? modelContext.fetch(descriptor) else { return }
        var placeholder = min(0, rows.map(\.uid).min() ?? 0)
        for row in rows where row.uid > 0 {
            placeholder -= 1
            row.uid = placeholder
        }
    }

    /// Next placeholder UID for `(mailbox, accountID)`. Placeholders are
    /// negative, so they sit outside the IMAP UID space (1...2^32-1) and can
    /// never collide with a message another client puts in the folder.
    private func nextPlaceholderUID(mailbox: String, accountID: UUID) -> Int {
        let descriptor = FetchDescriptor<Email>(
            predicate: #Predicate { email in
                email.mailbox == mailbox && email.accountID == accountID
            }
        )
        let lowest = (try? modelContext.fetch(descriptor))?.map(\.uid).min() ?? 0
        return min(0, lowest) - 1
    }

    // MARK: - Flags / archive / delete

    func archive(messageID: UUID) {
        guard let email = fetchEmail(by: messageID) else { return }
        email.isArchived = true
        save()
    }

    /// Soft-deletes the row. With `movedToMailbox`, it also refiles the row
    /// under that folder ahead of the server move; the row's UID belonged
    /// to the source folder, so it becomes a placeholder until the
    /// destination sync re-keys the row by Message-ID. Until then
    /// `serverUID` is `nil` and no server action can target it.
    func delete(messageID: UUID, movedToMailbox mailbox: String? = nil) {
        guard let email = fetchEmail(by: messageID) else { return }
        let previousMailbox = email.mailbox
        let previousDeleted = email.isDeleted
        email.isDeleted = true
        if let mailbox, !mailbox.isEmpty, mailbox != email.mailbox {
            email.uid = nextPlaceholderUID(mailbox: mailbox, accountID: email.accountID)
            email.isLocallySynthetic = true
            email.mailbox = mailbox
        }
        Self.logger.info("""
            repository delete emailID=\(email.id.uuidString, privacy: .public) \
            uid=\(email.uid, privacy: .public) \
            mailbox=\(previousMailbox, privacy: .public)->\(email.mailbox, privacy: .public) \
            isDeleted=\(previousDeleted, privacy: .public)->\(email.isDeleted, privacy: .public) \
            threadID=\(String(describing: email.thread?.id), privacy: .public)
            """)
        save()
    }

    /// Undoes `delete(messageID:movedToMailbox:)`'s refile after the server
    /// move failed: the message is still in `mailbox` under `uid`, so the
    /// row gets that real identity back (it stays soft-deleted locally).
    func revertPendingMove(messageID: UUID, toMailbox mailbox: String, uid: Int) {
        guard let email = fetchEmail(by: messageID), email.isLocallySynthetic else { return }
        email.mailbox = mailbox
        email.uid = uid
        email.isLocallySynthetic = false
        save()
    }

    /// Irrecoverable delete: actually removes the row + its `EmailNote`s
    /// (via the cascade rule) + the on-disk attachment bytes from
    /// `EmailAttachmentStore`. Only the Trash mailbox "Delete Permanently"
    /// affordance should call this — the regular `delete` is a recoverable
    /// move to Trash. The server-side expunge happens elsewhere via
    /// `MailClient.deletePermanently(uid:in:)`; this is the local-side half.
    func deletePermanently(messageID: UUID) {
        guard let email = fetchEmail(by: messageID) else { return }
        let emailID = email.id
        // The SwiftData cascade rule only deletes the `EmailAttachment` rows,
        // not the files in `~/Library/Application Support/SwiftClaw/EmailAttachments/`.
        modelContext.delete(email)
        saveThenDeleteAttachments(forEmailIDs: [emailID])
    }

    /// Sets the read state on a message. Used by `EmailThreadDetailView`
    /// when the user opens a thread (latest message marked read).
    func setRead(messageID: UUID, isRead: Bool) {
        guard let email = fetchEmail(by: messageID) else { return }
        guard email.isRead != isRead else { return }
        email.isRead = isRead
        // Mark unsynced so a stale server snapshot can't revert this before
        // `EmailServerAction` confirms the change server-side.
        email.needsFlagSync = true
        save()
    }

    /// Toggles the flag on a message. Returns the new flag state so the
    /// caller can mirror it to the server without re-reading the model.
    @discardableResult
    func toggleFlag(messageID: UUID) -> Bool? {
        guard let email = fetchEmail(by: messageID) else { return nil }
        email.isFlagged.toggle()
        email.needsFlagSync = true
        save()
        return email.isFlagged
    }

    /// Sets the flag state on a message (unlike `toggleFlag`, sets to an
    /// explicit value rather than flipping). Used by the review dispatcher's
    /// `.reply` path which flags + marks read. Returns the new flag state.
    @discardableResult
    func setFlag(messageID: UUID, isFlagged: Bool) -> Bool? {
        guard let email = fetchEmail(by: messageID) else { return nil }
        guard email.isFlagged != isFlagged else { return email.isFlagged }
        email.isFlagged = isFlagged
        email.needsFlagSync = true
        save()
        return email.isFlagged
    }

    /// Clears the pending-flag-sync marker once the server has confirmed
    /// `acknowledged`. Only clears when every acknowledged value still matches
    /// the row: if the user changed it again while the request was in flight,
    /// that newer change is still pending. After this the row is fair game
    /// for `reconcileFlagsFromSnapshot` again.
    func clearFlagSyncPending(messageID: UUID, acknowledging acknowledged: MailFlagUpdate) {
        guard let email = fetchEmail(by: messageID) else { return }
        guard email.needsFlagSync else { return }
        if let isRead = acknowledged.isRead, isRead != email.isRead { return }
        if let isFlagged = acknowledged.isFlagged, isFlagged != email.isFlagged { return }
        email.needsFlagSync = false
        save()
    }

    /// Rows in `(mailbox, accountID)` whose local read/flag state hasn't been
    /// confirmed by the server, for `MailSyncWorker`'s retry pass. Rows
    /// without a server UID are skipped until their identity is known.
    func pendingFlagSyncs(mailbox: String, accountID: UUID) -> [PendingFlagSync] {
        let descriptor = FetchDescriptor<Email>(
            predicate: #Predicate { email in
                email.mailbox == mailbox
                    && email.accountID == accountID
                    && email.needsFlagSync
            }
        )
        return ((try? modelContext.fetch(descriptor)) ?? []).compactMap { email in
            guard let uid = email.serverUID else { return nil }
            return PendingFlagSync(
                emailID: email.id,
                uid: uid,
                isRead: email.isRead,
                isFlagged: email.isFlagged
            )
        }
    }

    // MARK: - Notes

    @discardableResult
    func addNote(emailID: UUID, author: EmailNoteAuthor, content: String) -> EmailNote? {
        guard let email = fetchEmail(by: emailID) else { return nil }
        let note = EmailNote(email: email, author: author, content: content)
        email.notes.append(note)
        save()
        return note
    }

    // MARK: - Threading

    /// Re-clusters messages into account-scoped threads
    /// using an identity-stable, incremental algorithm:
    ///
    /// 1. Snapshot, per message, which `EmailThread` it currently
    ///    belongs to (so `EmailThread.id` survives a re-cluster).
    /// 2. Group messages by `Email.accountID`, then run
    ///    `ThreadResolver.cluster(...)` per account purely for its message
    ///    grouping.
    /// 3. For each cluster, reuse the prior thread that the *most* messages
    ///    in that cluster already belonged to, but only when the prior thread
    ///    is for the same account or has no account yet. A prior thread can be
    ///    claimed by at most one cluster, so old mixed-account threads split:
    ///    one account keeps the old id, the rest get new rows.
    /// 4. Re-attach messages to their canonical account thread by id.
    /// 5. Delete prior threads that are now empty.
    func resolveThreads() {
        resolveThreads(accountIDs: nil)
    }

    /// Sync-time rebuild restricted to the account that received inserts.
    /// The full overload above remains the repair path for legacy stores.
    func resolveThreads(for accountID: UUID) {
        resolveThreads(accountIDs: [accountID])
    }

    private func resolveThreads(accountIDs: Set<UUID>?) {
        let messages: [Email]
        if let accountIDs {
            let descriptor = FetchDescriptor<Email>(
                predicate: #Predicate { accountIDs.contains($0.accountID) }
            )
            messages = (try? modelContext.fetch(descriptor)) ?? []
        } else {
            messages = (try? modelContext.fetch(FetchDescriptor<Email>())) ?? []
        }
        guard !messages.isEmpty else {
            return
        }

        // Snapshot prior thread identity per visible message (keyed by
        // message.id) BEFORE we mutate anything. We use this map to pick
        // the canonical thread for each fresh cluster.
        let priorThreadByMessageID: [UUID: EmailThread] = Dictionary(
            messages.compactMap { message in
                message.thread.map { (message.id, $0) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        // Snapshot before detaching the scoped messages below. A scoped
        // rebuild must not claim a legacy mixed-account thread and relabel
        // messages belonging to an unaffected account.
        let reusableThreadIDs: Set<UUID>? = accountIDs.map { ids in
            Set(priorThreadByMessageID.values.compactMap { thread in
                thread.messages.allSatisfy { ids.contains($0.accountID) } ? thread.id : nil
            })
        }

        // Compute fresh cluster groupings per account. We use
        // `ThreadResolver.cluster` only for its grouping logic; the
        // freshly-allocated `EmailThread` objects it returns are discarded.
        let messagesByAccount = Dictionary(grouping: messages, by: \.accountID)
        let groupings: [ResolvedThreadGrouping] = messagesByAccount
            .keys
            .sorted { $0.uuidString < $1.uuidString }
            .flatMap { accountID -> [ResolvedThreadGrouping] in
                let accountMessages = messagesByAccount[accountID] ?? []
                return ThreadResolver.cluster(accountMessages).map { cluster in
                    ResolvedThreadGrouping(
                        accountID: accountID,
                        messageIDs: cluster.messages.map(\.id),
                        subject: cluster.subjectNormalized,
                        firstDate: cluster.firstDate,
                        lastDate: cluster.lastDate
                    )
                }
            }

        let messagesByID: [UUID: Email] = Dictionary(
            messages.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        // Detach ALL messages from any thread (including the
        // freshly-allocated ones ThreadResolver attached them to). We're
        // about to reassign them deliberately.
        for message in messages {
            message.thread = nil
        }

        // Index still-persisted threads by id so we can look them up to
        // reuse, and track — via `claimedExistingThreadIDs` — which existing
        // thread has already been claimed by a cluster (prevents a split
        // cluster from re-merging onto a previously-claimed thread).
        var existingThreadByID = Dictionary(
            priorThreadByMessageID.values.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        if let accountIDs {
            for accountID in accountIDs {
                let descriptor = FetchDescriptor<EmailThread>(
                    predicate: #Predicate { $0.accountID == accountID }
                )
                (try? modelContext.fetch(descriptor))?.forEach { thread in
                    existingThreadByID[thread.id] = thread
                }
            }
        } else {
            (try? modelContext.fetch(FetchDescriptor<EmailThread>()))?.forEach { thread in
                existingThreadByID[thread.id] = thread
            }
        }
        var claimedExistingThreadIDs: Set<UUID> = []

        // Order clusters by the strength of their prior-thread claim so that
        // when two clusters point at the same prior thread, the one with more
        // of its messages wins the id. The claim strength is computed once per
        // grouping (not inside the sort comparator).
        let orderedGroupings = groupings
            .map { grouping in
                (
                    grouping: grouping,
                    priorCount: bestPriorThreadCandidate(
                        for: grouping,
                        priorThreadByMessageID: priorThreadByMessageID,
                        claimedExistingThreadIDs: [],
                        reusableThreadIDs: reusableThreadIDs
                    )?.count ?? 0
                )
            }
            .sorted { lhs, rhs in
                if lhs.priorCount != rhs.priorCount { return lhs.priorCount > rhs.priorCount }
                if lhs.grouping.accountID != rhs.grouping.accountID {
                    return lhs.grouping.accountID.uuidString < rhs.grouping.accountID.uuidString
                }
                if lhs.grouping.lastDate != rhs.grouping.lastDate {
                    return lhs.grouping.lastDate > rhs.grouping.lastDate
                }
                return lhs.grouping.subject < rhs.grouping.subject
            }
            .map(\.grouping)

        for grouping in orderedGroupings {
            // Pick the prior thread that the largest number of this
            // cluster's messages already belonged to. Only existing
            // same-account or legacy nil-account threads are eligible — a
            // prior thread gets reused for exactly one cluster so identity
            // stays stable and mixed legacy threads split.
            let canonicalID = bestPriorThreadCandidate(
                for: grouping,
                priorThreadByMessageID: priorThreadByMessageID,
                claimedExistingThreadIDs: claimedExistingThreadIDs,
                reusableThreadIDs: reusableThreadIDs
            )?.threadID

            let canonical: EmailThread
            if let canonicalID, let existing = existingThreadByID[canonicalID] {
                canonical = existing
                claimedExistingThreadIDs.insert(canonicalID)
                // Refresh the reused thread to the exact account-local
                // cluster boundary. This also repairs legacy mixed threads
                // whose old date window included another account's messages.
                canonical.accountID = grouping.accountID
                canonical.firstDate = grouping.firstDate
                canonical.lastDate = grouping.lastDate
                canonical.subjectNormalized = grouping.subject
            } else {
                // Genuinely new cluster — none of its messages had a prior
                // thread (or all prior candidates were already claimed).
                let fresh = EmailThread(
                    accountID: grouping.accountID,
                    subjectNormalized: grouping.subject,
                    messages: [],
                    firstDate: grouping.firstDate,
                    lastDate: grouping.lastDate
                )
                modelContext.insert(fresh)
                existingThreadByID[fresh.id] = fresh
                canonical = fresh
            }

            // Re-attach each visible message in the cluster to its canonical thread.
            for mid in grouping.messageIDs {
                if let email = messagesByID[mid] {
                    email.thread = canonical
                }
            }
        }

        // Delete prior threads that are now truly empty.
        for (id, thread) in existingThreadByID where !claimedExistingThreadIDs.contains(id) {
            if thread.messages.isEmpty {
                modelContext.delete(thread)
            }
        }

        save()
    }

    private struct ResolvedThreadGrouping {
        let accountID: UUID
        let messageIDs: [UUID]
        let subject: String
        let firstDate: Date
        let lastDate: Date
    }

    private func bestPriorThreadCandidate(
        for grouping: ResolvedThreadGrouping,
        priorThreadByMessageID: [UUID: EmailThread],
        claimedExistingThreadIDs: Set<UUID>,
        reusableThreadIDs: Set<UUID>? = nil
    ) -> (threadID: UUID, count: Int)? {
        let candidateCount: [UUID: Int] = grouping.messageIDs.reduce(into: [:]) { counts, mid in
            guard let thread = priorThreadByMessageID[mid],
                  !claimedExistingThreadIDs.contains(thread.id) else {
                return
            }
            guard reusableThreadIDs?.contains(thread.id) ?? true,
                  thread.accountID == nil || thread.accountID == grouping.accountID else {
                return
            }
            counts[thread.id, default: 0] += 1
        }

        return candidateCount
            .max { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value < rhs.value }
                return lhs.key.uuidString > rhs.key.uuidString
            }
            .map { (threadID: $0.key, count: $0.value) }
    }

    // MARK: - Fetch helpers

    func fetchEmail(by id: UUID) -> Email? {
        var descriptor = FetchDescriptor<Email>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor))?.first
    }

    // MARK: - Sent-message ingestion

    /// Locally records a just-sent reply so it shows up immediately in the
    /// thread detail (and threads via `In-Reply-To`/`References`) without
    /// waiting for the next Sent-folder sync.
    ///
    /// The row gets a *local-only* negative placeholder uid, outside the
    /// real IMAP UID range, so a message another client appends to Sent can
    /// never be mistaken for it. The `isLocallySynthetic` flag marks the row
    /// as client-seeded; `serverUID` is `nil` until promotion, so no server
    /// action can target it.
    ///
    /// When a real Sent-folder sync lands the matching message (deduped by
    /// `messageID` in `upsertMessages`), the synthetic row is *promoted* —
    /// its `uid` is rewritten to the real server uid + `isLocallySynthetic`
    /// is cleared — so the final state has one row, not two. Sent-mailbox
    /// deletion reconciliation (`reconcileDeletions`) preserves synthetic
    /// rows by skipping any row still flagged `isLocallySynthetic`.
    ///
    /// Idempotent on `OutgoingEmail.messageID`: if a local row already
    /// exists for the same `(accountID, sentMailbox, messageID)` triple the
    /// call is a no-op (handles duplicate Sends and a future re-ingest
    /// after APPEND already wrote a copy).
    @discardableResult
    func upsertSentMessage(
        _ outgoing: OutgoingEmail,
        account: StoredEmailAccount,
        sentMailbox: String
    ) -> Email? {
        if let messageID = outgoing.messageID, !messageID.isEmpty {
            let existing = FetchDescriptor<Email>(
                predicate: #Predicate { email in
                    email.mailbox == sentMailbox
                        && email.accountID == account.id
                        && email.messageID == messageID
                }
            )
            if let already = try? modelContext.fetch(existing), !already.isEmpty {
                return already.first
            }
        }

        let syntheticUID = nextPlaceholderUID(mailbox: sentMailbox, accountID: account.id)

        let sent = Email(
            messageID: outgoing.messageID,
            subject: outgoing.subject,
            fromAddress: outgoing.fromAddress,
            toAddresses: outgoing.toAddresses,
            ccAddresses: outgoing.ccAddresses,
            bccAddresses: outgoing.bccAddresses,
            date: .now,
            receivedAt: .now,
            bodyText: outgoing.bodyText,
            bodyHTML: outgoing.bodyHTML,
            mailbox: sentMailbox,
            role: .sent,
            isRead: true,
            isFlagged: false,
            isArchived: false,
            isDeleted: false,
            inReplyTo: outgoing.inReplyTo,
            referencesRaw: outgoing.references,
            accountID: account.id,
            uid: syntheticUID
        )
        sent.isLocallySynthetic = true
        modelContext.insert(sent)
        resolveThreads()
        return sent
    }

    // MARK: - Deletion + flag reconciliation

    /// Reconciles the local store against the server's current mailbox
    /// membership: soft-deletes (`isDeleted = true`) any local row whose UID
    /// is no longer present on the server. Saves once and returns the count
    /// of rows newly soft-deleted.
    ///
    /// Preserves SwiftClaw-owned metadata by **soft-deleting only** — the
    /// `Email` row, its `EmailNote`s, `EmailThread` linkage, `lastReviewedAt`
    /// stamp, and local-only `isArchived`/`isFlagged` overrides stay intact
    /// on the moved-to-Trash row. The explicit "Delete Permanently"
    /// affordance in the Trash mailbox owns hard-delete; the
    /// `EmailNote` cascade rule means a hard-delete here would destroy
    /// user-authored notes, which is exactly why we don't.
    ///
    /// Rows the user explicitly archived (`isArchived = true`) are NOT
    /// touched — they're already filed out of Inbox and their server-side
    /// absence is expected. Reconciliation only retires rows that are still
    /// active (`!isArchived && !isDeleted`). New mail that just arrived in
    /// this same sync pass is already upserted before this runs, so it's
    /// present in `serverUIDs` and stays active.
    ///
    /// Scope: per `(mailbox, accountID)`. Multi-mailbox sync calls this per
    /// synced mailbox, taking care to skip the locally-synthetic Sent UIDs
    /// that `upsertSentMessage` produces (those won't be in the server set
    /// until the provider's Sent APPEND has landed).
    @discardableResult
    func reconcileDeletions(
        serverUIDs: Set<UInt32>,
        mailbox: String,
        accountID: UUID,
        preserveLocallySynthetic: Bool = false,
        hardDelete: Bool = false
    ) -> Int {
        let descriptor = FetchDescriptor<Email>(
            predicate: #Predicate { email in
                email.mailbox == mailbox
                    && email.accountID == accountID
                    && !email.isArchived
                    && !email.isDeleted
            }
        )
        guard let locals = try? modelContext.fetch(descriptor), !locals.isEmpty else {
            return 0
        }
        var removed = 0
        var hardDeletedIDs: [UUID] = []
        for email in locals {
            if let uid = email.serverUID, serverUIDs.contains(UInt32(uid)) { continue }
            // Skip locally-synthetic Sent rows — they're client-seeded echoes
            // of just-sent replies that the server has no record of yet.
            // The next Sent-folder sync reconciles them by `messageID`
            // (see `upsertSentMessage`). Only the Sent-mailbox pass passes
            // `preserveLocallySynthetic: true`.
            if preserveLocallySynthetic && email.isLocallySynthetic { continue }
            if hardDelete {
                hardDeletedIDs.append(email.id)
                modelContext.delete(email)
            } else {
                email.isDeleted = true
            }
            removed += 1
        }
        if removed > 0 {
            saveThenDeleteAttachments(forEmailIDs: hardDeletedIDs)
        }
        return removed
    }

    /// Refreshes `\Seen`/`\Flagged` on messages that already exist locally
    /// but whose flags changed on the server from another client. Closes the
    /// H2 flag-drift gap: under incremental sync, `reconcileFlags(existing:)`
    /// only fires when a message is *re-fetched* (new mail), so flag changes
    /// on persisting rows stayed stale until the next full mailbox re-fetch.
    /// The `MailboxUIDSet` comes from the same cheap `.uidFlagsOnly` scan the
    /// deletion pass uses — no extra round-trip. Saves once and returns the
    /// count of rows whose flags actually changed.
    @discardableResult
    func reconcileFlagsFromSnapshot(
        _ snapshot: MailboxUIDSet,
        mailbox: String,
        accountID: UUID
    ) -> Int {
        guard !snapshot.flagsByUID.isEmpty else { return 0 }
        // `#Predicate` can't call `UInt32(...)` initializers, so fetch by
        // mailbox+account and filter-by-UID in Swift (small per-call set).
        let descriptor = FetchDescriptor<Email>(
            predicate: #Predicate { email in
                email.mailbox == mailbox
                    && email.accountID == accountID
            }
        )
        guard let locals = try? modelContext.fetch(descriptor), !locals.isEmpty else {
            return 0
        }
        var changed = 0
        for email in locals {
            guard let uid = email.serverUID,
                  let snap = snapshot.flagsByUID[UInt32(uid)] else { continue }
            // Don't clobber a local flag/read change that hasn't synced yet —
            // the snapshot predates it. `EmailServerAction` clears the marker
            // once the server confirms, releasing the row to refresh again.
            if email.needsFlagSync { continue }
            if email.isRead != snap.isRead {
                email.isRead = snap.isRead
                changed += 1
            }
            if email.isFlagged != snap.isFlagged {
                email.isFlagged = snap.isFlagged
                changed += 1
            }
        }
        if changed > 0 {
            save()
        }
        return changed
    }

    /// Applies a UID/flag snapshot with one mailbox fetch, one scan, and one
    /// save. Sync uses this combined boundary so deletion and flag drift do
    /// not independently materialize the same SwiftData rows.
    @discardableResult
    func reconcileMailbox(
        _ snapshot: MailboxUIDSet,
        mailbox: String,
        accountID: UUID,
        preserveLocallySynthetic: Bool = false,
        hardDelete: Bool = false
    ) -> MailboxReconciliationOutcome {
        let descriptor = FetchDescriptor<Email>(
            predicate: #Predicate { email in
                email.mailbox == mailbox && email.accountID == accountID
            }
        )
        guard let locals = try? modelContext.fetch(descriptor), !locals.isEmpty else {
            return MailboxReconciliationOutcome(removedCount: 0, changedFlagCount: 0)
        }

        var removed = 0
        var changed = 0
        var hardDeletedIDs: [UUID] = []
        for email in locals {
            // Placeholder UIDs (see `Email.serverUID`) never match the
            // snapshot: no server flags apply, and the row counts as absent.
            let uid = email.serverUID.map { UInt32($0) }
            if let uid, let flags = snapshot.flagsByUID[uid], !email.needsFlagSync {
                if email.isRead != flags.isRead {
                    email.isRead = flags.isRead
                    changed += 1
                }
                if email.isFlagged != flags.isFlagged {
                    email.isFlagged = flags.isFlagged
                    changed += 1
                }
            }

            guard !(uid.map(snapshot.uids.contains) ?? false),
                  !email.isArchived,
                  !email.isDeleted,
                  !(preserveLocallySynthetic && email.isLocallySynthetic) else {
                continue
            }
            if hardDelete {
                hardDeletedIDs.append(email.id)
                modelContext.delete(email)
            } else {
                email.isDeleted = true
            }
            removed += 1
        }
        if removed > 0 || changed > 0 {
            saveThenDeleteAttachments(forEmailIDs: hardDeletedIDs)
        }
        return MailboxReconciliationOutcome(
            removedCount: removed,
            changedFlagCount: changed
        )
    }

    @discardableResult
    func backfillFolderRolesIfNeeded(
        accounts: [StoredEmailAccount],
        userDefaults: UserDefaults = .standard
    ) -> Int {
        let key = "email.folderRole.backfilled.v1"
        guard !userDefaults.bool(forKey: key) else { return 0 }

        // A failed fetch leaves the flag unset so the backfill retries on the
        // next launch instead of silently never running.
        guard let emails = try? modelContext.fetch(FetchDescriptor<Email>()) else { return 0 }

        let accountsByID = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        var changed = 0
        for email in emails {
            let targetRole = Self.backfillRole(for: email, account: accountsByID[email.accountID])
            if email.role != targetRole {
                email.role = targetRole
                changed += 1
            }
        }
        if changed > 0 {
            save()
        }
        userDefaults.set(true, forKey: key)
        return changed
    }

    // MARK: - Internals

    private static func backfillRole(for email: Email, account: StoredEmailAccount?) -> MailFolderRole {
        if email.isArchived { return .archive }
        if email.isDeleted { return .trash }
        return account?.folderRole(forMailbox: email.mailbox) ?? .inbox
    }

    private func fetchExistingMailboxIndex(uids: [Int], mailbox: String, accountID: UUID) -> [Int: Email] {
        guard !uids.isEmpty else { return [:] }
        // Placeholder rows are excluded: their uid isn't a server UID, so a
        // numeric match would bind them to an unrelated message. They're
        // matched by Message-ID instead.
        let descriptor = FetchDescriptor<Email>(
            predicate: #Predicate { email in
                email.mailbox == mailbox
                    && uids.contains(email.uid)
                    && email.accountID == accountID
                    && !email.isLocallySynthetic
            }
        )
        guard let results = try? modelContext.fetch(descriptor) else {
            return [:]
        }
        return Dictionary(results.map { ($0.uid, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Indexes existing rows by `messageID` for a single `(mailbox, accountID)`.
    /// Used by `upsertMessages`'s synthetic-row promotion path — see
    /// `upsertSentMessage` for the full lifecycle.
    private func fetchExistingByMessageID(
        messageIDs: [String],
        mailbox: String,
        accountID: UUID
    ) -> [String: Email] {
        guard !messageIDs.isEmpty else { return [:] }
        // Fetch the mailbox+account slice; `#Predicate` can't call
        // `UInt32(...)` initializers or thread `?? ""` through `contains`,
        // so filter by `messageID` in Swift (small per-call Sent slice).
        let descriptor = FetchDescriptor<Email>(
            predicate: #Predicate { email in
                email.mailbox == mailbox
                    && email.accountID == accountID
            }
        )
        guard let results = try? modelContext.fetch(descriptor) else {
            return [:]
        }
        let messageIDSet = Set(messageIDs)
        // First-wins on duplicate messageIDs (the synthetic-then-real
        // transition is the only expected duplicate; preferring either is
        // fine since the caller rewrites the synthetic's uid + marker).
        return Dictionary(
            results.compactMap { email in
                guard let mid = email.messageID, !mid.isEmpty, messageIDSet.contains(mid) else {
                    return nil
                }
                return (mid, email)
            },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// Indexes rows that a server-side archive should reclaim: an active INBOX
    /// row (or one the deletion pass just soft-deleted this sync) that shares a
    /// `messageID` with a message now arriving in the Archive folder. Scoped to
    /// one account and keyed by `messageID`. Excludes locally-synthetic Sent
    /// echoes and anything already filed in the Archive mailbox, so only a
    /// genuine "left INBOX → now in Archive" move reclaims its row.
    private func fetchArchiveReclaimCandidates(
        messageIDs: [String],
        archiveMailbox: String,
        accountID: UUID
    ) -> [String: Email] {
        guard !messageIDs.isEmpty else { return [:] }
        // `#Predicate` can't thread `messageID ?? ""` through `contains`, so
        // narrow to the account's INBOX + soft-deleted rows and match the
        // `messageID` in Swift (a small per-call set).
        let descriptor = FetchDescriptor<Email>(
            predicate: #Predicate { email in
                email.accountID == accountID
                    && email.mailbox != archiveMailbox
                    && !email.isLocallySynthetic
                    && (email.mailbox == "INBOX" || email.isDeleted)
            }
        )
        guard let results = try? modelContext.fetch(descriptor) else {
            return [:]
        }
        let messageIDSet = Set(messageIDs)
        return Dictionary(
            results.compactMap { email in
                guard let mid = email.messageID, !mid.isEmpty, messageIDSet.contains(mid) else {
                    return nil
                }
                return (mid, email)
            },
            uniquingKeysWith: { first, _ in first }
        )
    }

    @discardableResult
    private func insert(
        prepared: PreparedFetchedMessage,
        mailbox: String,
        accountID: UUID,
        role: MailFolderRole
    ) -> Email {
        let message = prepared.message
        let email = Email(
            id: prepared.emailID,
            messageID: message.messageID,
            subject: message.subject,
            fromAddress: EmailAddressDisplayFormatter.string(message.fromAddress),
            toAddresses: message.toAddresses.map(EmailAddressDisplayFormatter.string),
            ccAddresses: message.ccAddresses.map(EmailAddressDisplayFormatter.string),
            bccAddresses: message.bccAddresses.map(EmailAddressDisplayFormatter.string),
            date: message.date,
            receivedAt: message.internalDate ?? message.date,
            bodyText: message.bodyText,
            bodyHTML: message.bodyHTML,
            mailbox: mailbox,
            role: role,
            isRead: message.isRead,
            isFlagged: message.isFlagged,
            isArchived: role == .archive,
            isDeleted: role == .trash,
            inReplyTo: message.inReplyTo,
            referencesRaw: message.references,
            accountID: accountID,
            uid: message.uid
        )

        for descriptor in prepared.attachments {
            let attachment = EmailAttachment(
                filename: descriptor.filename,
                filePath: descriptor.filePath,
                mimeType: descriptor.mimeType,
                sizeBytes: descriptor.sizeBytes
            )
            attachment.email = email
            email.attachments.append(attachment)
        }

        modelContext.insert(email)
        return email
    }

    private func reconcileFlags(existing: Email, fetched: FetchedMessage) {
        // Skip rows with a pending local flag/read mutation the server hasn't
        // confirmed yet — the same protection `reconcileFlagsFromSnapshot`
        // applies. Without this, a UIDVALIDITY-reset refetch that reuses a UID
        // would clobber an unsynced local flag change with stale server state
        // (rather than letting `EmailServerAction` confirm the local mutation
        // server-side first and clear the flag).
        if existing.needsFlagSync {
            return
        }
        existing.fromAddress = EmailAddressDisplayFormatter.string(fetched.fromAddress)
        existing.toAddresses = fetched.toAddresses.map(EmailAddressDisplayFormatter.string)
        existing.ccAddresses = fetched.ccAddresses.map(EmailAddressDisplayFormatter.string)
        existing.bccAddresses = fetched.bccAddresses.map(EmailAddressDisplayFormatter.string)
        existing.isRead = fetched.isRead
        existing.isFlagged = fetched.isFlagged
        // Refresh body in case server-side edits happened.
        if existing.bodyText.isEmpty, !fetched.bodyText.isEmpty {
            existing.bodyText = fetched.bodyText
        }
        if existing.bodyHTML == nil, let html = fetched.bodyHTML {
            existing.bodyHTML = html
        }
    }

    /// Saves, then removes the on-disk attachment directories of rows that
    /// were hard-deleted in this transaction. Files are only removed once the
    /// rows are durably gone, so a failed save never leaves a row pointing at
    /// missing attachments.
    private func saveThenDeleteAttachments(forEmailIDs emailIDs: [UUID]) {
        do {
            try modelContext.save()
        } catch {
            Self.logger.error("EmailRepository save failed: \(String(describing: error))")
            return
        }
        for emailID in emailIDs {
            attachmentStore.deleteAttachments(forEmailID: emailID)
        }
    }

    /// Persists the current `ModelContext`. Visible to sibling-file
    /// extensions of `EmailRepository` (e.g. `EmailReviewSelection`); callers
    /// outside `EmailRepository` should still go through the higher-level
    /// mutation methods to keep transaction boundaries in one place.
    func save() {
        do {
            try modelContext.save()
        } catch {
            Self.logger.error("EmailRepository save failed: \(String(describing: error))")
        }
    }
}
